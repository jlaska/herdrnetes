"""CLI-level safety tests: default invocations never create anything and never execute kubectl (EXP-005-RWX)."""
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "harness")
RWX = os.path.join(HARNESS, "rwx")


class FakeKubectl(unittest.TestCase):
    """PATH contains a kubectl that records any invocation and fails; tests assert it is never called."""

    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.bin = os.path.join(self._td.name, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self._td.name, "kubectl.log")
        k = os.path.join(self.bin, "kubectl")
        with open(k, "w") as f:
            f.write(f"#!/bin/sh\necho \"$@\" >> {self.log}\nexit 1\n")
        os.chmod(k, os.stat(k).st_mode | stat.S_IXUSR)
        self.env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"])
        self.env.pop("KCTX", None)

    def rwx(self, *args, env=None):
        if "--live" in args or "--execute" in args:   # never write evidence into the repository from a test
            args = (*args, "--evidence-dir", os.path.join(self._td.name, "evidence"))
        return subprocess.run([sys.executable, RWX, *args], capture_output=True, text=True, env=env or self.env, timeout=60)

    def kubectl_calls(self):
        return open(self.log).read() if os.path.exists(self.log) else ""

    def test_no_args_prints_plan(self):
        r = self.rwx()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("nothing is contacted or created", r.stdout)
        self.assertIn("ReadWriteMany 1Gi storageClassName=longhorn", r.stdout)
        self.assertIn("R14", r.stdout)
        self.assertEqual(self.kubectl_calls(), "")

    def test_every_subcommand_without_flags_is_inert(self):
        for sub in ("plan", "preflight", "create", "run", "collect", "recreate", "cleanup"):
            args = [sub] + ([] if sub == "plan" else ["--run-id", "20261119a"])
            r = self.rwx(*args)
            self.assertEqual(r.returncode, 0, (sub, r.stdout, r.stderr))
            self.assertEqual(self.kubectl_calls(), "", sub)
        self.assertFalse(os.path.exists(os.path.join(HARNESS, "..", "evidence", "20261119a")))

    def test_execute_needs_matching_confirmation(self):
        for extra in ([], ["--confirm-run-id", "other"]):
            r = self.rwx("create", "--run-id", "20261119a", "--execute", *extra)
            self.assertEqual(r.returncode, 2)
            self.assertIn("--confirm-run-id", r.stderr)
        self.assertEqual(self.kubectl_calls(), "")

    def test_live_without_context_refused(self):
        r = self.rwx("preflight", "--run-id", "20261119a", "--live")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.kubectl_calls(), "")

    def test_bad_run_id_refused(self):
        for bad in ("UPPER", "a b", "x" * 40):
            r = self.rwx("plan", "--run-id", bad)
            self.assertEqual(r.returncode, 2, bad)

    def test_live_preflight_only_reads(self):
        env = dict(self.env, KCTX="ctx-test")
        r = self.rwx("preflight", "--run-id", "20261119a", "--live", env=env)
        self.assertEqual(r.returncode, 3, (r.stdout, r.stderr))   # fake kubectl fails: context not found => stop
        for line in self.kubectl_calls().splitlines():
            self.assertRegex(line, r"get-contexts|^--context ctx-test.* (get|version|auth)\b", line)
            self.assertNotRegex(line, r"\b(apply|delete|create|patch|exec)\b")

    def test_node_selector_value_not_printed(self):
        env = dict(self.env, RWX_NODE_SELECTOR="kubernetes.io/hostname=secret-node-1")
        r = self.rwx("plan", env=env)
        self.assertNotIn("secret-node-1", r.stdout)

    def test_sanitize_subcommand(self):
        p = os.path.join(self.bin, "x.txt")
        open(p, "w").write("ip 10.1.2.3 host a.lab.internal\n")
        r = self.rwx("sanitize", p)
        self.assertNotIn("10.1.2.3", r.stdout)
        self.assertNotIn("lab.internal", r.stdout)


class TestNoCommittedSecrets(unittest.TestCase):
    def test_tree_has_no_ips_or_hostnames(self):
        import re
        root = os.path.join(HARNESS, "..")
        for dp, dn, fn in os.walk(root):
            dn[:] = [d for d in dn if d not in ("__pycache__", "evidence", "tests")]   # tests use RFC 5737 examples
            for f in fn:
                if f.endswith(".pyc"):
                    continue
                text = open(os.path.join(dp, f), errors="replace").read()
                for m in re.finditer(r"\b(\d{1,3}\.){3}\d{1,3}\b", text):
                    self.assertIn(m.group(0), ("127.0.0.1", "0.0.0.0"), f"{f}: {m.group(0)}")
                self.assertNotRegex(text, r"talos-[a-z0-9]{3,}", f)


if __name__ == "__main__":
    unittest.main()
