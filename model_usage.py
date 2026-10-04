#!/usr/bin/env python3
"""
현재 5시간창 / 주간창 구간의 Claude Code 사용량을 **모델별** 토큰·비용으로
집계해 model_usage.json 에 쓴다.

창 경계는 rate_limits.json 의 resets_at 에서 역산한다:
  5시간창 = [five_hour.resets_at - 5h, now]   (resets_at 이 미래일 때만; 아니면 idle)
  주간창  = [seven_day.resets_at - 7d, now]   (없으면 [now - 7d, now] 폴백)

usage_stats.py 의 iter_events / cost_for 를 재사용한다. 주간창이 5시간창을
포함하므로 로그는 **한 번만** 훑고 두 버킷에 나눠 담는다.

무거운 전체 스캔이라 statusline.py 는 이 스크립트를 detached 로 스폰하고
기다리지 않는다. model_usage.json 이 MIN_REFRESH 초 안에 갱신됐으면 즉시
종료해서 중복 스폰을 흡수한다 (--force 로 무시).

스키마 (가산 확장만):
  {
    "computed_at": float,
    "last_model": str|null,        # 로그상 가장 최근 assistant 이벤트의 모델 라벨
    "last_model_at": float|null,
    "weekly":    {"window_start": float,      "models": [row, ...]},
    "five_hour": {"window_start": float|null, "idle": bool, "models": [row, ...]}
  }
  row = {"id": str, "label": str, "tokens": int, "cost": float, "requests": int}
  models 는 cost 내림차순, tokens == 0 은 제외.
"""
import json
import os
import sys
import time
from collections import defaultdict

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
from usage_stats import cost_for, iter_events  # noqa: E402

RL_JSON = os.path.join(BASE, "rate_limits.json")
MU_JSON = os.path.join(BASE, "model_usage.json")

MIN_REFRESH = 45          # 이 초 안에 갱신됐으면 재계산 스킵
FIVE_H = 5 * 3600
WEEK = 7 * 86400

# 모델 id -> 팝오버에 쓸 짧은 라벨
LABELS = {
    "claude-opus-5-5": "Opus 5.5",
    "claude-opus-5": "Opus 5",
    "claude-opus-4-8": "Opus 4.8",
    "claude-opus-4-7": "Opus 4.7",
    "claude-opus-4-6": "Opus 4.6",
    "claude-sonnet-5-5": "Sonnet 5.5",
    "claude-sonnet-5": "Sonnet 5",
    "claude-sonnet-4-6": "Sonnet 4.6",
    "claude-haiku-4-5": "Haiku",
    "claude-fable-5": "Fable 5",
    "claude-fable-5-1": "Fable 5.1",
}


def label_for(model):
    if not model:
        return None
    if model in LABELS:
        return LABELS[model]
    m = model[7:] if model.startswith("claude-") else model
    return m.split("-")[0].capitalize() or model


def toks_of(u):
    """지불 대상 토큰 합 (usage_stats.collect 와 동일 정의)."""
    return (
        (u.get("input_tokens", 0) or 0)
        + (u.get("output_tokens", 0) or 0)
        + (u.get("cache_creation_input_tokens", 0) or 0)
        + (u.get("cache_read_input_tokens", 0) or 0)
    )


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
    except (OSError, ValueError):
        return {}
    return obj if isinstance(obj, dict) else {}


def atomic_write(path, obj):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def window_starts(now):
    """(five_start | None, seven_start) — epoch 초."""
    rl = load_json(RL_JSON).get("rate_limits")
    rl = rl if isinstance(rl, dict) else {}

    def reset(key):
        w = rl.get(key)
        if not isinstance(w, dict):
            return None
        try:
            return float(w.get("resets_at"))
        except (TypeError, ValueError):
            return None

    five_reset = reset("five_hour")
    seven_reset = reset("seven_day")

    five_start = five_reset - FIVE_H if (five_reset and five_reset > now) else None
    if seven_reset and seven_reset > now:
        seven_start = seven_reset - WEEK
    else:
        seven_start = now - WEEK
    return five_start, seven_start


def _rows(acc):
    rows = [
        {
            "id": m,
            "label": label_for(m),
            "tokens": v["tokens"],
            "cost": round(v["cost"], 2),
            "requests": v["requests"],
        }
        for m, v in acc.items()
        if v["tokens"] > 0
    ]
    rows.sort(key=lambda r: r["cost"], reverse=True)
    return rows


def collect(now):
    five_start, seven_start = window_starts(now)
    scan_from = seven_start - 3600            # mtime 프리필터 여유 1h

    seen = set()
    wk = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "requests": 0})
    fh = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "requests": 0})
    latest_ep, latest_model = 0.0, None

    for dt, model, u, _sid, key in iter_events(mtime_after=scan_from):
        ep = dt.timestamp()
        if ep > latest_ep:
            latest_ep, latest_model = ep, model
        if ep > now + 300 or key in seen:       # 미래 타임스탬프 / 중복 라인
            continue
        seen.add(key)
        t = toks_of(u)
        c = cost_for(model, u)
        if ep >= seven_start:
            b = wk[model]
            b["tokens"] += t
            b["cost"] += c
            b["requests"] += 1
        if five_start is not None and ep >= five_start:
            b = fh[model]
            b["tokens"] += t
            b["cost"] += c
            b["requests"] += 1

    return five_start, seven_start, _rows(fh), _rows(wk), latest_ep, latest_model


def main():
    argv = sys.argv[1:]
    now = time.time()

    if "--force" not in argv:
        try:
            if now - os.path.getmtime(MU_JSON) < MIN_REFRESH:
                return
        except OSError:
            pass

    five_start, seven_start, fh_rows, wk_rows, latest_ep, latest_model = collect(now)

    out = {
        "computed_at": now,
        "last_model": label_for(latest_model),
        "last_model_at": latest_ep or None,
        "weekly": {"window_start": seven_start, "models": wk_rows},
        "five_hour": {
            "window_start": five_start,
            "idle": five_start is None,
            "models": fh_rows,
        },
    }
    atomic_write(MU_JSON, out)

    if "--print" in argv:
        print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
