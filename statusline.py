#!/usr/bin/env python3
"""
Claude Code statusLine 훅.

Claude Code 가 stdin 으로 주는 JSON 에서 rate_limits (5시간창 / 주간 / spend 한도)
를 뽑는다. 이 키는 **매 호출마다 오지 않는다** — API 응답 직후 등 특정 시점에만
실린다. 따라서:

  1. 매 실행마다 기존 rate_limits.json 을 먼저 읽는다.
  2. 이번 payload 에 실린 창들만 저장본 위에 **창 단위로 병합**한다.
     (이번에 안 온 창은 마지막 스냅샷 그대로 유지)
  3. 병합 결과를 원자적으로 다시 저장한다. 창마다 자체 captured_at 을 붙여
     창별 나이를 알 수 있게 한다.
  4. 배너(stdout)는 병합된 데이터로 그린다. 저장된 창이 하나라도 있으면
     절대 "대기 중" 을 출력하지 않는다.

맥 메뉴바 앱(kb-usage-menubar)이 rate_limits.json 을 폴링해서 표시한다.
스키마는 가산적으로만 확장한다:
  {"rate_limits": {창: {used_percentage, resets_at, captured_at}}, "captured_at": float}
최상위 captured_at 은 메뉴바의 "30분 stale" 로직이 계속 맞도록 최근 쓰기 시각.
"""
import json
import os
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
RL_JSON = os.path.join(BASE, "rate_limits.json")
SESS_DIR = os.path.join(BASE, "sessions")

STALE_SECONDS = 1800  # 창 자체 나이가 이걸 넘으면 배너에 '?' 마커
SESS_KEEP_SECONDS = 86400  # 이보다 오래된 세션 파일은 청소

# output_style.name → 상태줄에 보일 짧은 태그. "default" 는 아무것도 안 보임.
# 매핑에 없는 이름은 이름 그대로 보여준다(새 output style 추가돼도 안 깨지게).
AGENT_TAGS = {
    "돌쇠": "🧑‍🌾 돌쇠",
    "개똥이": "🔧 개똥이",
}


def load_stored():
    """마지막 스냅샷을 읽는다. 없거나 깨졌으면 빈 dict."""
    try:
        with open(RL_JSON, encoding="utf-8") as f:
            obj = json.load(f)
    except (OSError, ValueError):
        return {}
    return obj if isinstance(obj, dict) else {}


def _near(a, b, tol=90):
    """두 epoch 초가 tol 이내면 같은 리셋 경계로 본다."""
    try:
        return abs(float(a) - float(b)) <= tol
    except (TypeError, ValueError):
        return False


def _earlier(a, b):
    """a 가 b 보다 확실히 이른 리셋 경계면 True. 숫자 아니면 False."""
    try:
        return float(a) < float(b)
    except (TypeError, ValueError):
        return False


def atomic_write_path(path, payload):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def atomic_write(payload):
    atomic_write_path(RL_JSON, payload)


