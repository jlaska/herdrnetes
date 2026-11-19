"""Local tests for harness/request-repo (EXP-005 M1). stdlib only; no cluster.

Run: uv run python -m unittest discover -s experiments/exp-005/tests -v
Uses synthetic repositories in a temp dir; never touches a real workspace.
"""
import hashlib, json, os, signal, subprocess, sys, tempfile, time, unittest
from concurrent.futures import ThreadPoolExecutor

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "harness", "request-repo")
GENV = dict(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
            GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid", GIT_AUTHOR_DATE="2026-01-01T00:00:00Z",
            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
            GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")


def git(*args, cwd=None):
    # GIT_OPTIONAL_LOCKS=0 keeps `git status` from rewriting the index in snapshots
    r = subprocess.run(["git", *args], cwd=cwd, env=dict(os.environ, **GENV, GIT_OPTIONAL_LOCKS="0"), capture_output=True, text=True)
    assert r.returncode == 0, (args, r.stderr)
    return r.stdout


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = os.path.realpath(self._td.name)
        self.ws = os.path.join(self.tmp, "workspace")
        os.mkdir(self.ws)
        self.src = self.make_source("src-a")
        self.addCleanup(self._td.cleanup)

    def make_source(self, name, files=None):
        work = os.path.join(self.tmp, name + "-work")
        os.mkdir(work)
        git("init", "-q", "-b", "main", cwd=work)
        for fn, content in (files or {"README": "hello\n", "a.txt": "a\n"}).items():
            with open(os.path.join(work, fn), "w") as f:
                f.write(content)
        git("add", ".", cwd=work)
        git("commit", "-q", "-m", "init", cwd=work)
        bare = os.path.join(self.tmp, name + ".git")
        git("clone", "-q", "--bare", work, bare)
        return bare

    def env(self, **extra):
        e = dict(os.environ, **GENV, WORKSPACE_ROOT=self.ws)
        e.pop("REQUEST_REPO_TEST_PAUSE_AFTER_CLONE", None)
        e.update(extra)
        return e

    def popen(self, rid, src, *opts, **envx):
        return subprocess.Popen([sys.executable, TOOL, *opts, rid, src], env=self.env(**envx),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def req(self, rid, src=None, *opts, **envx):
        p = self.popen(rid, src or self.src, *opts, **envx)
        o, e = p.communicate()
        try:
            j = json.loads(o)
        except ValueError:
            self.fail(f"non-JSON stdout {o!r} stderr {e!r}")
        return p.returncode, j, e

    def meta(self, sub):
        return os.path.join(self.ws, ".herdr-repos", sub)

    def fsck(self, rid):
        git("fsck", "--strict", cwd=os.path.join(self.ws, rid))

    def state(self, rid):
        with open(os.path.join(self.meta("state"), rid + ".json")) as f:
            return json.load(f)


class Lifecycle(Base):
    def test_s01_s02_s03_hydrate(self):
        target = os.path.join(self.ws, "repo1")
        self.assertFalse(os.path.lexists(target))  # S01
        rc, j, _ = self.req("repo1")
        self.assertEqual(rc, 0, j)
        self.assertEqual((j["status"], j["action"]), ("ready", "hydrated"))
        self.assertEqual(j["path"], target)  # S03 stable absolute path
        self.assertEqual(j["head"], git("rev-parse", "HEAD", cwd=self.src).strip())  # S02
        self.assertIn(j["promotion"], ("renameat2", "rename-fallback"))
        self.fsck("repo1")
        self.assertEqual(self.state("repo1")["status"], "ready")
        self.assertEqual(os.listdir(self.meta("staging")), [])

    def test_s05_repeat_is_noop(self):
        self.req("repo1")
        g = os.path.join(self.ws, "repo1", ".git")
        before = (os.stat(g).st_ino, os.stat(g).st_mtime_ns, os.stat(g + "/index").st_mtime_ns, sha(g + "/HEAD"))
        sbefore = os.stat(os.path.join(self.meta("state"), "repo1.json")).st_mtime_ns
        rc, j, _ = self.req("repo1")
        self.assertEqual((rc, j["action"]), (0, "already_ready"))
        after = (os.stat(g).st_ino, os.stat(g).st_mtime_ns, os.stat(g + "/index").st_mtime_ns, sha(g + "/HEAD"))
        self.assertEqual(before, after)
        self.assertEqual(sbefore, os.stat(os.path.join(self.meta("state"), "repo1.json")).st_mtime_ns)

    def test_s06_two_repos(self):
        other = self.make_source("src-b", {"B": "b\n"})
        self.assertEqual(self.req("one")[0], 0)
        self.assertEqual(self.req("two", other)[0], 0)
        self.fsck("one"); self.fsck("two")
        self.assertTrue(os.path.exists(os.path.join(self.ws, "two", "B")))
        self.assertFalse(os.path.exists(os.path.join(self.ws, "one", "B")))

    def test_s07_concurrent_single_clone(self):
        n = 8
        with ThreadPoolExecutor(n) as ex:
            res = list(ex.map(lambda _: self.req("race"), range(n)))
        self.assertTrue(all(r[0] == 0 for r in res), [r[1] for r in res])
        actions = sorted(r[1]["action"] for r in res)
        self.assertEqual(actions.count("hydrated"), 1, actions)
        self.assertEqual(actions.count("already_ready"), n - 1)
        clones = sum(r[2].count("cloning ") for r in res)
        self.assertEqual(clones, 1)
        self.assertEqual(self.state("race")["attempts"], 1)
        self.assertTrue(any(r[1]["waited"] for r in res))
        self.fsck("race")
        self.assertEqual(os.listdir(self.meta("staging")), [])

    def test_s08_failed_then_retry(self):
        bad = os.path.join(self.tmp, "does-not-exist.git")
        rc, j, _ = self.req("r8", bad)
        self.assertEqual(rc, 5, j)
        self.assertFalse(os.path.lexists(os.path.join(self.ws, "r8")))
        st = self.state("r8")
        self.assertEqual((st["status"], st["attempts"]), ("failed", 1))
        self.assertEqual(os.listdir(self.meta("staging")), [])
        rc, j, _ = self.req("r8", self.src)
        self.assertEqual((rc, j["action"], j["attempt"]), (0, "hydrated", 2))
        self.fsck("r8")

    def test_s09_sigkill_mid_hydration(self):
        p = self.popen("r9", self.src, REQUEST_REPO_TEST_PAUSE_AFTER_CLONE="60")
        stg = self.meta("staging")
        deadline = time.time() + 30
        while time.time() < deadline:
            if os.path.isdir(stg) and any(n.startswith("r9@") for n in os.listdir(stg)):
                break
            time.sleep(0.05)
        time.sleep(0.5)  # clone finished, process is in the pause
        p.send_signal(signal.SIGKILL); p.communicate()
        self.assertFalse(os.path.lexists(os.path.join(self.ws, "r9")))
        self.assertTrue(any(n.startswith("r9@") for n in os.listdir(stg)))
        rc, j, e = self.req("r9")
        self.assertEqual((rc, j["action"]), (0, "hydrated"), e)
        self.assertIn("removing stale staging", e)
        self.assertEqual(os.listdir(stg), [])
        self.fsck("r9")

    def test_s10_existing_repo_untouched(self):
        self.req("r10")
        d = os.path.join(self.ws, "r10")
        git("config", "user.name", "t", cwd=d); git("config", "user.email", "t@x.invalid", cwd=d)
        with open(d + "/README", "a") as f: f.write("dirty\n")
        with open(d + "/untracked.txt", "w") as f: f.write("u\n")
        with open(d + "/a.txt", "a") as f: f.write("committed\n")
        git("commit", "-qam", "local", cwd=d)
        with open(d + "/a.txt", "a") as f: f.write("stashme\n")
        git("stash", "-q", cwd=d)
        with open(d + "/README", "a") as f: f.write("dirty2\n")
        # make the index non-trivial (staged change)
        with open(d + "/staged.txt", "w") as f: f.write("s\n")
        git("add", "staged.txt", cwd=d)

        def snap():
            # index stat first: `git status` itself may refresh the index
            idx = (os.stat(d + "/.git/index").st_mtime_ns, sha(d + "/.git/index"))
            return dict(idx=idx, status=git("status", "--porcelain=v2", "--branch", cwd=d),
                        head=git("rev-parse", "HEAD", cwd=d), stash=git("stash", "list", cwd=d),
                        refs=git("for-each-ref", cwd=d),
                        hashes={n: sha(os.path.join(d, n)) for n in ("README", "a.txt", "untracked.txt", "staged.txt")})
        before = snap()
        self.assertIn("stash@{0}", before["stash"])
        rc, j, _ = self.req("r10")
        self.assertEqual((rc, j["action"]), (0, "already_ready"))
        self.assertEqual(before, snap())

    def test_s13_worktree_paths(self):
        self.req("r13")
        d = os.path.join(self.ws, "r13")
        wt = os.path.join(self.ws, "r13-wt")
        git("worktree", "add", "-q", "-b", "feat", wt, cwd=d)
        gitfile = open(os.path.join(wt, ".git")).read().strip()
        admin = os.path.join(d, ".git", "worktrees", "r13-wt", "gitdir")
        back = open(admin).read().strip()
        print(f"\nS13 git {git('--version').strip()}: worktree .git file={gitfile!r} gitdir backlink={back!r}",
              file=sys.stderr)
        self.assertTrue(gitfile.startswith("gitdir: /"))  # absolute (git < 2.48 / no relative paths)
        self.assertTrue(os.path.isabs(back))
        rc, j, _ = self.req("r13")
        self.assertEqual(j["action"], "already_ready")


class Errors(Base):
    def test_invalid_ids(self):
        for bad in ("..", "a..b", "A", "-x", ".x", "a/b", "", "x" * 64, "a@b"):
            pr = self.popen(bad, self.src)
            pr.communicate()
            self.assertEqual(pr.returncode, 2, bad)
        self.assertFalse(os.path.exists(self.meta("staging")))

    def test_disallowed_source(self):
        for s in ("https://example.invalid/x.git", "relative/path", "git@host:x.git"):
            self.assertEqual(self.req("ok", s)[0], 2, s)

    def test_usage_error(self):
        p = subprocess.run([sys.executable, TOOL], env=self.env(), capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)

    def test_source_mismatch(self):
        self.assertEqual(self.req("m")[0], 0)
        other = self.make_source("src-b")
        rc, j, _ = self.req("m", other)
        self.assertEqual((rc, j["status"]), (3, "source-mismatch"))
        self.assertEqual(self.req("m")[0], 0)

    def test_file_url_equivalent_to_path(self):
        self.assertEqual(self.req("u", "file://" + self.src)[0], 0)
        self.assertEqual(self.req("u", self.src)[1]["action"], "already_ready")

    def test_conflict_unmanaged_dir_and_file(self):
        os.mkdir(os.path.join(self.ws, "plain"))
        with open(os.path.join(self.ws, "plain", "x"), "w") as f: f.write("x")
        rc, j, _ = self.req("plain")
        self.assertEqual(rc, 4)
        self.assertEqual(open(os.path.join(self.ws, "plain", "x")).read(), "x")
        with open(os.path.join(self.ws, "afile"), "w") as f: f.write("f")
        self.assertEqual(self.req("afile")[0], 4)

    def test_conflict_empty_dir_not_replaced(self):
        d = os.path.join(self.ws, "empty")
        os.mkdir(d)
        ino = os.stat(d).st_ino
        rc, j, _ = self.req("empty")
        self.assertEqual(rc, 4)
        self.assertEqual((os.listdir(d), os.stat(d).st_ino), ([], ino))

    def test_conflict_nested_inside_other_repo(self):
        # a plain dir inside a parent repo must not be mistaken for a repo root
        self.assertEqual(self.req("parent")[0], 0)
        # directory that is not a repo root but lives under WORKSPACE_ROOT with a stray .git file
        d = os.path.join(self.ws, "fake")
        os.mkdir(d)
        with open(os.path.join(d, ".git"), "w") as f: f.write("gitdir: /nonexistent\n")
        self.assertEqual(self.req("fake")[0], 4)

    def test_recover_existing_repo_without_state(self):
        self.assertEqual(self.req("rec")[0], 0)
        os.unlink(os.path.join(self.meta("state"), "rec.json"))
        rc, j, _ = self.req("rec")
        self.assertEqual((rc, j["action"]), (0, "recovered"))
        self.assertTrue(self.state("rec")["recovered"])
        # different origin -> conflict
        os.unlink(os.path.join(self.meta("state"), "rec.json"))
        self.assertEqual(self.req("rec", self.make_source("src-b"))[0], 4)

    def test_lock_timeout(self):
        import fcntl
        self.assertEqual(self.req("lk")[0], 0)
        fd = os.open(os.path.join(self.meta("locks"), "lk.lock"), os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            rc, j, _ = self.req("lk", None, "--timeout", "0.5")
            self.assertEqual((rc, j["status"]), (6, "lock-timeout"))
        finally:
            os.close(fd)

    def test_cross_device_staging(self):
        if not os.path.isdir("/dev/shm") or os.stat("/dev/shm").st_dev == os.stat(self.ws).st_dev:
            self.skipTest("no second filesystem available")
        os.makedirs(os.path.join(self.ws, ".herdr-repos"))
        try:
            os.symlink("/dev/shm", self.meta("staging"))
        except OSError:
            self.skipTest("cannot symlink")
        for d in ("locks", "state"):
            os.makedirs(self.meta(d))
        rc, j, _ = self.req("xdev")
        self.assertEqual(rc, 7, j)

    def test_shallow_and_filter(self):
        rc, j, _ = self.req("sh", None, "--depth", "1")
        self.assertEqual((rc, j["shallow"]), (0, True))


if __name__ == "__main__":
    unittest.main()
