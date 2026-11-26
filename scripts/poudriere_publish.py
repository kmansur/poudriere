#!/usr/local/bin/python3
"""Experimental isolated publisher. No writes to native Poudriere directories."""
# Version: 1.19.0-beta.1
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG = Path("/usr/local/etc/poudriere-progressive.json")
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+@,-]*$")
PKG = "/usr/local/sbin/pkg"
TAR = "/usr/bin/tar"

def token(value):
    if not SAFE.fullmatch(value):
        raise ValueError("Invalid identifier")
    return value

def load_config():
    if not CONFIG.exists():
        return {"enabled": False}
    if CONFIG.stat().st_uid != 0 or CONFIG.stat().st_mode & 0o022:
        raise ValueError("Configuration must be root-owned and not group/world writable")
    return json.loads(CONFIG.read_text())

def atomic_json(path, obj):
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".event-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(obj, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def roots(cfg, master):
    token(master)
    if master not in cfg["masters"]:
        raise ValueError("Master not enabled")
    native = Path(cfg["native_root"]).resolve() / master
    root = Path(cfg["state_root"]).resolve() / master
    if root.is_relative_to(native.parent) or native.is_relative_to(root):
        raise ValueError("Native and progressive paths must be disjoint")
    return native, root

def event(cfg, hook, args):
    # Hooks must be short and must not run pkg repo or copy package files.
    master = os.environ.get("MASTERNAME", "")
    if master not in cfg["masters"] or not args:
        return
    kind = args[0]
    if (hook, kind) not in {("bulk","start"), ("bulk","done"),
                           ("bulk","crashed"), ("pkgbuild","success"),
                           ("pkgrepo","publish")}:
        return
    native, root = roots(cfg, master)
    build = token(os.environ["BUILDNAME"])
    pkgname = token(args[2]) if hook == "pkgbuild" else ""
    if hook == "pkgbuild":
        # PACKAGES must point at the shadow tree for atomic builds.
        if Path(os.environ["PACKAGES"]).resolve() != (native / ".building").resolve():
            raise ValueError("Unexpected package build directory")
    queue = root / "events" / build
    queue.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_json(queue / (hook + "-" + kind + ("-" + pkgname if pkgname else "") + ".json"),
                {"hook":hook,"kind":kind,"pkgname":pkgname,"build":build,
                 "time":time.time()})

def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def manifest(path):
    # The compact manifest is JSON in pkg archives. Fail closed on any mismatch.
    raw = subprocess.check_output([TAR, "-xOf", str(path), "+COMPACT_MANIFEST"])
    m = json.loads(raw)
    for key in ("name","version","origin"):
        if not isinstance(m.get(key), str) or not m[key]:
            raise ValueError("Missing manifest field: " + key)
    if not isinstance(m.get("deps", {}), dict):
        raise ValueError("Invalid dependency manifest")
    for key in ("shlibs_required","shlibs_provided"):
        if not isinstance(m.get(key, []), list):
            raise ValueError("Invalid shared library manifest")
    return m

def abi(m):
    value = m.get("abi") or m.get("arch")
    if not isinstance(value, str) or not value:
        raise ValueError("Missing ABI")
    return value

def violations(packages, base_external):
    # Exact version checks are intentionally conservative; not a full pkg solver.
    supplied = {lib for m, _ in packages.values() for lib in m.get("shlibs_provided", [])}
    errors = []
    for name, (m, _) in packages.items():
        for dep, spec in m.get("deps", {}).items():
            other = packages.get(dep)
            if not other or not isinstance(spec, dict) or (
                other[0]["version"] != spec.get("version") or
                (spec.get("origin") and other[0]["origin"] != spec["origin"])
            ):
                errors.append(name + ": dependency " + dep)
        for lib in m.get("shlibs_required", []):
            # Permit only requirements already external for this same package.
            if lib not in supplied and lib not in base_external.get(name, set()):
                errors.append(name + ": library " + lib)
    return errors

def external(packages):
    supplied = {lib for m, _ in packages.values() for lib in m.get("shlibs_provided", [])}
    return {n:set(m.get("shlibs_required", []))-supplied for n,(m,_) in packages.items()}

def check_space(cfg, root):
    if shutil.disk_usage(root).free < int(cfg.get("min_free_gib",20))*1024**3:
        raise RuntimeError("Minimum free space threshold reached")

def import_pkg(cfg, root, source):
    # Copy once into a private immutable-by-policy object store; never hardlink
    # directly to native packages. Hash before and after to reject changing files.
    if not source.is_file() or source.is_symlink():
        raise ValueError("Expected regular package file")
    check_space(cfg, root)
    checksum = digest(source)
    store = root / "objects"
    store.mkdir(exist_ok=True, mode=0o755)
    dst = store / (checksum + ".pkg")
    if not dst.exists():
        if shutil.disk_usage(root).free - source.stat().st_size < int(cfg.get("min_free_gib",20))*1024**3:
            raise RuntimeError("Package copy would breach free space threshold")
        fd, tmp = tempfile.mkstemp(dir=store, prefix=".copy-")
        os.close(fd)
        try:
            shutil.copyfile(source, tmp)
            if digest(Path(tmp)) != checksum or digest(source) != checksum:
                raise RuntimeError("Package changed while copying")
            os.chmod(tmp, 0o444)
            os.replace(tmp, dst)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    if digest(dst) != checksum:
        raise RuntimeError("Object checksum mismatch")
    return manifest(dst), dst

