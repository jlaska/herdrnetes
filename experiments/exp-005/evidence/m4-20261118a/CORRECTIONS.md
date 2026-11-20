# Run m4-20261118a: harness results versus reported classification

`results-014249.tsv` and `summary-014249.json` are the harness output as recorded (`failures: 4`) and are not
edited. `RESULTS.md` reports these four checks differently, for the reasons below. Each reason rests only on raw files
in this directory.

| Check | Harness | Reported | Basis |
| --- | --- | --- | --- |
| F06 | FAIL | FAIL → fixed (F06r PASS) | Real defect: the original tool adopted a linked worktree (`raw/f06-*`). That tool was the M1 ConfigMap copy, not hashed at the time; `harness/request-repo` as committed in b844b6d has sha256 `ca9bc27950f88fd6cd4b4b54f47d3ceebfd780499ed2623b560e61a2047d6fa7`. F06r ran the fixed tool, `raw/f06r-tool-sha.txt` (`b1729a55…`), which matches the committed tool at 204bc04. |
| F01-kill | FAIL | LIMITATION | The threshold was "Git helpers gone within 2s of the SIGKILL". They took 4.96s (`raw/f01-kill.txt`). Correctness held: F01 PASS, target absent, retry hydrated, fsck clean. Tracked in issue #34. |
| F03 | FAIL | PASS | The check compared `rcs` to `{'0': 8}`, but the harness itself records rcs as `{'rc=0': 8}` (`F03-raw`, `raw/f03-all.txt`). Every other criterion passed: hydrated=1, already_ready=7, one clone, attempts=1, fsck clean. |
| F02-ready | FAIL | PASS | The check required a new `herdr server` PID. A restarted container gets a new PID namespace, where the PID is 7 again. The restart is established by restartCount 0→1 with the same pod UID (`raw/f02-container-state.txt`). |

The harness check logic (`harness/m4-cluster.sh`) for F03 and F02-ready was fixed after the run. The run was not
repeated.
