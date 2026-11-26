"""EXP-008 Stage C: derived metrics and pre-registered classification (stdlib only, offline).

Never prints transcript text, prompts, replies, tokens or commands: only counts, hashes, timestamps,
booleans and classification values, so its output may be committed after the redaction scan.

usage:
  python3 -I metrics.py m        <taskdir>                                   -> M (median attempt interval)
  python3 -I metrics.py window   <taskdir> <transcript.jsonl> <open_ms> <close_ms> <M_s> <skew_ms>
  python3 -I metrics.py probe    <transcript.jsonl> <probe-token> <codeword-file|-> <last_done>
  python3 -I metrics.py prefix   <transcript.jsonl> <nbytes>                 -> sha256 of the first n bytes
  python3 -I metrics.py usage    <transcript.jsonl>                          -> spend estimate (Haiku 5.5 card)
  python3 -I metrics.py screen   <capture.txt>                               -> terminal-state rule
  python3 -I metrics.py rawmode  <pty.raw>                                   -> renderer mode seen in raw output
  python3 -I metrics.py ledger   <taskdir>                                   -> hash-chain check

<taskdir> holds local copies of attempts.log, progress.log, refusals.log, ledger.log.
All times are epoch milliseconds on the WORKSTATION clock; <skew_ms> is (workload clock - workstation
clock) measured by the harness, and |skew| + its uncertainty is applied as a margin against the window.
"""

from __future__ import annotations

import hashlib
import json
import re
import statistics
import sys
from datetime import datetime, timezone

STEP_RE = re.compile(r"(?:^|[\s;&|(/])(?:\./)?step\.sh\s+(\d+)\s+([a-z0-9]+)")
LOG_RE = re.compile(r"^(attempt|done|refused) n=(\S+) t=(\S+)(.*)$")


