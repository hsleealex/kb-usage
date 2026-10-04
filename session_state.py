#!/usr/bin/env python3
"""
Claude Code 훅 — 세션 상태(작업 중 / 승인 필요 / idle)를 sessions/<id>.state.json 에 쓴다.

메뉴바 앱이 statusline.py 의 sessions/<id>.json (컨텍스트·비용) 과 합쳐서 세션
목록을 그린다. 파일을 나눈 이유: statusline.py 는 3초마다 자기 파일을 통째로
다시 쓰므로 같은 파일에 상태를 얹으면 서로 덮어쓴다.

  UserPromptSubmit / PreToolUse / PostToolUse  → working
  Notification (승인·질문·입력 대기)           → attention   (다음 working/idle 로 풀림)
  SessionStart / Stop                          → idle        (Stop 이면 done_at 기록)
  SessionEnd                                   → 이 세션 파일 두 개 삭제
  attention 이 풀리면 그 세션의 승인 알림 팝업(그룹 cc-<session_id>)을 치운다

**모든 세션의 모든 도구 호출**에 붙으므로:
  - 아무것도 출력하지 않는다 (UserPromptSubmit/SessionStart 의 stdout 은 대화에 섞인다)
  - 항상 exit 0, 예외는 삼킨다
  - 쓰기는 임시파일 + rename, 세션 id 별 파일이라 세션끼리 안 부딪힌다
  - 무거운 일(터미널 pid 찾기)은 세션당 한 번만

기록하는 것은 짧은 메타데이터뿐이다: 상태, 시각, 도구 이름, 파일 basename,
todo 개수·진행 중 항목 제목(40자), pid. 프롬프트·명령어·도구 입출력·대화
본문은 읽지도 쓰지도 않는다.

스키마 (sessions/<id>.state.json):
  {"session_id", "state": "working"|"attention"|"idle", "state_since": float,
   "event": str, "event_at": float, "done_at": float|null,
   "attention": str|null,                       # notification_type
   "tool": str|null, "hint": str|null,          # 도구 이름, 파일 basename 등
   "todo_done": int|null, "todo_total": int|null, "todo_active": str|null,
   "claude_pid": int|null, "claude_start": float|null,   # pid 재사용 확인용 시작 시각
   "term_pid": int|null, "pid_checked": bool, "start_checked": bool}
"""
import json
import os
import subprocess
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
SESS_DIR = os.path.join(BASE, "sessions")

# 승인 알림 팝업(alerter / terminal-notifier)의 그룹 이름 = NOTIFY_GROUP + session_id.
# 승인 대기가 풀리면(attention → working/idle, 또는 세션 종료) 그 팝업을 치운다.
# 누를 때까지 남는 팝업이라 이미 승인했는데도 화면에 남아 있던 문제 (2026-10-04).
NOTIFY_GROUP = "cc-"
DISMISSERS = (
    (os.path.join(os.path.expanduser("~"), ".local", "bin", "alerter"), "--remove"),
    ("/opt/homebrew/bin/terminal-notifier", "-remove"),
)

WORKING_EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse")
IDLE_EVENTS = ("SessionStart", "Stop")
HINT_MAX = 40
FILE_TOOLS = ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit")


def _sid(raw):
    s = "".join(c for c in str(raw or "") if c.isalnum() or c in "-_")[:64]
    return s or None


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
    except (OSError, ValueError):
        return {}
    return obj if isinstance(obj, dict) else {}


def atomic_write(path, obj):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def clip(s, n=HINT_MAX):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def tool_meta(ev):
    """(도구 짧은 이름, 안전한 힌트). Bash 등은 이름만 — 명령어는 안 남긴다."""
    name = ev.get("tool_name")
    if not isinstance(name, str) or not name:
        return None, None
    short = name.split("__")[-1] if name.startswith("mcp__") else name
    inp = ev.get("tool_input")
    inp = inp if isinstance(inp, dict) else {}
    hint = None
    if name in FILE_TOOLS:
        p = inp.get("file_path") or inp.get("notebook_path")
        if isinstance(p, str) and p:
            hint = os.path.basename(p.rstrip("/"))
    elif name in ("Agent", "Task"):
        t = inp.get("subagent_type")
        hint = t if isinstance(t, str) else None
    return clip(short, 32), (clip(hint) if hint else None)


def todo_meta(ev):
    """TodoWrite 의 todos → (완료 수, 전체 수, 진행 중 항목 제목). 아니면 None."""
    if ev.get("tool_name") != "TodoWrite":
        return None
    inp = ev.get("tool_input")
    todos = inp.get("todos") if isinstance(inp, dict) else None
    if not isinstance(todos, list):
        return None
    todos = [t for t in todos if isinstance(t, dict)]
    done = sum(1 for t in todos if t.get("status") == "completed")
    active = None
    for t in todos:
        if t.get("status") == "in_progress":
            a = t.get("activeForm") or t.get("content")
            active = clip(a) if isinstance(a, str) and a.strip() else None
            break
    return done, len(todos), active


