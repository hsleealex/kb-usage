#!/usr/bin/env python3
"""
Codex (ChatGPT 구독) 사용 한도 + 최근 스레드를 codex_limits.json 에 쓴다.

Codex CLI 는 statusLine 훅이 없다. 대신 공식 `codex app-server --stdio`
(JSON-RPC, 줄 단위 JSON) 에 물어본다. 계정 단위 값이라 다른 기기(윈도우)
사용량도 반영되고, 세션 로그 파일은 아예 안 읽는다.

  initialize → initialized(알림) → account/rateLimits/read
                                  → thread/list {limit, sortKey: updated_at, desc}

두 호출 모두 계정 메타데이터 조회라 모델 토큰을 쓰지 않는다. 프롬프트를 보내는
호출(thread/start, turn/start 등)은 이 파일에 절대 넣지 않는다.

app-server 는 **띄울 때마다** ~/.codex 상태 DB·로그·플러그인 캐시를 건드리고
1초쯤 걸린다. 그래서 --daemon 은 하나를 붙잡고 POLL_SECONDS 마다 요청만
보낸다 (요청 자체는 ~/.codex 에 아무것도 안 쓴다 — 2026-10-03 확인). 메뉴바
앱이 자식으로 띄우고, 부모가 죽으면 스스로 내려간다.

  codex_usage.py --daemon   상주 (메뉴바 앱이 씀)
  codex_usage.py --print    한 번 조회해서 쓰고 한 줄 요약 출력

스키마 (rate_limits.json 과 같은 결, 가산 확장만):
  {
    "ok": bool,                     # 마지막 조회 성공 여부
    "error": str|null,              # 실패 사유 (짧게)
    "checked_at": float,            # 마지막 조회 시도 시각
    "captured_at": float|null,      # 마지막 **성공** 시각 (아래 값의 기준 시각)
    "rate_limits": {
      "five_hour": {"used_percentage", "resets_at", "window_minutes"},
      "seven_day": {"used_percentage", "resets_at", "window_minutes"},
      "plan_type": str|null, "limit_id": str|null,
      "credits": {"has_credits", "unlimited", "balance"}|null
    } | null,
    "threads": [{"id", "name", "source", "model", "created_at", "updated_at", "status"}]
                                    # source: cli(codex-tui) | vscode(ChatGPT 앱: Codex Desktop / Work)
  }
    "live": {"checked_at": float, "cli": [{"thread_id", "pid", "started_at", "term_pid"}]},
    "models": {"window_start", "computed_at", "basis": "tokens", "total", "rows": [{"label", "tokens", "share"}]}
실패하면 ok=false 로 쓰되 rate_limits/captured_at 은 마지막 성공값을 남긴다.
메뉴바는 ok=false 거나 checked_at 이 묵었으면 "조회 불가" 로 그린다.
리셋 시각이 지났는지는 표시 시점에 판단한다.
"""
import json
import os
import queue
import select
import shutil
import signal
import subprocess
import sys
import threading
import time

BASE = os.path.dirname(os.path.abspath(__file__))
CX_JSON = os.path.join(BASE, "codex_limits.json")

POLL_SECONDS = 60         # 조회 주기
REQ_TIMEOUT = 15.0        # 요청 하나 타임아웃
MAX_THREADS = 12          # 저장할 최근 스레드 수 (CLI 스레드가 앱 스레드에 밀려나지 않게 넉넉히)
THREAD_NAME_MAX = 48


def codex_exe():
    """~/.local/bin/codex (ChatGPT 앱 번들 링크) 우선, 없으면 PATH."""
    p = os.path.join(os.path.expanduser("~"), ".local", "bin", "codex")
    if os.access(p, os.X_OK):
        return p
    return shutil.which("codex") or "codex"


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


