"""Tests for harness/podprobe.py run locally against a temp directory (EXP-005-RWX). No cluster.

The probes are exercised exactly as in a pod: as separate `python3 -I - <cmd>` processes fed the script on stdin.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "harness")
sys.path.insert(0, HARNESS)
import podprobe as P  # noqa: E402
import rwxlib as L  # noqa: E402

SRC = open(os.path.join(HARNESS, "podprobe.py")).read()
GENV = dict(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def popen(*args, env=None):
    return subprocess.Popen([sys.executable, "-I", "-", *map(str, args)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, env=dict(os.environ, **GENV, **(env or {})))


def spawn(*args, env=None):
    """Start a probe with the script on stdin; stdin is then detached so communicate() works."""
    p = popen(*args, env=env)
    p.stdin.write(SRC)
    p.stdin.close()
    p.stdin = None
    return p


def run(*args, env=None, timeout=120):
    p = popen(*args, env=env)
    out, err = p.communicate(SRC, timeout=timeout)
    assert p.returncode == 0, (args, err)
    return L.parse_probe_output(out)


class Tmp(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self._td.name)
        self.addCleanup(self._td.cleanup)


class TestIdentityMount(Tmp):
    def test_identity(self):
        r = run("identity")
        self.assertEqual(r["uid"], os.getuid())
        self.assertIn("git version", r["git"])

    def test_mountinfo_parse(self):
        text = ("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n"
                "2 1 0:50 / /rwx rw,relatime - nfs4 192.0.2.1:/pvc-1 rw,vers=4.1,rsize=1048576,hard,timeo=600,local_lock=none,sec=sys\n"
                "3 1 0:51 / /rwx/with\\040space rw - tmpfs tmpfs rw\n")
        m = P.parse_mountinfo(text, "/rwx/work/x")
        self.assertEqual((m["mount_point"], m["fstype"], m["source"]), ("/rwx", "nfs4", "192.0.2.1:/pvc-1"))
        self.assertEqual(P.nfs_options(m["super_options"])["vers"], "4.1")
        self.assertEqual(P.nfs_options(m["super_options"])["hard"], True)
        self.assertEqual(P.parse_mountinfo(text, "/rwx/with space/a")["fstype"], "tmpfs")
        self.assertEqual(P.parse_mountinfo(text, "/etc")["mount_point"], "/")

    def test_mountinfo_cmd_reports_fsgroup(self):
        r = run("mountinfo", self.d)
        self.assertEqual(r["root_stat"]["uid"], os.getuid())
        self.assertIn("applied", r["fsgroup_observation"])
        self.assertGreater(r["statvfs"]["total_mib"], 0)


class TestGate(Tmp):
    def test_gate_passes_and_leaves_no_residue(self):
        r = run("writegate", self.d)
        self.assertTrue(r["ok"], r)
        self.assertEqual(os.listdir(self.d), [])
        r["steps"]["owner_is_caller"]["file_uid"] = 1000      # locally the caller is not uid 1000
        ok, why = L.evaluate_gate(dict(r, uid=1000, gid=1000, root_stat=dict(r["root_stat"], uid=1000, gid=1000)))
        self.assertTrue(ok, why)

    @unittest.skipIf(os.getuid() == 0, "root bypasses permissions")
    def test_gate_fails_on_readonly_root_and_never_escalates(self):
        os.chmod(self.d, 0o555)
        self.addCleanup(os.chmod, self.d, 0o755)
        r = run("writegate", self.d)
        self.assertFalse(r["ok"])
        self.assertEqual(r["steps"]["create_write_fsync"]["errno"], "EACCES")
        self.assertEqual(list(r["steps"]), ["create_write_fsync"], "stops at the first failed step")
        self.assertEqual(oct(os.stat(self.d).st_mode & 0o777), "0o555", "gate must not chmod the root")
        ok, why = L.evaluate_gate(dict(r, uid=1000, gid=1000))
        self.assertFalse(ok)

    def test_gate_includes_git_smoke_and_leaves_no_residue(self):
        r = run("writegate", self.d)
        self.assertTrue(r["steps"]["git_smoke"]["ok"], r["steps"]["git_smoke"])
        self.assertEqual(os.listdir(self.d), [])

    def test_git_smoke_failure_stops_gate_and_records_stderr(self):
        orig = P.git

        def failing(args, cwd=None, env=None, timeout=600):
            if args and args[0] == "clone":
                return subprocess.CompletedProcess(["git"] + list(args), 128, "", "fatal: could not create work tree dir: Permission denied")
            return orig(args, cwd=cwd, env=env, timeout=timeout)
        P.git = failing
        try:
            r = P.run_gate(self.d)
        finally:
            P.git = orig
        self.assertFalse(r["ok"])
        self.assertEqual(r["steps"]["git_smoke"]["errno"], "GIT")
        self.assertIn("Permission denied", r["steps"]["git_smoke"]["msg"])
        self.assertNotIn("unlink_rmdir", r["steps"], "gate stops at the first failed step")
        self.assertEqual(os.listdir(self.d), [], "gate dirs removed even on failure")
        ok, why = L.evaluate_gate(dict(r, uid=1000, gid=1000, root_stat=dict(r["root_stat"], uid=1000, gid=1000)))
        self.assertFalse(ok)
        self.assertIn("Permission denied", " ".join(why))

    def test_git_env_is_hermetic(self):
        self.assertEqual(P.GIT_ENV["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(P.GIT_ENV["GIT_CONFIG_NOSYSTEM"], "1")   # no user signing/hook config can leak into probes
        self.assertEqual((P.GIT_ENV["GIT_CONFIG_KEY_0"], P.GIT_ENV["GIT_CONFIG_VALUE_0"]), ("commit.gpgsign", "false"))

    def test_probe_source_has_no_privilege_escalation(self):
        for banned in ("os.chown", "chown(", "setuid", "sudo", "os.setgid", "os.mount", "libc.mount", "subprocess.run([\"chmod\"",
                       "privileged", "CAP_"):
            self.assertNotIn(banned, SRC, banned)


class TestRepos(Tmp):
    def test_mkrepo_deterministic_and_fsck(self):
        a = run("mkrepo", self.d, "r1", 60, 3, env={"GIT_AUTHOR_NAME": "x"})
        os.makedirs(os.path.join(self.d, "b"))
        b = run("mkrepo", os.path.join(self.d, "b"), "r1", 60, 3)
        self.assertEqual(a["head"], b["head"], "synthetic repos are deterministic")
        self.assertTrue(run("fsck", a["bare"])["ok"])
        info = run("gitinfo", a["bare"])
        self.assertEqual(info["commits"], 3)

    def test_commit_and_info(self):
        a = run("mkrepo", self.d, "r2", 20, 2)
        clone = os.path.join(self.d, "c")
        subprocess.run(["git", "clone", "-q", a["bare"], clone], check=True, env=dict(os.environ, **GENV))
        c = run("gitcommit", clone, "t", 0)
        self.assertTrue(c["ok"])
        self.assertEqual(run("gitinfo", clone)["head"], c["head"])


class TestPingPong(Tmp):
    def test_roundtrip_modes(self):
        for mode, kind in (("open", "new"), ("listdir", "new"), ("stat", "new"), ("open", "inplace")):
            d = os.path.join(self.d, f"{mode}-{kind}")
            b = spawn("pingpong", "b", d, 5, mode, kind, 10)
            a = run("pingpong", "a", d, 5, mode, kind, 10)
            out, err = b.communicate(timeout=60)
            rb = L.parse_probe_output(out)
            self.assertEqual(a["timeouts"], 0, (mode, kind, a, err))
            self.assertEqual(rb["timeouts"], 0)
            self.assertEqual(len(a["rtt_ms"]), 5)
            self.assertEqual(rb["content_mismatch"], 0)

    def test_a_reports_missing_b(self):
        d = os.path.join(self.d, "x")
        os.makedirs(d)
        orig = P.wait_for
        P.wait_for = lambda pred, timeout, poll=0.002: None   # B never ready
        try:
            r = P.pingpong("a", d, 2, "open", "new", 1)
        finally:
            P.wait_for = orig
        self.assertIn("error", r)


class TestLocks(Tmp):
    def test_flock_and_fcntl_exclude_across_processes(self):
        for kind in ("flock", "fcntl"):
            path = os.path.join(self.d, f"{kind}.lock")
            h = spawn("lockhold", path, 3, kind)
            first = json.loads(h.stdout.readline())
            self.assertEqual(first["event"], "HELD")
            c1 = run("locktry", path, 0.3, kind)
            self.assertFalse(c1["acquired"])
            self.assertEqual(c1["errno"], "EWOULDBLOCK")
            c2 = run("locktry", path, 20, kind)
            self.assertTrue(c2["acquired"])
            self.assertGreater(c2["waited_s"], 0.3)
            h.wait(timeout=30)


class TestRename(Tmp):
    def test_local_fs_semantics(self):
        r = run("renameprobe", self.d)
        self.assertEqual(r["file_to_absent"]["rc"], 0)
        self.assertEqual(r["file_to_existing_file"]["errno"], "EEXIST")
        self.assertTrue(r["file_to_existing_file"]["src_exists_after"])
        self.assertEqual(r["dir_to_existing_empty_dir"]["errno"], "EEXIST")
        self.assertTrue(r["plain_rename_dir_onto_empty_dir"]["replaced"], "plain rename silently replaces an empty dir")
        self.assertTrue(r["noreplace_supported"])
        ne = r["plain_rename_dir_onto_nonempty_dir"]
        self.assertFalse(ne["replaced"])
        self.assertIn(ne["errno"], ("ENOTEMPTY", "EEXIST"))
        self.assertTrue(ne["src_exists_after"])
        self.assertIn(r["noreplace_dir_onto_nonempty_dir"]["errno"], ("EEXIST", "ENOTEMPTY"))
        self.assertEqual(os.listdir(self.d), [], "probe cleans up after itself")

    def test_rename_command(self):
        a, b = os.path.join(self.d, "a"), os.path.join(self.d, "b")
        os.mkdir(a)
        self.assertTrue(run("rename", a, b)["ok"])
        self.assertFalse(os.path.exists(a))
        self.assertFalse(run("rename", a, b)["ok"])


class TestRaces(Tmp):
    def test_oexcl_two_processes_exactly_once(self):
        d = os.path.join(self.d, "o")
        start = time.time() + 1.5
        pa, pb = spawn("oexcl", d, 200, "oa", start), spawn("oexcl", d, 200, "ob", start)
        ra, rb = (L.parse_probe_output(p.communicate(timeout=60)[0]) for p in (pa, pb))
        self.assertEqual(len(ra["won"]) + len(rb["won"]), 200)
        self.assertFalse(set(ra["won"]) & set(rb["won"]))
        v = run("oexcl_verify", d, 200, "oa,ob")
        self.assertEqual(v["missing"], [])
        self.assertEqual(v["by_label"], {"oa": len(ra["won"]), "ob": len(rb["won"])})

    def test_append_race_analysis(self):
        p = os.path.join(self.d, "a.log")
        start = time.time() + 1
        pa, pb = spawn("appendrace", p, 100, "pa", start), spawn("appendrace", p, 100, "pb", start)
        for q in (pa, pb):
            q.communicate(timeout=60)
        v = run("appendverify", p, 100, "pa,pb")
        self.assertEqual(v["expected"], 200)
        self.assertEqual(v["garbled"], 0)
        self.assertEqual(v["lines"], 200, "local O_APPEND is atomic")

    def test_analyze_append_detects_loss_and_garbage(self):
        p = os.path.join(self.d, "b.log")
        open(p, "w").write("pa:00000\npa:00001\npb:00000\ngarbage\n")
        v = P.analyze_append(p, 2, ["pa", "pb"])
        self.assertEqual(v["missing"], {"pa": 0, "pb": 1})
        self.assertEqual(v["garbled"], 1)

    def test_git_race_same_repo_classifies_and_stays_consistent(self):
        a = run("mkrepo", self.d, "g", 10, 2)
        repo = os.path.join(self.d, "wc")
        subprocess.run(["git", "clone", "-q", a["bare"], repo], check=True, env=dict(os.environ, **GENV))
        before = run("gitinfo", repo)["commits"]
        start = time.time() + 1.5
        pa, pb = spawn("gitrace", repo, 15, "ga", start), spawn("gitrace", repo, 15, "gb", start)
        ra, rb = (L.parse_probe_output(q.communicate(timeout=120)[0]) for q in (pa, pb))
        after = run("gitinfo", repo)["commits"]
        self.assertEqual(after, before + ra["commits_ok"] + rb["commits_ok"], "no lost update")
        self.assertTrue(run("fsck", repo)["ok"])
        self.assertTrue(set(ra["failures"]) <= {"index.lock", "ref-lock", "nothing-to-commit", "other"})


class TestEdgesPerf(Tmp):
    def test_posix_edges(self):
        r = run("posixedges", os.path.join(self.d, "e"), "a")
        self.assertTrue(r["hardlink"]["ok"] and r["symlink"]["ok"] and r["atomic_replace"]["ok"])
        self.assertEqual(r["atomic_replace"]["content"], "new")
        self.assertFalse(r["chmod_444_access_w"])
        self.assertEqual(r["umask_modes"]["077"]["file"], "0o600")
        sha = run("readsha", r["mmap_file"])
        self.assertEqual(sha["sha256"], r["mmap_sha256"])
        self.assertEqual(sha["stat"]["size"], 65536)

    def test_perf_small(self):
        a = run("mkrepo", self.d, "p", 40, 2)
        r = run("perf", a["bare"], self.d, 30, 2, "t", timeout=300)
        for op in ("clone", "status_clean", "checkout_alt", "checkout_main", "fsck", "small_create", "small_stat",
                   "small_read", "small_delete", "rm_tree"):
            self.assertEqual(len(r["ops"][op]), 2, op)
        self.assertEqual(sorted(os.listdir(self.d)), ["p-work", "p.git"], "perf cleans its clones")

    def test_heartbeat_and_df_and_clock(self):
        h = run("heartbeat", os.path.join(self.d, "hb"), 1)
        self.assertGreater(h["writes"], 2)
        self.assertEqual(h["errors"], {})
        self.assertGreater(run("df", self.d)["total_mib"], 0)
        self.assertAlmostEqual(run("clock")["time"], time.time(), delta=5)

    def test_unknown_command(self):
        p = popen("nosuch")
        p.communicate(SRC)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