def iso_ms(ts: str) -> int:
    return int(datetime.strptime(ts.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp() * 1000)


def read_log(path: str) -> list[dict]:
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = LOG_RE.match(line.strip())
                if not m:
                    continue
                kv = dict(re.findall(r"(\w+)=(\S+)", m.group(4)))
                n = int(m.group(2)) if m.group(2).isdigit() else None
                rows.append({"kind": m.group(1), "n": n, "t": iso_ms(m.group(3)), **kv})
    except FileNotFoundError:
        pass
    return rows


def load_task(d: str) -> dict:
    return {k: read_log(f"{d}/{k}.log") for k in ("attempts", "progress", "refusals")}


def median_interval(task: dict, first: int = 5) -> float | None:
    """M: median interval (s) between consecutive first attempts of steps 1..first+1."""
    firsts: dict[int, int] = {}
    for a in task["attempts"]:
        if a["n"] is not None and a["n"] not in firsts:
            firsts[a["n"]] = a["t"]
    ns = sorted(n for n in firsts if n <= first + 1)
    iv = [(firsts[b] - firsts[a]) / 1000 for a, b in zip(ns, ns[1:]) if b == a + 1]
    return statistics.median(iv) if len(iv) >= first else None


def load_transcript(path: str) -> list[dict]:
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                out.append({"_line": i, "_bad": True})
                continue
            e["_line"] = i
            ts = e.get("timestamp")
            e["_t"] = iso_ms(ts) if isinstance(ts, str) and ts.endswith("Z") else None
            out.append(e)
    return out


def blocks(e: dict) -> list[dict]:
    c = (e.get("message") or {}).get("content")
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def text_of(e: dict) -> str:
    """All text in an entry (content strings, text blocks, attachment payloads)."""
    m = e.get("message") or {}
    parts = []
    if isinstance(m.get("content"), str):
        parts.append(m["content"])
    for b in blocks(e):
        if b.get("type") == "text":
            parts.append(b.get("text", ""))
        elif b.get("type") == "tool_result":
            c = b.get("content")
            parts.append(c if isinstance(c, str) else json.dumps(c))
    for k in ("attachment", "content", "prompt"):
        if k in e and not isinstance(e[k], (int, float, bool)):
            parts.append(e[k] if isinstance(e[k], str) else json.dumps(e[k]))
    return "\n".join(parts)


def tool_uses(tr: list[dict]) -> list[dict]:
    """Bash tool_use blocks that invoke step.sh: id, assistant-entry time, step numbers in the command."""
    out = []
    for e in tr:
        if e.get("type") != "assistant":
            continue
        for b in blocks(e):
            if b.get("type") == "tool_use" and b.get("name") == "Bash":
                cmd = str((b.get("input") or {}).get("command", ""))
                steps = [int(n) for n, _ in STEP_RE.findall(cmd)]
                if steps or "step.sh" in cmd:
                    out.append({"id": b.get("id"), "t": e["_t"], "steps": steps, "n_calls": max(len(steps), cmd.count("step.sh"))})
    return out


def window(task: dict, tr: list[dict], t_open: int, t_close: int, m_s: float, skew_ms: int, margin_ms: int) -> dict:
    """Section 3.3 rule with a clock-skew margin; times converted to the workload clock."""
    w_open, w_close = t_open + skew_ms + margin_ms, t_close + skew_ms - margin_ms
    uses = tool_uses(tr)
    by_step: dict[int, dict] = {}
    for u in uses:
        for n in u["steps"]:
            by_step.setdefault(n, u)  # the first tool_use naming step n
    first_attempt: dict[int, dict] = {}
    for a in task["attempts"]:
        if a["n"] is not None:
            first_attempt.setdefault(a["n"], a)
    counted, batched_ids, reasons = [], set(), {}
    for n, a in sorted(first_attempt.items()):
        if not (w_open < a["t"] <= w_close):
            continue
        u = by_step.get(n)
        if u is None:
            reasons[n] = "no-tool_use"
            continue
        if u["n_calls"] != 1:
            batched_ids.add(u["id"])
            reasons[n] = "batched"
            continue
        if u["t"] is None or not (w_open < u["t"] <= w_close):
            reasons[n] = "assistant-outside-window"
            continue
        if u["t"] > a["t"]:
            reasons[n] = "assistant-after-attempt"
            continue
        counted.append(n)
    ids = {by_step[n]["id"] for n in counted}
    # independent batching check: two counted steps started by the same shell (ppid + its start time)
    shells = [(first_attempt[n].get("ppid"), first_attempt[n].get("pstart")) for n in counted]
    shared_shell = len([x for x in shells if x[0]]) != len({x for x in shells if x[0]})
    if shared_shell:
        batched_ids.add("shared-shell")
    progressed = len(counted) >= 2 and len(ids) == len(counted) and not shared_shell
    # activity: attempts + timestamped transcript entries; frozen = any gap > 3M inside the window
    acts = sorted([a["t"] for a in task["attempts"]] + [e["_t"] for e in tr if e.get("_t")])
    inside = [w_open] + [t for t in acts if w_open < t <= w_close] + [w_close]
    max_gap = max((b - a for a, b in zip(inside, inside[1:])), default=0) / 1000
    frozen = max_gap > 3 * m_s
    after = [n for n, a in sorted(first_attempt.items()) if w_close < a["t"] <= w_close + 3 * m_s * 1000
             and n in by_step and by_step[n]["n_calls"] == 1]
    api_in = sum(1 for e in tr if e.get("type") == "api-request" and e.get("_t") and w_open < e["_t"] <= w_close)
    asst_in = sum(1 for e in tr if e.get("type") == "assistant" and e.get("_t") and w_open < e["_t"] <= w_close)
    # did the agent end its turn (no tool_use pending) inside the window? (pre-registered "stopped-early" signal)
    last_asst = [e for e in tr if e.get("type") == "assistant" and e.get("_t") and e["_t"] <= w_close]
    last_asst.sort(key=lambda e: e["_t"])
    turn_ended = bool(last_asst) and (last_asst[-1].get("message") or {}).get("stop_reason") == "end_turn"
    if batched_ids:
        work = "batched"
    elif progressed:
        work = "progressed"
    elif frozen and len(after) >= 2:
        work = "stalled-then-recovered"
    else:
        work = "stalled"
    return {
        "window_ms": t_close - t_open, "margin_ms": margin_ms, "skew_ms": skew_ms, "M_s": m_s,
        "attempts_in_window": sum(1 for a in task["attempts"] if w_open < a["t"] <= w_close),
        "done_in_window": sum(1 for a in task["progress"] if w_open < a["t"] <= w_close),
        "refusals_total": len(task["refusals"]),
        "counted_steps": counted, "excluded": {str(k): v for k, v in reasons.items()},
        "assistant_entries_in_window": asst_in, "api_requests_in_window": api_in,
        "max_activity_gap_s": round(max_gap, 3), "frozen": frozen, "steps_within_3M_after": after,
        "batched_tool_uses": len(batched_ids), "shared_shell": shared_shell, "turn_ended_by_close": turn_ended, "work": work,
    }


def _order(tr: list[dict]) -> list[dict]:
    """Timestamp order (2.1.323 writes some entries out of file order); untimestamped keep file position."""
    last = 0
    keyed = []
    for e in tr:
        last = e.get("_t") or last
        keyed.append((last, e["_line"], e))
    return [e for _, _, e in sorted(keyed, key=lambda x: (x[0], x[1]))]


def probe(tr: list[dict], token: str, codeword: str | None, last_done: int) -> dict:
    """Q: did the typed probe reach this session, and was it answered in it?
    2.1.323 records input typed while busy as queue-operation (enqueue/dequeue) and, on delivery, an
    attachment of type queued_command; an idle prompt is a user entry. Enqueue alone = queued, not delivered."""
    tr = _order(tr)
    hits = [e for e in tr if e.get("type") != "assistant" and token in text_of(e)]
    kinds = sorted({e.get("type") + (":" + str((e.get("attachment") or {}).get("type") or e.get("operation") or "")) if isinstance(e.get("attachment"), dict) or e.get("operation") else e.get("type") for e in hits})
    delivered = [e for e in hits if e.get("type") == "user" or (isinstance(e.get("attachment"), dict) and e["attachment"].get("type") == "queued_command")]
    hit = delivered[0] if delivered else (hits[0] if hits else None)
    r = {"probe_in_transcript": bool(delivered), "probe_queued_only": bool(hits) and not delivered, "probe_entry_kinds": kinds}
    if not delivered:
        return r | {"reply": False}
    idx = tr.index(hit)
    later = tr[idx + 1:]
    reply = next((e for e in later if e.get("type") == "assistant" and token in text_of(e)), None)
    r["reply"] = reply is not None
    r["session_ids"] = sorted({e.get("sessionId") for e in tr if e.get("sessionId")})
    if reply:
        span = later[: later.index(reply) + 1]
        r["tool_use_before_reply"] = sum(1 for e in span for b in blocks(e) if b.get("type") == "tool_use")
        txt = text_of(reply)
        nums = {int(x) for x in re.findall(r"\b(\d{1,3})\b", txt)}
        r["reply_mentions_last_done"] = last_done in nums or (last_done + 1) in nums
        r["reply_codeword"] = None if codeword is None else (codeword.lower() in txt.lower())
        r["reply_latency_ms"] = (reply["_t"] - hit["_t"]) if reply.get("_t") and hit.get("_t") else None
    return r


# Claude Haiku 5.5 rate card, USD per MTok (platform.claude.com/docs/en/about-claude/pricing, read 2026-11-25).
# Two cards chosen PER REQUEST by prompt length = input + cache writes + cache reads; > 100,000 tokens pays
# the long-context card on every token category of that request. US-only inference_geo adds 1.1x.
RATE_CARD = {
    "model_prefix": "claude-haiku-5-5",
    "long_context_threshold": 100_000,
    "base": {"in": 0.10, "cw5m": 0.125, "cw1h": 0.20, "cr": 0.01, "out": 0.50},
    "long": {"in": 0.50, "cw5m": 0.625, "cw1h": 1.00, "cr": 0.05, "out": 2.50},
    "geo_us_multiplier": 1.1,
}
USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def _nonneg_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def usage(tr: list[dict], card: dict = RATE_CARD) -> dict:
    """Transcript-based spend ESTIMATE (the Console workspace cap is the authoritative control).

    reliable=false (with reasons) whenever a cost cannot be computed from what the transcript records: an
    assistant entry without a usable usage object or message id, an unknown model, a corrupt line before
    the last one, or unpriced server-tool use. Requests the transcript never records (aborted streams,
    client retries, side requests) are not visible here, so the estimate can undercount.
    """
    reasons: set[str] = set()
    per: dict[str, dict] = {}
    synthetic = 0
    last = max((e.get("_line", -1) for e in tr), default=-1)
    for e in tr:
        if e.get("_bad"):
            if e.get("_line") != last:  # a partially written final line is normal; anything earlier is not
                reasons.add("corrupt-line")
            continue
        if e.get("type") != "assistant":
            continue
        m = e.get("message")
        if not isinstance(m, dict):
            reasons.add("missing-message")
            continue
        model = m.get("model")
        if model == "<synthetic>":  # client-generated (e.g. an API error shown to the user): no API cost
            synthetic += 1
            continue
        if not isinstance(model, str) or not model.startswith(card["model_prefix"]):
            reasons.add("unknown-model")
            continue
        mid, u = m.get("id"), m.get("usage")
        if not isinstance(mid, str) or not mid:
            reasons.add("missing-message-id")
            continue
        if not isinstance(u, dict):
            reasons.add("missing-usage")
            continue
        vals = {k: u.get(k, 0 if k.startswith("cache_") else None) for k in USAGE_FIELDS}
        if not all(_nonneg_int(v) for v in vals.values()):
            reasons.add("bad-usage-field")
            continue
        cc = u.get("cache_creation")
        split = None
        if isinstance(cc, dict) and _nonneg_int(cc.get("ephemeral_5m_input_tokens")) and _nonneg_int(cc.get("ephemeral_1h_input_tokens")) \
                and cc["ephemeral_5m_input_tokens"] + cc["ephemeral_1h_input_tokens"] == vals["cache_creation_input_tokens"]:
            split = (cc["ephemeral_5m_input_tokens"], cc["ephemeral_1h_input_tokens"])
        stu = u.get("server_tool_use")
        if isinstance(stu, dict) and any(_nonneg_int(v) and v > 0 for v in stu.values()):
            reasons.add("server-tool-use-unpriced")
        geo = u.get("inference_geo")
        # streamed content blocks of one message repeat its usage, and early entries can carry partial
        # output counts: keep the per-field maximum for each message id
        p = per.setdefault(mid, {k: 0 for k in USAGE_FIELDS} | {"split": None, "geo_us": False})
        for k in USAGE_FIELDS:
            p[k] = max(p[k], vals[k])
        if split is not None and sum(split) == p["cache_creation_input_tokens"]:
            p["split"] = split
        p["geo_us"] = p["geo_us"] or (isinstance(geo, str) and geo.lower() == "us")
    tot = {k: 0 for k in USAGE_FIELDS}
    usd, long_n, max_prompt, assumed_1h = 0.0, 0, 0, 0
    for p in per.values():
        prompt = p["input_tokens"] + p["cache_creation_input_tokens"] + p["cache_read_input_tokens"]
        max_prompt = max(max_prompt, prompt)
        r = card["long"] if prompt > card["long_context_threshold"] else card["base"]
        long_n += r is card["long"]
        if p["split"] is not None and sum(p["split"]) == p["cache_creation_input_tokens"]:
            cw = p["split"][0] * r["cw5m"] + p["split"][1] * r["cw1h"]
        else:  # TTL split unknown: price every cache write at the higher 1-hour rate
            cw = p["cache_creation_input_tokens"] * r["cw1h"]
            assumed_1h += p["cache_creation_input_tokens"] > 0
        c = p["input_tokens"] * r["in"] + cw + p["cache_read_input_tokens"] * r["cr"] + p["output_tokens"] * r["out"]
        usd += c * (card["geo_us_multiplier"] if p["geo_us"] else 1.0)
        for k in USAGE_FIELDS:
            tot[k] += p[k]
    return {"basis": "transcript-estimate", "messages": len(per), "synthetic_messages": synthetic, **tot,
            "max_prompt_tokens": max_prompt, "long_context_messages": long_n,
            "cache_write_ttl_assumed_1h_messages": assumed_1h,
            "est_usd": round(usd / 1e6, 8), "reliable": not reasons, "unreliable_reasons": sorted(reasons)}


ESC_FRAG = re.compile(r"\x1b|\[\?\d{1,4}[hl]|\[\d{1,3}(;\d{1,3})*[mHJKf]|\]\d;")


def screen(text: str) -> dict:
    """Pre-registered rule. 2.1.323's input box is two rule lines of >= 20 '─' around the prompt line
    (EXP-006 s3b pane-k02-ready.txt; stage3 RUNBOOK). Coherent = >= 2 such rule lines, no literal
    escape-sequence fragments. The prompt glyph is recorded but not required (masked in s3b evidence)."""
    rules = len(re.findall(r"^\s*[╭╰]?─{20,}", text, re.M))
    prompt = re.search(r"^\s*[│|]?\s*(>|❯)\s", text, re.M) is not None
    frags = len(ESC_FRAG.findall(text))
    return {"rule_lines": rules, "prompt_glyph": prompt, "escape_fragments": frags,
            "banner": "Claude Code" in text, "nonblank_lines": sum(1 for l in text.splitlines() if l.strip()),
            "coherent": rules >= 2 and frags == 0}


def rawmode(data: bytes) -> dict:
    return {"alt_screen_enter": data.count(b"\x1b[?1049h"), "alt_screen_exit": data.count(b"\x1b[?1049l"),
            "clear_screen": data.count(b"\x1b[2J"), "raw_bytes": len(data)}


def ledger(d: str) -> dict:
    lines = _read(f"{d}/ledger.log").splitlines()
    bad, prev = [], None
    for i, l in enumerate(lines):
        h = re.search(r"prev=(\S+)$", l)
        want = hashlib.sha256((prev + "\n").encode()).hexdigest()[:16] if prev is not None else hashlib.sha256(b"").hexdigest()[:16]
        if not h or h.group(1) != want:
            bad.append(i + 1)
        prev = l
    return {"ledger_lines": len(lines), "chain_ok": not bad, "bad_lines": bad[:10],
            "last_line_sha256": hashlib.sha256(lines[-1].encode()).hexdigest() if lines else None}


def _read(p: str, mode: str = "r"):
    try:
        with open(p, mode, **({} if "b" in mode else {"encoding": "utf-8", "errors": "replace"})) as f:
            return f.read()
    except FileNotFoundError:
        return b"" if "b" in mode else ""


def main(a: list[str]) -> int:
    cmd = a[0] if a else ""
    if cmd == "m":
        r = {"M_s": median_interval(load_task(a[1]))}
    elif cmd == "window":
        task, tr = load_task(a[1]), load_transcript(a[2])
        skew = int(a[6])
        margin = int(a[7]) if len(a) > 7 else 2000
        r = window(task, tr, int(a[3]), int(a[4]), float(a[5]), skew, margin)
    elif cmd == "probe":
        cw = None if a[3] == "-" else _read(a[3]).strip()
        r = probe(load_transcript(a[1]), a[2], cw, int(a[4]))
    elif cmd == "prefix":
        data = _read(a[1], "rb")[: int(a[2])]
        r = {"prefix_bytes": len(data), "prefix_sha256": hashlib.sha256(data).hexdigest()}
    elif cmd == "usage":
        r = usage(load_transcript(a[1]))
    elif cmd == "screen":
        r = screen(_read(a[1]))
    elif cmd == "rawmode":
        r = rawmode(_read(a[1], "rb"))
    elif cmd == "ledger":
        r = ledger(a[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(r, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