def write_session(data, now):
    """이 세션의 컨텍스트·비용 스냅샷을 sessions/<session_id>.json 에 쓴다.

    context_window / cost / prompt_cache 는 전부 **세션별** 값이라 여러 세션이
    한 파일을 공유하면 서로 덮어쓴다. 세션마다 자기 파일만 쓰게 해서 경쟁을
    원천 차단한다. 메뉴바 앱이 디렉토리를 훑어 신선한 것만 표시한다.
    """
    sid = data.get("session_id")
    if not sid:
        return
    sid = "".join(c for c in str(sid) if c.isalnum() or c in "-_")[:64]
    if not sid:
        return

    ctx = data.get("context_window") or {}
    cost = data.get("cost") or {}
    cache = data.get("prompt_cache") or {}
    ws = data.get("workspace") or {}

    name = data.get("session_name")
    if not name:
        name = os.path.basename((ws.get("current_dir") or "").rstrip("/")) or sid[:8]

    path = os.path.join(SESS_DIR, "%s.json" % sid)

    # started_at 은 세션이 처음 등장한 시각. 메뉴바가 이걸로 **안정 정렬**한다
    # (updated_at 으로 정렬하면 세션들이 각자 갱신될 때마다 순서가 튄다).
    started = now
    try:
        with open(path, encoding="utf-8") as f:
            prev = json.load(f)
        if isinstance(prev, dict) and isinstance(prev.get("started_at"), (int, float)):
            started = prev["started_at"]
    except (OSError, ValueError):
        pass

    rec = {
        "session_id": sid,
        "name": name,
        "model": (data.get("model") or {}).get("display_name"),
        "context_pct": ctx.get("used_percentage"),
        "context_tokens": ctx.get("total_input_tokens"),
        "context_size": ctx.get("context_window_size"),
        "cost_usd": cost.get("total_cost_usd"),
        "lines_added": cost.get("total_lines_added"),
        "lines_removed": cost.get("total_lines_removed"),
        "duration_ms": cost.get("total_duration_ms"),
        "cache_hit_ratio": cache.get("hit_ratio"),
        "started_at": started,
        "updated_at": now,
    }

    try:
        os.makedirs(SESS_DIR, exist_ok=True)
    except OSError:
        return
    atomic_write_path(path, rec)

    # 죽은 세션 파일 청소 (하루 넘게 안 갱신된 것)
    try:
        for fn in os.listdir(SESS_DIR):
            if not fn.endswith(".json"):
                continue
            fp = os.path.join(SESS_DIR, fn)
            if now - os.path.getmtime(fp) > SESS_KEEP_SECONDS:
                os.unlink(fp)
    except OSError:
        pass


