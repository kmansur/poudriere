#!/usr/bin/env python3
# Version: 1.19.0-beta.2
# Unit tests for the experimental publisher. They run anywhere with Python
# 3.11+: tar, pkg and the native Poudriere tree are replaced by fakes.
import errno
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock
spec = importlib.util.spec_from_file_location("publisher", Path(__file__).resolve().parents[1]/"scripts"/"poudriere_publish.py")
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
def package(name, version, deps=None, provides=None, requires=None, arch="FreeBSD:14:amd64"):
    return (dict(name=name, version=version, origin="test/"+name, abi=arch,
                 deps=deps or {}, shlibs_provided=provides or [], shlibs_required=requires or []),
            Path(name+"-"+version+".pkg"))
class Selection(unittest.TestCase):
    def test_independent(self):
        base={"a":package("a","1")}
        self.assertEqual(p.choose(base,[package("a","2")])["a"][0]["version"],"2")
    def test_reverse_dependency(self):
        base={"lib":package("lib","1",provides=["lib.so.1"]),
              "app":package("app","1",{"lib":{"version":"1"}},requires=["lib.so.1"])}
        self.assertEqual(p.choose(base,[package("lib","2",provides=["lib.so.2"])])["lib"][0]["version"],"1")
    def test_coherent_group(self):
        base={"lib":package("lib","1"),"app":package("app","1",{"lib":{"version":"1"}})}
        result=p.choose(base,[package("lib","2"),package("app","2",{"lib":{"version":"2"}})])
        self.assertEqual(result["lib"][0]["version"],"2")
    def test_wrong_abi(self):
        base={"a":package("a","1")}
        self.assertEqual(p.choose(base,[package("a","2",arch="FreeBSD:15:amd64")])["a"][0]["version"],"1")
    def test_new_unknown_library(self):
        base={"a":package("a","1")}
        self.assertNotIn("b",p.choose(base,[package("b","1",requires=["unknown.so"])]))
    def test_invalid_baseline(self):
        with self.assertRaises(ValueError):
            p.choose({"a":package("a","1",{"missing":{"version":"1"}})},[])
    def test_unversioned_baseline(self):
        # PKG_NO_VERSION_FOR_DEPS=yes: dependencies carry no version.
        for spec in ({"origin":"test/lib"}, {"origin":"test/lib","version":""},
                     {"origin":"test/lib","version":"(null)"}):
            base={"lib":package("lib","1"),"app":package("app","1",{"lib":spec})}
            self.assertEqual(p.choose(base,[])["app"][0]["version"],"1")
    def test_unversioned_update(self):
        base={"lib":package("lib","1",provides=["lib.so.1"]),
              "app":package("app","1",{"lib":{"origin":"test/lib"}},requires=["lib.so.1"])}
        same_abi=p.choose(base,[package("lib","1_1",provides=["lib.so.1"])])
        self.assertEqual(same_abi["lib"][0]["version"],"1_1")
        new_abi=p.choose(base,[package("lib","2",provides=["lib.so.2"])])
        self.assertEqual(new_abi["lib"][0]["version"],"1")
    def test_unversioned_wrong_origin(self):
        base={"lib":package("lib","1"),"app":package("app","1",{"lib":{"origin":"other/lib"}})}
        with self.assertRaises(ValueError):
            p.choose(base,[])

def fake_manifest(path):
    # Test packages hold their manifest as plain JSON instead of a tar archive.
    return p.check_manifest(json.loads(Path(path).read_text()))

def write_pkg(path, name, version):
    path.write_text(json.dumps(dict(name=name, version=version, origin="test/"+name,
                                    abi="FreeBSD:14:amd64", deps={})))

