#!/usr/local/bin/python3
"""Experimental isolated publisher. No writes to native Poudriere directories."""
# Version: 1.19.0
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG = Path("/usr/local/etc/poudriere-progressive.json")
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+@,-]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
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

def check_manifest(m):
    if not isinstance(m, dict):
        raise ValueError("Invalid manifest")
    for key in ("name","version","origin"):
        if not isinstance(m.get(key), str) or not m[key]:
            raise ValueError("Missing manifest field: " + key)
    if not isinstance(m.get("deps", {}), dict):
        raise ValueError("Invalid dependency manifest")
    for key in ("shlibs_required","shlibs_provided"):
        if not isinstance(m.get(key, []), list):
            raise ValueError("Invalid shared library manifest")
    return m

def manifest(path):
    # The compact manifest is JSON in pkg archives. Fail closed on any mismatch.
    raw = subprocess.check_output([TAR, "-xOf", str(path), "+COMPACT_MANIFEST"])
    return check_manifest(json.loads(raw))

def cached_manifest(root, checksum, obj):
    # Objects are content addressed, so a manifest extracted once per checksum
    # stays valid. This avoids running tar on every package every run.
    store = root / "manifests"
    store.mkdir(exist_ok=True, mode=0o755)
    path = store / (checksum + ".json")
    if path.is_file():
        try:
            return check_manifest(json.loads(path.read_text()))
        except ValueError:
            path.unlink()
    m = manifest(obj)
    atomic_json(path, m)
    return m

def abi(m):
    value = m.get("abi") or m.get("arch")
    if not isinstance(value, str) or not value:
        raise ValueError("Missing ABI")
    return value

UNVERSIONED = (None, "", "(null)")

def dependency_ok(spec, other):
    # A dependency is satisfied when the package exists, the origin matches
    # (when recorded) and the version matches exactly. Packages built with
    # PKG_NO_VERSION_FOR_DEPS=yes record no version for their dependencies;
    # those are matched by name and origin only, and binary compatibility is
    # then left to the shared library checks below.
    if not other or not isinstance(spec, dict):
        return False
    if spec.get("origin") and other[0]["origin"] != spec["origin"]:
        return False
    version = spec.get("version")
    return version in UNVERSIONED or other[0]["version"] == version

def violations(packages, base_external):
    # Exact version checks are intentionally conservative; not a full pkg solver.
    supplied = {lib for m, _ in packages.values() for lib in m.get("shlibs_provided", [])}
    errors = []
    for name, (m, _) in packages.items():
        for dep, spec in m.get("deps", {}).items():
            if not dependency_ok(spec, packages.get(dep)):
                errors.append(name + ": dependency " + dep)
        for lib in m.get("shlibs_required", []):
            # Permit only requirements already external for this same package.
            if lib not in supplied and lib not in base_external.get(name, set()):
                errors.append(name + ": library " + lib)
    return errors

def external(packages):
    supplied = {lib for m, _ in packages.values() for lib in m.get("shlibs_provided", [])}
    return {n:set(m.get("shlibs_required", []))-supplied for n,(m,_) in packages.items()}

def check_space(cfg, root, needed=0):
    if shutil.disk_usage(root).free - needed < int(cfg.get("min_free_gib",20))*1024**3:
        raise RuntimeError("Minimum free space threshold reached")

def stat_key(st):
    return "%d:%d" % (st.st_dev, st.st_ino)

def load_index(root):
    # Index of package files already hashed: "dev:inode" -> size, mtime, sha256.
    path = root / "index.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}

def import_pkg(cfg, root, source, index, seen):
    # Bring a package into the private content-addressed object store.
    #
    # Fast path: a file already hashed in a previous run (same inode, size and
    # mtime) whose object still exists is reused without reading it again.
    #
    # Slow path: hard link the file to a private temporary name first and hash
    # that inode, so a rename of the source during the scan cannot mix two
    # files. Poudriere never rewrites package files in place (its own shadow
    # .building tree is a hard link clone), so sharing the inode is safe and
    # costs no disk space. Across file systems the file is copied instead and
    # hashed before and after to reject a file that changed while copying.
    if not source.is_file() or source.is_symlink():
        raise ValueError("Expected regular package file")
    store = root / "objects"
    store.mkdir(exist_ok=True, mode=0o755)
    st = source.stat()
    key = stat_key(st)
    entry = index.get(key)
    if (isinstance(entry, dict) and entry.get("size") == st.st_size and
            entry.get("mtime_ns") == st.st_mtime_ns and
            SHA256.fullmatch(str(entry.get("sha256", "")))):
        dst = store / (entry["sha256"] + ".pkg")
        if dst.is_file() and dst.stat().st_size == st.st_size:
            seen[key] = entry
            return cached_manifest(root, entry["sha256"], dst), dst
    tmp = store / (".import-%d-%s" % (os.getpid(), secrets.token_hex(8)))
    try:
        try:
            os.link(source, tmp)
            copied = False
        except OSError as exc:
            if exc.errno not in (errno.EXDEV, errno.EPERM, errno.EMLINK):
                raise
            check_space(cfg, root, st.st_size)
            shutil.copyfile(source, tmp)
            os.chmod(tmp, 0o444)
            copied = True
        checksum = digest(tmp)
        if copied and digest(source) != checksum:
            raise RuntimeError("Package changed while copying")
        dst = store / (checksum + ".pkg")
        if not dst.exists():
            os.rename(tmp, dst)
    finally:
        if os.path.lexists(tmp):
            os.unlink(tmp)
    after = source.stat()
    if (stat_key(after) == key and after.st_size == st.st_size and
            after.st_mtime_ns == st.st_mtime_ns):
        seen[key] = {"size": st.st_size, "mtime_ns": st.st_mtime_ns,
                     "sha256": checksum}
    return cached_manifest(root, checksum, dst), dst