def read_native(cfg, native, root):
    generation = (native / ".latest").resolve(strict=True)
    if generation.parent != native or not generation.name.startswith(".real_"):
        raise ValueError("Unexpected native repository generation")
    packages = {}
    for path in sorted((generation / "All").glob("*.pkg")):
        m, obj = import_pkg(cfg, root, path)
        if m["name"] in packages:
            raise ValueError("Duplicate package name in native catalogue")
        packages[m["name"]] = (m,obj)
    if not packages:
        raise ValueError("Empty native repository")
    if (native / ".latest").resolve(strict=True) != generation:
        raise RuntimeError("Native generation switched during scan; retry")
    return generation, packages

def choose(base, candidates):
    base_abis = {abi(m) for m,_ in base.values()}
    if len(base_abis) != 1:
        raise ValueError("Mixed baseline ABI")
    allowed = external(base)
    if violations(base, allowed):
        raise ValueError("Native baseline fails conservative dependency checks")
    pending = {}
    for m,obj in candidates:
        if abi(m) not in base_abis:
            continue
        old = base.get(m["name"])
        if old and old[0]["origin"] != m["origin"]:
            continue
        pending[m["name"]] = (m,obj)
    trial = dict(base, **pending)
    if not violations(trial, allowed):
        return trial
    # Try independently compatible updates; defer all unresolved groups.
    accepted = dict(base)
    changed = True
    while changed:
        changed = False
        for name in sorted(list(pending)):
            trial = dict(accepted)
            trial[name] = pending[name]
            if not violations(trial, allowed):
                accepted = trial
                del pending[name]
                changed = True
    return accepted

def publish(cfg, root, packages):
    generations = root / "generations"
    generations.mkdir(exist_ok=True, mode=0o755)
    key = Path(cfg["signing_key"]).resolve(strict=True)
    if key.is_relative_to(root) or key.stat().st_uid != 0 or key.stat().st_mode & 0o077:
        raise ValueError("Signing key must be private and outside published tree")
    fingerprint = hashlib.sha256("\n".join(sorted(obj.name for _,obj in packages.values())).encode()).hexdigest()
    current = root / "current"
    if current.is_symlink() and current.resolve().name == fingerprint:
        return
    final = generations / fingerprint
    if not final.exists():
        stage = Path(tempfile.mkdtemp(dir=generations, prefix=".stage-"))
        try:
            all_dir = stage / "All"
            all_dir.mkdir()
            for _,obj in packages.values():
                # Links only between private immutable objects and staging.
                os.link(obj, all_dir / obj.name)
            check_space(cfg, root)
            subprocess.run([PKG, "repo", str(stage), "rsa:" + str(key)], check=True)
            for name in ("meta.conf","data.pkg","packagesite.pkg"):
                if not (stage / name).is_file():
                    raise RuntimeError("Missing signed catalogue component: " + name)
            os.chmod(stage, 0o755)
            os.rename(stage, final)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    # Atomic pointer update. Never touch the native .latest symlink.
    link = root / (".current-" + str(os.getpid()))
    try:
        link.symlink_to(Path("generations") / fingerprint)
        os.replace(link, current)
    finally:
        if link.is_symlink():
            link.unlink()
    print("Published experimental generation " + str(final))

def worker(cfg, master):
    native, root = roots(cfg, master)
    root.mkdir(parents=True, exist_ok=True, mode=0o755)
    with (root / ".worker.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        check_space(cfg, root)
        generation, base = read_native(cfg, native, root)
        candidates = []
        queues = root / "events"
        # Only use events belonging to the current shadow build. A stale queue
        # or a completed/crashed build cannot supply unpublished packages.
        shadow = native / ".building"
        marker = shadow / ".buildname"
        if marker.is_file():
            build = token(marker.read_text().strip())
            queue = queues / build
            if (queue / "bulk-start.json").is_file() and not any(
                (queue / x).exists() for x in ("bulk-done.json","bulk-crashed.json","pkgrepo-publish.json")
            ):
                for path in sorted(queue.glob("pkgbuild-success-*.json")):
                    evt = json.loads(path.read_text())
                    source = shadow / "All" / (token(evt["pkgname"]) + ".pkg")
                    if source.is_file():
                        m,obj = import_pkg(cfg, root, source)
                        if m["name"] + "-" + m["version"] != evt["pkgname"]:
                            raise ValueError("Package name mismatch")
                        candidates.append((m,obj))
                if not marker.is_file() or marker.read_text().strip() != build:
                    raise RuntimeError("Shadow generation switched; retry")
        selected = choose(base, candidates)
        if (native / ".latest").resolve(strict=True) != generation:
            raise RuntimeError("Native generation switched; retry")
        publish(cfg, root, selected)

def main():
    cfg = load_config()
    if not cfg.get("enabled", False):
        return 0
    if len(sys.argv) >= 4 and sys.argv[1] == "event":
        event(cfg, sys.argv[2], sys.argv[3:])
    elif sys.argv[1:] == ["publish"]:
        failed = False
        for master in cfg["masters"]:
            try:
                worker(cfg, master)
            except Exception as exc:
                print(master + ": " + str(exc), file=sys.stderr)
                failed = True
        return int(failed)
    else:
        raise ValueError("Usage: poudriere_publish.py publish")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("poudriere-progressive: " + str(exc), file=sys.stderr)
        sys.exit(1)
