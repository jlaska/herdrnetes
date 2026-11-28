"""Writes a C4c fixture in the harness's own E/L layout, for tests/c4c-bundle-test.sh (FIND-101 regression).

Usage: python3 -I c4c_fixture.py <E> <L> <session-uuid>
The post-resume run is test_metrics4's expected primary-pass shape (probe answered, one "Continue the task.",
the in-flight step re-attempted once, two more steps), with every transcript entry carrying <session-uuid>.
Only the files the stagec4.sh c4c bundle block reads are written; the transcript listing (obs/c4c-final-T.txt)
and tr_rel are left to the test, which varies them.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("test_metrics4", os.path.join(HERE, "test_metrics4.py"))
tm = importlib.util.module_from_spec(_s)
_s.loader.exec_module(tm)

E, L, sid = sys.argv[1], sys.argv[2], sys.argv[3]
tm.TB.__init__.__defaults__ = (sid,)  # every synthetic entry carries the given session id
with tempfile.TemporaryDirectory() as td:
    r = tm.Run(td)
    r.probe(); r.cont(); r.continue_steps()
    b = r.bundle()
    for d in ("metrics", "obs"):
        os.makedirs(os.path.join(E, d), exist_ok=True)
    for d in ("task", "tr"):
        os.makedirs(os.path.join(L, d), exist_ok=True)
    shutil.copytree(b["R_dir"], os.path.join(L, "task", "c4a-R"))
    shutil.copytree(b["final_dir"], os.path.join(L, "task", "c4c-final"))
    os.makedirs(os.path.join(L, "task", "c4b-pre"))
    shutil.copy(b["pre_transcript"], os.path.join(L, "task", "c4b-pre", "transcript.jsonl"))
    shutil.copy(b["R_transcript"], os.path.join(L, "tr", "c4a-R.jsonl"))
    shutil.copy(b["final_transcript"], os.path.join(L, "tr", "c4c-final.jsonl"))
    json.dump(b["c4b"], open(os.path.join(E, "metrics", "c4b.json"), "w"))
    json.dump({"pass": True}, open(os.path.join(E, "metrics", "c0-control.json"), "w"))
    open(os.path.join(E, "obs", "c4b-result.txt"), "w").write("step=c4b value=intact\nlauncher_refusal=none approval_tail=same,same\n")
    open(os.path.join(L, "c4c-probe"), "w").write(tm.TOK)
    open(os.path.join(L, "codeword"), "w").write(tm.CW)
    # the shell variables the block reads, as the c4c step sets them
    print(json.dumps({"M_s": b["M_s"], "start_t": b["start_t"], "dialogs": b["dialogs"], "c4b_value": b["c4b"]["value"]}))