def main():
    now = time.time()

    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}

    # ── 세션별 컨텍스트·비용 스냅샷 ──
    try:
        write_session(data, now)
    except Exception:
        pass

    stored = load_stored()
    stored_rl = stored.get("rate_limits")
    if not isinstance(stored_rl, dict):
        stored_rl = {}
    stored_top_cap = stored.get("captured_at")

    incoming = data.get("rate_limits")
    if not isinstance(incoming, dict):
        incoming = {}

    # ── 창 단위 병합 ────────────────────────────────────────────────
    # 여러 Claude Code 세션이 각자 statusline.py 를 돌리는데, 세션마다 마지막으로
    # 받은 rate_limits 스냅샷이 다르다(놀던 세션은 옛날 값). 그대로 덮으면 파일이
    # 세션 간 값 사이에서 튄다. 사용률은 리셋 전까지 단조증가하므로 "뒤로 가는"
    # 갱신은 무시한다:
    #   1) resets_at 이 바뀌면(리셋 경계) → 새 값 채택
    #   2) 새 % >= 저장 % → 새 값 채택 (높은 쪽이 최신)
    #   3) 새 % < 저장 % → 저장값 유지 (놀던 세션의 옛날 스냅샷)
    #   4) 단, 저장값이 STALE_SECONDS 넘게 오래됐으면 새 값 채택 (썩은 파일 회복)
    #   5) resets_at 이 저장본보다 **이르면** 이전 창 스냅샷 → 무시. 창은 시간순으로
    #      앞으로만 간다. 플랜 변경(2026-09-10 Max 결제)으로 5시간창이 새로 시작되자
    #      놀던 세션들이 옛 창(62%)을 계속 밀어넣어 새 창(4%)과 번갈아 깜빡였다.
    merged = dict(stored_rl)
    for key, win in incoming.items():
        if not isinstance(win, dict):
            continue
        w = dict(win)
        w["captured_at"] = now

        old = merged.get(key)
        new_pct = w.get("used_percentage")
        if isinstance(old, dict):
            old_cap = old.get("captured_at")
            old_fresh = old_cap is not None and (now - old_cap) <= STALE_SECONDS
            new_ra, old_ra = w.get("resets_at"), old.get("resets_at")
            old_pct = old.get("used_percentage")
            if old_fresh:
                if _near(new_ra, old_ra):
                    if (old_pct is not None and new_pct is not None
                            and new_pct < old_pct):
                        continue  # 뒤로 가는 갱신 — 저장값·저장 captured_at 그대로 유지
                elif _earlier(new_ra, old_ra):
                    continue  # 이전 창 스냅샷 — 무시

        # ── 소진 속도 → ETA ──
        # 10분+ 간격의 baseline(rate_ref) 대비 %상승 기울기로 소진 시각을 잰다.
        # rate_ref 는 같은 창(resets_at) 안에서만 유효, 10분마다 슬라이드.
        ref = old.get("rate_ref") if isinstance(old, dict) else None
        cur_reset = w.get("resets_at")
        if (isinstance(ref, dict) and new_pct is not None
                and _near(ref.get("resets_at"), cur_reset, tol=120)):
            dt = now - (ref.get("at") or now)
            dpct = new_pct - (ref.get("pct") or new_pct)
            if dt >= 600:
                if dpct > 0.2:
                    rate = dpct / dt  # % per sec
                    w["eta_at"] = now + (100.0 - new_pct) / rate
                # dpct 미미 → 사실상 소진 안 함, eta 키 생략(메뉴바가 줄을 안 그림)
                w["rate_ref"] = {"at": now, "pct": new_pct, "resets_at": cur_reset}
            else:
                w["rate_ref"] = ref  # 아직 간격 부족 — 유지
                if old.get("eta_at") is not None:
                    w["eta_at"] = old["eta_at"]
        else:
            w["rate_ref"] = {"at": now, "pct": new_pct, "resets_at": cur_reset}

        merged[key] = w

    if incoming:
        atomic_write({"rate_limits": merged, "captured_at": now})

    # ── 모델별 사용량 집계 트리거 (비차단) ────────────────────────
    # model_usage.py 는 ~/.claude 전체 로그를 훑어 ~0.7s 걸린다. statusLine 훅은
    # 빨라야 하므로 여기서 기다리지 않고 detached 로 스폰만 한다. model_usage.py
    # 가 45초 스로틀을 자체적으로 걸어 중복 스폰을 흡수한다. 실패는 무시한다.
    try:
        mu_json = os.path.join(BASE, "model_usage.json")
        try:
            mu_stale = (now - os.path.getmtime(mu_json)) > 45
        except OSError:
            mu_stale = True
        if mu_stale:
            import subprocess
            subprocess.Popen(
                [sys.executable, os.path.join(BASE, "model_usage.py")],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
    except Exception:
        pass

    # ── 터미널 하단 요약 (병합된 데이터로) ──
    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d"), ("spend_limit", "$")):
        w = merged.get(key)
        if not isinstance(w, dict) or w.get("used_percentage") is None:
            continue
        seg = "%s %.0f%%" % (label, w["used_percentage"])

        # 창 자체 나이 > 30분 → 숫자는 그대로, '?' 마커
        cap = w.get("captured_at")
        if cap is None:
            cap = stored_top_cap  # 구 스키마 폴백
        if cap is not None and (now - cap) > STALE_SECONDS:
            seg += "?"

        ra = w.get("resets_at")
        if key == "five_hour" and ra:
            left = max(0, int(ra - now))
            h, m = divmod(left // 60, 60)
            seg += " (%dh%02dm)" % (h, m) if h else " (%dm)" % m
        parts.append(seg)

    style = (data.get("output_style") or {}).get("name")
    agent_tag = None
    if style and style != "default":
        agent_tag = AGENT_TAGS.get(style, style)

    model = (data.get("model") or {}).get("display_name")

    prefix = ""
    if agent_tag:
        prefix += "%s  " % agent_tag
    if model:
        prefix += "%s  " % model

    if parts:
        print(prefix + "  ".join(parts))
    elif merged:
        # 창은 있는데 쓸 수 있는 수치가 없음 — 그래도 "대기 중" 은 아니다
        print(prefix.rstrip() or "usage: —")
    else:
        # 정말 한 번도 데이터가 없을 때만
        print(prefix + "usage: rate_limit 대기 중")


if __name__ == "__main__":
    main()
