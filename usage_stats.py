#!/usr/bin/env python3
"""
Claude Code 로컬 사용량 집계기.

~/.claude/projects/**/*.jsonl 를 전부 훑어 assistant 응답의 usage 블록을 모아
오늘 / 최근 7일 / 누적 토큰·비용을 계산한다. API 키 불필요.

비용은 로그에 안 박혀 있어서 모델별 단가표(PRICING)로 직접 계산한다.
단가 출처: claude-api 스킬 모델 표 (2026-06-24 기준), 단위 = USD / 1M tokens.
  - cache write(5m)  = input * 1.25
  - cache write(1h)  = input * 2.0
  - cache read       = input * 0.1
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

CLAUDE_DIR = os.path.expanduser("~/.claude/projects")

# Claude 사용 한도 창 길이. 로그 timestamp 로 근사한다(서버는 첫 메시지 기준
# 고정 5h 창을 쓰지만 로컬에선 5h 이상 공백이 나면 창을 끊는 방식으로 추정).
WINDOW = timedelta(hours=5)

# USD per 1M tokens: (input, output)
PRICING = {
    "claude-opus-5-5": (4.00, 20.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4-8": (5.00, 25.00),
    "claude-opus-4-7": (5.00, 25.00),
    "claude-opus-4-6": (5.00, 25.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-sonnet-5": (2.00, 10.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-fable-5": (10.00, 50.00),
    "claude-fable-5-1": (10.00, 50.00),
}
# 모르는 모델 fallback (sonnet-5 요율)
DEFAULT_RATE = (2.00, 10.00)

_TS_RE = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?Z?")


def parse_ts(ts):
    """ISO8601(Z) 문자열 -> aware datetime(UTC). 3.9 호환."""
    if not ts:
        return None
    m = _TS_RE.match(ts)
    if not m:
        return None
    dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    return dt.replace(tzinfo=timezone.utc)


def cost_for(model, u):
    in_rate, out_rate = PRICING.get(model, DEFAULT_RATE)
    inp = u.get("input_tokens", 0) or 0
    out = u.get("output_tokens", 0) or 0
    cc = u.get("cache_creation", {}) or {}
    c5 = cc.get("ephemeral_5m_input_tokens")
    c1h = cc.get("ephemeral_1h_input_tokens")
    if c5 is None and c1h is None:
        # 세부 없음 -> 통합 필드를 5m 로 취급
        c5 = u.get("cache_creation_input_tokens", 0) or 0
        c1h = 0
    else:
        c5 = c5 or 0
        c1h = c1h or 0
    cr = u.get("cache_read_input_tokens", 0) or 0
    dollars = (
        inp * in_rate
        + out * out_rate
        + c5 * in_rate * 1.25
        + c1h * in_rate * 2.0
        + cr * in_rate * 0.1
    ) / 1_000_000
    return dollars


def iter_events(session_filter=None, mtime_after=None):
    """(dt_utc, model, usage, session_id, dedup_key) 를 yield. 중복은 호출측에서 제거.

    mtime_after (epoch 초) 를 주면 그보다 오래 전에 마지막 수정된 jsonl 은 열지
    않는다 — 짧은 창(5시간 등) 집계 시 전체 스캔을 크게 줄인다.
    """
    files = glob.glob(os.path.join(CLAUDE_DIR, "**", "*.jsonl"), recursive=True)
    for fp in files:
        sid = os.path.splitext(os.path.basename(fp))[0]
        if session_filter and session_filter not in (sid, fp):
            continue
        if mtime_after is not None:
            try:
                if os.path.getmtime(fp) < mtime_after:
                    continue
            except OSError:
                pass
        try:
            fh = open(fp, "r", encoding="utf-8")
        except OSError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line or '"usage"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") != "assistant":
                    continue
                msg = rec.get("message") or {}
                u = msg.get("usage")
                if not u:
                    continue
                model = msg.get("model", "unknown")
                if model == "<synthetic>":
                    continue
                dt = parse_ts(rec.get("timestamp"))
                if dt is None:
                    continue
                # dedup: message.id + requestId (재개된 세션의 복제 라인 대비)
                key = (msg.get("id"), rec.get("requestId"))
                yield dt, model, u, rec.get("sessionId") or sid, key


def collect(session_filter=None):
    seen = set()
    # 날짜(로컬) -> {tokens, cost}
    by_day = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "requests": 0})
    totals = {"tokens": 0, "cost": 0.0, "requests": 0}
    by_model = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "requests": 0})
    session_totals = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "requests": 0, "last": None})

    events = []  # (dt_utc, tokens, cost) — dedup 후, window 계산용

    for dt, model, u, sid, key in iter_events(session_filter):
        if key in seen:
            continue
        seen.add(key)
        local_day = dt.astimezone().strftime("%Y-%m-%d")
        # "토큰"은 지불 대상 토큰의 합 (input + output + cache write + cache read)
        toks = (
            (u.get("input_tokens", 0) or 0)
            + (u.get("output_tokens", 0) or 0)
            + (u.get("cache_creation_input_tokens", 0) or 0)
            + (u.get("cache_read_input_tokens", 0) or 0)
        )
        c = cost_for(model, u)
        for bucket in (by_day[local_day], totals, by_model[model], session_totals[sid]):
            bucket["tokens"] += toks
            bucket["cost"] += c
            bucket["requests"] += 1
        st = session_totals[sid]
        if st["last"] is None or dt > st["last"]:
            st["last"] = dt
        events.append((dt, toks, c))

    events.sort(key=lambda e: e[0])
    return by_day, totals, by_model, session_totals, events


def compute_window(events, now=None):
    """5시간 사용 한도 창 근사.

    이벤트를 시간순으로 훑어 5h 이상 공백이 있으면 새 창으로 본다.
    마지막 창의 시작 + 5h 가 리셋 시각. now 가 그 시각을 지났으면
    현재는 idle(다음 요청이 새 창을 연다)로 처리한다.
    """
    if now is None:
        now = datetime.now(timezone.utc)
    empty = {
        "active": False, "tokens": 0, "cost": 0.0, "requests": 0,
        "start": None, "end": None, "reset_in_seconds": 0,
    }
    if not events:
        return empty

    win_start = events[0][0]
    for dt, _, _ in events[1:]:
        if dt - win_start >= WINDOW:
            win_start = dt
    win_end = win_start + WINDOW

    if now >= win_end:
        return {**empty, "start": win_start.astimezone().isoformat(),
                "end": win_end.astimezone().isoformat()}

    toks = cost = reqs = 0
    for dt, t, c in events:
        if dt >= win_start:
            toks += t
            cost += c
            reqs += 1
    return {
        "active": True,
        "tokens": toks,
        "cost": round(cost, 4),
        "requests": reqs,
        "start": win_start.astimezone().isoformat(),
        "end": win_end.astimezone().isoformat(),
        "reset_in_seconds": int((win_end - now).total_seconds()),
    }


def build_report(session_filter=None):
    by_day, totals, by_model, session_totals, events = collect(session_filter)
    today = datetime.now().astimezone().strftime("%Y-%m-%d")
    window = compute_window(events)

    # 최근 7일 (오늘 포함), 오래된 -> 최신
    days = []
    base = datetime.now().astimezone().date()
    for i in range(6, -1, -1):
        d = (base.toordinal() - i)
        ds = datetime.fromordinal(d).strftime("%Y-%m-%d")
        rec = by_day.get(ds, {"tokens": 0, "cost": 0.0, "requests": 0})
        days.append({"date": ds, "tokens": rec["tokens"], "cost": round(rec["cost"], 4),
                     "requests": rec["requests"]})

    last7_tokens = sum(x["tokens"] for x in days)
    last7_cost = sum(x["cost"] for x in days)

    # 가장 최근 활동 세션
    active = None
    if session_totals:
        sid = max(session_totals, key=lambda s: session_totals[s]["last"] or datetime.min.replace(tzinfo=timezone.utc))
        st = session_totals[sid]
        active = {
            "session_id": sid,
            "tokens": st["tokens"],
            "cost": round(st["cost"], 4),
            "requests": st["requests"],
            "last": st["last"].astimezone().isoformat() if st["last"] else None,
        }

    return {
        "generated_at": datetime.now().astimezone().isoformat(),
        "window5h": window,
        "today": {
            "date": today,
            "tokens": by_day.get(today, {}).get("tokens", 0),
            "cost": round(by_day.get(today, {}).get("cost", 0.0), 4),
            "requests": by_day.get(today, {}).get("requests", 0),
        },
        "last7": {"tokens": last7_tokens, "cost": round(last7_cost, 4), "days": days},
        "total": {
            "tokens": totals["tokens"],
            "cost": round(totals["cost"], 4),
            "requests": totals["requests"],
        },
        "by_model": {m: {"tokens": v["tokens"], "cost": round(v["cost"], 4),
                         "requests": v["requests"]}
                     for m, v in sorted(by_model.items())},
        "active_session": active,
    }


def main():
    ap = argparse.ArgumentParser(description="Claude Code 로컬 사용량 집계")
    ap.add_argument("--session", help="특정 session id(파일명) 만 집계")
    ap.add_argument("--out", help="JSON 을 파일로 저장 (기본: stdout)")
    ap.add_argument("--pretty", action="store_true", help="사람이 읽기 좋은 요약도 출력")
    args = ap.parse_args()

    report = build_report(args.session)
    text = json.dumps(report, ensure_ascii=False, indent=2)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        print(text)

    if args.pretty:
        t = report["today"]
        tot = report["total"]
        w = report["window5h"]
        if w["active"]:
            h, m = divmod(w["reset_in_seconds"] // 60, 60)
            print(f"\n5h창   : {w['tokens']:>14,} tok  |  ${w['cost']:.2f}  |  "
                  f"{w['requests']} req  |  리셋까지 {h}h {m}m", file=sys.stderr)
        else:
            print("\n5h창   : idle (진행 중인 창 없음)", file=sys.stderr)
        print(f"오늘   : {t['tokens']:>14,} tok  |  ${t['cost']:.2f}  |  {t['requests']} req",
              file=sys.stderr)
        print(f"최근7일: {report['last7']['tokens']:>14,} tok  |  ${report['last7']['cost']:.2f}",
              file=sys.stderr)
        print(f"누적   : {tot['tokens']:>14,} tok  |  ${tot['cost']:.2f}  |  {tot['requests']} req",
              file=sys.stderr)


if __name__ == "__main__":
    main()
