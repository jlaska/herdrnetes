"""EXP-008 Stage C4: real-model predicate, strict probe, C4b state comparison and the C4c decision procedure.

Stdlib only, offline. Never prints transcript text, prompts, replies, tokens, the codeword or commands: only
counts, hashes, booleans, timestamps and classification values, so its output may be committed after the
redaction scan. Reused C0-C3 functions are loaded by path from ../stage-c/metrics.py (unchanged there).

usage:
  python3 -I metrics4.py h4      <transcript.jsonl>                  -> real model entries (C0 H4 gate)
  python3 -I metrics4.py probe4  <transcript.jsonl> <token> <codeword-file> <expected_last_csv> [after_bytes]
  python3 -I metrics4.py activity <transcript.jsonl> <after_bytes>   -> real model / API-error entries after a byte offset
  python3 -I metrics4.py c4b     <bundle.json>                       -> C4b value and allowance items
  python3 -I metrics4.py c4c     <bundle.json>                       -> every C4c axis and the Resume value
Design: STAGE-C4-PROPOSAL.md (PR #48, f19de00) sections 5.4, 5.6, 5.7, 6.2, 6.3 and 7.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import sys

_spec = importlib.util.spec_from_file_location(
    "stagec_metrics", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "stage-c", "metrics.py"))
m0 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m0)

PINNED_MODEL = "claude-haiku-5-5"  # exact match: a different or dated id fails closed (not counted)
STEP_CMD_RE = re.compile(r"^\./step\.sh ([0-9]+) ([a-z0-9]+)$")  # the ONLY conforming Bash command
# the reply must be EXACTLY this one line (surrounding whitespace only): no prefix, suffix, second line or punctuation
PROBE_RE = re.compile(r"PROBE-([0-9a-f]{8}) CODEWORD=([A-Za-z0-9]+) LAST=(0|[1-9][0-9]{0,2})")
TAIL_TYPES = {"assistant", "api-request", "cost-state", "last-prompt"}  # tail entries 1-3 (approved allowance)
TAIL_META_TYPES = {"api-request", "cost-state", "last-prompt"}           # tail entries 4-5 (owner decision D-1)
TAIL_MAX_BYTES, TAIL_MAX_ENTRIES, TAIL_BASE_ENTRIES = 65536, 5, 3
C4B_VALUES = ("intact", "intact-with-allowance", "corrupt", "lost", "not-restartable", "unmeasured")
RESUME_VALUES = ("lost", "fresh-no-history", "inconclusive", "not-started", "failed", "re-executed", "probe-ignored",
                 "resumed-context-lost", "resumed-auto-continued", "resumed-continued-after-prompt", "responded-no-progress")


# ---------------------------------------------------------------- the shared real-model-response predicate (A)
def is_real_model_entry(e: dict, model: str = PINNED_MODEL) -> bool:
    """A transcript entry that is a real response of the pinned model: type assistant, a message object with
    a non-empty id, model == the pinned model, a usage object with integer input and output counts, and no
    API-error marker. Synthetic entries (model "<synthetic>", e.g. an API error shown to the user, or the
    "No response requested." entry Claude Code appends on resume) and malformed lines never qualify."""
    if not isinstance(e, dict) or e.get("_bad") or e.get("type") != "assistant":
        return False
    if e.get("isApiErrorMessage") or e.get("error"):
        return False
    msg = e.get("message")
    if not isinstance(msg, dict) or msg.get("model") != model:
        return False
    mid, u = msg.get("id"), msg.get("usage")
    if not isinstance(mid, str) or not mid or not isinstance(u, dict):
        return False
    return m0._nonneg_int(u.get("input_tokens")) and m0._nonneg_int(u.get("output_tokens"))


def is_api_error_entry(e: dict) -> bool:
    if not isinstance(e, dict) or e.get("_bad"):
        return False
    if e.get("isApiErrorMessage"):
        return True
    return e.get("type") == "assistant" and isinstance(e.get("error"), (str, dict)) and bool(e.get("error"))


def is_synthetic_entry(e: dict) -> bool:
    return isinstance(e, dict) and e.get("type") == "assistant" and (e.get("message") or {}).get("model") == "<synthetic>"


def h4(tr: list[dict]) -> dict:
    real = [e for e in tr if is_real_model_entry(e)]
    return {"real_model_entries": len(real), "assistant_entries": sum(1 for e in tr if e.get("type") == "assistant"),
            "api_error_entries": sum(1 for e in tr if is_api_error_entry(e)),
            "synthetic_entries": sum(1 for e in tr if is_synthetic_entry(e)),
            "malformed_lines": sum(1 for e in tr if e.get("_bad")), "ok": bool(real)}


# ---------------------------------------------------------------- transcripts by byte offset
def load_bytes(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def parse_lines(data: bytes, base_line: int = 0) -> list[dict]:
    """JSONL bytes -> entries (as metrics.load_transcript); a line that does not parse is {_bad: True}."""
    out = []
    for i, raw in enumerate(data.split(b"\n")):
        if not raw.strip():
            continue
        try:
            e = json.loads(raw.decode("utf-8", "replace"))
            if not isinstance(e, dict):
                raise ValueError
        except ValueError:
            out.append({"_line": base_line + i, "_bad": True, "_partial": False})
            continue
        e["_line"] = base_line + i
        ts = e.get("timestamp")
        try:
            e["_t"] = m0.iso_ms(ts) if isinstance(ts, str) and ts.endswith("Z") else None
        except ValueError:
            e["_t"] = None
        out.append(e)
    if data and not data.endswith(b"\n") and out:
        out[-1]["_partial"] = True
    return out


def after(data: bytes, offset: int) -> list[dict]:
    """Entries written after byte <offset>. If the bytes before it do not end with a newline, the first
    segment completes (or seals) that torn line and is not a new entry (Claude Code 2.1.323 seals a torn
    tail with a newline before its next append: proposal CR1)."""
    rest = data[offset:]
    if offset > 0 and not data[:offset].endswith(b"\n"):
        nl = rest.find(b"\n")
        rest = b"" if nl < 0 else rest[nl + 1:]
    return parse_lines(rest)


def text_of(e: dict) -> str:
    return m0.text_of(e)


def tool_use_blocks(e: dict) -> list[dict]:
    return [b for b in m0.blocks(e) if b.get("type") == "tool_use"] if e.get("type") == "assistant" else []


def bash_commands(entries: list[dict]) -> list[dict]:
    out = []
    for e in entries:
        for b in tool_use_blocks(e):
            if b.get("name") == "Bash":
                out.append({"id": b.get("id"), "t": e.get("_t"), "cmd": str((b.get("input") or {}).get("command", ""))})
    return out


def find_step_tool_use(entries: list[dict], n: int) -> dict | None:
    """The LAST conforming `./step.sh n <token>` Bash tool_use (the in-flight call at the reference snapshot)."""
    hit = None
    for c in bash_commands(entries):
        m = STEP_CMD_RE.match(c["cmd"])
        if m and int(m.group(1)) == n:
            hit = {"id": c["id"], "t": c["t"], "token_sha256": hashlib.sha256(m.group(2).encode()).hexdigest()}
    return hit


# ---------------------------------------------------------------- strict probe (5.6)
def probe4(entries: list[dict], token: str, codeword: str | None, expected_last: set[int]) -> dict:
    """The probe/control line of proposal 5.6, in file order (Claude Code writes each content block as its
    own entry). Pass = delivered; a REAL model entry carries the token in the strict format; the codeword
    matches exactly; LAST is in expected_last; ZERO tool_use blocks between the probe entry and that reply.
    Tool calls ordered after the reply are continuation (task/prompt.txt asks the agent to continue)."""
    delivered = None
    queued = False
    for i, e in enumerate(entries):
        if e.get("type") == "assistant" or token not in text_of(e):
            continue
        att = e.get("attachment")
        if e.get("type") == "user" or (isinstance(att, dict) and att.get("type") == "queued_command"):
            delivered = i
            break
        queued = True
    r = {"delivered": delivered is not None, "queued_only": queued and delivered is None}
    if delivered is None:
        return r | {"reply": False, "pass": False, "first_action": "none", "tool_use_before_reply": 0}
    later = entries[delivered + 1:]
    first_action, tools_before, reply, reply_text = "none", 0, None, ""
    for e in later:
        if not is_real_model_entry(e):
            continue
        for b in m0.blocks(e):
            t = b.get("type")
            if t == "tool_use":
                tools_before += 1
                first_action = "tool" if first_action == "none" else first_action
            elif t == "text" and b.get("text", "").strip():
                first_action = "text" if first_action == "none" else first_action
                if token in b.get("text", ""):
                    reply, reply_text = e, b.get("text", "")
                    break
        if reply is not None:
            break
    if reply is None:
        tools_after = sum(len(tool_use_blocks(e)) for e in later if is_real_model_entry(e))
        return r | {"reply": False, "pass": False, "first_action": first_action, "tool_use_before_reply": tools_after}
    # strict: the first text block that carries the token must BE the one-line reply (fullmatch after strip)
    m = PROBE_RE.fullmatch(reply_text.strip())
    fmt = bool(m) and ("PROBE-" + m.group(1)) == token
    cw_ok = bool(fmt and codeword is not None and m.group(2) == codeword)
    last = int(m.group(3)) if fmt else None
    last_ok = bool(fmt and last in expected_last)
    hit_t, rep_t = entries[delivered].get("_t"), reply.get("_t")
    r |= {"reply": True, "format_ok": fmt, "codeword_ok": cw_ok, "last_ok": last_ok, "first_action": first_action,
          "tool_use_before_reply": tools_before, "reply_t": rep_t, "probe_t": hit_t,
          "reply_latency_ms": (rep_t - hit_t) if rep_t and hit_t else None}
    r["pass"] = bool(fmt and cw_ok and last_ok and tools_before == 0)
    return r


# ---------------------------------------------------------------- C4b: retained state against R (5.4, 6.2)
def _lines(p: str) -> list[str] | None:
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return None


def _sha(p: str) -> str | None:
    try:
        return hashlib.sha256(load_bytes(p)).hexdigest()
    except FileNotFoundError:
        return None


def in_flight(rdir: str) -> int | None:
    """N = the one step with an attempt and no done at R (the last attempt), or None if R has no single one."""
    att, prog = _lines(f"{rdir}/attempts.log") or [], _lines(f"{rdir}/progress.log") or []
    if not att:
        return None
    m = re.match(r"^attempt n=([0-9]+) ", att[-1])
    if not m:
        return None
    n = int(m.group(1))
    done = {int(x.group(1)) for x in (re.match(r"^done n=([0-9]+) ", l) for l in prog) if x}
    last_done = max(done) if done else 0
    return n if n not in done and n == last_done + 1 else None


def c4b(b: dict) -> dict:
    """b: {R_dir, pre_dir, R_transcript, pre_transcript, V_before, V_after, R_state_id_sha256,
    R_token_file_sha256, precheck: {state_id_sha256, next_token_hash_file_sha256, ...}}"""
    reasons: list[str] = []
    va, vb = b.get("V_after") or {}, b.get("V_before") or {}
    pc = b.get("precheck") or {}
    if b.get("not_restartable"):
        return {"value": "not-restartable", "reasons": [str(b.get("not_restartable"))]}
    if b.get("launch_mode") == "fresh":
        # the relaunched launcher found no state and started a fresh session: the state did not survive
        return {"value": "lost", "reasons": ["relaunch-ran-in-fresh-mode"]}
    if not b.get("precheck_present"):
        # no frozen copy was read. A refusal phrase (launcher log or record) says why; otherwise the state was
        # not measurable through the supported path (an exec failed): never reported as corrupt state.
        why = str(b.get("launcher_refusal") or "")
        if re.search(r"partial state|session id|transcript for the recorded session|state id", why):
            return {"value": "lost", "reasons": ["launcher:" + why[:80]]}
        if re.search(r"ledger chain broken|differs from the package|freeze directory", why):
            return {"value": "corrupt", "reasons": ["launcher:" + why[:80]]}
        return {"value": "unmeasured", "reasons": ["launcher:" + why[:80] if why else
                                                   ("precheck-listed-but-not-copied" if b.get("precheck_listed") else "no-precheck-read")]}
    for k in ("pvc_uid", "pv", "volume_handle"):
        if not vb.get(k) or va.get(k) != vb.get(k):
            reasons.append(f"volume-{k}-changed-or-unreadable")
    if not pc.get("state_id_sha256") or pc.get("state_id_sha256") != b.get("R_state_id_sha256"):
        reasons.append("state-id-changed-or-absent")
    if reasons:
        return {"value": "lost", "reasons": reasons}
    n = in_flight(b["R_dir"])
    if n is None:
        return {"value": "corrupt", "reasons": ["reference-has-no-single-in-flight-step"]}
    logs = {}
    for name in ("attempts", "progress", "refusals", "ledger", "locks"):
        r, p = _lines(f"{b['R_dir']}/{name}.log"), _lines(f"{b['pre_dir']}/{name}.log")
        r, p = r or [], p or []
        if p[: len(r)] != r:
            logs[name] = {"state": "changed"}
        else:
            logs[name] = {"state": "identical" if len(p) == len(r) else "appended", "added": p[len(r):]}
    for name in ("attempts", "refusals", "locks"):
        if logs[name]["state"] != "identical":
            reasons.append(f"{name}-{logs[name]['state']}")
    prog, led = logs["progress"], logs["ledger"]
    tok_changed = pc.get("next_token_hash_file_sha256") != b.get("R_token_file_sha256")
    done_added = prog["state"] == "appended" and len(prog["added"]) == 1 and re.match(rf"^done n={n} ", prog["added"][0])
    led_added = led["state"] == "appended" and len(led["added"]) == 1 and re.match(rf"^n={n} ", led["added"][0])
    if prog["state"] == "changed" or (prog["state"] == "appended" and not done_added):
        reasons.append("progress-unexpected")
    if led["state"] == "changed" or (led["state"] == "appended" and not led_added):
        reasons.append("ledger-unexpected")
    state = None
    if not reasons:
        key = (tok_changed, bool(done_added), bool(led_added))
        state = {(False, False, False): 0, (True, False, False): 1, (True, True, False): 2, (True, True, True): 3}.get(key)
        if state is None:
            reasons.append(f"partial-write-order-impossible:{key}")
    chain = m0.ledger(b["pre_dir"])
    if not chain["chain_ok"]:
        reasons.append("ledger-chain-broken")
    # transcript: byte prefix and the bounded tail (5.4 allowance)
    rt, pt = load_bytes(b["R_transcript"]), load_bytes(b["pre_transcript"])
    tail = {"prefix_ok": pt.startswith(rt), "R_bytes": len(rt), "pre_bytes": len(pt)}
    if not tail["prefix_ok"]:
        reasons.append("transcript-prefix-changed")
    else:
        ents = after(pt, len(rt))
        uuids = {e.get("uuid") for e in parse_lines(rt) if e.get("uuid")}
        stepn = find_step_tool_use(parse_lines(rt), n)
        cont, types_ok, extra_ok, tool_ok = True, True, True, True
        for pos, e in enumerate(ents, start=1):
            if e.get("_bad"):
                # a torn final line is allowed among entries 1-3 only: at positions 4-5 its type cannot be
                # recognized as metadata, so it is not accepted (D-1: entries 4-5 must be recognized metadata)
                if not e.get("_partial") or pos > TAIL_BASE_ENTRIES:
                    types_ok = types_ok and e.get("_partial", False)
                    extra_ok = extra_ok and pos <= TAIL_BASE_ENTRIES
                continue
            # also allowed among entries 1-3: the step-N tool result itself (in-flight-completed)
            # (exactly one block: step N's tool_result and nothing else)
            bl = m0.blocks(e)
            own_result = e.get("type") == "user" and stepn and len(bl) == 1 and bl[0].get("type") == "tool_result" and bl[0].get("tool_use_id") == stepn["id"]
            if pos > TAIL_BASE_ENTRIES:
                if e.get("type") not in TAIL_META_TYPES:
                    extra_ok = False
            elif e.get("type") not in TAIL_TYPES and not own_result:
                types_ok = False
            # no additional tool activity after R: the step-N call is already in R, so a tail tool_use is new work
            if tool_use_blocks(e):
                tool_ok = False
            if e.get("parentUuid") and e["parentUuid"] not in uuids:
                cont = False
            if e.get("uuid"):
                uuids.add(e["uuid"])
        tail |= {"tail_bytes": len(pt) - len(rt), "tail_entries": len(ents), "tail_extra_metadata_ok": extra_ok, "tail_no_tool_use": tool_ok,
                 "tail_partial_final": bool(ents and ents[-1].get("_partial")), "tail_types_ok": types_ok, "parent_continuity": cont}
        if tail["tail_bytes"] > TAIL_MAX_BYTES:
            reasons.append("tail-too-large")
        if len(ents) > TAIL_MAX_ENTRIES:
            reasons.append("tail-too-many-entries")
        if not types_ok:
            reasons.append("tail-unexpected-entry")
        if not extra_ok:
            reasons.append("tail-entry-4-5-not-metadata")
        if not tool_ok:
            reasons.append("tail-tool-activity")
        if not cont:
            reasons.append("tail-parent-discontinuity")
    allowance = []
    if tail.get("tail_entries"):
        allowance.append("transcript-tail")
    if state:
        allowance.append({1: "in-flight-partial(1)", 2: "in-flight-partial(2)", 3: "in-flight-completed"}[state])
    # chain-broken-by-fault: the step-N output (with the next token) is lost unless the tail holds it
    cbf = state in (1, 2)
    if state == 3:
        out_in_tail = any(f"STEP {n} OK" in text_of(e) for e in after(pt, len(rt)) if not e.get("_bad")) if tail.get("prefix_ok") else False
        cbf = not out_in_tail
    value = "corrupt" if reasons else ("intact-with-allowance" if allowance else "intact")
    return {"value": value, "in_flight_step": n, "in_flight_state": state if state is not None else "n/a",
            "chain_broken_by_fault": bool(cbf) if not reasons else None, "allowance": allowance,
            "logs": {k: {"state": v["state"], "added_lines": len(v.get("added", []))} for k, v in logs.items()},
            "token_hash_file_changed": tok_changed, "ledger": chain, "transcript": tail, "reasons": reasons}


# ---------------------------------------------------------------- C4c: decision procedure (6.3)
def _task_after(rdir: str, fdir: str, name: str) -> list[str]:
    r, f = _lines(f"{rdir}/{name}.log") or [], _lines(f"{fdir}/{name}.log") or []
    return f[len(r):] if f[: len(r)] == r else f


def _kv(line: str) -> dict:
    return dict(re.findall(r"(\w+)=(\S+)", line))


def c4c(b: dict) -> dict:
    """b (built by stagec4.sh c4c from local copies; see README section 5):
    c4b: C4b result dict; R_dir/final_dir: task-log copies; R_transcript/pre_transcript/final_transcript: paths;
    transcripts_after: transcript file names seen after resume; R_transcript_name; process: new-process |
    not-started | same-as-original; launcher_refused: bool; probe_token; codeword (str); expected_last: [int];
    control_pass: bool; M_s: float; start_t: resume start (ms, sandbox clock); end_t: end of observation;
    dialogs: {name: bool}; spend_stop: bool; probe_typed: bool; continue_typed: bool."""
    v = {"axes": {}, "attributes": {}, "decision_path": []}
    c4bv = (b.get("c4b") or {}).get("value")
    n = (b.get("c4b") or {}).get("in_flight_step")
    v["attributes"]["c4b"] = c4bv
    pre = load_bytes(b["pre_transcript"]) if b.get("pre_transcript") and os.path.exists(b["pre_transcript"]) else b""
    if not pre and b.get("R_transcript") and os.path.exists(b["R_transcript"]):
        pre = load_bytes(b["R_transcript"])  # no frozen copy read: R (a prefix of it) is the boundary
        v["attributes"]["boundary"] = "R"
    fin_ok = bool(b.get("final_transcript")) and os.path.exists(b["final_transcript"])
    fin = load_bytes(b["final_transcript"]) if fin_ok else b""
    v["attributes"]["final_transcript_available"] = fin_ok
    post = after(fin, len(pre)) if fin.startswith(pre) and pre else []
    # ---- Session axis
    # names: transcript basenames seen after resume (all project directories). The final copy is always the
    # pre-fault file. A different basename = a new session id; the same basename twice = a second file for the
    # same id; the pre-fault file no longer starting with its frozen bytes = the history was not kept.
    names = b.get("transcripts_after") or []
    rname = b.get("R_transcript_name")
    if not fin_ok or not names:
        session = "unavailable"  # no final copy, or no listing proving which transcript files exist
    elif not fin or not pre or not fin.startswith(pre):
        session = "fresh-no-history"
    elif any(x != rname for x in names):
        session = "new-id"
    elif names.count(rname) > 1:
        session = "same-id-new-file"
    elif names == [rname]:
        session = "same-id-same-file"
    else:
        session = "unavailable"
    v["axes"]["session"] = session
    # unambiguous original-session continuation: ONE session id before the fault, and every resumed entry
    # carries that same id (a second id inside the same file would be an ambiguous identity)
    pre_sids = {e.get("sessionId") for e in parse_lines(pre) if e.get("sessionId")}
    post_sids = {e.get("sessionId") for e in post if e.get("sessionId")}
    stem = (rname or "").removesuffix(".jsonl")
    sid_consistent = len(pre_sids) == 1 and bool(post_sids) and post_sids <= pre_sids and pre_sids == {stem}
    v["attributes"]["session_ids_consistent"] = sid_consistent
    # ---- Process axis
    proc = b.get("process") or "not-started"
    v["axes"]["process"] = proc
    # ---- evidence after the resume boundary
    real = [e for e in post if is_real_model_entry(e)]
    api_err = [e for e in post if is_api_error_entry(e)]
    pr = probe4(post, b.get("probe_token") or "\0", b.get("codeword"), set(b.get("expected_last") or [])) if b.get("probe_token") else \
        {"delivered": False, "pass": False, "reply": False, "first_action": "none", "tool_use_before_reply": 0}
    inputs = [t for t in (pr.get("probe_t"),) if t]
    cont_t = None
    for e in post:
        if e.get("type") == "user" and "Continue the task." in text_of(e):
            cont_t = e.get("_t")
            break
    if cont_t:
        inputs.append(cont_t)
    first_input = min(inputs) if inputs else None
    last_input = max(inputs) if inputs else None
    rt = parse_lines(load_bytes(b["R_transcript"])) if b.get("R_transcript") and os.path.exists(b["R_transcript"]) else []
    stepn = find_step_tool_use(rt, n) if n else None
    cmds = bash_commands(post)
    nonconf = [c for c in cmds if not STEP_CMD_RE.match(c["cmd"])]
    att = [_kv(l) | {"_raw": l} for l in _task_after(b["R_dir"], b["final_dir"], "attempts")]
    done = {int(_kv(l).get("n", -1)) for l in _task_after(b["R_dir"], b["final_dir"], "progress")}
    refs = [_kv(l) for l in _task_after(b["R_dir"], b["final_dir"], "refusals")]
    accepted = None
    if n:
        for a in att:
            if a.get("n") == str(n):
                accepted = a
                break
    t_acc = m0.iso_ms(accepted["t"]) if accepted and accepted.get("t") else None
    token_ok = False
    if accepted and stepn:
        for c in cmds:
            m = STEP_CMD_RE.match(c["cmd"])
            if m and int(m.group(1)) == n and hashlib.sha256(m.group(2).encode()).hexdigest() == stepn["token_sha256"] \
                    and (c["t"] is None or t_acc is None or c["t"] <= t_acc + 1000):
                token_ok = True
                break
    continued = bool(accepted and token_ok and not nonconf and n and {n, n + 1, n + 2} <= done)
    # ---- Repeat/skip axis
    def rn(r):
        try:
            return int(r.get("n"))
        except (TypeError, ValueError):
            return None
    dup = [r for r in refs if rn(r) is not None and n and rn(r) <= n - 1 and str(r.get("reason", "")).startswith("expected-n")]
    restart = [r for r in dup if rn(r) == 1 and n and n > 1]
    skip = [r for r in refs if rn(r) is not None and n and rn(r) > n and str(r.get("reason", "")).startswith("expected-n")]
    if restart:
        rs = "restart-from-start"
    elif dup:
        rs = f"duplicate-refused({len(dup)})"
    elif skip:
        rs = f"skip-refused({len(skip)})"
    elif accepted and int(accepted.get("prior_attempts", "0") or 0) >= 1:
        rs = "in-flight-reattempt-only"
    else:
        rs = "none"
    v["axes"]["repeat_skip"] = rs
    # ---- Interrupted-turn axis (structure only)
    it = "absent"
    if stepn:
        for e in post:
            for bl in m0.blocks(e):
                if bl.get("type") == "tool_result" and bl.get("tool_use_id") == stepn["id"]:
                    kinds = json.dumps(e)
                    it = "synthesized-interrupted" if bl.get("is_error") and '"toolDenialKind": "interrupted"' in kinds.replace('":"', '": "') else "other"
    v["axes"]["interrupted_turn"] = it
    # ---- the decision procedure: first match wins
    six_m = 6 * float(b.get("M_s") or 0) * 1000
    ref_t = last_input if last_input else b.get("start_t")
    responded = any(e.get("_t") and ref_t and ref_t < e["_t"] <= ref_t + six_m for e in real)
    blocking = any((b.get("dialogs") or {}).values())
    def decide() -> tuple[str, str]:
        if c4bv == "lost":
            return "lost", "c4b-lost"
        if session == "unavailable":
            if b.get("launcher_refused") or proc == "not-started":
                return "not-started", "launcher-refused-or-no-process"
            return "inconclusive", "final-transcript-unavailable" if not fin_ok else "transcript-listing-unavailable"
        if session == "fresh-no-history":
            return "fresh-no-history", "session-fresh-no-history"
        if (b.get("c4b") or {}).get("chain_broken_by_fault"):
            return "inconclusive", "chain-broken-by-fault"
        if proc == "same-as-original":
            return "inconclusive", "original-process-not-replaced"
        if proc == "unreadable":
            return "inconclusive", "process-unreadable"
        if api_err:
            return "inconclusive", "api-error-after-resume"
        if b.get("spend_stop"):
            return "inconclusive", "spend-stop"
        if not b.get("control_pass") and not pr.get("pass"):
            return "inconclusive", "control-and-probe-failed"
        if b.get("launcher_refused") or proc == "not-started":
            return "not-started", "launcher-refused-or-no-process"
        if session == "new-id":
            return "inconclusive", "session-new-id-not-followed"
        if session == "same-id-new-file":
            return "inconclusive", "session-duplicated-file"
        if post and not sid_consistent:
            return "inconclusive", "session-id-ambiguous"
        if not b.get("probe_typed"):
            return "inconclusive", "probe-not-typed"
        if b.get("probe_typed") and not pr.get("delivered") and real:
            return "inconclusive", "probe-not-delivered"
        if blocking:
            return "failed", "blocking-dialog"
        if not responded:
            return "failed", "no-real-model-entry-within-6M"
        if restart or len(dup) > 1:
            return "re-executed", "restart-or-repeated-duplicates"
        if pr.get("tool_use_before_reply", 0) > 0:
            return "probe-ignored", "tool-before-reply"
        if not pr.get("pass"):
            return "resumed-context-lost", "probe-wrong-or-missing"
        if continued and t_acc is not None and (first_input is None or t_acc < first_input):
            return "resumed-auto-continued", "accepted-before-input"
        if continued:
            return "resumed-continued-after-prompt", "accepted-after-input"
        return "responded-no-progress", "fallthrough"
    val, why = decide()
    v["axes"]["resume"] = val
    v["decision_path"] = why
    pre_ents = parse_lines(pre)
    pre_uuids = {e.get("uuid") for e in pre_ents if e.get("uuid")}
    first_parent = next((e.get("parentUuid") for e in post if e.get("parentUuid") is not None or e.get("uuid")), None)
    v["attributes"]["first_resumed_parent_in_prefault"] = bool(first_parent and first_parent in pre_uuids)
    v["attributes"] |= {"real_model_entries_after_resume": len(real), "api_error_entries_after_resume": len(api_err),
                        "nonconforming_bash_commands": len(nonconf), "step_n": n, "step_n_accepted": bool(accepted),
                        "step_n_prior_attempts": accepted.get("prior_attempts") if accepted else None,
                        "step_n_token_matches_prefault": token_ok, "done_after_resume": sorted(x for x in done if x >= 0),
                        "accepted_before_first_input": bool(t_acc and (first_input is None or t_acc < first_input)),
                        "refusals_after_resume": len(refs), "wrong_token_refusals": sum(1 for r in refs if r.get("reason") == "wrong-token"),
                        "probe": {k: pr.get(k) for k in ("delivered", "queued_only", "reply", "format_ok", "codeword_ok", "last_ok",
                                                         "first_action", "tool_use_before_reply", "reply_latency_ms", "pass")},
                        "continue_typed": bool(b.get("continue_typed")), "continue_delivered": cont_t is not None,
                        "dialogs": b.get("dialogs") or {}, "responded_within_6M": responded}
    # primary pass: a resume value, no repeated work, retained state, AND unambiguous continuation of the
    # original session by a new process (one file, one session id, the prefix kept, evidence available)
    v["primary_pass"] = val in ("resumed-auto-continued", "resumed-continued-after-prompt") and \
        rs in ("none", "in-flight-reattempt-only") and c4bv in ("intact", "intact-with-allowance") and \
        session == "same-id-same-file" and proc == "new-process" and fin_ok and sid_consistent
    return v


def main(a: list[str]) -> int:
    cmd = a[0] if a else ""
    if cmd == "h4":
        r = h4(m0.load_transcript(a[1]))
    elif cmd == "probe4":
        data = load_bytes(a[1])
        ents = after(data, int(a[5])) if len(a) > 5 else parse_lines(data)
        cw = m0._read(a[3]).strip() if a[3] != "-" else None
        r = probe4(ents, a[2], cw, {int(x) for x in a[4].split(",") if x.strip()})
        r.pop("reply_t", None), r.pop("probe_t", None)
    elif cmd == "activity":
        ents = after(load_bytes(a[1]), int(a[2]))
        r = {"entries": len(ents), "real_model_entries": sum(1 for e in ents if is_real_model_entry(e)),
             "api_error_entries": sum(1 for e in ents if is_api_error_entry(e)),
             "synthetic_entries": sum(1 for e in ents if is_synthetic_entry(e))}
    elif cmd == "c4b":
        r = c4b(json.loads(m0._read(a[1])))
    elif cmd == "c4c":
        r = c4c(json.loads(m0._read(a[1])))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(r, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
