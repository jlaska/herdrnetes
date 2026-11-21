#!/usr/bin/env python3
"""In-pod probes for EXP-005-RWX (issue #32). stdlib only; runs as UID 1000 inside a scratch pod.

Delivered over stdin, never copied into the image or a ConfigMap:
    kubectl exec -i rwx-a -c ws -- python3 -I - <subcommand> [args] < podprobe.py
Every subcommand prints diagnostics freely and ends with ONE line of JSON (the result).
Nothing here changes ownership, privileges or mounts, and it only chmods paths it created itself.
The tests under tests/test_podprobe.py run these same functions against a local temp directory.
"""
import ctypes
import errno
import fcntl
import hashlib
import json
import mmap
import os
import re
import shutil
import signal
import subprocess
import sys
import time

GIT_ENV = dict(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",   # hermetic: no signing/hooks from user config
               GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="commit.gpgsign", GIT_CONFIG_VALUE_0="false",
               GIT_AUTHOR_NAME="rwx-synthetic",
               GIT_AUTHOR_EMAIL="rwx@example.invalid", GIT_COMMITTER_NAME="rwx-synthetic",
               GIT_COMMITTER_EMAIL="rwx@example.invalid", GIT_AUTHOR_DATE="2026-01-01T00:00:00Z",
               GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
RENAME_NOREPLACE = 1


def emit(obj):
    print(json.dumps(obj, sort_keys=True), flush=True)


def en(e):
    return errno.errorcode.get(e.errno, str(e.errno)) if isinstance(e, OSError) else repr(e)


class GateFail(Exception):
    """A non-OSError gate failure (for example a git command); carries the captured stderr."""


def step(fn):
    t = time.monotonic()
    try:
        extra = fn()
        return dict(ok=True, ms=round((time.monotonic() - t) * 1000, 2), **(extra or {}))
    except OSError as e:
        return dict(ok=False, errno=en(e), msg=e.strerror, ms=round((time.monotonic() - t) * 1000, 2))
    except GateFail as e:
        return dict(ok=False, errno="GIT", msg=str(e)[:600], ms=round((time.monotonic() - t) * 1000, 2))


def git(args, cwd=None, env=None, timeout=600):
    e = dict(os.environ, **GIT_ENV)
    if env:
        e.update(env)
    return subprocess.run(["git"] + list(args), cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stat_dict(path):
    st = os.stat(path)
    return dict(uid=st.st_uid, gid=st.st_gid, mode=st.st_mode & 0o7777, is_dir=os.path.isdir(path),
                nlink=st.st_nlink, size=st.st_size)


# ---------------------------------------------------------------------------------------- identity / mount
def cmd_identity(_a):
    def ver(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip().splitlines()[0]
        except Exception as e:  # noqa: BLE001
            return f"unavailable: {type(e).__name__}"
    um = os.umask(0)
    os.umask(um)
    emit(dict(uid=os.getuid(), gid=os.getgid(), groups=os.getgroups(), umask=oct(um), kernel=os.uname().release,
              git=ver(["git", "--version"]), python=sys.version.split()[0], flock=ver(["flock", "--version"]),
              no_new_privs=_status_field("NoNewPrivs"), cap_eff=_status_field("CapEff"),
              seccomp=_status_field("Seccomp")))


def _status_field(name):
    try:
        for line in open("/proc/self/status"):
            if line.startswith(name + ":"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return None


def unescape_mount(s):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


def parse_mountinfo(text, path):
    """Longest-prefix mount containing path. Returns dict(fstype, source, mount_point, options, super_options)."""
    best = None
    for line in text.splitlines():
        parts = line.split()
        if "-" not in parts:
            continue
        i = parts.index("-")
        mp = unescape_mount(parts[4])
        if path == mp or path.startswith(mp.rstrip("/") + "/") or mp == "/":
            if best is None or len(mp) > len(best["mount_point"]):
                best = dict(mount_point=mp, mount_options=parts[5], fstype=parts[i + 1], source=parts[i + 2],
                            super_options=parts[i + 3] if len(parts) > i + 3 else "")
    return best


def nfs_options(opts):
    """Pick the NFS-relevant options out of the super options string."""
    keys = ("vers", "proto", "rsize", "wsize", "hard", "soft", "timeo", "retrans", "sec", "local_lock",
            "lookupcache", "acregmin", "acregmax", "acdirmin", "acdirmax", "noac", "actimeo", "nolock", "lock",
            "cto", "nocto", "fatal_neterrors", "minorversion", "namlen", "nconnect", "noresvport", "resvport")
    out = {}
    for o in opts.split(","):
        k, _, v = o.partition("=")
        if k in keys:
            out[k] = v if v else True
    return out


def cmd_mountinfo(a):
    path = a[0]
    with open("/proc/self/mountinfo") as f:
        mi = parse_mountinfo(f.read(), os.path.realpath(path))
    out = dict(path=path, mount=mi)
    if mi:
        out["nfs_options"] = nfs_options(mi["super_options"] + "," + mi["mount_options"])
    sv = os.statvfs(path)
    out["statvfs"] = dict(total_mib=round(sv.f_blocks * sv.f_frsize / 1048576, 1),
                          free_mib=round(sv.f_bavail * sv.f_frsize / 1048576, 1), namemax=sv.f_namemax)
    out["root_stat"] = stat_dict(path)
    out["root_listing"] = sorted(os.listdir(path))[:50]
    out["fsgroup_observation"] = dict(root_gid=out["root_stat"]["gid"], expected_fsgroup=1000,
                                      applied=out["root_stat"]["gid"] == 1000,
                                      setgid_bit=bool(out["root_stat"]["mode"] & 0o2000))
    emit(out)


# ---------------------------------------------------------------------------------------- R02 write gate
def run_gate(root):
    """UID 1000 must create/write/fsync/rename/mkdir/unlink at the mount root. Only touches ./.gate-<pid>*."""
    tag = f".gate-{os.getpid()}"
    f1, f2, d1, d2, sl, gsrc, gdst = (os.path.join(root, tag + s) for s in ("-f1", "-f2", "-d1", "-d2", "-sl", "-gsrc", "-gdst"))
    steps = {}

    def create_write():
        fd = os.open(f1, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        try:
            os.write(fd, b"gate\n")
            os.fsync(fd)
        finally:
            os.close(fd)

    def read_back():
        assert open(f1, "rb").read() == b"gate\n"

    def rename_file():
        os.rename(f1, f2)

    def mkdir_rename():
        os.mkdir(d1, 0o755)
        os.rename(d1, d2)

    def create_in_subdir():
        fd = os.open(os.path.join(d2, "x"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.close(fd)

    def symlink_():
        os.symlink("target", sl)

    def git_smoke():
        """Longhorn issue #10621: non-root `git clone` onto an RWX export failed with EACCES while other operations worked.
        init a tiny source on the volume, clone it (file://) onto the volume, commit in the clone, fsck. Stderr is recorded."""
        def g(args, cwd=None):
            r = git(args, cwd=cwd, timeout=120)
            if r.returncode != 0:
                raise GateFail(f"git {' '.join(args[:2])} rc={r.returncode}: {(r.stderr or r.stdout).strip()[-400:]}")
            return r
        os.mkdir(gsrc)
        g(["init", "-q", "-b", "main", gsrc])
        with open(os.path.join(gsrc, "a.txt"), "w") as f:
            f.write("gate\n")
        g(["add", "a.txt"], cwd=gsrc)
        g(["commit", "-q", "-m", "gate"], cwd=gsrc)
        g(["clone", "-q", "--", "file://" + gsrc, gdst])
        with open(os.path.join(gdst, "b.txt"), "w") as f:
            f.write("gate2\n")
        g(["add", "b.txt"], cwd=gdst)
        g(["commit", "-q", "-m", "gate2"], cwd=gdst)
        g(["fsck", "--strict", "--no-progress"], cwd=gdst)
        return dict(steps="init,commit,clone,commit,fsck")

    def owner_is_caller():
        st = os.stat(f2)
        if st.st_uid != os.getuid():
            raise OSError(errno.EPERM, f"created file owner uid {st.st_uid} != caller {os.getuid()}")
        return dict(file_uid=st.st_uid, file_gid=st.st_gid, file_mode=st.st_mode & 0o7777)

    def cleanup():
        for p in (gsrc, gdst):
            shutil.rmtree(p, ignore_errors=True)
        for p in (os.path.join(d2, "x"), f2, sl):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        try:
            os.rmdir(d2)
        except FileNotFoundError:
            pass

    for name, fn in (("create_write_fsync", create_write), ("read_back", read_back), ("rename_file", rename_file),
                     ("owner_is_caller", owner_is_caller), ("mkdir_rename_dir", mkdir_rename),
                     ("create_in_subdir", create_in_subdir), ("symlink", symlink_), ("git_smoke", git_smoke),
                     ("unlink_rmdir", cleanup)):
        steps[name] = step(fn)
        if not steps[name]["ok"]:
            # best-effort removal of only the gate's own names; never anything else, never a chmod/chown
            try:
                cleanup()
            except OSError:
                pass
            break
    return dict(uid=os.getuid(), gid=os.getgid(), root=root, steps=steps, root_stat=stat_dict(root),
                ok=all(s["ok"] for s in steps.values()))


def cmd_writegate(a):
    emit(run_gate(a[0]))


def cmd_mkwork(a):
    work = os.path.join(a[0], "work")
    for d in ("", "sources", "ws", "locks", "worktrees", "pp", "scratch", "perf"):
        os.makedirs(os.path.join(work, d), exist_ok=True)
    emit(dict(ok=True, work=work, listing=sorted(os.listdir(work)), stat=stat_dict(work)))


def cmd_df(a):
    sv = os.statvfs(a[0])
    total = sv.f_blocks * sv.f_frsize
    used = total - sv.f_bfree * sv.f_frsize
    emit(dict(total_mib=round(total / 1048576, 1), used_mib=round(used / 1048576, 1),
              used_pct=round(100 * used / total, 1) if total else None))


# ---------------------------------------------------------------------------------------- synthetic repos
def file_content(i, gen=0):
    base = f"file {i} gen {gen}\n"
    return (base + ("".join(f"line {i}-{j} {'x' * 40}\n" for j in range(20)))).encode()


def make_repo(parent, name, nfiles, ncommits):
    """work repo parent/<name>-work (branches main, alt) and bare clone parent/<name>.git. Deterministic."""
    work, bare = os.path.join(parent, name + "-work"), os.path.join(parent, name + ".git")
    os.makedirs(work, exist_ok=False)
    for args in (["init", "-q", "-b", "main"], ):
        assert git(args, cwd=work).returncode == 0
    for i in range(nfiles):
        d = os.path.join(work, f"d{i % 50:02d}")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"f{i}.txt"), "wb") as f:
            f.write(file_content(i))
    assert git(["add", "-A"], cwd=work).returncode == 0
    assert git(["commit", "-q", "-m", "initial"], cwd=work).returncode == 0
    for c in range(1, ncommits):
        for i in range(c % max(nfiles, 1), nfiles, max(nfiles // 10, 1)):
            with open(os.path.join(work, f"d{i % 50:02d}", f"f{i}.txt"), "ab") as f:
                f.write(f"commit {c}\n".encode())
        assert git(["commit", "-q", "-a", "-m", f"commit {c}"], cwd=work).returncode == 0
    assert git(["checkout", "-q", "-b", "alt"], cwd=work).returncode == 0
    for i in range(nfiles):
        with open(os.path.join(work, f"d{i % 50:02d}", f"f{i}.txt"), "wb") as f:
            f.write(file_content(i, gen=1))
    assert git(["commit", "-q", "-a", "-m", "alt: touch every file"], cwd=work).returncode == 0
    assert git(["checkout", "-q", "main"], cwd=work).returncode == 0
    assert git(["clone", "-q", "--bare", "--", work, bare]).returncode == 0
    head = git(["rev-parse", "main"], cwd=bare).stdout.strip()
    return dict(work=work, bare=bare, files=nfiles, commits=ncommits, head=head)


def cmd_mkrepo(a):
    parent, name, nfiles, ncommits = a[0], a[1], int(a[2]), int(a[3])
    t = time.monotonic()
    out = make_repo(parent, name, nfiles, ncommits)
    out["seconds"] = round(time.monotonic() - t, 3)
    emit(out)


def cmd_fsck(a):
    r = git(["fsck", "--strict", "--no-progress"], cwd=a[0])
    emit(dict(ok=r.returncode == 0, rc=r.returncode, stderr=r.stderr.strip()[-500:],
              stdout=r.stdout.strip()[-500:]))


def cmd_gitinfo(a):
    """Read-only repo facts (GIT_OPTIONAL_LOCKS=0, no index rewrite)."""
    cwd = a[0]
    g = lambda *x: git(list(x), cwd=cwd, env={"GIT_OPTIONAL_LOCKS": "0"})  # noqa: E731
    head, cnt, wt = g("rev-parse", "HEAD"), g("rev-list", "--count", "HEAD"), g("worktree", "list", "--porcelain")
    emit(dict(head=head.stdout.strip(), head_rc=head.returncode, head_err=head.stderr.strip()[-300:],
              commits=int(cnt.stdout.strip() or 0) if cnt.returncode == 0 else None,
              worktrees=[ln for ln in wt.stdout.splitlines() if ln.startswith("worktree ")],
              branch=g("rev-parse", "--abbrev-ref", "HEAD").stdout.strip(),
              dotgit_file=_read_small(os.path.join(cwd, ".git"))))


def _read_small(p):
    try:
        if os.path.isfile(p):
            return open(p).read(300).strip()
    except OSError:
        pass
    return None


# ---------------------------------------------------------------------------------------- R03 ping-pong
def visible(path, mode):
    """Is `path` visible to this client? mode: open | stat | listdir."""
    if mode == "open":
        try:
            os.close(os.open(path, os.O_RDONLY))
            return True
        except FileNotFoundError:
            return False
    if mode == "stat":
        try:
            os.stat(path)
            return True
        except FileNotFoundError:
            return False
    if mode == "listdir":
        return os.path.basename(path) in os.listdir(os.path.dirname(path))
    raise ValueError(mode)


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


def write_sync(path, data, excl=False):
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if excl else os.O_TRUNC)
    fd = os.open(path, flags, 0o644)
    try:
        os.write(fd, data.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def wait_for(pred, timeout, poll=0.002):
    t0 = time.monotonic()
    while True:
        v = pred()
        if v:
            return time.monotonic() - t0
        if time.monotonic() - t0 > timeout:
            return None
        time.sleep(poll)


def pingpong(role, d, n, mode, kind, timeout):
    """A writes ping i and waits for pong i; B waits for ping i (content-checked) and writes pong i.
    A measures round trips on its own monotonic clock only (no cross-node clock needed)."""
    os.makedirs(d, exist_ok=True)
    tag = f"{kind}.{mode}"
    ready = os.path.join(d, f"b-ready.{tag}")
    inplace = os.path.join(d, f"inplace.{tag}")
    res = dict(role=role, mode=mode, kind=kind, n=n, timeouts=0, content_mismatch=0, rtt_ms=[], wait_ms=[])
    if role == "b":
        write_sync(ready, "ready", excl=False)
    else:
        if wait_for(lambda: visible(ready, "open"), 60, 0.05) is None:
            res["error"] = "B never became ready"
            return res
    for i in range(n):
        payload = f"{i}:{tag}"
        ping = inplace if kind == "inplace" else os.path.join(d, f"ping.{tag}.{i}")
        pong = os.path.join(d, f"pong.{tag}.{i}")
        if role == "a":
            t0 = time.monotonic()
            write_sync(ping, payload, excl=(kind == "new"))
            dt = wait_for(lambda: read_text(pong) == payload, timeout)  # noqa: B023 (called immediately)
            if dt is None:
                res["timeouts"] += 1
            else:
                res["rtt_ms"].append(round((time.monotonic() - t0) * 1000, 2))
        else:
            if kind == "inplace":
                pred = lambda: read_text(ping) == payload  # noqa: E731,B023
            else:
                pred = lambda: visible(ping, mode)  # noqa: E731,B023
            dt = wait_for(pred, timeout)
            if dt is None:
                res["timeouts"] += 1
                write_sync(pong, "timeout")
                continue
            res["wait_ms"].append(round(dt * 1000, 2))
            if kind == "new" and read_text(ping) != payload:
                # visible by name but stale/empty content: a close-to-open violation worth recording
                if wait_for(lambda: read_text(ping) == payload, timeout) is None:  # noqa: B023
                    res["content_mismatch"] += 1
            write_sync(pong, payload)
    return res


def cmd_pingpong(a):
    role, d, n, mode, kind = a[0], a[1], int(a[2]), a[3], a[4]
    timeout = float(a[5]) if len(a) > 5 else 30.0
    emit(pingpong(role, d, n, mode, kind, timeout))


# ---------------------------------------------------------------------------------------- R06 locks
def take_lock(path, kind, blocking, timeout):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    t0 = time.monotonic()
    while True:
        try:
            if kind == "flock":
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0)
            return fd, True, None, time.monotonic() - t0
        except OSError as e:
            if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                os.close(fd)
                return None, False, en(e), time.monotonic() - t0
        if not blocking or time.monotonic() - t0 >= timeout:
            os.close(fd)
            return None, False, "EWOULDBLOCK", time.monotonic() - t0
        time.sleep(0.05)


def cmd_lockhold(a):
    path, seconds, kind = a[0], float(a[1]), (a[2] if len(a) > 2 else "flock")
    fd, ok, err, _ = take_lock(path, kind, False, 0)
    print(json.dumps(dict(event="HELD" if ok else "NOT_HELD", errno=err, kind=kind, ts=time.time())), flush=True)
    if not ok:
        emit(dict(ok=False, errno=err))
        return
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    time.sleep(seconds)
    emit(dict(ok=True, held_seconds=seconds, released=True))


def cmd_locktry(a):
    path, timeout, kind = a[0], float(a[1]), (a[2] if len(a) > 2 else "flock")
    fd, ok, err, waited = take_lock(path, kind, True, timeout)
    if ok:
        os.close(fd)
    emit(dict(acquired=ok, errno=err, waited_s=round(waited, 3), kind=kind, timeout_s=timeout))


# ---------------------------------------------------------------------------------------- R07 renameat2
def _renameat2(src, dst, flags):
    libc = ctypes.CDLL(None, use_errno=True)
    fn = libc.renameat2
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    fn.restype = ctypes.c_int
    ctypes.set_errno(0)
    rc = fn(-100, os.fsencode(src), -100, os.fsencode(dst), flags)
    return rc, ctypes.get_errno()


def rename_probe(d):
    base = os.path.join(d, f"rn-{os.getpid()}")
    os.makedirs(base)
    out = {}

    def mk(kind, name):
        p = os.path.join(base, name)
        if kind == "file":
            open(p, "w").write(name)
        else:
            os.mkdir(p)
        return p

    cases = [("file_to_absent", "file", None), ("file_to_existing_file", "file", "file"),
             ("dir_to_absent", "dir", None), ("dir_to_existing_empty_dir", "dir", "dir")]
    for label, skind, dkind in cases:
        src = mk(skind, f"{label}-src")
        dst = os.path.join(base, f"{label}-dst")
        if dkind:
            mk(dkind, f"{label}-dst")
        try:
            rc, err = _renameat2(src, dst, RENAME_NOREPLACE)
            out[label] = dict(rc=rc, errno=errno.errorcode.get(err, str(err)) if err else None,
                              src_exists_after=os.path.lexists(src), dst_exists_after=os.path.lexists(dst))
        except AttributeError:
            out[label] = dict(rc=-1, errno="NO_RENAMEAT2_SYMBOL")
    # plain rename onto an existing EMPTY directory: documents why the fallback re-checks absence under the lock
    s, t = mk("dir", "plain-src"), mk("dir", "plain-dst")
    try:
        os.rename(s, t)
        out["plain_rename_dir_onto_empty_dir"] = dict(replaced=True, src_exists_after=os.path.lexists(s))
    except OSError as e:
        out["plain_rename_dir_onto_empty_dir"] = dict(replaced=False, errno=en(e))
    # plain rename onto an existing NON-empty directory must fail (ENOTEMPTY/EEXIST); never pre-create an empty target
    s2, t2 = mk("dir", "ne-src"), mk("dir", "ne-dst")
    open(os.path.join(t2, "x"), "w").write("x")
    try:
        os.rename(s2, t2)
        out["plain_rename_dir_onto_nonempty_dir"] = dict(replaced=True)
    except OSError as e:
        out["plain_rename_dir_onto_nonempty_dir"] = dict(replaced=False, errno=en(e), src_exists_after=os.path.lexists(s2))
    s3, t3 = mk("dir", "ne2-src"), mk("dir", "ne2-dst")
    open(os.path.join(t3, "x"), "w").write("x")
    rc, err = _renameat2(s3, t3, RENAME_NOREPLACE)
    out["noreplace_dir_onto_nonempty_dir"] = dict(rc=rc, errno=errno.errorcode.get(err, str(err)) if err else None)
    supported = out["file_to_absent"].get("rc") == 0 and out["file_to_existing_file"].get("errno") == "EEXIST"
    out["noreplace_supported"] = bool(supported)
    out["noreplace_einval_or_enosys"] = any(v.get("errno") in ("EINVAL", "ENOSYS") for v in out.values()
                                            if isinstance(v, dict))
    shutil.rmtree(base, ignore_errors=True)
    return out


def cmd_renameprobe(a):
    emit(rename_probe(a[0]))


# ---------------------------------------------------------------------------------------- R08 races
def wait_until(ts):
    d = ts - time.time()
    if d > 0:
        time.sleep(d)


def oexcl_race(d, n, label, start_at):
    os.makedirs(d, exist_ok=True)
    wait_until(start_at)
    won, lost, other = [], 0, {}
    for i in range(n):
        p = os.path.join(d, f"x{i}")
        try:
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.write(fd, label.encode())
            os.fsync(fd)
            os.close(fd)
            won.append(i)
        except FileExistsError:
            lost += 1
        except OSError as e:
            other[en(e)] = other.get(en(e), 0) + 1
    return dict(label=label, n=n, won=won, lost=lost, other_errors=other)


def cmd_oexcl(a):
    emit(oexcl_race(a[0], int(a[1]), a[2], float(a[3])))


def verify_oexcl(d, n, labels):
    """Each name must exist exactly once, written by exactly one label."""
    owners = {}
    for i in range(n):
        owners[i] = read_text(os.path.join(d, f"x{i}"))
    missing = [i for i, o in owners.items() if o is None]
    return dict(n=n, missing=missing, by_label={lb: sum(1 for o in owners.values() if o == lb) for lb in labels})


def cmd_oexcl_verify(a):
    emit(verify_oexcl(a[0], int(a[1]), a[2].split(",")))


def append_race(path, n, label, start_at):
    wait_until(start_at)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    errs = 0
    for i in range(n):
        try:
            os.write(fd, f"{label}:{i:05d}\n".encode())
        except OSError:
            errs += 1
    os.fsync(fd)
    os.close(fd)
    return dict(label=label, n=n, write_errors=errs)


def cmd_appendrace(a):
    emit(append_race(a[0], int(a[1]), a[2], float(a[3])))


def analyze_append(path, n, labels):
    lines = open(path).read().splitlines()
    got = {lb: set() for lb in labels}
    garbled = 0
    for ln in lines:
        m = re.fullmatch(r"([a-z0-9-]+):(\d{5})", ln)
        if m and m.group(1) in got:
            got[m.group(1)].add(int(m.group(2)))
        else:
            garbled += 1
    return dict(expected=n * len(labels), lines=len(lines), garbled=garbled,
                missing={lb: n - len(v) for lb, v in got.items()})


def cmd_appendverify(a):
    emit(analyze_append(a[0], int(a[1]), a[2].split(",")))


def git_race(repo, n, label, start_at):
    """Commit loop on a SHARED repo/index from this pod. Classifies every failure; never retries."""
    wait_until(start_at)
    ok, kinds = 0, {}
    samples = {}
    for i in range(n):
        with open(os.path.join(repo, f"{label}-{i}.txt"), "w") as f:
            f.write(f"{label} {i}\n")
        a = git(["add", f"{label}-{i}.txt"], cwd=repo)
        c = git(["commit", "-q", "-m", f"{label} {i}"], cwd=repo) if a.returncode == 0 else a
        if c.returncode == 0:
            ok += 1
            continue
        msg = (c.stderr + c.stdout)
        if "index.lock" in msg:
            k = "index.lock"
        elif ".lock" in msg and "ref" in msg.lower():
            k = "ref-lock"
        elif "nothing" in msg.lower() or "no changes" in msg.lower():
            k = "nothing-to-commit"
        elif "dubious ownership" in msg:
            k = "dubious-ownership"
        else:
            k = "other"
        kinds[k] = kinds.get(k, 0) + 1
        samples.setdefault(k, msg.strip().replace("\n", " ")[:200])
    return dict(label=label, n=n, commits_ok=ok, failures=kinds, samples=samples)


def cmd_gitrace(a):
    emit(git_race(a[0], int(a[1]), a[2], float(a[3])))


# ---------------------------------------------------------------------------------------- R10 posix edges
def posix_edges(d, label):
    os.makedirs(d, exist_ok=True)
    out = {}
    # umask / mode
    modes = {}
    for um in (0o022, 0o002, 0o077):
        old = os.umask(um)
        try:
            f, dd = os.path.join(d, f"um{um:03o}-f"), os.path.join(d, f"um{um:03o}-d")
            os.close(os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o666))
            if not os.path.isdir(dd):
                os.mkdir(dd, 0o777)
            modes[f"{um:03o}"] = dict(file=oct(os.stat(f).st_mode & 0o7777), dir=oct(os.stat(dd).st_mode & 0o7777),
                                       gid=os.stat(f).st_gid)
        finally:
            os.umask(old)
    out["umask_modes"] = modes
    # chmod on own file, then access
    p = os.path.join(d, "perm.txt")
    open(p, "w").write("x")
    os.chmod(p, 0o444)
    out["chmod_444_access_w"] = os.access(p, os.W_OK)
    os.chmod(p, 0o644)
    # setgid directory (chmod on a directory this process created)
    sg = os.path.join(d, "setgid-dir")
    os.makedirs(sg, exist_ok=True)
    out["chmod_g_s_dir"] = step(lambda: os.chmod(sg, 0o2775))
    # mmap + msync, content verified by the other pod through `readsha`
    mp = os.path.join(d, f"mmap-{label}.bin")
    fd = os.open(mp, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
    os.ftruncate(fd, 65536)
    mm = mmap.mmap(fd, 65536)
    pattern = (label.encode() * 65536)[:65536]
    mm[:] = pattern
    mm.flush()
    mm.close()
    os.fsync(fd)
    os.close(fd)
    out["mmap_file"] = mp
    out["mmap_sha256"] = sha256_file(mp)
    # fsync / fdatasync latency
    lat = []
    for i in range(20):
        fp = os.path.join(d, f"sync-{label}-{i}")
        fd = os.open(fp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        os.write(fd, b"y" * 4096)
        t = time.monotonic()
        os.fsync(fd)
        lat.append((time.monotonic() - t) * 1000)
        os.close(fd)
    out["fsync_ms"] = dict(min=round(min(lat), 2), median=round(sorted(lat)[len(lat) // 2], 2), max=round(max(lat), 2))
    # hardlink / symlink / atomic replace / truncate / xattr
    a, b = os.path.join(d, "hl-a"), os.path.join(d, "hl-b")
    open(a, "w").write("hl")
    out["hardlink"] = step(lambda: (os.link(a, b), dict(nlink=os.stat(a).st_nlink))[1])
    out["symlink"] = step(lambda: (os.symlink("hl-a", os.path.join(d, "sl")), dict(target=os.readlink(os.path.join(d, "sl"))))[1])
    t1, t2 = os.path.join(d, "rep-1"), os.path.join(d, "rep-2")
    open(t1, "w").write("new")
    open(t2, "w").write("old")
    out["atomic_replace"] = step(lambda: (os.replace(t1, t2), dict(content=open(t2).read()))[1])
    out["xattr_user"] = step(lambda: (os.setxattr(a, "user.exp005", b"1"), dict(val=os.getxattr(a, "user.exp005").decode()))[1])
    out["fallocate"] = step(lambda: os.posix_fallocate(os.open(os.path.join(d, "falloc"), os.O_RDWR | os.O_CREAT, 0o644), 0, 8192))
    return out


def cmd_posixedges(a):
    emit(posix_edges(a[0], a[1]))


def cmd_readsha(a):
    emit(dict(sha256=sha256_file(a[0]), stat=stat_dict(a[0])))


def cmd_statinfo(a):
    emit({p: (stat_dict(p) if os.path.lexists(p) else None) for p in a})


# ---------------------------------------------------------------------------------------- R11 performance
def timed(fn):
    t = time.monotonic()
    fn()
    return time.monotonic() - t


def small_file_ops(d, n):
    os.makedirs(d)
    names = [os.path.join(d, f"f{i % 20}", f"s{i}") for i in range(n)]
    for i in range(20):
        os.makedirs(os.path.join(d, f"f{i}"))
    data = b"z" * 1024

    def create():
        for p in names:
            with open(p, "wb") as f:
                f.write(data)

    def stat():
        for p in names:
            os.stat(p)

    def read():
        for p in names:
            with open(p, "rb") as f:
                f.read()

    def delete():
        for p in names:
            os.unlink(p)

    return dict(create=timed(create), stat=timed(stat), read=timed(read), delete=timed(delete))


def perf_run(src_bare, dest_parent, nfiles, runs, prefix):
    import shutil
    ops = {}

    def add(k, v):
        ops.setdefault(k, []).append(round(v, 4))

    for r in range(runs):
        dest = os.path.join(dest_parent, f"{prefix}-{r}")  # lambdas below run immediately within this iteration
        add("clone", timed(lambda: git(["clone", "-q", "--", src_bare, dest]).check_returncode()))
        add("status_clean", timed(lambda: git(["status", "--porcelain"], cwd=dest).check_returncode()))
        add("checkout_alt", timed(lambda: git(["checkout", "-q", "alt"], cwd=dest).check_returncode()))
        add("status_after_checkout", timed(lambda: git(["status", "--porcelain"], cwd=dest).check_returncode()))
        add("checkout_main", timed(lambda: git(["checkout", "-q", "main"], cwd=dest).check_returncode()))
        add("fsck", timed(lambda: git(["fsck", "--no-progress"], cwd=dest).check_returncode()))
        add("rm_tree", timed(lambda: shutil.rmtree(dest)))
        for k, v in small_file_ops(os.path.join(dest_parent, f"{prefix}-sf-{r}"), nfiles).items():
            add("small_" + k, v)
        shutil.rmtree(os.path.join(dest_parent, f"{prefix}-sf-{r}"), ignore_errors=True)
    return dict(prefix=prefix, files=nfiles, runs=runs, ops=ops)


def cmd_perf(a):
    emit(perf_run(a[0], a[1], int(a[2]), int(a[3]), a[4]))


def cmd_heartbeat(a):
    """Write a timestamp to FILE every ~200 ms for SECONDS; report the longest gap and any I/O errors."""
    path, seconds = a[0], float(a[1])
    end, last, gaps, errs, writes = time.monotonic() + seconds, time.monotonic(), [], {}, 0
    while time.monotonic() < end:
        t = time.monotonic()
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            os.write(fd, f"{time.time()}\n".encode())
            os.fsync(fd)
            os.close(fd)
            writes += 1
        except OSError as e:
            errs[en(e)] = errs.get(en(e), 0) + 1
        gaps.append(t - last)
        last = t
        time.sleep(0.2)
    emit(dict(writes=writes, errors=errs, max_gap_s=round(max(gaps), 3) if gaps else None, seconds=seconds))


def cmd_rename(a):
    """rename(2) of a path this harness created, within the same volume (R09 optional sub-step)."""
    emit(step(lambda: os.rename(a[0], a[1])))


def cmd_clock(_a):
    emit(dict(time=time.time()))


def cmd_gitcommit(a):
    """Add and commit one synthetic file in repo a[0] (label a[1], counter a[2]); print the new HEAD."""
    repo, label, i = a[0], a[1], a[2]
    with open(os.path.join(repo, f"handoff-{label}-{i}.txt"), "w") as f:
        f.write(f"{label} {i}\n")
    r1 = git(["add", f"handoff-{label}-{i}.txt"], cwd=repo)
    r2 = git(["commit", "-q", "-m", f"handoff {label} {i}"], cwd=repo) if r1.returncode == 0 else r1
    head = git(["rev-parse", "HEAD"], cwd=repo).stdout.strip()
    emit(dict(ok=r2.returncode == 0, rc=r2.returncode, head=head, stderr=r2.stderr.strip()[-300:]))


def cmd_listing(a):
    """Names (not contents) under a directory, depth-limited. For evidence of what exists."""
    base, depth = a[0], int(a[1]) if len(a) > 1 else 2
    out = []
    for root, dirs, files in os.walk(base):
        if root[len(base):].count(os.sep) >= depth:
            dirs[:] = []
        out.append(os.path.relpath(root, base) + "/ " + str(len(files)) + " files")
    emit(dict(base=base, dirs=out[:200]))


COMMANDS = {k[4:]: v for k, v in dict(globals()).items() if k.startswith("cmd_")}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print("usage: podprobe <" + "|".join(sorted(COMMANDS)) + "> [args]", file=sys.stderr)
        return 2
    COMMANDS[argv[1]](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