def proc_info(start):
    """(start 프로세스 시작 시각, 처음 만나는 .app 조상 pid) — ps 한 번 (~10ms).

    시작 시각은 pid 재사용 오탐을 막는 데 쓴다 (메뉴바가 같은 pid 라도 시작 시각이
    다르면 죽은 세션으로 본다). .app 조상은 그 세션의 터미널 창 (Ghostty 는 창마다
    프로세스가 따로라 이 pid 가 곧 그 창이다).
    """
    try:
        out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="], capture_output=True,
                             text=True, timeout=2, env={"LC_ALL": "C"}).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 7)
        if len(parts) == 8 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), " ".join(parts[2:7]), parts[7])
    started = None
    if start in table:
        try:
            started = time.mktime(time.strptime(table[start][1], "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            pass
    pid = start
    for _ in range(25):
        if pid <= 1 or pid not in table:
            return started, None
        ppid, _lst, comm = table[pid]
        if ".app/Contents/MacOS/" in comm and pid != start:
            return started, pid
        pid = ppid
    return started, None


def dismiss_popup(sid):
    """그 세션의 승인 알림을 치운다. 분리된 프로세스로 띄우고 기다리지 않는다
    (훅 지연 0). 이미 닫혔으면 도구가 조용히 끝난다."""
    for exe, flag in DISMISSERS:
        if os.access(exe, os.X_OK):
            try:
                subprocess.Popen([exe, flag, NOTIFY_GROUP + sid], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except OSError:
                pass


def handle(ev, now):
    sid = _sid(ev.get("session_id"))
    event = ev.get("hook_event_name")
    if not sid or not isinstance(event, str):
        return
    base = os.path.join(SESS_DIR, sid)
    path = base + ".state.json"

    if event == "SessionEnd":
        if load(path).get("state") == "attention":
            dismiss_popup(sid)
        for p in (path, base + ".json"):     # 이 세션 파일만
            try:
                os.unlink(p)
            except OSError:
                pass
        return

    if event in WORKING_EVENTS:
        state = "working"
    elif event == "Notification":
        state = "attention"
    elif event in IDLE_EVENTS:
        state = "idle"
    else:
        return

    prev = load(path)
    rec = {k: prev.get(k) for k in (
        "done_at", "tool", "hint", "todo_done", "todo_total", "todo_active",
        "claude_pid", "claude_start", "term_pid", "pid_checked", "start_checked", "state_since")}
    rec.update(session_id=sid, state=state, event=event, event_at=now, attention=None)
    if prev.get("state") != state or not rec.get("state_since"):
        rec["state_since"] = now
    if state == "attention":
        kind = ev.get("notification_type")
        rec["attention"] = clip(kind, 32) if isinstance(kind, str) else "attention"
    if event == "Stop":
        rec["done_at"] = now
    if event == "SessionStart":
        rec.update(done_at=None, tool=None, hint=None)
    if event == "UserPromptSubmit":
        rec.update(tool=None, hint=None)
    if event in ("PreToolUse", "PostToolUse"):
        rec["tool"], rec["hint"] = tool_meta(ev)
        td = todo_meta(ev)
        if td is not None:
            rec["todo_done"], rec["todo_total"], rec["todo_active"] = td

    # 터미널 pid 는 세션당 한 번만 찾는다. 훅은 `sh -c` 가 exec 한 프로세스라
    # getppid() 가 claude 다 (cos/bin/session_registry.py 주석 참고).
    # (시작 시각을 아직 안 재 본 옛 상태 파일이면 한 번만 다시 채운다)
    if not rec.get("pid_checked") or not rec.get("start_checked"):
        cp = os.getppid()
        started, term = proc_info(cp)
        rec.update(claude_pid=cp, claude_start=started, term_pid=term, pid_checked=True, start_checked=True)

    try:
        os.makedirs(SESS_DIR, exist_ok=True)
    except OSError:
        return
    atomic_write(path, rec)

    # 승인 대기가 풀리는 순간에만 팝업 정리 (평소 이벤트는 비교 한 번뿐)
    if prev.get("state") == "attention" and state != "attention":
        dismiss_popup(sid)


def main():
    try:
        raw = sys.stdin.read()
        ev = json.loads(raw) if raw.strip() else {}
        if isinstance(ev, dict):
            handle(ev, time.time())
    except Exception:
        pass        # 상태 기록 실패가 세션을 막으면 안 된다
    return 0


if __name__ == "__main__":
    sys.exit(main())