class Store(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.native = self.dir / "native"
        self.native.mkdir()
        self.root = self.dir / "state"
        self.root.mkdir()
        self.cfg = {"min_free_gib": 0}
        patcher = mock.patch.object(p, "manifest", side_effect=fake_manifest)
        self.manifest = patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)
    def test_hard_link_and_cache(self):
        src = self.native / "a-1.pkg"
        write_pkg(src, "a", "1")
        index, seen = {}, {}
        m, obj = p.import_pkg(self.cfg, self.root, src, index, seen)
        self.assertEqual(m["name"], "a")
        self.assertEqual(obj.stat().st_ino, src.stat().st_ino)
        self.assertEqual(len(seen), 1)
        # Second run: nothing is hashed and tar is not called again.
        with mock.patch.object(p, "digest", side_effect=AssertionError("rehashed")):
            seen2 = {}
            m2, obj2 = p.import_pkg(self.cfg, self.root, src, seen, seen2)
        self.assertEqual(obj2, obj)
        self.assertEqual(seen2, seen)
        self.assertEqual(self.manifest.call_count, 1)
    def test_changed_file_is_rehashed(self):
        src = self.native / "a-1.pkg"
        write_pkg(src, "a", "1")
        seen = {}
        _, first = p.import_pkg(self.cfg, self.root, src, {}, seen)
        src.unlink()
        write_pkg(src, "a", "2")
        _, second = p.import_pkg(self.cfg, self.root, src, seen, {})
        self.assertNotEqual(first.name, second.name)
    def test_copy_across_file_systems(self):
        src = self.native / "a-1.pkg"
        write_pkg(src, "a", "1")
        with mock.patch.object(p.os, "link", side_effect=OSError(errno.EXDEV, "cross-device")):
            _, obj = p.import_pkg(self.cfg, self.root, src, {}, {})
        self.assertNotEqual(obj.stat().st_ino, src.stat().st_ino)
        self.assertEqual(obj.stat().st_mode & 0o777, 0o444)
        self.assertFalse(list((self.root / "objects").glob(".import-*")))
    def test_prune(self):
        gens = self.root / "generations"
        objects = self.root / "objects"
        gens.mkdir(); objects.mkdir()
        names = []
        for i in range(4):
            name = ("%x" % i) * 64
            name = name[:64]
            obj = objects / ("%064x.pkg" % i)
            obj.write_text("x")
            (gens / name / "All").mkdir(parents=True)
            os.link(obj, gens / name / "All" / obj.name)
            old = time.time() - 86400 * 10 + i
            os.utime(gens / name, (old, old))
            names.append(name)
        (objects / ("f" * 64 + ".pkg")).write_text("orphan")
        (self.root / "current").symlink_to(Path("generations") / names[0])
        events = self.root / "events"
        (events / "old").mkdir(parents=True)
        (events / "active").mkdir()
        old = time.time() - 86400 * 30
        os.utime(events / "old", (old, old)); os.utime(events / "active", (old, old))
        cfg = {"retention": {"keep_generations": 1, "min_age_hours": 24, "event_days": 7}}
        with mock.patch.object(p.time, "time", return_value=time.time() + 7200):
            p.prune(cfg, self.root, "active")
        left = sorted(x.name for x in gens.iterdir())
        # Current (oldest) and the newest one stay; the two in between go.
        self.assertEqual(left, sorted([names[0], names[3]]))
        self.assertFalse((objects / ("f" * 64 + ".pkg")).exists())
        self.assertFalse((objects / ("%064x.pkg" % 1)).exists())
        self.assertTrue((objects / ("%064x.pkg" % 0)).exists())
        self.assertFalse((events / "old").exists())
        self.assertTrue((events / "active").exists())
    def test_prune_disabled(self):
        gens = self.root / "generations"
        (gens / ("a" * 64)).mkdir(parents=True)
        old = time.time() - 86400 * 30
        os.utime(gens / ("a" * 64), (old, old))
        p.prune({"retention": {"enabled": False, "keep_generations": 0}}, self.root, "")
        self.assertTrue((gens / ("a" * 64)).exists())

@unittest.skipUnless(hasattr(os, "getuid") and os.getuid() == 0, "needs root (key ownership check)")
class Worker(unittest.TestCase):
    # End to end with a fake pkg(8): native generation with unversioned
    # dependencies, one package built in the shadow tree, two worker runs.
    def test_progressive_run(self):
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(p, "manifest", side_effect=fake_manifest):
            d = Path(tmp)
            fake_pkg = d / "pkg"
            fake_pkg.write_text("#!/bin/sh\nfor f in meta.conf data.pkg packagesite.pkg; do : > \"$2/$f\"; done\n")
            fake_pkg.chmod(0o755)
            key = d / "key"
            key.write_text("k"); key.chmod(0o600)
            master = "14-amd64-default"
            native = d / "packages" / master
            real = native / ".real_1" / "All"
            real.mkdir(parents=True)
            (native / ".latest").symlink_to(".real_1")
            def pkg(dirpath, name, version, deps=None):
                (dirpath / (name + "-" + version + ".pkg")).write_text(json.dumps(dict(
                    name=name, version=version, origin="test/" + name,
                    abi="FreeBSD:14:amd64", deps=deps or {})))
            pkg(real, "lib", "1")
            pkg(real, "app", "1", {"lib": {"origin": "test/lib"}})
            shadow = native / ".building"
            (shadow / "All").mkdir(parents=True)
            (shadow / ".buildname").write_text("b1\n")
            pkg(shadow / "All", "lib", "1_1")
            cfg = {"masters": [master], "native_root": str(d / "packages"),
                   "state_root": str(d / "progressive"), "signing_key": str(key),
                   "min_free_gib": 0}
            events = d / "progressive" / master / "events" / "b1"
            events.mkdir(parents=True)
            (events / "bulk-start.json").write_text("{}")
            (events / "pkgbuild-success-lib-1_1.json").write_text(json.dumps({"pkgname": "lib-1_1"}))
            with mock.patch.object(p, "PKG", str(fake_pkg)):
                p.worker(cfg, master)
                current = d / "progressive" / master / "current"
                names = sorted(x.name for x in (current / "All").iterdir())
                self.assertEqual(len(names), 2)
                published = [fake_manifest(current / "All" / n)["version"] for n in names]
                self.assertIn("1_1", published)
                with mock.patch.object(p, "digest", side_effect=AssertionError("rehashed")):
                    p.worker(cfg, master)

if __name__=="__main__":
    unittest.main()