def read_native(cfg, native, root, index, seen):
    generation = (native / ".latest").resolve(strict=True)
    if generation.parent != native or not generation.name.startswith(".real_"):
        raise ValueError("Unexpected native repository generation")
    packages = {}
    for path in sorted((generation / "All").glob("*.pkg")):
        m, obj = import_pkg(cfg, root, path, index, seen)
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

def build_in_progress(native):
    marker = native / ".building" / ".buildname"
    try:
        return marker.read_text().strip()
    except OSError:
        return ""

def prune(cfg, root, active_build):
    # Retention, enabled by default; set "retention": {"enabled": false} to
    # keep everything. Never removes the current generation, the newest
    # keep_generations ones, or anything younger than min_age_hours (clients
    # of the laboratory may still be downloading from it).
    policy = cfg.get("retention", {})
    if not policy.get("enabled", True):
        return
    keep = int(policy.get("keep_generations", 5))
    min_age = float(policy.get("min_age_hours", 24)) * 3600
    event_age = float(policy.get("event_days", 7)) * 86400
    stale_tmp = 3600
    now = time.time()
    generations = root / "generations"
    current = root / "current"
    current_name = current.resolve().name if current.is_symlink() else None
    if generations.is_dir():
        finished = [p for p in generations.iterdir()
                    if SHA256.fullmatch(p.name) and p.is_dir() and not p.is_symlink()]
        finished.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        protected = {p.name for p in finished[:keep]}
        protected.add(current_name)
        for path in finished:
            if path.name in protected or now - path.stat().st_mtime < min_age:
                continue
            shutil.rmtree(path)
            print("Removed old generation " + path.name)
        for path in generations.glob(".stage-*"):
            if path.is_dir() and not path.is_symlink() and now - path.stat().st_mtime > stale_tmp:
                shutil.rmtree(path)
        referenced = set()
        for path in generations.iterdir():
            if path.is_dir() and not path.is_symlink():
                referenced.update(f.name for f in (path / "All").glob("*.pkg"))
    else:
        referenced = set()
    objects = root / "objects"
    if objects.is_dir():
        for path in objects.iterdir():
            st = path.lstat()
            # ctime changes when a hard link is added, so it marks when the
            # object entered the store even if the package file is old.
            age = now - st.st_ctime
            if path.name.startswith("."):
                if age > stale_tmp:
                    path.unlink()
            elif path.name.endswith(".pkg") and path.name not in referenced and age > stale_tmp:
                path.unlink()
    manifests = root / "manifests"
    if manifests.is_dir():
        for path in manifests.glob("*.json"):
            if not (objects / (path.stem + ".pkg")).exists():
                path.unlink()
    events = root / "events"
    if events.is_dir():
        for path in events.iterdir():
            if (path.is_dir() and not path.is_symlink() and path.name != active_build
                    and now - path.stat().st_mtime > event_age):
                shutil.rmtree(path)

def worker(cfg, master):
    native, root = roots(cfg, master)
    root.mkdir(parents=True, exist_ok=True, mode=0o755)
    with (root / ".worker.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        check_space(cfg, root)
        index = load_index(root)
        seen = {}
        generation, base = read_native(cfg, native, root, index, seen)
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
                        m,obj = import_pkg(cfg, root, source, index, seen)
                        if m["name"] + "-" + m["version"] != evt["pkgname"]:
                            raise ValueError("Package name mismatch")
                        candidates.append((m,obj))
                if not marker.is_file() or marker.read_text().strip() != build:
                    raise RuntimeError("Shadow generation switched; retry")
        # Save the hash index before the selection, so a run that fails
        # closed below still spares the next run from hashing again. Only
        # entries for files seen in this run are kept; the index stays small.
        atomic_json(root / "index.json", seen)
        selected = choose(base, candidates)
        if (native / ".latest").resolve(strict=True) != generation:
            raise RuntimeError("Native generation switched; retry")
        publish(cfg, root, selected)
        prune(cfg, root, build_in_progress(native))

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
