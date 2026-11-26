#!/usr/bin/env python3
# Version: 1.19.0-beta.1
# Unit tests for conservative dependency selection; no native repo access.
import importlib.util
from pathlib import Path
import unittest
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
if __name__=="__main__":
    unittest.main()