class AppServer:
    """`codex app-server --stdio` 위의 작은 동기 JSON-RPC 클라이언트.

    응답은 별도 스레드가 stdout 을 읽어 id 별 큐로 나눈다. 서버가 먼저 보내는
    알림(account/updated 등)은 버린다. stderr 는 버린다 (로그에 남기지 않음).
    """

    def __init__(self, exe=None):
        self.exe = exe or codex_exe()
        self.proc = None
        self._next = 1
        self._waiting = {}
        self._lock = threading.Lock()

    def start(self):
        self.proc = subprocess.Popen(
            [self.exe, "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        threading.Thread(target=self._read_loop, daemon=True).start()
        self.request("initialize", {
            "clientInfo": {"name": "kb-usage", "title": "kb-usage menubar", "version": "0.1.0"},
            "capabilities": {"experimentalApi": True},
        })
        self._send({"method": "initialized", "params": {}})

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _send(self, obj):
        if not self.alive() or self.proc.stdin is None:
            raise RuntimeError("app-server not running")
        self.proc.stdin.write(json.dumps(obj, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def _read_loop(self):
        proc = self.proc
        try:
            for line in proc.stdout:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                rid = o.get("id") if isinstance(o, dict) else None
                if isinstance(rid, int):
                    with self._lock:
                        q = self._waiting.get(rid)
                    if q is not None:
                        q.put(o)
        except (OSError, ValueError):
            pass            # close() 가 파이프를 닫으면 여기로 — 조용히 끝낸다

    def request(self, method, params=None):
        with self._lock:
            rid = self._next
            self._next += 1
            q = queue.Queue(maxsize=1)
            self._waiting[rid] = q
        try:
            self._send({"method": method, "id": rid, "params": params or {}})
            try:
                resp = q.get(timeout=REQ_TIMEOUT)
            except queue.Empty:
                raise TimeoutError("timeout: %s" % method)
        finally:
            with self._lock:
                self._waiting.pop(rid, None)
        if "error" in resp:
            err = resp["error"]
            msg = err.get("message") if isinstance(err, dict) else None
            raise RuntimeError("%s: %s" % (method, str(msg or "error")[:120]))
        res = resp.get("result")
        if not isinstance(res, dict):
            raise RuntimeError("%s: bad result" % method)
        return res

    def close(self):
        proc, self.proc = self.proc, None
        if proc is None:
            return
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        try:
            proc.stdout.close()     # 재기동 반복 시 FD 누수 방지
        except (OSError, ValueError):
            pass


# ── 정규화 (화이트리스트 필드만) ─────────────────────────

def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def _str(v, n=32):
    return v[:n] if isinstance(v, str) else None


def choose_limit(res):
    """rateLimitsByLimitId['codex'] 우선, 없으면 아무 거나, 그것도 없으면 레거시 rateLimits."""
    by_id = res.get("rateLimitsByLimitId")
    if isinstance(by_id, dict):
        if isinstance(by_id.get("codex"), dict):
            return by_id["codex"]
        for v in by_id.values():
            if isinstance(v, dict):
                return v
    legacy = res.get("rateLimits")
    return legacy if isinstance(legacy, dict) else {}


def _window(w):
    if not isinstance(w, dict):
        return None
    pct = _num(w.get("usedPercent"))
    if pct is None:
        return None
    return {
        "used_percentage": max(0.0, min(100.0, pct)),
        "resets_at": _num(w.get("resetsAt")),
        "window_minutes": _num(w.get("windowDurationMins")),
    }


def normalize_limits(res):
    """account/rateLimits/read 결과 → rate_limits dict. 쓸 창이 없으면 None.

    창 이름은 길이로 정한다: 하루 미만 = five_hour, 하루 이상 = seven_day.
    (지금은 primary=300분, secondary=10080분)
    """
    snap = choose_limit(res)
    wins = [w for w in (_window(snap.get("primary")), _window(snap.get("secondary"))) if w]
    if not wins:
        return None
    short = [w for w in wins if (w["window_minutes"] or 300) < 1440]
    long_ = [w for w in wins if (w["window_minutes"] or 0) >= 1440]
    out = {}
    if short:
        out["five_hour"] = min(short, key=lambda w: abs((w["window_minutes"] or 300) - 300))
    if long_:
        out["seven_day"] = max(long_, key=lambda w: w["window_minutes"] or 0)
    cr = snap.get("credits")
    out["credits"] = {
        "has_credits": cr.get("hasCredits") is True,
        "unlimited": cr.get("unlimited") is True,
        "balance": _num(cr.get("balance")),
    } if isinstance(cr, dict) else None
    out["plan_type"] = _str(snap.get("planType"))
    out["limit_id"] = _str(snap.get("limitId"))
    return out


def normalize_threads(res):
    """thread/list 결과 → 메타데이터만. preview(첫 메시지) 같은 본문 필드는 버린다.

    status 는 이 app-server 가 직접 로드한 스레드만 의미가 있다. 남의 프로세스
    (ChatGPT 앱·CLI)가 돌리는 스레드는 늘 notLoaded 라 그건 null 로 둔다
    — 상태를 추측해서 만들지 않는다.
    """
    rows = []
    data = res.get("data")
    if not isinstance(data, list):
        return rows
    for t in data:
        if not isinstance(t, dict) or t.get("ephemeral") is True:
            continue
        st = t.get("status")
        st = st.get("type") if isinstance(st, dict) else None
        name = t.get("name")
        if not isinstance(name, str) or not name.strip() or "�" in name:
            cwd = t.get("cwd")
            name = os.path.basename(cwd.rstrip("/")) if isinstance(cwd, str) and cwd else ""
        rows.append({
            "id": _str(t.get("id"), 64),
            "name": name.strip()[:THREAD_NAME_MAX] or None,
            "source": _str(t.get("source")),          # cli | vscode (ChatGPT 앱) — 2026-10-03 실측
            "model": _str(t.get("model")),
            "created_at": _num(t.get("createdAt")),     # 목록 안정 정렬용
            "updated_at": _num(t.get("updatedAt")),
            "status": st if st and st != "notLoaded" else None,
        })
        if len(rows) >= MAX_THREADS:
            break
    return rows


# ── 모델별 주간 사용 (로컬 rollout 증분 집계) ─────────────
#
# app-server 는 모델별 사용량을 안 준다. 그래서 Claude 쪽 model_usage.py 처럼 로컬
# 로그를 집계한다: rollout 의 turn_context 이벤트(payload.model)로 지금 모델을
# 따라가고, token_count 이벤트의 info.last_token_usage.total_tokens 를 그 모델에
# 더한다. total_tokens = input(캐시 포함) + output(reasoning 포함) — Claude 쪽
# "input + output + cache_creation + cache_read" 와 같은 정의. 한 턴에 token_count
# 가 겹쳐 찍히는 일이 있어 누적 total_token_usage 가 바뀐 이벤트만 센다.
#
# 각 줄은 JSON 으로 파싱하되 type·model·토큰 숫자만 꺼내고 바로 버린다. 대화·도구
# 입출력·지시문은 어디에도 남기지 않는다. 캐시에는 파일별 (mtime, size, 읽은 offset,
# 현재 모델, 직전 누적값, 5분 단위 모델별 토큰) 만 — 경로는 sessions/ 기준 상대경로.
#
# 기간은 Codex 주간 한도 창: [seven_day.resets_at − 창 길이, now]
# (리셋 시각이 없거나 지났으면 [now − 7일, now] — model_usage.py 와 같은 폴백).
# 이 Mac 의 rollout 만 보므로 다른 기기 사용량과 --ephemeral 호출은 안 잡힌다.
# Claude 기록을 변환해 들여온 세션(external_agent_session_imports.json 의
# imported_thread_id)은 뺀다.

MODELS_CACHE = os.path.join(BASE, "codex_models_cache.json")
WEEK = 7 * 86400
BUCKET = 300              # 5분 단위 — 창 경계 오차 5분 이내
TOP_MODELS = 3            # 상위 N 개 + 나머지는 "기타"


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def imported_ids(home):
    """외부(Claude) 임포트 스레드 id 들. 파일 없거나 깨지면 빈 집합."""
    o = load_json(os.path.join(home, "external_agent_session_imports.json"))
    recs = o.get("records")
    if not isinstance(recs, list):
        return set()
    return {r["imported_thread_id"] for r in recs
            if isinstance(r, dict) and isinstance(r.get("imported_thread_id"), str) and r["imported_thread_id"]}


def _epoch(ts):
    if not isinstance(ts, str):
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def scan_file(path, ent):
    """ent 의 offset 부터 새로 붙은 완성된 줄만 읽어 ent 를 갱신한다 (증분)."""
    buckets = ent.setdefault("buckets", {})
    model = ent.get("model") or "unknown"
    prev_total = ent.get("prev_total")
    with open(path, "rb") as f:
        f.seek(ent.get("offset", 0))
        pos = f.tell()
        for line in f:
            if not line.endswith(b"\n"):
                break                       # 쓰는 중인 마지막 줄 — 다음에 다시
            pos += len(line)
            # 싼 사전 필터 — 두 이벤트가 아니면 파싱도 안 한다
            is_ctx = b'"turn_context"' in line
            if not is_ctx and b'"token_count"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            pl = e.get("payload") if isinstance(e, dict) else None
            if not isinstance(pl, dict):
                continue
            if is_ctx and e.get("type") == "turn_context":
                m = pl.get("model")
                model = m[:48] if isinstance(m, str) and m else "unknown"
                continue
            if pl.get("type") != "token_count" or not isinstance(pl.get("info"), dict):
                continue
            info = pl["info"]
            tot = info.get("total_token_usage")
            tot = _num(tot.get("total_tokens")) if isinstance(tot, dict) else None
            if tot is not None and tot == prev_total:
                continue                    # 같은 턴이 겹쳐 찍힌 것
            prev_total = tot
            last = info.get("last_token_usage")
            n = _num(last.get("total_tokens")) if isinstance(last, dict) else None
            if n is None and isinstance(last, dict):
                n = (_num(last.get("input_tokens")) or 0) + (_num(last.get("output_tokens")) or 0)
            ts = _epoch(e.get("timestamp"))
            if not n or ts is None:
                continue
            b = buckets.setdefault(model, {})
            k = str(int(ts // BUCKET))
            b[k] = b.get(k, 0) + int(n)
    ent.update(offset=pos, model=model, prev_total=prev_total)


def collect_models(window_start, now, home=None, cache_path=MODELS_CACHE):
    """창 구간 모델별 토큰 → (rows, total). rows = 상위 TOP_MODELS + "기타"(unknown 포함)."""
    home = home or codex_home()
    sess = os.path.join(home, "sessions")
    cache = load_json(cache_path)
    files = cache.get("files") if isinstance(cache.get("files"), dict) else {}
    skip_ids = imported_ids(home)
    keep_from = now - WEEK - 86400            # 창이 아무리 일러도 8일 전까지만
    seen = {}
    for root, _dirs, names in os.walk(sess):
        for n in names:
            if not (n.startswith("rollout-") and n.endswith(".jsonl")):
                continue
            if any(i in n for i in skip_ids):
                continue                       # Claude 기록을 변환한 임포트 세션
            p = os.path.join(root, n)
            rel = os.path.relpath(p, sess)
            try:
                st = os.stat(p)
            except OSError:
                continue
            ent = files.get(rel)
            if ent is None and st.st_mtime < keep_from:
                continue                       # 창보다 오래전에 끝난 파일 — 읽을 일 없음
            if not isinstance(ent, dict) or st.st_size < ent.get("offset", 0):
                ent = {}                       # 처음 보거나 파일이 줄었다 — 처음부터
            if ent.get("size") != st.st_size or ent.get("mtime") != st.st_mtime:
                try:
                    scan_file(p, ent)
                except OSError:
                    continue
                ent.update(size=st.st_size, mtime=st.st_mtime)
            # 오래된 버킷 정리
            cut = int(keep_from // BUCKET)
            for m in list(ent.get("buckets", {})):
                bk = {k: v for k, v in ent["buckets"][m].items() if int(k) >= cut}
                if bk:
                    ent["buckets"][m] = bk
                else:
                    del ent["buckets"][m]
            seen[rel] = ent
    atomic_write(cache_path, {"version": 1, "files": seen})

    lo = int(window_start // BUCKET)
    acc = {}
    for ent in seen.values():
        for m, bk in ent.get("buckets", {}).items():
            s = sum(v for k, v in bk.items() if int(k) >= lo)
            if s:
                acc[m] = acc.get(m, 0) + s
    total = sum(acc.values())
    ranked = sorted(((m, t) for m, t in acc.items() if m != "unknown"), key=lambda x: -x[1])
    rows = [{"label": m, "tokens": t} for m, t in ranked[:TOP_MODELS]]
    rest = sum(t for _m, t in ranked[TOP_MODELS:]) + acc.get("unknown", 0)
    if rest:
        rows.append({"label": "기타", "tokens": rest, "other": True})
    for r in rows:
        r["share"] = round(r["tokens"] / total, 4) if total else 0
    return rows, total


def week_window(lim, now):
    """Codex 주간 한도 창 시작. model_usage.window_starts 와 같은 규칙."""
    w = lim.get("seven_day") if isinstance(lim, dict) else None
    ra = w.get("resets_at") if isinstance(w, dict) else None
    mins = (w.get("window_minutes") if isinstance(w, dict) else None) or 10080
    if ra and ra > now:
        return ra - mins * 60
    return now - WEEK


def models_block(out, now, home=None, cache_path=MODELS_CACHE):
    """out["models"] 를 채운다. 실패하면 이전 값 유지 (값을 지어내지 않는다)."""
    start = week_window(out.get("rate_limits"), now)
    try:
        rows, total = collect_models(start, now, home, cache_path)
    except Exception as e:                    # 집계 실패가 한도 표시를 막으면 안 된다
        out.setdefault("models_error", str(e)[:120])
        return out
    out["models"] = {"window_start": start, "computed_at": now, "basis": "tokens",
                     "total": total, "rows": rows}
    return out


# ── 소진 ETA (statusline.py 의 Claude 쪽과 같은 방식) ─────
# 10분+ 간격 baseline(rate_ref) 대비 %상승 기울기로 소진 시각을 잰다. rate_ref 는
# 같은 창(resets_at ±120초) 안에서만 유효, 10분마다 슬라이드. 상승이 미미하면 생략.
ETA_BASELINE = 600
ETA_MIN_DELTA = 0.2


def merge_eta(lim, prev_lim, now):
    prev_lim = prev_lim if isinstance(prev_lim, dict) else {}
    for key in ("five_hour", "seven_day"):
        w = lim.get(key)
        if not isinstance(w, dict):
            continue
        old = prev_lim.get(key) if isinstance(prev_lim.get(key), dict) else {}
        pct, reset = w.get("used_percentage"), w.get("resets_at")
        ref = old.get("rate_ref")
        same = (isinstance(ref, dict) and reset is not None and ref.get("resets_at") is not None
                and abs(reset - ref["resets_at"]) <= 120)
        if same and pct is not None:
            dt = now - (ref.get("at") or now)
            dp = pct - (ref.get("pct") if ref.get("pct") is not None else pct)
            if dt >= ETA_BASELINE:
                if dp > ETA_MIN_DELTA:
                    w["eta_at"] = now + (100.0 - pct) / (dp / dt)
                w["rate_ref"] = {"at": now, "pct": pct, "resets_at": reset}
            else:
                w["rate_ref"] = ref
                if old.get("eta_at") is not None:
                    w["eta_at"] = old["eta_at"]
        else:
            w["rate_ref"] = {"at": now, "pct": pct, "resets_at": reset}
    return lim


# ── 조회 / 기록 ──────────────────────────────────────────

def poll(server, prev, now):
    """한 번 조회. 성공이면 새 값, 실패면 ok=false + 마지막 성공값 유지."""
    out = {
        "ok": False,
        "error": None,
        "checked_at": now,
        "captured_at": prev.get("captured_at"),
        "rate_limits": prev.get("rate_limits") if isinstance(prev.get("rate_limits"), dict) else None,
        "threads": prev.get("threads") if isinstance(prev.get("threads"), list) else [],
        "models": prev.get("models") if isinstance(prev.get("models"), dict) else None,
    }
    try:
        lim = normalize_limits(server.request("account/rateLimits/read"))
        if lim is None:
            raise RuntimeError("no rate limits in response")
        lim = merge_eta(lim, prev.get("rate_limits"), now)
        out.update(ok=True, rate_limits=lim, captured_at=time.time())
        try:
            out["threads"] = normalize_threads(server.request(
                "thread/list", {"limit": 12, "sortKey": "updated_at", "sortDirection": "desc"}))
        except (RuntimeError, TimeoutError, OSError):
            pass        # 스레드 목록은 부가 정보 — 한도만 성공이면 ok
    except (RuntimeError, TimeoutError, OSError, ValueError) as e:
        out["error"] = str(e)[:160]
    return out


def describe(out, now):
    """--print 용 한 줄 요약. 리셋 지난 창은 0% (reset)."""
    rl = out.get("rate_limits")
    if not out.get("ok"):
        return "codex: unavailable (%s)" % (out.get("error") or "?")
    if not isinstance(rl, dict):
        return "codex: no data"
    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        w = rl.get(key)
        if not isinstance(w, dict):
            continue
        ra = w.get("resets_at")
        if ra is not None and ra <= now:
            parts.append("%s 0%% (reset)" % label)
        else:
            parts.append("%s %.0f%%" % (label, w.get("used_percentage") or 0))
    md = out.get("models")
    mtxt = ""
    if isinstance(md, dict) and md.get("rows"):
        mtxt = " · week by model: " + ", ".join(
            "%s %.0f%%" % (r["label"], r["share"] * 100) for r in md["rows"])
    return "codex %s: %s · %d threads%s" % (rl.get("plan_type") or "?", "  ".join(parts),
                                           len(out.get("threads") or []), mtxt)


def once(out_path=CX_JSON, exe=None):
    srv = AppServer(exe)
    prev = load_json(out_path)
    try:
        srv.start()
        out = poll(srv, prev, time.time())
    except (RuntimeError, TimeoutError, OSError) as e:
        out = poll_failed(prev, str(e))
    finally:
        srv.close()
    models_block(out, time.time())
    atomic_write(out_path, out)
    return out


def poll_failed(prev, err):
    """app-server 자체를 못 띄웠을 때."""
    return {
        "ok": False,
        "error": err[:160],
        "checked_at": time.time(),
        "captured_at": prev.get("captured_at"),
        "rate_limits": prev.get("rate_limits") if isinstance(prev.get("rate_limits"), dict) else None,
        "threads": prev.get("threads") if isinstance(prev.get("threads"), list) else [],
        "models": prev.get("models") if isinstance(prev.get("models"), dict) else None,
    }


# ── 지금 살아있는 Codex CLI 세션 ─────────────────────────
# 목록의 CLI 행은 "최근 활동"이 아니라 **지금 떠 있는 codex CLI 프로세스**가 받칠 때만
# 보인다. Codex 코어는 스레드를 로드한 동안 그 rollout 파일을 열어 둔다 (ChatGPT 앱의
# app-server 로 확인, 2026-10-03) → 프로세스가 연 rollout 파일명의 thread id 로 매칭.
# 파일 내용은 안 읽는다. app-server / exec / exec-server / ChatGPT 앱 자식은 뺀다.
# 프로세스가 rollout 을 아직 안 열었거나(첫 메시지 전) 매칭이 안 되면 행을 안 만든다.
LIVE_SECONDS = 10
# 안 바뀌어도 이 간격마다는 써서 live.checked_at 을 갱신한다. 메뉴바는 live 가
# CODEX_LIVE_MAX_AGE(90초)보다 묵으면 안 믿는다 — 10초 틱·한도 조회 멈춤까지 더해도 그 안에 들게.
LIVE_HEARTBEAT = 20
_LSTART = "%a %b %d %H:%M:%S %Y"


def _ps_table():
    """{pid: (ppid, started_epoch|None, comm)} — ps 한 번."""
    try:
        out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="], capture_output=True,
                             text=True, timeout=5, env={"LC_ALL": "C"}).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 7)
        if len(parts) < 8 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        try:
            started = time.mktime(time.strptime(" ".join(parts[2:7]), _LSTART))
        except ValueError:
            started = None
        table[int(parts[0])] = (int(parts[1]), started, parts[7])
    return table


def _ancestors(table, pid):
    seen = []
    for _ in range(30):
        ent = table.get(pid)
        if not ent or ent[0] <= 1:
            break
        pid = ent[0]
        seen.append(pid)
    return seen


def live_cli(table=None):
    """[{"thread_id", "pid", "started_at", "term_pid"}] — 지금 떠 있는 codex CLI 와 그 스레드."""
    table = table if table is not None else _ps_table()
    cands = []
    for pid, (_pp, _st, comm) in table.items():
        base = os.path.basename(comm)
        if base not in ("codex", "codex-tui"):
            continue
        if any("/ChatGPT.app/Contents/MacOS/" in table.get(a, (0, 0, ""))[2] for a in _ancestors(table, pid)):
            continue                        # ChatGPT 앱이 띄운 것 (앱의 app-server 등)
        cands.append(pid)
    if not cands:
        return []
    # 하위 명령 확인: app-server / exec / exec-server 는 대화형 CLI 가 아니다.
    # args 는 메모리에서 이 검사에만 쓰고 버린다 (exec 의 프롬프트가 들어 있을 수 있음).
    try:
        out = subprocess.run(["/bin/ps", "-o", "pid=,args=", "-p", ",".join(map(str, cands))],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    keep = []
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        toks = parts[1].split()[1:]
        sub = next((t for t in toks if not t.startswith("-") and "=" not in t), "")
        if sub in ("app-server", "exec", "exec-server", "e", "mcp-server", "proto"):
            continue
        keep.append(int(parts[0]))
    if not keep:
        return []
    try:
        out = subprocess.run(["/usr/sbin/lsof", "-n", "-w", "-Fpn", "-p", ",".join(map(str, keep))],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows, pid, seen = [], None, set()
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:]) if line[1:].isdigit() else None
        elif line.startswith("n") and pid is not None:
            name = os.path.basename(line[1:])
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            tid = name[:-6][-36:]           # rollout-<시각>-<uuid>.jsonl
            if (pid, tid) in seen:
                continue
            seen.add((pid, tid))
            term = next((a for a in _ancestors(table, pid) if ".app/Contents/MacOS/" in table[a][2]), None)
            rows.append({"thread_id": tid, "pid": pid, "started_at": table[pid][1], "term_pid": term})
    return rows


def daemon(out_path=CX_JSON, exe=None):
    """app-server 하나를 붙잡고 POLL_SECONDS 마다 조회. 부모가 죽으면 끝낸다.

    app-server 가 죽거나 요청이 실패하면 다음 주기에 새로 띄운다 (실패가
    이어지면 최대 10분까지 간격을 늘린다).
    """
    parent = os.getppid()
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    srv = None
    fails = 0
    next_at = 0.0
    live_at = 0.0
    live_written = 0.0
    out = None
    while not stop:
        if os.getppid() != parent:          # 메뉴바 앱이 죽었다 → 같이 내려간다
            break
        now = time.time()
        if now >= live_at and now < next_at and out is not None:
            # 한도 조회 사이사이 10초마다: 살아있는 CLI 만 다시 본다 (바뀌었을 때만 쓰기)
            live_at = now + LIVE_SECONDS
            cli = live_cli()
            changed = cli != (out.get("live") or {}).get("cli")
            out["live"] = {"checked_at": now, "cli": cli}
            if changed or now - live_written >= LIVE_HEARTBEAT:   # 안 바뀌어도 checked_at 갱신용으로 씀
                live_written = now
                atomic_write(out_path, out)
        if now >= next_at:
            prev = load_json(out_path)
            try:
                if srv is None or not srv.alive():
                    if srv is not None:
                        srv.close()
                    srv = AppServer(exe)
                    srv.start()
                out = poll(srv, prev, now)
            except (RuntimeError, TimeoutError, OSError) as e:
                out = poll_failed(prev, str(e))
            models_block(out, time.time())
            out["live"] = {"checked_at": time.time(), "cli": live_cli()}
            live_at = time.time() + LIVE_SECONDS
            atomic_write(out_path, out)
            if out["ok"]:
                fails = 0
            else:
                fails += 1
                if srv is not None:         # 꼬였을 수 있으니 다음엔 새로 띄운다
                    srv.close()
                    srv = None
            next_at = time.time() + min(600, POLL_SECONDS * (2 ** min(fails, 4) if fails > 1 else 1))
        # 2초 단위로 깨어나 부모 생존 확인 (stdin 없는 select 로 대기)
        select.select([], [], [], 2.0)
    if srv is not None:
        srv.close()


def main():
    argv = sys.argv[1:]
    if "--daemon" in argv:
        daemon()
        return
    out = once()
    if "--print" in argv:
        print(describe(out, time.time()))


if __name__ == "__main__":
    main()
