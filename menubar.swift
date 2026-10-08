// Claude + Codex 사용 한도 / 세션 상태 메뉴바 앱.
//
// 메뉴바:  같은 모양의 이중 링 두 개 — 왼쪽 Claude(테라코타), 오른쪽 Codex(시안).
//          바깥 = 5시간, 안쪽 = 주간. 승인 대기 세션이 있으면 두 링 사이 위에 호박색 점.
//          한도 임박 표현은 변형 1/2/3 (기본 1 굵기) — `defaults write kb-usage-menubar iconVariant 1`
// 클릭  :  팝오버 — 위: CLAUDE / CODEX 한도 (같은 컴포넌트), 아래: 세션 목록
//
// 데이터: statusline.py   → rate_limits.json, sessions/<id>.json   (Claude statusLine 훅)
//         session_state.py → sessions/<id>.state.json              (Claude 상태 훅)
//         model_usage.py  → model_usage.json
//         codex_usage.py --daemon → codex_limits.json  (이 앱이 자식으로 띄움)
//
// 빌드:  swiftc -O menubar.swift -o kb-usage-menubar \
//          -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker bundle/Info.plist
//        (Info.plist 를 박아야 "Ghostty 제어" 권한을 물을 수 있다 — install.sh 가 함)
// 실행:  ./kb-usage-menubar &
// 아이콘 비교 시트:  ./kb-usage-menubar --render-icon <out.png>

import AppKit
import Foundation
import QuartzCore

let RL_PATH = ("~/developer/kb-usage/rate_limits.json" as NSString).expandingTildeInPath
let MU_PATH = ("~/developer/kb-usage/model_usage.json" as NSString).expandingTildeInPath
let SESS_DIR = ("~/developer/kb-usage/sessions" as NSString).expandingTildeInPath
let CX_PATH = ("~/developer/kb-usage/codex_limits.json" as NSString).expandingTildeInPath
let CX_SCRIPT = ("~/developer/kb-usage/codex_usage.py" as NSString).expandingTildeInPath
let SESSION_STALE = 90.0      // statusline 이 이보다 안 갱신된 세션은 (훅 pid 로 살아있음을 못 보면) 숨김
let POLL_SECONDS = 2.0        // 평상시 파일 폴링
let POPOVER_TICK = 1.0        // 팝오버 열려있을 때 (카운트다운 부드럽게)
let STALE_SECONDS = 1800.0
let CODEX_SECONDS = 60.0      // codex_usage.py --daemon 조회 주기 (같은 값 유지)
let LIST_MAX_H: CGFloat = 330       // 세션 목록 최대 높이 — 넘으면 스크롤
// Codex live(지금 떠 있는 CLI) 를 믿는 최대 나이. 데몬은 바뀔 때 + 20초마다 쓰지만, 10초 틱 간격과
// 한도 조회 중 멈춤(요청 타임아웃 15초 ×2 + 모델 집계)이 겹치면 60초 넘게 벌어질 수 있다.
// 넉넉히 잡아도 죽은 프로세스는 행마다 pid+시작 시각(sameProcess)으로 다시 걸러진다.
let CODEX_LIVE_MAX_AGE = 90.0
let CODEX_START_TIMEOUT = 45.0      // 앱 시작 후 이 시간까지 codex_limits.json 첫 기록이 없으면 STARTING 대신 이유
let POPOVER_CHROME: CGFloat = 28    // 팝오버 화살표·테두리·화면 끝 여백 — 표시 화면 가용 높이에서 뺀다
let POPOVER_MIN_H: CGFloat = 160
let ATTN_BAR_H: CGFloat = 30        // 높이 제한에 걸렸을 때 위에 고정하는 승인 요약 줄

// "동작 줄이기" — 모든 애니메이션 경로가 이걸 본다
func reduceMotion() -> Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// ── 팔레트 (위젯과 동일) ──────────────────────────────
enum C {
    static let bg      = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)
    static let text    = NSColor(srgbRed: 0.910, green: 0.902, blue: 0.890, alpha: 1)
    static let dim     = NSColor(srgbRed: 0.478, green: 0.471, blue: 0.459, alpha: 1)
    static let faint   = NSColor(srgbRed: 0.353, green: 0.345, blue: 0.333, alpha: 1)
    static let track   = NSColor(srgbRed: 0.133, green: 0.118, blue: 0.110, alpha: 1)
    static let hair    = NSColor(srgbRed: 0.196, green: 0.184, blue: 0.176, alpha: 1)
    static let hover   = NSColor(srgbRed: 0.090, green: 0.086, blue: 0.090, alpha: 1)
    // 서비스 색: Claude = 테라코타 #D97657 (기존 accent), Codex = ECHO 시안 #5cdcff
    static let claude  = NSColor(srgbRed: 0.851, green: 0.463, blue: 0.341, alpha: 1)
    static let cyan    = NSColor(srgbRed: 0.361, green: 0.863, blue: 1.000, alpha: 1)
    // 상태 색: 승인 필요 = 호박색 #ffad4d, 한도 95%+ = 장미색 #ff5d6c (ECHO 값)
    static let amber   = NSColor(srgbRed: 1.000, green: 0.678, blue: 0.302, alpha: 1)
    static let rose    = NSColor(srgbRed: 1.000, green: 0.365, blue: 0.424, alpha: 1)
    // 작업 완료(아직 안 봄) = 세이지 #8fb89a — 채도 낮은 회녹색. 호박·장미·테라코타·시안 어느 쪽과도 색상각이 멀다
    static let sage    = NSColor(srgbRed: 0.561, green: 0.722, blue: 0.604, alpha: 1)
    static let accent  = claude
}

struct Win { var pct: Double?; var resetsAt: Double?; var etaAt: Double? }
struct CodexWin { var pct: Double?; var resetsAt: Double?; var minutes: Double?; var etaAt: Double? }
struct CodexThread {
    var id: String; var name: String?; var source: String?; var model: String?
    var createdAt: Double?; var updatedAt: Double?; var status: String?
}
struct CodexLive { var threadId: String; var pid: Int32; var startedAt: Double?; var termPid: Int32? }
struct ModelShare { var label: String; var share: Double; var other: Bool }
enum CodexFileState { case missing, unreadable, ok }
struct CodexSnap {
    var five = CodexWin(); var seven = CodexWin()
    var plan: String?
    var file = CodexFileState.missing // codex_limits.json 자체를 읽었나
    var error: String?                // 데몬이 남긴 마지막 실패 사유 (짧게)
    var ok = false                    // 마지막 app-server 조회 성공 여부
    var checkedAt: Double?            // 마지막 조회 시도
    var capturedAt: Double?           // 마지막 성공 (값의 기준 시각)
    var threads: [CodexThread] = []
    var live: [CodexLive] = []        // 지금 떠 있는 codex CLI 와 그 스레드 (데몬이 10초마다)
    var liveAt: Double?
    var models: [ModelShare]?         // 이번 주(한도 창) 모델별 토큰 비중, nil = 아직 집계 전
    var hasData: Bool { five.pct != nil || seven.pct != nil }
}
struct CodexDaemonInfo { var appStartedAt: Double; var scriptExists: Bool; var running: Bool?; var exitStatus: Int32? }
struct ModelRow { var id: String; var label: String; var tokens: Double; var cost: Double }
struct SessionRow {
    var name: String; var agent: String?; var model: String?
    var ctxPct: Double?; var ctxSize: Double?; var cost: Double?
    var startedAt: Double; var updatedAt: Double
    var sid: String
    // session_state.py 훅 (sessions/<id>.state.json) — 훅이 없으면 전부 nil
    var state: String?; var stateSince: Double?; var eventAt: Double?; var doneAt: Double?
    var attention: String?
    var tool: String?; var hint: String?
    var todoDone: Int?; var todoTotal: Int?; var todoActive: String?
    var termPid: Int32?               // 그 세션을 품은 터미널 앱(Ghostty) 프로세스
    var titles: [String] = []         // 터미널 창 제목 매칭 후보: statusline 세션 이름(자동 제목), 레지스트리 이름
}
struct Snap {
    var five = Win(); var seven = Win(); var spend = Win()
    var capturedAt: Double?; var missing = false
    var weekly: [ModelRow] = []       // 주간창 모델별 (cost 내림차순, model_usage.json)
    var lastModel: String?            // 로그상 가장 최근에 쓴 모델 라벨
    var muCapturedAt: Double?
    var sessions: [SessionRow] = []   // 살아있고 창이 있는 Claude 세션 전부
    var hiddenNoWindow: [String] = [] // 살아있지만 터미널 창이 없어 숨긴 세션 id (tmux 헤드리스 등)
    var codex = CodexSnap()           // codex_limits.json
    var codexDaemon: CodexDaemonInfo? // App 이 채운다 (STARTING 시간 제한·실패 이유용). nil = 모름
    var chatgptRunning = false        // ChatGPT 앱 (Codex Work) 프로세스가 떠 있나
    var attention: Bool { sessions.contains { $0.state == "attention" } }
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

// Codex 한도 + 최근 스레드 (codex_usage.py --daemon 이 app-server 에서 받아 씀).
// 없거나 깨지면 빈 값.
func readCodex() -> CodexSnap {
    var c = CodexSnap()
    guard let d = FileManager.default.contents(atPath: CX_PATH) else { c.file = .missing; return c }
    guard let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { c.file = .unreadable; return c }
    c.file = .ok
    c.error = root["error"] as? String
    c.ok = (root["ok"] as? Bool) ?? false
    c.checkedAt = root["checked_at"] as? Double
    c.capturedAt = root["captured_at"] as? Double
    if let rl = root["rate_limits"] as? [String: Any] {
        func w(_ k: String) -> CodexWin {
            guard let x = rl[k] as? [String: Any] else { return CodexWin() }
            return CodexWin(pct: x["used_percentage"] as? Double,
                            resetsAt: x["resets_at"] as? Double,
                            minutes: x["window_minutes"] as? Double,
                            etaAt: x["eta_at"] as? Double)
        }
        c.five = w("five_hour"); c.seven = w("seven_day")
        c.plan = rl["plan_type"] as? String
    }
    if let arr = root["threads"] as? [[String: Any]] {
        c.threads = arr.compactMap { t in
            guard let id = t["id"] as? String else { return nil }
            return CodexThread(id: id, name: t["name"] as? String, source: t["source"] as? String,
                               model: t["model"] as? String, createdAt: t["created_at"] as? Double,
                               updatedAt: t["updated_at"] as? Double,
                               status: t["status"] as? String)
        }
    }
    if let lv = root["live"] as? [String: Any] {
        c.liveAt = lv["checked_at"] as? Double
        c.live = ((lv["cli"] as? [[String: Any]]) ?? []).compactMap { x in
            guard let t = x["thread_id"] as? String, let p = x["pid"] as? Int else { return nil }
            return CodexLive(threadId: t, pid: Int32(p), startedAt: x["started_at"] as? Double,
                             termPid: (x["term_pid"] as? Int).map { Int32($0) })
        }
    }
    if let md = root["models"] as? [String: Any], let rows = md["rows"] as? [[String: Any]] {
        c.models = rows.compactMap { r in
            guard let l = r["label"] as? String, let sh = r["share"] as? Double else { return nil }
            return ModelShare(label: l, share: sh, other: (r["other"] as? Bool) ?? false)
        }
    }
    return c
}

// 조회가 실패했거나 데몬이 멎어 checked_at 이 묵었으면 "조회 불가" — 옛 값을 현재처럼 안 보인다
func codexUnavailable(_ c: CodexSnap, _ now: Double) -> Bool {
    guard let chk = c.checkedAt else { return true }
    return !c.ok || now - chk > CODEX_SECONDS * 3
}

// 리셋 시각이 지났으면 그 뒤로 안 썼다는 뜻 → 옛 % 대신 0. (리셋됐는지, 표시할 %)
func codexEffective(_ w: CodexWin, _ now: Double) -> (reset: Bool, pct: Double?) {
    guard let p = w.pct else { return (false, nil) }
    if let r = w.resetsAt, r <= now { return (true, 0) }
    return (false, p)
}

func pidAlive(_ pid: Int32?) -> Bool {
    guard let p = pid, p > 1 else { return false }
    return kill(p, 0) == 0 || errno == EPERM
}

// 프로세스 시작 시각 (proc_pidinfo, 프로세스 안 띄움)
func procStart(_ pid: Int32) -> Double? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
}

// pid 가 살아있고, 기록된 시작 시각이 있으면 그것까지 맞아야 같은 프로세스
// (pid 가 재사용돼 다른 프로세스를 가리키는 오탐 방지. ps lstart 는 초 단위라 ±2초)
func sameProcess(_ pid: Int32?, _ started: Double?) -> Bool {
    guard let p = pid, p > 1 else { return false }
    guard let want = started else { return pidAlive(p) }
    guard let got = procStart(p) else { return false }
    return abs(got - want) < 2.0
}

// Claude Code 자체 세션 레지스트리 ~/.claude/sessions/<pid>.json:
//   {pid, sessionId, procStart("Sun Oct  4 03:25:26 2026", UTC), name, tmux?, ...}
// 훅 없이도 claude pid ↔ 세션을 안다. 내용(대화)은 없다 — pid·id·시작 시각·이름만 쓴다.
let CLAUDE_REG_DIR = ("~/.claude/sessions" as NSString).expandingTildeInPath
struct ClaudeProc { var pid: Int32; var started: Double?; var name: String? }

func readClaudeRegistry() -> [String: ClaudeProc] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: CLAUDE_REG_DIR) else { return [:] }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    var out: [String: ClaudeProc] = [:]
    for n in names where n.hasSuffix(".json") {
        guard let o = readJSON((CLAUDE_REG_DIR as NSString).appendingPathComponent(n)),
              let sid = o["sessionId"] as? String, let pid = o["pid"] as? Int else { continue }
        let st = (o["procStart"] as? String).flatMap {
            f.date(from: $0.split(separator: " ").joined(separator: " "))?.timeIntervalSince1970 }
        out[sid] = ClaudeProc(pid: Int32(pid), started: st, name: o["name"] as? String)
    }
    return out
}

// 부모 pid (sysctl — root 소유 login 같은 남의 프로세스도 읽힌다; proc_pidinfo 는 거부됨)
func parentPid(_ pid: Int32) -> Int32? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    return kp.kp_eproc.e_ppid
}

// pid 의 부모를 거슬러 처음 만나는 일반 GUI 앱(Ghostty 등 터미널) pid. 없으면 창 없음
// (tmux 헤드리스·launchd 직속 등). 프로세스를 띄우지 않는다.
func terminalAncestor(_ pid: Int32) -> Int32? {
    var cur = pid
    for _ in 0..<30 {
        guard let pp = parentPid(cur), pp > 1 else { return nil }
        if let app = NSRunningApplication(processIdentifier: pp), app.activationPolicy == .regular { return pp }
        cur = pp
    }
    return nil
}

// 세션 스냅샷은 세션마다 자기 파일에 쓴다 (context/cost 는 세션별 값이라
// 한 파일을 공유하면 서로 덮어쓴다). 상태는 훅이 <id>.state.json 에 따로 쓴다
// — statusline 이 3초마다 자기 파일을 통째로 새로 쓰므로 섞으면 지워진다.
//
// 목록 기준 — **지금 살아있고 터미널 창이 있는 세션만**:
//   1) Claude 레지스트리에 그 세션의 pid 가 있으면: pid + 시작 시각이 맞아야 살아있음,
//      조상에 터미널 앱이 없으면(tmux 헤드리스 등) 창 없음 → 숨김
//   2) 없으면 훅이 남긴 claude pid 로 같은 판정
//   3) 둘 다 없으면 statusline 90초 폴백 (창 여부는 모름)
// 헤드리스 claude -p 는 statusline 파일이 없어 애초에 빠진다.
func readSessions() -> ([SessionRow], [String]) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: SESS_DIR) else { return ([], []) }
    let now = Date().timeIntervalSince1970
    let reg = readClaudeRegistry()
    var rows: [SessionRow] = []
    var hidden: [String] = []
    for n in names where n.hasSuffix(".json") && !n.hasSuffix(".state.json") {
        let p = (SESS_DIR as NSString).appendingPathComponent(n)
        guard let o = readJSON(p) else { continue }
        let up = (o["updated_at"] as? Double) ?? 0
        let sid = (o["session_id"] as? String) ?? String(n.dropLast(5))
        let st = readJSON((SESS_DIR as NSString).appendingPathComponent(sid + ".state.json"))
        var term: Int32?
        if let rp = reg[sid] {
            if !sameProcess(rp.pid, rp.started) { continue }
            term = terminalAncestor(rp.pid)
            if term == nil { hidden.append(sid); continue }
        } else if let cp = (st?["claude_pid"] as? Int).map({ Int32($0) }) {
            if !sameProcess(cp, st?["claude_start"] as? Double) { continue }
            term = terminalAncestor(cp)
            if term == nil { hidden.append(sid); continue }
        } else if now - up > SESSION_STALE { continue }
        var r = SessionRow(name: (o["name"] as? String) ?? "?",
                           agent: o["agent"] as? String,
                           model: o["model"] as? String,
                           ctxPct: o["context_pct"] as? Double,
                           ctxSize: o["context_size"] as? Double,
                           cost: o["cost_usd"] as? Double,
                           startedAt: (o["started_at"] as? Double) ?? up,
                           updatedAt: up, sid: sid)
        r.termPid = term
        // Ghostty 창 제목 = Claude 자동 제목(statusline session_name). 레지스트리 name 은
        // derived 면 폴더 이름(cos-bf 등)이라 보조 후보로만
        r.titles = [o["name"] as? String, reg[sid]?.name].compactMap { $0 }.filter { !$0.isEmpty }
        if let s = st {
            r.state = s["state"] as? String
            r.stateSince = s["state_since"] as? Double
            r.eventAt = s["event_at"] as? Double
            r.doneAt = s["done_at"] as? Double
            r.attention = s["attention"] as? String
            r.tool = s["tool"] as? String
            r.hint = s["hint"] as? String
            r.todoDone = s["todo_done"] as? Int
            r.todoTotal = s["todo_total"] as? Int
            r.todoActive = s["todo_active"] as? String
        }
        rows.append(r)
    }
    return (rows, hidden)
}

func readSnap() -> Snap {
    var s = Snap()
    s.codex = readCodex()             // Claude 파일이 없어도 Codex 는 따로 보인다
    (s.sessions, s.hiddenNoWindow) = readSessions()
    s.chatgptRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
    guard let root = readJSON(RL_PATH) else { s.missing = true; return s }
    s.capturedAt = root["captured_at"] as? Double
    if let rl = root["rate_limits"] as? [String: Any] {
        func w(_ k: String) -> Win {
            var x = Win()
            if let d = rl[k] as? [String: Any] {
                x.pct = d["used_percentage"] as? Double
                x.resetsAt = d["resets_at"] as? Double
                x.etaAt = d["eta_at"] as? Double
            }
            return x
        }
        s.five = w("five_hour"); s.seven = w("seven_day"); s.spend = w("spend_limit")
    }

    // 모델별 사용량 (별도 파일, 없거나 깨져도 무시)
    if let mroot = readJSON(MU_PATH) {
        s.muCapturedAt = mroot["computed_at"] as? Double
        s.lastModel = mroot["last_model"] as? String
        if let wk = mroot["weekly"] as? [String: Any],
           let arr = wk["models"] as? [[String: Any]] {
            s.weekly = arr.compactMap { d in
                guard let l = d["label"] as? String else { return nil }
                return ModelRow(id: (d["id"] as? String) ?? "",
                                label: l,
                                tokens: (d["tokens"] as? Double) ?? 0,
                                cost: (d["cost"] as? Double) ?? 0)
            }
        }
    }
    return s
}

func fmtLeft(_ secs: Double) -> String {
    if secs <= 0 { return "now" }
    let m = Int(secs) / 60, h = m / 60, d = h / 24
    if d >= 1 { return "\(d)d \(h % 24)h" }
    if h >= 1 { return String(format: "%dh %02dm", h, m % 60) }
    return "\(m % 60)m"
}
func fmtWhen(_ ts: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "EEE h a"
    return f.string(from: Date(timeIntervalSince1970: ts))
}
func fmtAgo(_ secs: Double) -> String {
    if secs < 45 { return "just now" }
    let m = Int((secs / 60).rounded())
    if m < 60 { return "\(m)m ago" }
    let h = Int((Double(m) / 60).rounded())
    return h < 24 ? "\(h)h ago" : "\(Int((Double(h) / 24).rounded()))d ago"
}
// 세션 행의 경과 시간 ("3분", "2시간", "1일")
func fmtKo(_ secs: Double) -> String {
    let m = max(0, Int(secs / 60))
    if m < 1 { return "<1분" }
    if m < 60 { return "\(m)분" }
    if m < 60 * 24 { return "\(m / 60)시간" }
    return "\(m / 1440)일"
}
func fmtTok(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
    return String(format: "%.0f", n)
}
// "Opus 5.5 (1M context)" -> "Opus 5.5" (세션 줄이 좁아서 이름+버전만)
func shortModel(_ s: String?) -> String? {
    guard let s = s else { return nil }
    let words = s.split(separator: " ").prefix(2)
    return words.isEmpty ? nil : words.joined(separator: " ")
}
func clip(_ s: String, _ n: Int) -> String {
    return s.count > n ? String(s.prefix(max(1, n - 1))) + "…" : s
}

func attr(_ s: String, _ size: CGFloat, _ color: NSColor,
          weight: NSFont.Weight = .regular, tracking: CGFloat = 0) -> NSAttributedString {
    var f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    if let d = f.fontDescriptor.withDesign(.rounded) { f = NSFont(descriptor: d, size: size) ?? f }
    return NSAttributedString(string: s, attributes: [
        .font: f, .foregroundColor: color, .tracking: tracking,
    ])
}

func gauge(_ frac: Double, _ rect: NSRect, _ color: NSColor) {
    let r = min(rect.height / 2, 3)
    C.hair.setFill()   // 트랙 — bg 위에서 빈 구간이 보이게 (C.track 은 너무 어두움)
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    if frac > 0 {
        let w = max(rect.height, rect.width * CGFloat(min(1, max(0, frac))))
        let fr = NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        color.setFill()
        NSBezierPath(roundedRect: fr, xRadius: r, yRadius: r).fill()
    }
}

// BY MODEL 행 묶기 (Claude·Codex 공용): 비중 1% 이상인 모델만 개별 행(최대 3개),
// 나머지·unknown·이미 묶인 "기타"는 합쳐 "기타" (합이 0.5% 미만이면 생략). 합은 그대로 100%.
struct ShareRow: Equatable { var label: String; var share: Double; var right: String? = nil; var other = false }
let SHARE_MIN = 0.01, SHARE_TOP = 3, OTHER_MIN = 0.005

func groupShares(_ rows: [ShareRow]) -> [ShareRow] {
    let total = rows.reduce(0.0) { $0 + $1.share }
    guard total > 0 else { return [] }
    let named = rows.filter { !$0.other && $0.label != "unknown" && $0.share / total >= SHARE_MIN }
        .sorted { $0.share > $1.share }.prefix(SHARE_TOP)
    var out = named.map { ShareRow(label: $0.label, share: $0.share / total, right: $0.right) }
    let rest = 1.0 - out.reduce(0.0) { $0 + $1.share }
    if rest >= OTHER_MIN { out.append(ShareRow(label: "기타", share: rest, other: true)) }
    return out
}
func pctText(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

// 종량 과금 모델(페이블 등)의 이번 주 실제 청구액 — 비중 % 열과 섞지 않고 note 줄로. 없으면 nil
func meteredCostNote(_ rows: [ModelRow]) -> String? {
    let m = rows.filter { $0.id.hasPrefix("claude-fable") && $0.cost >= 0.5 }
    guard !m.isEmpty else { return nil }
    return "종량 청구 · " + m.map { "\(clip($0.label, 14)) " + String(format: "$%.0f", $0.cost) }.joined(separator: ", ")
}

// ── 접근성 문구 (순수 함수) ──
func windowLabelKo(_ l: String) -> String {
    switch l { case "WEEKLY": return "주간"; case "5H": return "5시간"; default: return l }
}
func limitAccessibilityValue(_ l: LimitLine) -> String {
    var parts = [l.pct.map { "\(Int($0.rounded()))% 사용" } ?? "값 없음"]
    if l.resetDone { parts.append("마지막 조회 이후 리셋됨") } else if let r = l.reset { parts.append(r) }
    if let e = l.eta { parts.append(e) }
    return parts.joined(separator: ", ")
}
func modelAccessibilityValue(_ rows: [ShareRow], empty: String?, note: String?) -> String {
    var s = rows.isEmpty ? (empty ?? "기록 없음") : rows.map { "\($0.label) \(pctText($0.share))" }.joined(separator: ", ")
    if let n = note { s += ". " + n }
    return s
}

// Codex 첫 기록 전 꼬리말: 시간 제한 안이면 STARTING + 경과초, 넘거나 원인이 보이면 이유. (문구, 경고)
func codexStartingFoot(_ file: CodexFileState, _ d: CodexDaemonInfo?, _ now: Double) -> (String, Bool) {
    if let d, !d.scriptExists { return ("NO DATA — codex_usage.py 없음", true) }
    if file == .unreadable { return ("NO DATA — codex_limits.json 읽기 실패", true) }
    if let d, d.running == false {
        return ("NO DATA — 수집 데몬 종료" + (d.exitStatus.map { " (exit \($0))" } ?? "") + " · menubar.log 확인", true)
    }
    guard let d else { return ("STARTING…", false) }
    let el = max(0, now - d.appStartedAt)
    if el < CODEX_START_TIMEOUT { return ("STARTING… \(Int(el))S", false) }
    return ("NO DATA — \(Int(el))초째 첫 기록 없음 · menubar.log 확인", true)
}

// ── 팝오버 위쪽: 한도 ─────────────────────────────────
// Claude 와 Codex 를 **같은 컴포넌트**(limitBlock)로 그린다:
//   서비스 이름 헤더(서비스 색) + 우측 플랜/경고
//   5H / WEEKLY 두 줄 — 같은 라벨·숫자 크기·막대 높이·간격·리셋 문구
//   마지막 UPDATED 줄 — 같은 형식
// 서비스 색은 이름·막대·리셋 문구에만. 숫자는 흰색, 80%+ 서비스 색, 95%+ 장미색.
let VIEW_W: CGFloat = 340
let VIEW_H: CGFloat = 212        // 초기/최소 높이 — 내용에 따라 draw 에서 늘린다

struct LimitLine {
    var label: String                 // "5H" / "WEEKLY"
    var pct: Double?
    var reset: String?                // "resets 4h 11m"
    var resetDone = false             // 리셋 시각 지남 (마지막 조회 이후)
    var eta: String?                  // Claude 만: "est. 2h 10m to limit"
    var etaUrgent = false
}

final class UsageView: NSView {
    var snap = Snap()
    var measuredHeight: CGFloat = VIEW_H
    var onHeightChange: ((CGFloat) -> Void)?
    var drawnKey = ""                 // 마지막으로 그린 내용 — 같으면 다시 안 그린다
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "사용 한도" }

    func rightText(_ s: NSAttributedString, _ y: CGFloat, _ padX: CGFloat) {
        s.draw(at: NSPoint(x: bounds.width - padX - s.size().width, y: y))
    }

    func windowName(_ m: Double?, _ fallback: String) -> String {
        guard let m = m else { return fallback }
        return m == 10080 ? "WEEKLY" : (Int(m) % 60 == 0 ? "\(Int(m) / 60)H" : "\(Int(m))M")
    }

    // 화면에 보이는 값들만 모은 문자열. 같으면 draw 를 건너뛴다 (매초 폴링에도 깜빡임 없음).
    func contentKey(_ now: Double) -> String {
        let (claude, codex) = (lines(now).claude, lines(now).codex)
        func k(_ ls: [LimitLine]) -> String {
            ls.map { "\($0.label)|\($0.pct ?? -1)|\($0.reset ?? "")|\($0.resetDone)|\($0.eta ?? "")" }.joined(separator: ";")
        }
        let w = snap.weekly.prefix(4).map { "\($0.label)\(Int($0.tokens))\(Int($0.cost))" }.joined()
            + (snap.codex.models ?? []).map { "\($0.label)\(Int($0.share * 1000))" }.joined() + "\(snap.codex.models == nil)"
        return [k(claude), k(codex), claudeFoot(now).0, codexFoot(now).0, w,
                snap.codex.plan ?? "", "\(codexUnavailable(snap.codex, now))"].joined(separator: "#")
    }

    func lines(_ now: Double) -> (claude: [LimitLine], codex: [LimitLine]) {
        func cl(_ w: Win, _ label: String, _ long: Bool) -> LimitLine {
            var l = LimitLine(label: label, pct: w.pct)
            if let r = w.resetsAt, w.pct != nil { l.reset = "resets " + (long ? fmtWhen(r) : fmtLeft(r - now)) }
            if let eta = w.etaAt, let reset = w.resetsAt, eta > now {
                l.eta = "est. \(fmtLeft(eta - now)) to limit"
                l.etaUrgent = eta < reset - 60
            }
            return l
        }
        let cxDown = codexUnavailable(snap.codex, now)
        func cx(_ w: CodexWin, _ fb: String, _ long: Bool) -> LimitLine {
            let eff = codexEffective(w, now)
            var l = LimitLine(label: windowName(w.minutes, fb), pct: eff.pct)
            l.resetDone = eff.reset
            if let r = w.resetsAt, !eff.reset, !cxDown {
                l.reset = "resets " + (long ? fmtWhen(r) : fmtLeft(r - now))
                // 소진 ETA — codex_usage.py 가 Claude 쪽(statusline.py)과 같은 방식으로 계산
                if let eta = w.etaAt, eta > now {
                    l.eta = "est. \(fmtLeft(eta - now)) to limit"
                    l.etaUrgent = eta < r - 60
                }
            }
            return l
        }
        return ([cl(snap.five, "5H", false), cl(snap.seven, "WEEKLY", true)],
                snap.codex.hasData ? [cx(snap.codex.five, "5H", false), cx(snap.codex.seven, "WEEKLY", true)] : [])
    }

    // (문구, 경고 여부)
    func claudeFoot(_ now: Double) -> (String, Bool) {
        guard let c = snap.capturedAt else { return ("NO DATA — RUN CLAUDE CODE", false) }
        let stale = now - c > STALE_SECONDS
        var s = "UPDATED \(fmtAgo(now - c))" + (stale ? "  ·  STALE" : "")
        if let lm = snap.lastModel, !lm.isEmpty { s += "  ·  VIA \(lm)" }
        return (s.uppercased(), stale)
    }
    func codexFoot(_ now: Double) -> (String, Bool) {
        let cx = snap.codex
        guard let c = cx.capturedAt else {
            if cx.checkedAt == nil { return codexStartingFoot(cx.file, snap.codexDaemon, now) }
            return ("NO DATA — " + (cx.error.map { "APP-SERVER: " + clip($0, 34) } ?? "CODEX APP-SERVER UNAVAILABLE"), true)
        }
        let down = codexUnavailable(cx, now)
        return ((down ? "LAST OK " : "UPDATED ") + fmtAgo(now - c).uppercased(), down)
    }

    // 접근성 요소 (직접 그리는 뷰라 draw 에서 위치를 모아 만든다). VoiceOver 가 읽는 값만, 그림 없음.
    var axItems: [(role: NSAccessibility.Role, label: String, value: String, pct: Double?, rect: NSRect)] = []
    var axKey = ""
    func rebuildAccessibility() {
        let key = axItems.map { "\($0.label)|\($0.value)|\(Int($0.rect.minY))" }.joined(separator: "#")
        if key == axKey { return }
        axKey = key
        setAccessibilityChildren(axItems.map { it -> NSAccessibilityElement in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(it.role)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(it.rect)
            e.setAccessibilityLabel(it.label)
            if let p = it.pct {
                e.setAccessibilityValue(NSNumber(value: p))
                e.setAccessibilityMinValue(NSNumber(value: 0)); e.setAccessibilityMaxValue(NSNumber(value: 100))
                e.setAccessibilityValueDescription(it.value)
            } else {
                e.setAccessibilityValue(it.value)
            }
            return e
        })
    }

    override func draw(_ dirty: NSRect) {
        C.bg.setFill(); bounds.fill()
        let now = Date().timeIntervalSince1970
        let padX: CGFloat = 20
        let gW = bounds.width - 2 * padX
        var y: CGFloat = 18
        let (claudeLines, codexLines) = lines(now)
        axItems = []
        func ax(_ role: NSAccessibility.Role, _ label: String, _ value: String, pct: Double? = nil, _ y0: CGFloat, _ y1: CGFloat) {
            axItems.append((role, label, value, pct, NSRect(x: padX, y: y0, width: gW, height: max(1, y1 - y0))))
        }

        func limitBlock(_ name: String, _ color: NSColor, right: String?, rightWarn: Bool,
                        _ ls: [LimitLine], dimmed: Bool, foot: (String, Bool), extra: (() -> Void)?) {
            attr(name, 11, color, weight: .semibold, tracking: 1.6).draw(at: NSPoint(x: padX, y: y))
            if let r = right, !r.isEmpty {
                rightText(attr(r, 9, rightWarn ? C.amber : C.faint, tracking: 0.8), y + 1, padX)
            }
            ax(.staticText, name, [name, right ?? ""].filter { !$0.isEmpty }.joined(separator: ", "), y, y + 16)
            y += 22
            for (i, l) in ls.enumerated() {
                if i > 0 { y += 8 }
                let y0 = y
                attr(l.label, 10, C.dim, weight: .medium, tracking: 1.4).draw(at: NSPoint(x: padX, y: y))
                if l.resetDone {
                    rightText(attr("reset since last check", 11, C.faint), y - 1, padX)
                } else if let r = l.reset {
                    rightText(attr(r, 11, dimmed ? C.faint : color), y - 1, padX)
                }
                y += 15
                var numColor = C.text
                var bar = color
                if let p = l.pct, p >= 95 { numColor = C.rose; bar = C.rose }
                else if let p = l.pct, p >= 80 { numColor = color }
                if dimmed || l.resetDone { numColor = C.faint; bar = color.withAlphaComponent(0.35) }
                let txt = l.pct.map { "\(Int($0.rounded()))%" } ?? "—"
                attr(txt, 24, numColor, weight: .bold, tracking: -0.5).draw(at: NSPoint(x: padX - 1, y: y))
                let gx = padX + 66
                gauge((l.pct ?? 0) / 100, NSRect(x: gx, y: y + 12, width: bounds.width - padX - gx, height: 6), bar)
                y += 32
                if let e = l.eta {
                    attr(e, 10, l.etaUrgent ? color : C.faint, tracking: 0.2).draw(at: NSPoint(x: gx, y: y - 8))
                    y += 8
                }
                ax(.progressIndicator, "\(name) \(windowLabelKo(l.label)) 한도", limitAccessibilityValue(l),
                   pct: l.pct, y0, y)
            }
            if ls.isEmpty {
                attr("no data", 11, C.dim).draw(at: NSPoint(x: padX, y: y))
                ax(.staticText, "\(name) 한도", "데이터 없음", y, y + 16)
                y += 18
            }
            extra?()
            y += 6
            attr(foot.0, 9, foot.1 ? C.amber : C.dim, tracking: 0.8).draw(at: NSPoint(x: padX, y: y))
            ax(.staticText, "\(name) 갱신 상태", foot.0, y, y + 12)
            y += 14
        }

        // BY MODEL — Claude·Codex 공용 하위 블록 (같은 줄 높이·막대). 오른쪽 열은 항상 주간 토큰 비중 %.
        // 비용($)은 같은 열에 섞지 않고 아래 note 줄로 따로.
        func modelBlock(_ service: String, _ rows: [ShareRow], _ color: NSColor,
                        empty: String?, note: String?) {
            y += 10
            let y0 = y
            attr("BY MODEL", 9, C.dim, weight: .medium, tracking: 1.4).draw(at: NSPoint(x: padX, y: y))
            rightText(attr("주간 토큰 비중", 9, C.faint, tracking: 0.6), y, padX)
            y += 16
            if rows.isEmpty, let e = empty {
                attr(e, 10, C.faint).draw(at: NSPoint(x: padX, y: y))
                y += 16
            }
            for row in rows {
                attr(clip(row.label, 14), 11, C.text).draw(at: NSPoint(x: padX, y: y))
                let barX = padX + 92
                gauge(row.share, NSRect(x: barX, y: y + 4, width: gW - 92 - 40, height: 4), color.withAlphaComponent(0.8))
                rightText(attr(pctText(row.share), 10, C.dim), y + 1, padX)
                y += 17
            }
            if let n = note {
                attr(n, 9, C.faint, tracking: 0.2).draw(at: NSPoint(x: padX, y: y))
                y += 13
            }
            ax(.staticText, "\(service) 모델별 주간 토큰 비중",
               modelAccessibilityValue(rows, empty: empty, note: note), y0, y)
        }

        // ── CLAUDE ──
        let cFoot = claudeFoot(now)
        limitBlock("CLAUDE", C.claude, right: cFoot.1 ? "STALE" : nil, rightWarn: true,
                   claudeLines, dimmed: cFoot.1 || snap.capturedAt == nil, foot: cFoot) {
            // Claude 구역 안의 하위 블록: 주간 모델별 (model_usage.json)
            guard !self.snap.weekly.isEmpty else { return }
            let totTok = max(1, self.snap.weekly.reduce(0.0) { $0 + $1.tokens })
            let grouped = groupShares(self.snap.weekly.map { ShareRow(label: $0.label, share: $0.tokens / totTok) })
            // 소넷·오퍼스는 Max 구독이라 $ 가 가상치 → 비중만. 종량 과금(페이블 등)만 실제 청구액을 note 줄로
            modelBlock("CLAUDE", grouped, C.claude, empty: nil, note: meteredCostNote(self.snap.weekly))
        }

        // ── CODEX ── (codex_usage.py --daemon 이 app-server 에 60초마다 물어본 계정 단위 값)
        y += 6
        C.hair.setFill(); NSRect(x: padX, y: y, width: gW, height: 1).fill()
        y += 14
        let cxDown = codexUnavailable(snap.codex, now) && snap.codex.checkedAt != nil
        limitBlock("CODEX", C.cyan, right: cxDown ? "UNAVAILABLE" : snap.codex.plan?.uppercased(),
                   rightWarn: cxDown, codexLines, dimmed: cxDown, foot: codexFoot(now)) {
            // 모델별: 서버가 안 줘서 이 Mac 의 rollout 을 한도 주간 창 구간만 집계 (codex_usage.py).
            // 아직 집계 전이면 "집계 중" — 값을 지어내지 않는다.
            let ms = self.snap.codex.models
            let grouped = groupShares((ms ?? []).map { ShareRow(label: $0.label, share: $0.share, other: $0.other) })
            modelBlock("CODEX", grouped, C.cyan,
                       empty: ms == nil ? "집계 중…" : "이번 주 이 Mac 기록 없음",
                       note: ms == nil ? nil : "이 Mac 기준 · Windows·ephemeral 호출은 안 잡힘")
        }
        y += 4
        rebuildAccessibility()

        // ── 높이 확정 ──
        // 동기 호출: 콜백이 팝오버 크기를 바로 맞춘다. 커진 뒤 재draw 때는
        // needed == measuredHeight 라 재진입 없음.
        let needed = max(VIEW_H, ceil(y))
        if abs(needed - measuredHeight) > 0.5 {
            measuredHeight = needed
            onHeightChange?(needed)
        }
    }
}

// ── 팝오버 아래쪽: 세션 목록 ──────────────────────────
// 행 = Claude 세션 / Codex CLI 스레드 / "Codex Work"(ChatGPT 앱 스레드 묶음 한 줄).
// 정렬은 **안정적**: 승인 필요 행이 맨 위(그 안에서 승인 대기 시작 순), 나머지는
// 에이전트 종류 → 시작 시각. 갱신 시각으로는 절대 정렬하지 않는다 (statusline 이
// 3초마다 바꾸는 값이라 순서가 매 폴링 뒤섞였다). 행 위치는 승인 필요 ↔ 그 외
// 이동 때만 바뀐다.
enum RowState: Int { case attention = 0, working = 1, idle = 2, unknown = 3 }

struct ListItem: Equatable {
    var key: String                   // "c:<sid>" / "x:<thread id>" / "x:work"
    var codex: Bool
    var state: RowState
    var title: String                 // "돌쇠 · 세션 이름"
    var status: String                // 우측 위: "작업 3분" / "승인 필요 1분" / "완료 후 12분"
    var progress: String              // 아래 줄: 도구·파일 / todo / 모델
    var right2: String                // 아래 줄 우측: 남은 컨텍스트 등
    var right2Warn = false
    var ctxPct: Double?
    var rank = 0                      // 에이전트 종류 순서
    var startedAt: Double = 0         // 안정 정렬 키
    var attentionSince: Double = 0
    var termPid: Int32?               // 그 세션의 터미널(Ghostty) 창 프로세스
    var matchNames: [String] = []     // 그 프로세스 안에서 창을 고를 때 쓰는 세션 이름 후보 (터미널 제목)
    var work = false                  // Codex Work 묶음 행 (클릭 = ChatGPT 앱)
    var done = false                  // 작업 완료 후 아직 안 봄 (세이지 체크 + 상태 글자 강조)
    var note = ""                     // 셋째 줄 (게이지 없는 행만): Codex 상태 확인 불가 안내
}

let ATTENTION_LABEL = ["permission_prompt": "승인 필요", "elicitation_dialog": "질문 대기",
                       "agent_needs_input": "입력 대기"]

// ── Codex 행 상태 ──
// 승인 대기·idle 을 믿을 만하게 얻을 곳이 없다 (2026-10-07 조사):
//   - app-server 의 thread status(active + activeFlags: waitingOnApproval)는 **그 app-server 가
//     직접 로드한 스레드**에만 채워진다. CLI·ChatGPT 앱 스레드는 남의 프로세스라 늘 notLoaded(→ null).
//   - rollout 파일엔 승인 요청 이벤트가 안 남고, 상태 DB(threads 테이블)에도 그런 칸이 없다.
//   - notify 훅은 턴 완료(agent-turn-complete)만 준다.
// 그래서 상태를 지어내지 않고 "상태 확인 불가 · 승인 알림 미지원"을 행에 그대로 적는다.
// (혹시 status 가 active 로 오면 작업 중으로만 — 그때도 승인 알림은 없다)
let CODEX_NO_STATE = "상태 확인 불가 · 승인 알림 미지원"
func codexRowState(_ status: String?) -> RowState { status == "active" ? .working : .unknown }
func codexStateNote(_ st: RowState) -> String { st == .working ? "승인 알림 미지원" : CODEX_NO_STATE }

// live(지금 떠 있는 codex CLI 목록)를 믿어도 되나 — 데몬 쓰기 간격보다 넉넉히
func codexLiveFresh(_ liveAt: Double?, _ now: Double) -> Bool {
    guard let t = liveAt else { return false }
    return now - t <= CODEX_LIVE_MAX_AGE
}

func agentRank(_ agent: String?) -> Int {
    switch agent { case "돌쇠": return 0; case "개똥이": return 1; default: return 2 }
}

func sortItems(_ items: [ListItem]) -> [ListItem] {
    return items.sorted { a, b in
        let aa = a.state == .attention, ba = b.state == .attention
        if aa != ba { return aa }
        if aa { return a.attentionSince != b.attentionSince ? a.attentionSince < b.attentionSince : a.key < b.key }
        if a.rank != b.rank { return a.rank < b.rank }
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        return a.key < b.key
    }
}

// done = 작업 완료 후 아직 안 본 세션 id (App.doneUnseen / doneShown) — 그 행을 강조
func listItems(_ s: Snap, _ now: Double, done: Set<String> = []) -> [ListItem] {
    var out: [ListItem] = []
    for r in s.sessions {
        let st: RowState
        switch r.state {
        case "attention": st = .attention
        case "working": st = .working
        case "idle": st = .idle
        default: st = .unknown
        }
        let since = now - (r.stateSince ?? r.startedAt)
        var status = ""
        switch st {
        case .attention: status = "\(ATTENTION_LABEL[r.attention ?? ""] ?? "확인 필요") \(fmtKo(since))"
        case .working: status = "작업 \(fmtKo(since))"
        case .idle: status = r.doneAt != nil ? "완료 후 \(fmtKo(now - r.doneAt!))" : "대기 \(fmtKo(since))"
        case .unknown: status = ""
        }
        // 진행 상황 한 줄: todo 가 있으면 그것, 아니면 현재/직전 도구, 아니면 모델
        var prog = ""
        if let t = r.todoTotal, t > 0 {
            prog = "✓ \(r.todoDone ?? 0)/\(t)"
            if let a = r.todoActive, !a.isEmpty { prog += "  ·  \(a)" }
        } else if let tool = r.tool {
            prog = tool + (r.hint.map { "  ·  \($0)" } ?? "")
        } else if let m = shortModel(r.model) {
            prog = m
        }
        var right2 = ""
        var warn = false
        // 컨텍스트 % 는 정수로 반올림해서 쓴다 — 소수 흔들림에 행이 매번 다시 그려지지 않게
        let ctx = r.ctxPct.map { $0.rounded() }
        if let p = ctx, p >= 85 {
            right2 = "compact 임박"; warn = true
        } else if let p = ctx, let sz = r.ctxSize, sz > 0 {
            right2 = "\(fmtTok(sz * (100 - p) / 100)) left"
        } else if let p = ctx {
            right2 = "\(Int(p))% used"
        }
        out.append(ListItem(key: "c:" + r.sid, codex: false, state: st,
                            title: "\(r.agent ?? "Claude")  ·  \(r.name)",
                            status: status, progress: prog, right2: right2, right2Warn: warn,
                            ctxPct: ctx, rank: agentRank(r.agent),
                            startedAt: r.startedAt, attentionSince: r.stateSince ?? 0,
                            termPid: r.termPid, matchNames: r.titles,
                            done: st == .idle && done.contains(r.sid)))
    }
    // Codex CLI: **지금 떠 있는 codex CLI 프로세스**가 받칠 때만 (codex_usage.py 의 live —
    // 프로세스가 연 rollout 파일의 thread id 로 매칭). 최근 활동만으로는 안 띄운다.
    // 데몬이 멎어 live 가 CODEX_LIVE_MAX_AGE 넘게 묵었으면 믿지 않는다. pid 도 여기서 한 번 더 확인.
    let byId = Dictionary(s.codex.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let liveOK = codexLiveFresh(s.codex.liveAt, now)
    // Claude 와 같은 기준: 프로세스가 살아있고 조상에 터미널 앱(창)이 있어야 한다
    for lv in (liveOK ? s.codex.live : []) where sameProcess(lv.pid, lv.startedAt) {
        guard let term = terminalAncestor(lv.pid) else { continue }
        let t = byId[lv.threadId]
        var prog = "CLI"
        if let m = t?.model { prog += "  ·  \(m)" }
        let st = codexRowState(t?.status)
        out.append(ListItem(key: "x:" + lv.threadId, codex: true, state: st,
                            title: "Codex  ·  \(t?.name ?? "CLI 세션")",
                            status: t?.updatedAt.map { "활동 \(fmtKo(now - $0)) 전" } ?? "실행 중",
                            progress: prog, right2: "", rank: 3,
                            startedAt: t?.createdAt ?? lv.startedAt ?? 0, termPid: term,
                            note: codexStateNote(st)))
    }
    // Codex Work: ChatGPT 앱이 떠 있을 때만 한 줄. 앱 스레드(source != cli)는 어차피 앱에
    // 들어가 눌러야 하므로 묶는다. 스레드 수는 최근 30분 활동 기준.
    if s.chatgptRunning {
        let app = s.codex.threads.filter { $0.source != "cli" }
        let last = app.compactMap { $0.updatedAt }.max()
        let n = app.filter { now - ($0.updatedAt ?? 0) < 1800 }.count
        out.append(ListItem(key: "x:work", codex: true, state: .unknown,
                            title: "Codex Work",
                            status: last.map { "활동 \(fmtKo(now - $0)) 전" } ?? "",
                            progress: n > 0 ? "ChatGPT 앱  ·  최근 30분 스레드 \(n)개" : "ChatGPT 앱",
                            right2: "", rank: 4, startedAt: 0, work: true, note: CODEX_NO_STATE))
    }
    return sortItems(out)
}

let ROW_H: CGFloat = 52
let LIST_HEAD_H: CGFloat = 34

// 상태 아이콘: 레이어 애니메이션만 쓴다 (타이머로 다시 그리지 않음 → CPU 거의 0).
// 승인 필요 = 호박색 삼각형 깜빡임 (이 상태만 깜빡인다), 작업 중 = 서비스 색 점 숨쉬기,
// idle = 흐린 빈 원, 상태 모름(Codex) = 점선 원.
// 애니메이션은 행에 붙은 영속 레이어에 한 번 붙이고, 상태가 바뀔 때만 다시 건다.
final class StatusIcon: NSView {
    let shape = CAShapeLayer()
    let symbol = CALayer()
    private(set) var current: (RowState, Bool, Bool)?     // (상태, codex, 완료 안 봄)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        layer?.addSublayer(symbol)
        setAccessibilityElement(false)   // 장식 — 상태는 행의 접근성 문구가 말한다
    }
    required init?(coder: NSCoder) { fatalError() }

    // 창에서 떨어졌다 붙으면(팝오버 닫고 열기) 애니메이션이 빠져 있을 수 있다 — 없을 때만 다시
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyMotion(restart: false)
    }

    // 지금 상태에 맞는 애니메이션만 건다. "동작 줄이기"면 전부 떼고 정적 모양만 (모든 경로가 여기로).
    // restart=false 면 이미 붙어 있는 건 그대로 둔다 (위상이 튀지 않게).
    func applyMotion(restart: Bool) {
        guard let c = current else { return }
        let motion = !reduceMotion()
        func want(_ l: CALayer, _ key: String, _ on: Bool, _ make: () -> CAAnimation) {
            if on && motion {
                if restart || l.animation(forKey: key) == nil { l.removeAnimation(forKey: key); l.add(make(), forKey: key) }
            } else if l.animation(forKey: key) != nil {
                l.removeAnimation(forKey: key)
            }
        }
        want(symbol, "blink", c.0 == .attention, blinkAnim)
        want(shape, "breathe", c.0 == .working, breatheAnim)
        want(symbol, "pulse", c.0 == .idle && c.2, pulseAnim)
    }

    func blinkAnim() -> CAAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.15; a.duration = 0.75
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        return a
    }
    // 완료 체크: 메뉴바 점과 같은 느린 펄스 (승인 깜빡임보다 차분하게)
    func pulseAnim() -> CAAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.35; a.duration = 1.1
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        return a
    }
    func breatheAnim() -> CAAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.3; a.duration = 1.4
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        return a
    }

    func set(_ st: RowState, codex: Bool, done: Bool = false) {
        if let c = current, c.0 == st, c.1 == codex, c.2 == done { return }   // 같으면 그대로 (애니메이션 유지)
        current = (st, codex, done)
        shape.removeAllAnimations(); symbol.removeAllAnimations()
        shape.isHidden = false; symbol.isHidden = true
        let b = bounds
        let tint = codex ? C.cyan : C.claude
        func circle(_ d: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: b.midX - d / 2, y: b.midY - d / 2, width: d, height: d), transform: nil)
        }
        shape.frame = b
        shape.lineDashPattern = nil
        switch st {
        case .attention:
            shape.isHidden = true; symbol.isHidden = false
            symbol.frame = b
            symbol.contentsGravity = .resizeAspect
            // 원(작업/idle)과 모양부터 다르게 삼각형. 느낌표는 배경색으로 뚫어 보이게
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [C.bg, C.amber]))
            symbol.contents = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            symbol.contentsScale = window?.backingScaleFactor ?? 2
        case .working:
            shape.path = circle(8)
            shape.fillColor = tint.cgColor; shape.strokeColor = nil
        case .idle where done:
            // 완료 안 봄: 승인 삼각형과 같은 방식(심볼 레이어)으로, 모양은 체크 원
            shape.isHidden = true; symbol.isHidden = false
            symbol.frame = b
            symbol.contentsGravity = .resizeAspect
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [C.bg, C.sage]))
            symbol.contents = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            symbol.contentsScale = window?.backingScaleFactor ?? 2
        case .idle:
            shape.path = circle(7)
            shape.fillColor = nil; shape.strokeColor = C.faint.cgColor; shape.lineWidth = 1.2
        case .unknown:
            shape.path = circle(7)
            shape.fillColor = nil; shape.lineWidth = 1.2
            shape.strokeColor = (codex ? C.cyan.withAlphaComponent(0.45) : C.faint).cgColor
            shape.lineDashPattern = codex ? [2, 2] : nil   // Codex: 상태 모름 = 점선 원
        }
        applyMotion(restart: true)
    }
}

// 행 접근성 문구 (순수 함수): 라벨 = 제목 + 상태, 값 = 진행·컨텍스트·안내
func rowStateWord(_ it: ListItem) -> String {
    switch it.state {
    case .attention: return ""                         // status 가 이미 "승인 필요 1분"
    case .working: return "작업 중"
    case .idle: return it.done ? "완료, 아직 안 봄" : "대기"
    case .unknown: return it.codex ? "상태 확인 불가" : "상태 모름"
    }
}
func rowAccessibility(_ it: ListItem) -> (label: String, value: String, help: String) {
    let title = it.title.replacingOccurrences(of: "  ·  ", with: ", ")
    let st = [rowStateWord(it), it.status].filter { !$0.isEmpty }.joined(separator: ", ")
    let value = [it.progress.replacingOccurrences(of: "  ·  ", with: ", "), it.right2, it.note]
        .filter { !$0.isEmpty }.joined(separator: ". ")
    let help = it.work ? "누르면 ChatGPT 앱으로 이동" : "누르면 이 세션의 터미널 창으로 이동"
    return (st.isEmpty ? title : "\(title) — \(st)", value, help)
}

final class SessionRowView: NSView {
    var item: ListItem
    let icon = StatusIcon(frame: NSRect(x: 18, y: 10, width: 14, height: 14))
    var onClick: ((ListItem) -> Void)?
    var onMove: ((String, Int) -> Void)?   // 키보드 위/아래: (내 key, -1|+1)
    private var hovering = false
    override var isFlipped: Bool { true }

    // ── 접근성: 버튼 하나 = 세션 하나 ──
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { rowAccessibility(item).label }
    override func accessibilityValue() -> Any? { rowAccessibility(item).value }
    override func accessibilityHelp() -> String? { rowAccessibility(item).help }
    override func accessibilityPerformPress() -> Bool { onClick?(item); return true }

    // ── 키보드: ↑↓ 행 이동, Return/Enter/Space 누르기. 포커스 링은 시스템 것 ──
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 6, dy: 3) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 6, yRadius: 6).fill()
    }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 125: onMove?(item.key, 1)                        // ↓
        case 126: onMove?(item.key, -1)                       // ↑
        case 36, 76, 49: onClick?(item)                       // Return, Enter, Space
        default: super.keyDown(with: e)
        }
    }

    init(_ item: ListItem, width: CGFloat) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: ROW_H))
        addSubview(icon)
        icon.set(item.state, codex: item.codex, done: item.done)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    // 내용이 같으면 아무것도 안 한다 (다시 그리지 않음)
    @discardableResult
    func update(_ it: ListItem) -> Bool {
        if it == item { return false }
        item = it
        icon.set(it.state, codex: it.codex, done: it.done)
        needsDisplay = true
        return true
    }

    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true }
    // 팝오버 창이 key 가 아니어도 첫 클릭을 받는다 (기본값 false 면 첫 클릭은 창 활성화에만 쓰임)
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    // mouseDown 을 직접 받아야 같은 뷰로 mouseUp 이 온다
    override func mouseDown(with e: NSEvent) { logLine("click-down \(keyTag(item.key))") }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        logLine("click-up \(keyTag(item.key)) inside=\(inside)")
        if inside { onClick?(item) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirty: NSRect) {
        (hovering ? C.hover : C.bg).setFill(); bounds.fill()
        let padX: CGFloat = 20
        let x0: CGFloat = 40
        let tint = item.codex ? C.cyan : C.claude
        let statusColor: NSColor = item.state == .attention ? C.amber
            : item.done ? C.sage : (item.state == .working ? tint : C.faint)
        let st = attr(item.status, 10, statusColor, weight: item.state == .attention || item.done ? .semibold : .regular)
        let stW = st.size().width
        st.draw(at: NSPoint(x: bounds.width - padX - stW, y: 9))
        // 제목: 상태 글자 자리만큼 비우고 자른다
        let maxChars = max(8, Int((bounds.width - x0 - padX - stW - 10) / 7.2))
        attr(clip(item.title, maxChars), 12, (item.state == .idle && !item.done) || item.state == .unknown ? C.dim : C.text)
            .draw(at: NSPoint(x: x0, y: 7))
        // 둘째 줄: 진행 상황 + 우측 컨텍스트
        let r2 = attr(item.right2, 10, item.right2Warn ? C.amber : C.faint)
        let r2W = item.right2.isEmpty ? 0 : r2.size().width
        if !item.right2.isEmpty { r2.draw(at: NSPoint(x: bounds.width - padX - r2W, y: 26)) }
        let pChars = max(8, Int((bounds.width - x0 - padX - r2W - 10) / 6.0))
        attr(clip(item.progress, pChars), 10, item.codex ? C.cyan.withAlphaComponent(0.6) : C.dim)
            .draw(at: NSPoint(x: x0, y: 25))
        // 컨텍스트 게이지 (Claude 만)
        if let p = item.ctxPct {
            gauge(p / 100, NSRect(x: x0, y: 41, width: bounds.width - x0 - padX, height: 3),
                  p >= 85 ? C.amber : tint.withAlphaComponent(0.75))
        } else if !item.note.isEmpty {
            // 게이지 자리(셋째 줄)에 안내 — Codex: 상태 확인 불가 · 승인 알림 미지원
            attr(clip(item.note, 40), 9, C.faint).draw(at: NSPoint(x: x0, y: 37))
        }
        C.hair.setFill(); NSRect(x: x0, y: bounds.height - 1, width: bounds.width - x0 - padX, height: 1).fill()
    }
}

final class SessionListView: NSView {
    var rows: [String: SessionRowView] = [:]
    var lastItems: [ListItem] = []
    var onClick: ((ListItem) -> Void)?
    override var isFlipped: Bool { true }

    // 키보드: 팝오버를 열면 목록이 first responder. ↓ = 첫 행, ↑ = 끝 행부터 (그 뒤는 행이 받는다).
    // 마우스로 열었을 때 포커스 링이 바로 뜨지 않게 행을 미리 고르지는 않는다.
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 125: focusRow(0)
        case 126: focusRow(lastItems.count - 1)
        default: super.keyDown(with: e)
        }
    }
    func focusRow(_ i: Int) {
        guard !lastItems.isEmpty else { return }
        let k = lastItems[max(0, min(lastItems.count - 1, i))].key
        guard let r = rows[k] else { return }
        window?.makeFirstResponder(r)
        r.scrollToVisible(r.bounds)
    }
    func move(from key: String, by d: Int) {
        guard let i = lastItems.firstIndex(where: { $0.key == key }) else { focusRow(0); return }
        focusRow(i + d)
    }

    // 세션 key 기준 diff 로 **제자리 갱신**. 행은 재사용하고(재생성하면 애니메이션이
    // 리셋된다), 내용이 바뀐 행만 다시 그리고, 위치가 바뀐 행만 옮긴다.
    // 입력이 지난번과 똑같으면 nil (아무것도 안 함).
    func apply(_ items: [ListItem]) -> CGFloat? {
        if items == lastItems { return nil }
        lastItems = items
        var seen = Set<String>()
        var y: CGFloat = 0
        for it in items {
            seen.insert(it.key)
            let row: SessionRowView
            if let r = rows[it.key] { row = r; row.update(it) } else {
                row = SessionRowView(it, width: bounds.width)
                row.onClick = { [weak self] i in self?.onClick?(i) }
                row.onMove = { [weak self] k, d in self?.move(from: k, by: d) }
                rows[it.key] = row
                addSubview(row)
            }
            let f = NSRect(x: 0, y: y, width: bounds.width, height: ROW_H)
            if row.frame != f { row.frame = f }
            y += ROW_H
        }
        for (k, r) in rows where !seen.contains(k) {
            // 키보드 포커스가 있던 행이 빠지면 목록으로 돌려서 ↑↓ 가 계속 먹게
            if window?.firstResponder === r { window?.makeFirstResponder(self) }
            r.removeFromSuperview(); rows[k] = nil
        }
        return y
    }
    override func draw(_ dirty: NSRect) { C.bg.setFill(); bounds.fill() }
}

// 팝오버 높이 배치 (순수 함수).
//   평소: 한도(usageH) + 목록 머리 + 목록(최대 LIST_MAX_H, 넘으면 목록만 스크롤) — 예전과 같다.
//   그 합이 maxH(표시 화면 가용 높이 − 팝오버 테두리)를 넘으면: 목록을 통째로 펼치고
//   한도+머리+목록 전체를 바깥 스크롤 하나로 (스크롤 안의 스크롤 없음). 승인 대기가 있으면
//   승인 요약 줄을 그 위에 고정해서, 스크롤 위치와 상관없이 늘 보이게.
struct PopLayout: Equatable {
    var total: CGFloat        // 팝오버 내용 높이
    var constrained: Bool     // 화면 높이에 걸렸나
    var barH: CGFloat         // 위 고정 승인 요약 (0 = 없음)
    var viewportH: CGFloat    // 바깥 스크롤의 보이는 높이
    var contentH: CGFloat     // 바깥 스크롤의 내용 높이
    var listVisH: CGFloat     // 안쪽 목록 스크롤의 보이는 높이
}
func popoverLayout(usageH: CGFloat, listH: CGFloat, attention: Bool, maxH: CGFloat) -> PopLayout {
    let head = listH > 0 ? LIST_HEAD_H : 0
    let vis = min(listH, LIST_MAX_H)
    let natural = usageH + head + vis
    let cap = max(POPOVER_MIN_H, maxH)
    if natural <= cap {
        return PopLayout(total: natural, constrained: false, barH: 0, viewportH: natural, contentH: natural, listVisH: vis)
    }
    let bar: CGFloat = attention ? ATTN_BAR_H : 0
    let content = usageH + head + listH
    let viewport = min(content, cap - bar)
    return PopLayout(total: bar + viewport, constrained: true, barH: bar, viewportH: viewport,
                     contentH: content, listVisH: listH)
}
// 팝오버가 뜰 화면(메뉴바 버튼이 있는 화면)의 가용 높이 → 팝오버 내용 최대 높이
func popoverMaxHeight(visibleH: CGFloat) -> CGFloat { max(POPOVER_MIN_H, visibleH - POPOVER_CHROME) }

// 높이 제한 모드에서 안쪽 목록 스크롤은 통째로 펼쳐져 있으니 휠을 바깥 스크롤로 넘긴다
final class PassScrollView: NSScrollView {
    var passThrough = false
    override func scrollWheel(with e: NSEvent) {
        if passThrough, let n = nextResponder { n.scrollWheel(with: e) } else { super.scrollWheel(with: e) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) { C.bg.setFill(); bounds.fill() }
}

// 위(한도) + 목록 머리 + 스크롤 목록을 세로로 쌓는다. 높이는 내용에 맞춰 늘고,
// 목록은 LIST_MAX_H 를 넘으면 스크롤. 승인 필요 행은 정렬상 항상 맨 위.
// 전체가 표시 화면 높이를 넘으면 popoverLayout 대로 바깥 스크롤 + 위 고정 승인 요약.
final class PopoverView: NSView {
    let usage = UsageView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: VIEW_H))
    let head = ListHeadView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: LIST_HEAD_H))
    let scroll = PassScrollView()
    let list = SessionListView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: 0))
    let outer = NSScrollView()
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: VIEW_H))
    let attnBar = AttentionBarView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: ATTN_BAR_H))
    var listH: CGFloat = 0
    var attentionCount = 0
    var maxHeight: CGFloat = .greatestFiniteMagnitude     // App 이 팝오버를 열 때·화면이 바뀔 때 넣는다
    private(set) var layoutNow = PopLayout(total: VIEW_H, constrained: false, barH: 0,
                                           viewportH: VIEW_H, contentH: VIEW_H, listVisH: 0)
    var onSize: ((NSSize) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(outer); addSubview(attnBar)
        outer.documentView = content
        content.addSubview(usage); content.addSubview(head); content.addSubview(scroll)
        scroll.documentView = list
        for sv in [scroll, outer] {
            sv.drawsBackground = false
            sv.hasVerticalScroller = true
            sv.autohidesScrollers = true
            sv.scrollerStyle = .overlay
            sv.verticalScrollElasticity = .none
        }
        attnBar.isHidden = true
        attnBar.onClick = { [weak self] in self?.scrollToSessions() }
        usage.onHeightChange = { [weak self] _ in self?.relayout() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ s: Snap, done: Set<String> = []) {
        let now = Date().timeIntervalSince1970
        usage.snap = s
        let key = usage.contentKey(now)
        if key != usage.drawnKey { usage.drawnKey = key; usage.needsDisplay = true }
        let items = listItems(s, now, done: done)
        // 서비스별 개수 — Codex 만 떠 있어도 "0 LIVE" 가 되지 않게
        let cl = items.filter { !$0.codex }.count
        let cx = items.filter { $0.codex }.count
        let attItems = items.filter { $0.state == .attention }
        let att = attItems.count
        let dn = items.filter { $0.done }.count
        if cl != head.claude || cx != head.codex || att != head.attention || dn != head.done {
            head.claude = cl; head.codex = cx; head.attention = att; head.done = dn; head.needsDisplay = true
        }
        let first = attItems.first?.title ?? ""
        if att != attnBar.count || first != attnBar.first {
            attnBar.count = att; attnBar.first = first; attnBar.needsDisplay = true
        }
        var needLayout = (att > 0) != (attentionCount > 0)
        attentionCount = att
        if let h = list.apply(items), h != listH { listH = h; needLayout = true }
        if needLayout { relayout() }
    }

    var totalSize: NSSize {
        NSSize(width: VIEW_W, height: popoverLayout(usageH: usage.measuredHeight, listH: listH,
                                                    attention: attentionCount > 0, maxH: maxHeight).total)
    }

    func relayout() {
        let uh = usage.measuredHeight
        let L = popoverLayout(usageH: uh, listH: listH, attention: attentionCount > 0, maxH: maxHeight)
        layoutNow = L
        attnBar.isHidden = L.barH == 0
        attnBar.frame = NSRect(x: 0, y: 0, width: VIEW_W, height: ATTN_BAR_H)
        outer.frame = NSRect(x: 0, y: L.barH, width: VIEW_W, height: L.viewportH)
        content.frame = NSRect(x: 0, y: 0, width: VIEW_W, height: L.contentH)
        usage.frame = NSRect(x: 0, y: 0, width: VIEW_W, height: uh)
        head.isHidden = listH == 0; scroll.isHidden = listH == 0
        head.frame = NSRect(x: 0, y: uh, width: VIEW_W, height: LIST_HEAD_H)
        scroll.frame = NSRect(x: 0, y: uh + LIST_HEAD_H, width: VIEW_W, height: L.listVisH)
        scroll.passThrough = L.constrained
        list.frame = NSRect(x: 0, y: 0, width: VIEW_W, height: listH)
        onSize?(NSSize(width: VIEW_W, height: L.total))
    }

    // 승인 요약 줄 클릭: 바깥 스크롤을 세션 목록 머리로 (승인 행은 정렬상 맨 위)
    func scrollToSessions() {
        let maxY = max(0, layoutNow.contentH - layoutNow.viewportH)
        outer.contentView.scroll(to: NSPoint(x: 0, y: min(head.frame.minY, maxY)))
        outer.reflectScrolledClipView(outer.contentView)
    }
    override func draw(_ dirty: NSRect) { C.bg.setFill(); bounds.fill() }
}

// 목록 머리 오른쪽 요약 (순수 함수). 0 인 서비스는 뺀다 (둘 다 0 이면 CLAUDE 0).
// short = 좁을 때 줄인 표기.
func headSummary(claude: Int, codex: Int, attention: Int, done: Int, short: Bool) -> String {
    var parts: [String] = []
    if attention > 0 { parts.append(short ? "\(attention) NEED" : "\(attention) NEED YOU") }
    if done > 0 { parts.append("\(done) DONE") }
    if claude > 0 || codex == 0 { parts.append(short ? "CL \(claude)" : "CLAUDE \(claude)") }
    if codex > 0 { parts.append(short ? "CX \(codex)" : "CODEX \(codex)") }
    return parts.joined(separator: short ? " · " : "  ·  ")
}
func headAccessibility(claude: Int, codex: Int, attention: Int, done: Int) -> String {
    var p: [String] = []
    if attention > 0 { p.append("승인 필요 \(attention)") }
    if done > 0 { p.append("완료 \(done)") }
    p.append("Claude \(claude)")
    p.append("Codex \(codex)")
    return p.joined(separator: ", ")
}

final class ListHeadView: NSView {
    var claude = -1
    var codex = 0
    var attention = 0
    var done = 0
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "세션" }
    override func accessibilityValue() -> Any? {
        headAccessibility(claude: max(0, claude), codex: codex, attention: attention, done: done)
    }
    override func draw(_ dirty: NSRect) {
        C.bg.setFill(); bounds.fill()
        let padX: CGFloat = 20
        C.hair.setFill(); NSRect(x: padX, y: 2, width: bounds.width - 2 * padX, height: 1).fill()
        let title = attr("SESSIONS", 11, C.dim, weight: .semibold, tracking: 1.6)
        title.draw(at: NSPoint(x: padX, y: 14))
        let color = attention > 0 ? C.amber : done > 0 ? C.sage : C.faint
        let room = bounds.width - 2 * padX - title.size().width - 12
        var r = attr(headSummary(claude: max(0, claude), codex: codex, attention: attention, done: done, short: false),
                     9, color, tracking: 0.6)
        if r.size().width > room {
            r = attr(headSummary(claude: max(0, claude), codex: codex, attention: attention, done: done, short: true),
                     9, color, tracking: 0.6)
        }
        r.draw(at: NSPoint(x: bounds.width - padX - r.size().width, y: 15))
    }
}

// 높이 제한에 걸렸을 때만 팝오버 맨 위에 고정되는 승인 요약 한 줄. 정적 (애니메이션 없음).
// 클릭/Return/VoiceOver 누르기 = 세션 목록으로 스크롤.
final class AttentionBarView: NSView {
    var count = 0
    var first = ""
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "승인 필요 \(count)개" + (first.isEmpty ? "" : " — " + first) }
    override func accessibilityHelp() -> String? { "누르면 세션 목록으로 스크롤" }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 6, dy: 3) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 6, yRadius: 6).fill() }
    override func keyDown(with e: NSEvent) {
        if [36, 76, 49].contains(e.keyCode) { onClick?() } else { super.keyDown(with: e) }
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        C.bg.setFill(); bounds.fill()
        let padX: CGFloat = 20
        let a = attr("승인 필요 \(count)", 11, C.amber, weight: .semibold)
        a.draw(at: NSPoint(x: padX, y: 8))
        if !first.isEmpty {
            let x = padX + a.size().width + 10
            let chars = max(6, Int((bounds.width - x - padX) / 7.0))
            attr(clip(first, chars), 11, C.dim).draw(at: NSPoint(x: x, y: 8))
        }
        C.hair.setFill(); NSRect(x: padX, y: bounds.height - 1, width: bounds.width - 2 * padX, height: 1).fill()
    }
}

// ── 창 앞으로 ─────────────────────────────────────────
// Ghostty 는 창마다 프로세스가 따로라(open -na) 그 pid 를 앞으로 올리면 그 창이 온다.
// 한 프로세스에 창이 여럿이면 앱까지만 올라온다.
//
// 단계별로 시도하고 0.3초 뒤 실제 맨 앞 앱 pid 로 확인, 되면 멈춘다 (menubar.log 에 기록):
//   coop      우리 앱을 먼저 active 로 만든 뒤 협력적 활성화 (macOS 14+: activate(from:))
//   all       activate(options: .activateAllWindows)
//   ae        그 pid 에 raw Apple Event activate(misc/actv). 이미 Automation 권한이 있는
//             대상(= Ghostty)에만 보내고 묻지 않는다 — 새 권한 팝업 없음.
//   sysevents System Events 로 그 unix id 프로세스 frontmost = true (osascript).
//             "System Events 제어" 권한이 이미 허용(0)일 때만. 거부·미결정이면 건너뛴다 (팝업 안 띄움).
// coop/all 은 NSRunningApplication 이 있어야 해서, 못 찾으면 건너뛰고 ae → sysevents 로.
// 로그에는 key 앞 8자·pid·단계·결과만 남긴다.
let FOCUS_STEPS = ["coop", "all", "ae", "sysevents"]
let GHOSTTY_ID = "com.mitchellh.ghostty"

func logLine(_ s: String) {
    let f = ISO8601DateFormatter()
    FileHandle.standardError.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}
func keyTag(_ key: String) -> String {
    let parts = key.split(separator: ":", maxSplits: 1)
    return parts.count == 2 ? "\(parts[0]):\(parts[1].prefix(8))" : String(key.prefix(10))
}
func frontPid() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

// pid → NSRunningApplication. init(processIdentifier:) 가 잠깐 nil 을 줄 때가 있다
// (2026-10-04 21:52Z: Ghostty 가 Fcus 로 막 frontmost 가 되던 순간, 직전엔 같은 pid 를 찾았는데 nil).
// 그러면 실행 중 앱 목록(번들 id → 전체)에서 pid 로 한 번 더 찾는다.
func lookupApp(_ pid: Int32, tag: String) -> NSRunningApplication? {
    if let a = NSRunningApplication(processIdentifier: pid) { return a }
    logLine("focus \(tag) pid=\(pid) lookup=init ret=nil")
    let b = NSRunningApplication.runningApplications(withBundleIdentifier: GHOSTTY_ID)
        .first { $0.processIdentifier == pid }
    logLine("focus \(tag) pid=\(pid) lookup=bundle ret=\(b != nil)")
    if let b { return b }
    let w = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
    logLine("focus \(tag) pid=\(pid) lookup=workspace ret=\(w != nil)")
    return w
}

// 그 pid 에 Apple Event activate(misc/actv). 권한이 이미 허용일 때만 보낸다 (묻지 않음, 응답 안 기다림).
// 반환 0 = 보냄. 아니면 권한 상태(-1743 거부, -1744 미결정, -600 대상 없음) 또는 전송 오류 번호.
func aeActivate(_ pid: Int32) -> Int {
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    guard let d = target.aeDesc else { return Int(procNotFound) }
    let st = AEDeterminePermissionToAutomateTarget(d, fcc("misc"), fcc("actv"), false)
    if st != noErr { return Int(st) }
    let ev = NSAppleEventDescriptor(eventClass: fcc("misc"), eventID: fcc("actv"), targetDescriptor: target,
                                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    do { _ = try ev.sendEvent(options: [.noReply], timeout: 1); return 0 }
    catch { return (error as NSError).code }
}

// "System Events 제어" 권한 상태 (묻지 않음). 0 허용, -1743 거부, -1744 미결정, -600 실행 안 됨
func syseventsPermission() -> Int {
    guard let d = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents").aeDesc
    else { return Int(procNotFound) }
    return Int(AEDeterminePermissionToAutomateTarget(d, AEEventClass(typeWildCard), AEEventID(typeWildCard), false))
}

// 반환: "skip(이유)" = 시도 안 함(확인 대기 없이 다음 단계로), 그 외 = 시도한 결과
func runFocusStep(_ step: String, pid: Int32, app: NSRunningApplication?) -> String {
    switch step {
    case "coop":
        guard let app else { return "skip(no-app)" }
        if #available(macOS 14.0, *) {
            NSApp.activate()
            NSApp.yieldActivation(to: app)
            return "\(app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]))"
        }
        return "\(app.activate(options: [.activateAllWindows]))"
    case "all":
        guard let app else { return "skip(no-app)" }
        return "\(app.activate(options: [.activateAllWindows]))"
    case "ae":
        let r = aeActivate(pid)
        return r == 0 ? "0" : "skip(\(r))"
    case "sysevents":
        let perm = syseventsPermission()
        if perm != 0 { return "skip(perm=\(perm))" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to set frontmost of " +
                       "(first process whose unix id is \(pid)) to true"]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "false" }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            // 권한 거부 등은 osascript 오류 번호만 (예: -1743 = Automation 권한 없음)
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let code = msg.range(of: #"\(-?\d+\)"#, options: .regularExpression).map { String(msg[$0]) } ?? ""
            logLine("  sysevents osascript exit=\(p.terminationStatus) \(code)")
        }
        return "\(p.terminationStatus == 0)"
    default:
        return "skip(unknown)"
    }
}

// pid 를 앞으로. 끝나면 done(성공 여부, 성공한 단계)
func bringToFront(_ pid: Int32, tag: String, steps: [String] = FOCUS_STEPS,
                  done: ((Bool, String?) -> Void)? = nil) {
    let app = lookupApp(pid, tag: tag)
    if app == nil { logLine("focus \(tag) pid=\(pid) no-such-app → ae/sysevents") }
    runFocusSteps(pid, app, tag: tag, steps[...], done: done)
}

func runFocusSteps(_ pid: Int32, _ app: NSRunningApplication?, tag: String, _ steps: ArraySlice<String>,
                   done: ((Bool, String?) -> Void)?) {
    guard let step = steps.first else {
        logLine("focus \(tag) pid=\(pid) all-steps-failed"); done?(false, nil); return
    }
    let ret = runFocusStep(step, pid: pid, app: app)
    if ret.hasPrefix("skip") {
        logLine("focus \(tag) pid=\(pid) step=\(step) ret=\(ret)")
        runFocusSteps(pid, app, tag: tag, steps.dropFirst(), done: done); return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let fp = frontPid()
        let ok = fp == pid
        logLine("focus \(tag) pid=\(pid) step=\(step) ret=\(ret) front=\(fp.map(String.init) ?? "nil") ok=\(ok)")
        if ok { done?(true, step) } else { runFocusSteps(pid, app, tag: tag, steps.dropFirst(), done: done) }
    }
}

// ── Ghostty 창 고르기 (Apple Event, 대상 pid 지정) ──
// 한 Ghostty 프로세스가 창·탭을 여럿 품으므로 프로세스만 올리면 엉뚱한 창이 온다.
// Ghostty 1.3 AppleScript 사전(sdef)의 terminal(id, name) 과 focus 명령을 쓰되,
// `tell application "Ghostty"` 는 프로세스가 둘 이상이면 하나에만 닿으므로
// NSAppleEventDescriptor(processIdentifier:) 로 **그 pid 에** 직접 보낸다.
// 터미널 제목은 "✳ 리베이스 확인" 처럼 앞에 상태 글리프가 붙은 Claude 세션 이름 —
// 글리프를 떼고 세션 이름과 **정확히 하나** 맞을 때만 그 터미널로. 아니면 nil (프로세스 단위 폴백).
// "Ghostty 제어" Automation 권한이 필요하다 (처음 한 번 묻는다).
func fcc(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

func objSpec(_ want: String, from: NSAppleEventDescriptor?, form: String, seld: NSAppleEventDescriptor)
    -> NSAppleEventDescriptor? {
    let r = NSAppleEventDescriptor.record()
    r.setDescriptor(NSAppleEventDescriptor(typeCode: fcc(want)), forKeyword: fcc("want"))
    r.setDescriptor(from ?? NSAppleEventDescriptor.null(), forKeyword: fcc("from"))
    r.setDescriptor(NSAppleEventDescriptor(enumCode: fcc(form)), forKeyword: fcc("form"))
    r.setDescriptor(seld, forKeyword: fcc("seld"))
    return r.coerce(toDescriptorType: fcc("obj "))
}

// 모든 terminal 의 속성(prop: 'ID  ' 또는 'pnam') 목록
func ghosttyTerminalProp(_ pid: Int32, _ prop: String) throws -> [String] {
    var all = fcc("all ")
    let every = NSAppleEventDescriptor(descriptorType: fcc("abso"), bytes: &all, length: 4)!
    guard let terms = objSpec("Gtrm", from: nil, form: "indx", seld: every),
          let spec = objSpec("prop", from: terms, form: "prop", seld: NSAppleEventDescriptor(typeCode: fcc(prop)))
    else { throw NSError(domain: "kbusage", code: -1) }
    let ev = NSAppleEventDescriptor(eventClass: fcc("core"), eventID: fcc("getd"),
                                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    ev.setParam(spec, forKeyword: fcc("----"))
    let reply = try ev.sendEvent(options: [.waitForReply], timeout: 3)
    guard let list = reply.paramDescriptor(forKeyword: fcc("----")) else { return [] }
    return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.stringValue }
}

// 제목 앞 상태 글리프("✳ ", "◐ " 등) 떼기
func bareTitle(_ t: String) -> String {
    var s = Substring(t)
    while let c = s.first, !(c.isLetter || c.isNumber) { s = s.dropFirst() }
    return s.trimmingCharacters(in: .whitespaces)
}

// "Ghostty 제어" Automation 권한. askUser 면 미결정일 때 macOS 팝업을 띄우고 답을 기다린다
// (블록되므로 메인 스레드 밖에서). 반환: 0 허용, -1743 거부, -1744 동의 필요(미결정), -600 대상 없음.
// 매번 menubar.log 에 남겨서 팝업이 떴는지/어떻게 답했는지 로그만으로 알 수 있게.
func ghosttyPermission(_ pid: Int32, ask: Bool) -> OSStatus {
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    guard let d = target.aeDesc else { return OSStatus(procNotFound) }
    let pre = AEDeterminePermissionToAutomateTarget(d, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    if !ask || pre != OSStatus(errAEEventWouldRequireUserConsent) {
        logLine("ae-permission pid=\(pid) status=\(pre)")
        return pre
    }
    logLine("ae-permission pid=\(pid) status=-1744 asking-user…")
    let st = AEDeterminePermissionToAutomateTarget(d, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    logLine("ae-permission pid=\(pid) asked → status=\(st)")
    return st
}

enum GhosttyPick { case focused, noMatch(Int), ambiguous(Int), denied(Int), failed(String) }

// pid 의 Ghostty 에서 이름이 맞는 terminal 하나를 focus. 후보 이름을 차례로, 정확히 하나 맞는
// 첫 이름을 쓴다. 메인 스레드 밖에서 부를 것 (권한 팝업이 기다릴 수 있음)
func ghosttyFocus(pid: Int32, names: [String]) -> GhosttyPick {
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    let st = ghosttyPermission(pid, ask: true)
    if st != noErr { return .denied(Int(st)) }
    do {
        let ids = try ghosttyTerminalProp(pid, "ID  ")
        let titles = try ghosttyTerminalProp(pid, "pnam")
        guard ids.count == titles.count else { return .failed("count") }
        var hits: [(String, String)] = []
        var amb = 0
        for name in names {
            let h = zip(ids, titles).filter { bareTitle($0.1) == bareTitle(name) }
            if h.count == 1 { hits = h; break }
            amb = max(amb, h.count)
        }
        if hits.isEmpty { return amb > 1 ? .ambiguous(amb) : .noMatch(ids.count) }
        guard let spec = objSpec("Gtrm", from: nil, form: "ID  ", seld: NSAppleEventDescriptor(string: hits[0].0))
        else { return .failed("spec") }
        let ev = NSAppleEventDescriptor(eventClass: fcc("Ghst"), eventID: fcc("Fcus"), targetDescriptor: target,
                                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        ev.setParam(spec, forKeyword: fcc("----"))
        _ = try ev.sendEvent(options: [.waitForReply], timeout: 3)
        return .focused
    } catch {
        return .failed("\((error as NSError).code)")
    }
}

enum BundleActivation { case front, launching, failed }

func activateBundle(_ id: String, tag: String, done: ((BundleActivation) -> Void)? = nil) {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
        bringToFront(app.processIdentifier, tag: tag) { ok, _ in done?(ok ? .front : .failed) }
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        logLine("focus \(tag) open-app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        done?(.launching)
    } else { done?(.failed) }
}

// ── 창 이동 결과 ──
// 행 클릭이 "그 세션 창"까지 갔는지, 앱(프로세스)만 올라왔는지, 권한이 없어 못 골랐는지를 구분한다.
enum FocusOutcome: Equatable {
    case window                       // 그 세션의 터미널 창(탭)을 골라 맨 앞으로
    case target(String)               // 원래 대상이 앱인 행 (Codex Work → ChatGPT 앱)
    case appOnly(String)              // 앱만 맨 앞 — 창은 못 고름 (이유)
    case permission(front: Bool)      // "Ghostty 제어" 권한 없음 — 창을 못 고름 (앱은 올라왔나)
    case failed(String)               // 맨 앞으로 못 가져옴

    var reachedFront: Bool {          // --focus 요청 ack (예전 done(Bool) 과 같은 뜻)
        switch self {
        case .window, .target, .appOnly: return true
        case .permission(let f): return f
        case .failed: return false
        }
    }
}

// (순수 함수) Ghostty 창 고르기 결과 + 맨 앞 확인 → 결과. pick 이 nil 이면 창 고르기를 안 한 경우 (why = 이유)
func focusOutcome(pick: GhosttyPick?, frontOK: Bool, why: String) -> FocusOutcome {
    if case .denied(let code)? = pick, code == -1743 || code == -1744 { return .permission(front: frontOK) }
    if !frontOK { return .failed("앱이 맨 앞으로 오지 않음") }
    guard let pick else { return .appOnly(why) }
    switch pick {
    case .focused: return .window
    case .noMatch: return .appOnly("같은 제목의 창을 못 찾음")
    case .ambiguous(let n): return .appOnly("같은 제목의 창이 \(n)개")
    case .denied(let code): return .appOnly("Ghostty 응답 없음 (\(code))")
    case .failed: return .appOnly("창 목록 조회 실패")
    }
}

// (순수 함수) 사용자에게 보일 문구: (제목, 설명, 종류 0=성공 1=부분 2=실패)
func focusMessage(_ o: FocusOutcome) -> (title: String, detail: String?, level: Int) {
    switch o {
    case .window: return ("세션 창으로 이동했습니다", nil, 0)
    case .target(let s): return (s, nil, 0)
    case .appOnly(let why): return ("앱만 활성화 — 창은 못 고름", why, 1)
    case .permission(let front):
        return (front ? "권한 필요 — 앱만 활성화" : "권한 필요 — 이동 못 함",
                "시스템 설정 › 개인정보 보호 및 보안 › 자동화 › KbUsage 에서 Ghostty 허용", 2)
    case .failed(let why): return ("창으로 이동 못 함", why, 2)
    }
}

// done = 결과 (0.3초 뒤 실제 맨 앞 앱 pid 로 확인한 것 포함)
func focus(_ it: ListItem, done: ((FocusOutcome) -> Void)? = nil) {
    let tag = keyTag(it.key)
    if it.work {                                                    // Codex Work → ChatGPT 앱
        activateBundle("com.openai.codex", tag: tag) { r in
            switch r {
            case .front: done?(.target("ChatGPT 앱으로 이동했습니다"))
            case .launching: done?(.target("ChatGPT 앱을 여는 중"))
            case .failed: done?(.failed("ChatGPT 앱이 맨 앞으로 오지 않음"))
            }
        }
        return
    }
    // Claude 세션 / Codex CLI: 그 터미널 창 프로세스. 모르면 Ghostty 앱까지만
    if let pid = it.termPid, let app = lookupApp(pid, tag: tag) {
        guard app.bundleIdentifier == GHOSTTY_ID, !it.matchNames.isEmpty else {
            let why = app.bundleIdentifier != GHOSTTY_ID ? "Ghostty 가 아닌 터미널 — 창 고르기 미지원"
                : it.codex ? "Codex CLI 는 창 제목 정보가 없음" : "세션 이름을 몰라 창을 못 고름"
            bringToFront(pid, tag: tag) { ok, _ in done?(focusOutcome(pick: nil, frontOK: ok, why: why)) }
            return
        }
        // 그 Ghostty 프로세스 안에서 세션 창(터미널)을 먼저 고르고, 앱도 Apple Event 로 올린 뒤
        // (같은 대상이라 이미 받은 "Ghostty 제어" 권한으로 충분) 프로세스 단위 체인으로 확인
        DispatchQueue.global(qos: .userInitiated).async {
            let pick = ghosttyFocus(pid: pid, names: it.matchNames)
            var act: Int?
            if case .focused = pick { act = aeActivate(pid) }
            DispatchQueue.main.async {
                logLine("focus \(tag) ghostty-pick=\(pick)")
                if let act { logLine("focus \(tag) pid=\(pid) step=ghostty-activate ret=\(act)") }
                bringToFront(pid, tag: tag) { ok, _ in done?(focusOutcome(pick: pick, frontOK: ok, why: "")) }
            }
        }
    } else {
        logLine("focus \(tag) term_pid=\(it.termPid.map(String.init) ?? "nil") → Ghostty app")
        activateBundle(GHOSTTY_ID, tag: tag) { r in
            done?(r == .front ? .appOnly("세션의 터미널 창을 모름") : .failed("Ghostty 가 맨 앞으로 오지 않음"))
        }
    }
}

// 행 클릭 결과 알림: 메뉴바 아래 잠깐 뜨는 작은 패널 (포커스 안 뺏음, 애니메이션 없음) + VoiceOver 안내.
final class FocusToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ o: FocusOutcome, below button: NSStatusBarButton?) {
        let m = focusMessage(o)
        let color = m.level == 0 ? C.sage : m.level == 1 ? C.amber : C.rose
        let t = attr(m.title, 12, color, weight: .semibold)
        let d = m.detail.map { attr($0, 10, C.dim) }
        let padX: CGFloat = 14, padY: CGFloat = 9
        let w = min(360, max(200, max(t.size().width, d?.size().width ?? 0) + 2 * padX))
        let h = padY * 2 + t.size().height + (d.map { $0.size().height + 3 } ?? 0)

        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            p.isReleasedWhenClosed = false
            panel = p
            return p
        }()
        let v = ToastView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        v.title = t; v.detail = d; v.padX = padX; v.padY = padY
        p.contentView = v
        // 메뉴바 버튼 바로 아래, 화면 안으로
        var origin = NSPoint(x: 100, y: 100)
        if let b = button, let bw = b.window {
            let f = bw.convertToScreen(b.convert(b.bounds, to: nil))
            let vis = bw.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? f
            origin.x = min(max(vis.minX + 8, f.midX - w / 2), vis.maxX - w - 8)
            origin.y = vis.maxY - h - 6
        }
        p.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        p.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: m.title + (m.detail.map { ". " + $0 } ?? ""),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (m.level == 0 ? 1.6 : m.level == 1 ? 4 : 7), execute: work)
    }

    final class ToastView: NSView {
        var title = NSAttributedString(); var detail: NSAttributedString?
        var padX: CGFloat = 14; var padY: CGFloat = 9
        override var isFlipped: Bool { true }
        override func draw(_ dirty: NSRect) {
            let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            C.bg.setFill(); r.fill()
            C.hair.setStroke(); r.lineWidth = 1; r.stroke()
            title.draw(at: NSPoint(x: padX, y: padY))
            detail?.draw(at: NSPoint(x: padX, y: padY + title.size().height + 3))
        }
    }
}

// ── 외부 포커스 요청 (승인 알림 팝업 클릭 등) ──
// `kb-usage-menubar --focus <session_id>` 가 분산 알림으로 실행 중인 앱에 요청만 보내고
// ack 를 기다린다. 실제 Ghostty 제어는 상주 앱이 하므로 "Ghostty 제어" 권한이 이 앱 하나에만
// 필요하다. 앱이 없거나 실패하면 exit 1 → 호출한 쪽이 자기 방식(프로세스 단위)으로 폴백.
let FOCUS_REQ = Notification.Name("kb-usage.focus")
let FOCUS_ACK = Notification.Name("kb-usage.focus.ack")

// 세션 id → 목록 행. 목록에 없으면 (statusline 이 아직 없는 등) Claude 레지스트리로 만든다
func itemForSession(_ sid: String) -> ListItem? {
    let now = Date().timeIntervalSince1970
    if let it = listItems(readSnap(), now).first(where: { $0.key == "c:" + sid }) { return it }
    guard let rp = readClaudeRegistry()[sid], sameProcess(rp.pid, rp.started),
          let term = terminalAncestor(rp.pid) else { return nil }
    let sl = readJSON((SESS_DIR as NSString).appendingPathComponent(sid + ".json"))?["name"] as? String
    return ListItem(key: "c:" + sid, codex: false, state: .unknown, title: "", status: "", progress: "",
                    right2: "", termPid: term, matchNames: [sl, rp.name].compactMap { $0 }.filter { !$0.isEmpty })
}

func requestFocusCLI(_ sid: String) -> Int32 {
    let req = UUID().uuidString
    var result: Bool?
    let c = DistributedNotificationCenter.default()
    let obs = c.addObserver(forName: FOCUS_ACK, object: nil, queue: nil) { n in
        if (n.userInfo?["req"] as? String) == req { result = (n.userInfo?["ok"] as? Bool) ?? false }
    }
    c.postNotificationName(FOCUS_REQ, object: nil, userInfo: ["sid": sid, "req": req], deliverImmediately: true)
    let until = Date().addingTimeInterval(3)
    while result == nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    c.removeObserver(obs)
    return result == true ? 0 : 1
}

// ── 작업 완료 배너 (알림 센터) ──────────────────────────
// Stop 훅으로 세션이 working → idle 이 되면 App.sounds 가 조건을 보고 여기로 배너를 넘긴다.
//
// UNUserNotificationCenter 는 못 쓴다: 이 앱은 ad-hoc 서명이라 macOS 가 묻지도 않고
// "Notifications are not allowed for this application"(UNErrorDomain 1) 로 거부한다
// (launchd 직접 실행·open(LaunchServices) 둘 다, 2026-10-06 macOS 26.6 실측). Developer ID 서명이 있어야 한다.
// 그래서 승인 알림 팝업과 같은 alerter(Developer ID 서명, 클릭 결과를 stdout 으로 돌려줌)를 쓰고,
// 없으면 osascript display notification (이건 클릭해도 창 이동 불가 — 스크립트 편집기가 열린다).
//   그룹 "kbdone-<sid>": 같은 세션의 다음 완료가 이전 배너를 대체한다 (세션당 한 장).
//   클릭(@CONTENTCLICKED) → 그 세션 창으로 (행 클릭과 같은 focus()).
//   doneBannerSeconds(기본 10)초 뒤 자동으로 닫힌다. 0 = 누를 때까지 남김.
// 소리는 doneSound(NSSound) 가 따로 낸다 — 배너는 무음.
let ALERTER_PATHS = ["~/.local/bin/alerter", "/opt/homebrew/bin/alerter", "/usr/local/bin/alerter"]
    .map { ($0 as NSString).expandingTildeInPath }
let APP_ICON_PNG = ("~/developer/kb-usage/bundle/AppIcon-1024.png" as NSString).expandingTildeInPath

func fmtTook(_ secs: Double) -> String {
    let s = max(0, Int(secs.rounded()))
    if s < 60 { return "\(s)초" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60)분" : "\(s / 60)분 \(s % 60)초" }
    return "\(s / 3600)시간 \((s % 3600) / 60)분"
}

// 완료 알림을 낼지 (순수 함수). 반환 nil = 낸다, 아니면 안 내는 이유 (로그용)
func doneNotifyDecision(enabled: Bool, took: Double, minMinutes: Double, front: Int32?, term: Int32?) -> String? {
    if !enabled { return "off" }
    if took < minMinutes * 60 { return "short" }
    if let t = term, front == t { return "front" }
    return nil
}

// 안 본 완료 표시(메뉴바 점 + 행 강조)를 지울 이유 (순수 함수). nil = 유지.
// 팝오버를 연 것 / 행 클릭은 App 이 따로 지운다 (reason=popover / click).
func doneClearReason(alive: Bool, state: String?, term: Int32?, front: Int32?) -> String? {
    if !alive { return "gone" }                         // 세션 종료 (목록에서 빠짐)
    if state != "idle" { return "resumed" }             // 다시 working / attention
    if let t = term, front == t { return "front" }      // 그 창이 맨 앞 = 보고 있음
    return nil
}

final class DoneBanner {
    private var procs: [String: Process] = [:]     // sid → 떠 있는 alerter (같은 세션 새 배너면 이전 것 정리)

    func post(sid: String, title: String, body: String, seconds: Int) {
        let tag = keyTag("c:" + sid)
        guard let alerter = ALERTER_PATHS.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            postOsascript(tag: tag, title: title, body: body); return
        }
        procs[sid]?.terminate()
        var args = ["--title", title, "--message", body, "--group", "kbdone-" + sid,
                    "--close-label", "닫기", "--timeout", String(max(0, seconds))]
        if FileManager.default.fileExists(atPath: APP_ICON_PNG) { args += ["--app-icon", APP_ICON_PNG] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: alerter)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let r = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if self?.procs[sid] === proc { self?.procs[sid] = nil }
                logLine("done-banner result \(tag) \(r.isEmpty ? "(none)" : r) exit=\(proc.terminationStatus)")
                guard r == "@CONTENTCLICKED" else { return }
                guard let it = itemForSession(String(sid.prefix(64))) else { logLine("done-banner click no-session"); return }
                focus(it)
            }
        }
        do {
            try p.run()
            procs[sid] = p
            logLine("done-banner post \(tag) via=alerter ok=true")
        } catch {
            logLine("done-banner post \(tag) via=alerter ok=false err=\((error as NSError).code)")
            postOsascript(tag: tag, title: title, body: body)
        }
    }

    // 폴백: 클릭해도 창 이동 안 됨. 문자열은 argv 로 넘겨 이스케이프 문제 없게
    private func postOsascript(tag: String, title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                       "-e", "end run", title, body]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let ok = (try? p.run()) != nil
        logLine("done-banner post \(tag) via=osascript ok=\(ok)")
    }
}

// --test-focus <pid> [coop,all,ae,sysevents]: 메뉴바 앱과 같은 accessory 앱으로 띄워 포커스 체인을 한 번 시험하고,
// 원래 맨 앞 앱으로 되돌린 뒤 끝낸다. 결과는 stderr(=로그).
final class FocusTest: NSObject, NSApplicationDelegate {
    let pid: Int32
    let steps: [String]
    init(_ pid: Int32, _ steps: [String]) { self.pid = pid; self.steps = steps }
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let orig = frontPid()
        logLine("test-focus target=\(pid) original-front=\(orig.map(String.init) ?? "nil") steps=\(steps)")
        bringToFront(pid, tag: "test", steps: steps) { ok, step in
            logLine("test-focus result ok=\(ok) step=\(step ?? "-")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let o = orig, o != self.pid else { exit(ok ? 0 : 1) }
                bringToFront(o, tag: "restore", steps: self.steps) { rok, rstep in
                    logLine("test-focus restore ok=\(rok) step=\(rstep ?? "-")")
                    exit(ok ? 0 : 1)
                }
            }
        }
    }
}

// ── 메뉴바 아이콘 ────────────────────────────────────
// 같은 모양·굵기의 이중 링 두 개: 왼쪽 Claude(테라코타), 오른쪽 Codex(시안).
// 바깥 = 5시간, 안쪽 = 주간. 12시부터 시계방향으로 사용률만큼.
// 승인 대기 = 두 링 사이 위쪽 호박색 점 (테두리로 테라코타와 구분).
// 한도 임박은 색만으로 하면 테라코타와 헷갈려서 변형별로 다른 단서를 쓴다
// (`defaults write kb-usage-menubar iconVariant <1|2|3>`). 95%+ 는 셋 다 장미색.
//   1  굵기 — 80%+ 인 링이 굵어진다
//   2  외곽선 — 80%+ 면 그 서비스 링 바깥에 얇은 테두리 (다크=흰, 라이트=검)
//   3  글로우 — 80%+ 면 그 서비스 색으로 은은한 번짐
struct IconData {
    var five: Double?; var seven: Double?; var stale = false
    var cxFive: Double?; var cxSeven: Double?; var cxDown = false
    var attention = false
    var done = false                  // 안 본 작업 완료 — 승인 대기가 있으면 승인 점이 우선
    var drawDot = true                // 비교 시트용. 앱은 false (레이어 점)
}
let ATTN_DOT = NSPoint(x: 20, y: 16.6)       // 아이콘(40×20, y 위로) 안 승인 점 중심

func iconData(_ s: Snap, _ now: Double) -> IconData {
    let stale = (s.capturedAt.map { now - $0 > STALE_SECONDS }) ?? false
    let down = codexUnavailable(s.codex, now) || !s.codex.hasData
    // 조회 불가면 아이콘에선 Codex 값을 아예 비운다 (옛 % 를 현재처럼 안 보이게)
    return IconData(five: s.five.pct, seven: s.seven.pct, stale: stale || s.missing,
                    cxFive: down ? nil : codexEffective(s.codex.five, now).pct,
                    cxSeven: down ? nil : codexEffective(s.codex.seven, now).pct,
                    cxDown: down, attention: s.attention)
}

// 메뉴바 버튼 접근성 값 (순수 함수) — 아이콘이 그리는 것과 같은 정보를 글로
func iconAccessibilityValue(_ d: IconData, done: Bool) -> String {
    func p(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "값 없음" }
    var s = "Claude 5시간 \(p(d.five)), 주간 \(p(d.seven))" + (d.stale ? " (오래된 값)" : "")
    s += d.cxDown ? ". Codex 조회 불가" : ". Codex 5시간 \(p(d.cxFive)), 주간 \(p(d.cxSeven))"
    if d.attention { s += ". 승인 대기 세션 있음" } else if done { s += ". 끝난 작업 있음" }
    return s
}

func isDarkDrawing() -> Bool {
    NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}
// 서비스 색: 다크 메뉴바는 원색 그대로, 라이트는 같은 계열을 진하게 (흰 바탕에서 읽히게)
func claudeTint() -> NSColor {
    isDarkDrawing() ? C.claude : NSColor(srgbRed: 0.74, green: 0.36, blue: 0.24, alpha: 1)
}
func codexTint() -> NSColor {
    isDarkDrawing() ? C.cyan : NSColor(srgbRed: 0.05, green: 0.55, blue: 0.75, alpha: 1)
}
func attentionColor() -> NSColor {
    isDarkDrawing() ? C.amber : NSColor(srgbRed: 0.92, green: 0.62, blue: 0.0, alpha: 1)
}
// 완료 점: 다크 = 세이지, 라이트 = 같은 계열을 진하게 #4f7a5c
let SAGE_LIGHT = NSColor(srgbRed: 0.310, green: 0.478, blue: 0.361, alpha: 1)
func doneColor() -> NSColor { isDarkDrawing() ? C.sage : SAGE_LIGHT }

let ICON_W: CGFloat = 40
let ICON_VARIANTS = ["1", "2", "3"]
let ICON_DEFAULT = "1"

func drawRing(_ c: NSPoint, _ r: CGFloat, _ lw: CGFloat, _ pct: Double?, _ color: NSColor) {
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = lw
    color.withAlphaComponent(0.22).setStroke()
    track.stroke()
    guard let p = pct, p > 0 else { return }
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, p / 100)),
                  clockwise: true)
    arc.lineWidth = lw
    arc.lineCapStyle = .round
    color.setStroke()
    arc.stroke()
}

func dot(_ c: NSPoint, _ d: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
}

// 메뉴바 높이 20pt 기준. flipped=false (y 위로).
func drawIcon(_ v: String, _ d: IconData) {
    let h: CGFloat = 20
    let rOuter: CGFloat = 7.2, lw: CGFloat = 1.8, rInner: CGFloat = rOuter - lw - 1.5

    // 서비스 하나 = 이중 링 (바깥 5h, 안 주간)
    func pair(_ c: NSPoint, _ five: Double?, _ seven: Double?, _ tint: NSColor, off: Bool) {
        let base = off ? NSColor.tertiaryLabelColor : tint
        let hot = !off && max(five ?? 0, seven ?? 0) >= 80
        func col(_ p: Double?) -> NSColor { (p ?? 0) >= 95 && !off ? C.rose : base }
        func width(_ p: Double?) -> CGFloat { v == "1" && (p ?? 0) >= 80 && !off ? 2.7 : lw }
        if hot && v == "2" {
            let halo = NSBezierPath()
            halo.appendArc(withCenter: c, radius: rOuter + 2.0, startAngle: 0, endAngle: 360)
            halo.lineWidth = 0.9
            (max(five ?? 0, seven ?? 0) >= 95 ? C.rose : NSColor.labelColor.withAlphaComponent(0.85)).setStroke()
            halo.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        if hot && v == "3" {
            let sh = NSShadow()
            sh.shadowColor = (max(five ?? 0, seven ?? 0) >= 95 ? C.rose : tint).withAlphaComponent(0.9)
            sh.shadowBlurRadius = 3.5
            sh.shadowOffset = .zero
            sh.set()
        }
        drawRing(c, rOuter, width(five), off ? nil : five, col(five))
        drawRing(c, rInner, width(seven), off ? nil : seven, col(seven))
        NSGraphicsContext.restoreGraphicsState()
    }

    pair(NSPoint(x: 10, y: h / 2), d.five, d.seven, claudeTint(), off: d.stale)
    pair(NSPoint(x: 30, y: h / 2), d.cxFive, d.cxSeven, codexTint(), off: d.cxDown)
    if (d.attention || d.done) && d.drawDot {
        // 두 링 사이 위. 바탕색 테두리를 둘러 링과 붙어 보이지 않게
        // (메뉴바 앱은 이 점을 이미지 대신 펄스되는 레이어로 그린다 — ATTN_DOT)
        let p = ATTN_DOT
        dot(p, 6.2, isDarkDrawing() ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.8))
        dot(p, 4.6, d.attention ? attentionColor() : doneColor())
    }
}

func iconImage(_ v: String, _ d: IconData) -> NSImage {
    return NSImage(size: NSSize(width: ICON_W, height: 20), flipped: false) { _ in
        drawIcon(v, d)
        return true
    }
}

// 승인 대기 진입 소리 판정 (순수 함수): 기준선이 없으면(앱 시작 직후) 안 울림, 새로 생긴 키가
// 있고 쿨다운(2초)이 지났으면 한 번. 반환: (울릴지, 새 키들)
func attentionSoundDecision(prev: Set<String>?, keys: Set<String>, lastSound: Double, now: Double)
    -> (play: Bool, fresh: Set<String>) {
    guard let prev = prev else { return (false, []) }
    let fresh = keys.subtracting(prev)
    return (!fresh.isEmpty && now - lastSound >= 2, fresh)
}

// ── 앱 ────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let view = PopoverView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: VIEW_H))
    var timer: Timer?
    var fastTimer: Timer?
    var codexTimer: Timer?
    var codexProc: Process?
    var lastIcon: String?
    let attnDot = CALayer()             // 승인 대기 점 (펄스는 레이어 애니메이션)
    var acked = Set<String>()           // 팝오버로 이미 본 승인 대기 ("sid@시작") — 펄스 안 함
    var nudgedAt: [String: Double] = [:]  // attentionRepeatMinutes: 마지막으로 다시 알린 시각
    var prevState: [String: String] = [:]
    var workingSince: [String: Double] = [:]
    var doneSeen: [String: Double] = [:]
    var doneUnseen: [String: Double] = [:]   // 완료 알림을 냈고 아직 안 본 세션 (sid → done_at) — 메뉴바 점
    var doneShown = Set<String>()            // 팝오버를 열어 본 완료 — 팝오버가 닫힐 때까지만 행 강조 유지
    var attnSeen: Set<String>?          // 지난 갱신 때의 승인 대기 키 (nil = 아직 기준선 없음)
    var lastAttnSound = 0.0
    var dotKind = ""                    // 로그용: 지금 메뉴바 점 (attention / done / none)

    // ── 소리 (defaults) ──
    //   attentionSound          승인 대기에 **새로 들어가는 순간** 한 번 (기본 Glass, "" 이면 무음).
    //                           승인 알림 팝업은 kb-usage 가 커버하는 세션엔 안 뜨므로 소리는 여기서 낸다.
    //   attentionRepeatMinutes  N>0 이면 N분 넘게 이어질 때마다 다시 (기본 0 = 끔, 비권장)
    //   doneNotify              (기본 켜짐) Stop 때, 이번 턴이 doneNotifyMinMinutes(기본 1)분 이상이고
    //                           그 세션 창이 맨 앞이 아니면 1회: doneSound(기본 Tink, "" = 무음)
    //                           + doneDot(기본 켜짐) 메뉴바 세이지 점 펄스 + 팝오버 행 강조 (승인 대기와 같은 방식,
    //                             승인 점이 우선). 그 행 클릭 / 팝오버 열기 / 그 창이 맨 앞 / 다시 작업 / 세션 종료 때 사라짐
    //                           + doneBanner(기본 꺼짐) alerter 배너 (클릭 = 그 세션 창, doneBannerSeconds 기본 10초 뒤 닫힘)
    let ud = UserDefaults.standard
    var repeatMin: Double { ud.double(forKey: "attentionRepeatMinutes") }
    var attnSound: String { ud.string(forKey: "attentionSound") ?? "Glass" }
    var doneNotify: Bool { ud.object(forKey: "doneNotify") == nil ? true : ud.bool(forKey: "doneNotify") }
    var doneBannerOn: Bool { ud.object(forKey: "doneBanner") == nil ? false : ud.bool(forKey: "doneBanner") }
    var doneDotOn: Bool { ud.object(forKey: "doneDot") == nil ? true : ud.bool(forKey: "doneDot") }
    var doneBannerSecs: Int { ud.object(forKey: "doneBannerSeconds") == nil ? 10 : ud.integer(forKey: "doneBannerSeconds") }
    var doneMin: Double { ud.object(forKey: "doneNotifyMinMinutes") == nil ? 1 : ud.double(forKey: "doneNotifyMinMinutes") }
    var doneSound: String { ud.string(forKey: "doneSound") ?? "Tink" }
    let banner = DoneBanner()
    let toast = FocusToast()
    let startedAt = Date().timeIntervalSince1970
    var codexExit: Int32?                     // 데몬이 마지막으로 끝난 exit 코드 (STARTING 실패 이유용)
    var a11yValue = ""

    var variant: String {
        let v = UserDefaults.standard.string(forKey: "iconVariant") ?? ICON_DEFAULT
        return ICON_VARIANTS.contains(v) ? v : ICON_DEFAULT
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        item.length = ICON_W + 8   // 아이콘만 — 폭 고정, 안 흔들림

        view.onSize = { [weak self] sz in
            guard let self = self else { return }
            if abs(self.popover.contentSize.height - sz.height) > 0.5 { self.popover.contentSize = sz }
        }
        // 승인 점 레이어 (아이콘 위에 겹친다)
        if let b = item.button {
            b.wantsLayer = true
            attnDot.isHidden = true
            attnDot.cornerRadius = 3.1
            attnDot.borderWidth = 0.8
            b.layer?.addSublayer(attnDot)
        }
        // 외부 포커스 요청 (알림 팝업 클릭 → kb-usage-menubar --focus <sid>)
        DistributedNotificationCenter.default().addObserver(forName: FOCUS_REQ, object: nil, queue: .main) { n in
            guard let sid = n.userInfo?["sid"] as? String, let req = n.userInfo?["req"] as? String else { return }
            let ack = { (ok: Bool) in
                DistributedNotificationCenter.default().postNotificationName(
                    FOCUS_ACK, object: nil, userInfo: ["req": req, "ok": ok], deliverImmediately: true)
            }
            logLine("focus-request \(keyTag("c:" + sid))")
            guard let it = itemForSession(String(sid.prefix(64))) else { logLine("focus-request no-session"); ack(false); return }
            focus(it) { o in ack(o.reachedFront) }
        }

        // 행 클릭(마우스·키보드·VoiceOver 누르기 공통): 팝오버를 닫고 창으로 간 뒤, 결과를 메뉴바 아래에 잠깐 보인다
        // (성공 / 앱만 활성화 / 권한 필요 구분 — focusOutcome)
        view.list.onClick = { [weak self] it in
            if !it.codex, it.key.hasPrefix("c:") { self?.clearDone(String(it.key.dropFirst(2)), reason: "click") }
            self?.popover.performClose(nil)
            DispatchQueue.main.async {               // 팝오버가 닫힌 뒤에
                focus(it) { o in
                    logLine("focus \(keyTag(it.key)) outcome=\(o)")
                    self?.toast.show(o, below: self?.item.button)
                }
            }
        }
        item.button?.setAccessibilityLabel("Claude·Codex 사용량")
        item.button?.setAccessibilityHelp("누르면 한도와 세션 목록 팝오버")
        // 표시 화면이 바뀌면(미러링·해상도·디스플레이 연결) 팝오버 최대 높이 다시
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.view.maxHeight = self.popoverMaxH()
            self.view.relayout()
        }
        // "동작 줄이기"를 바꾸면 이미 붙은 애니메이션도 바로 따른다
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            logLine("reduce-motion=\(reduceMotion())")
            for r in self.view.list.rows.values { r.icon.applyMotion(restart: false) }
            self.updateAttentionDot(self.snap())
        }

        let vc = NSViewController()
        vc.view = view
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: VIEW_W, height: VIEW_H)
        popover.behavior = .transient
        popover.delegate = self

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: POLL_SECONDS, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        ensureCodexDaemon()
        codexTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.ensureCodexDaemon()
        }
    }

    // codex_usage.py --daemon 을 자식으로 하나 유지한다. 데몬이 app-server 하나를
    // 붙잡고 60초마다 조회만 하므로 앱 쪽은 파일만 읽는다 (UI 안 끊김). 이 앱이
    // 죽으면 데몬은 부모 pid 가 바뀐 걸 보고 스스로 내려간다.
    func ensureCodexDaemon() {
        if let p = codexProc, p.isRunning { return }
        guard FileManager.default.fileExists(atPath: CX_SCRIPT) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [CX_SCRIPT, "--daemon"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice   // stderr 는 menubar.log 로 (트레이스백만)
        p.terminationHandler = { [weak self] proc in
            let st = proc.terminationStatus
            DispatchQueue.main.async { self?.codexExit = st; logLine("codex-daemon exit=\(st)") }
        }
        do { try p.run(); codexProc = p } catch { codexProc = nil; logLine("codex-daemon start failed") }
    }

    // readSnap + 앱만 아는 것 (Codex 데몬 상태)
    func snap() -> Snap {
        var s = readSnap()
        s.codexDaemon = CodexDaemonInfo(appStartedAt: startedAt,
                                        scriptExists: FileManager.default.fileExists(atPath: CX_SCRIPT),
                                        running: codexProc.map { $0.isRunning }, exitStatus: codexExit)
        return s
    }

    // 메뉴바 버튼이 있는 화면의 가용 높이 기준 팝오버 최대 높이
    func popoverMaxH() -> CGFloat {
        guard let scr = item.button?.window?.screen ?? NSScreen.main else { return .greatestFiniteMagnitude }
        return popoverMaxHeight(visibleH: scr.visibleFrame.height)
    }

    // 바깥 클릭으로 닫혀도(transient) 1초 타이머를 끈다
    func popoverDidClose(_ n: Notification) {
        fastTimer?.invalidate(); fastTimer = nil
        doneShown.removeAll()                    // 열어서 본 완료 강조는 닫으면 끝
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let snap = self.snap()
            acked.formUnion(attentionKeys(snap))     // 팝오버로 봤으니 지금 대기들은 펄스 정지
            seeDoneInPopover()                       // 완료도 본 것으로 → 메뉴바 점 끔, 행 강조는 닫을 때까지
            updateAttentionDot(snap)
            view.maxHeight = popoverMaxH()
            view.apply(snap, done: doneShown)
            view.relayout()
            popover.contentSize = view.totalSize
            popover.animates = !reduceMotion()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // 키보드: ↑↓ 로 행 고르기 (목록이 먼저 키를 받는다)
            popover.contentViewController?.view.window?.autorecalculatesKeyViewLoop = true
            popover.contentViewController?.view.window?.makeFirstResponder(view.list)
            // 팝오버가 화면에 붙은 뒤 한 번 더 그려서 (동기) 높이를 즉시 확정.
            view.usage.displayIfNeeded()
            fastTimer?.invalidate()
            fastTimer = Timer.scheduledTimer(withTimeInterval: POPOVER_TICK, repeats: true) {
                [weak self] _ in self?.refresh()
            }
        }
    }

    func refresh() {
        let s = snap()
        sounds(s)                                  // 완료 감지 → doneUnseen
        pruneDone(s)
        if popover.isShown { seeDoneInPopover(); view.apply(s, done: doneShown) }   // 닫혀 있을 땐 아이콘만
        var d = iconData(s, Date().timeIntervalSince1970)
        d.drawDot = false                          // 점은 레이어로
        updateAttentionDot(s)
        // 아이콘도 값이 같으면 다시 안 만든다
        let key = "\(variant)|\(d.five ?? -1)|\(d.seven ?? -1)|\(d.stale)|\(d.cxFive ?? -1)|\(d.cxSeven ?? -1)|\(d.cxDown)|\(d.attention)"
        if key != lastIcon {
            lastIcon = key
            item.button?.image = iconImage(variant, d)
            item.button?.image?.isTemplate = false
            item.button?.title = ""
        }
        let v = iconAccessibilityValue(d, done: !doneUnseen.isEmpty)
        if v != a11yValue { a11yValue = v; item.button?.setAccessibilityValue(v) }
    }

    func attentionKeys(_ s: Snap) -> Set<String> {
        Set(s.sessions.filter { $0.state == "attention" }.map { "\($0.sid)@\(Int($0.stateSince ?? 0))" })
    }

    // 승인 대기 있으면 점. 아직 안 본 대기가 있으면 은은한 펄스 (동작 줄이기면 정적).
    // 팝오버를 열면 그때의 대기들은 본 것으로 → 정지. 새 대기가 오면 다시 펄스.
    // 승인 대기가 없고 안 본 작업 완료가 있으면 같은 자리·같은 펄스로 세이지 점 (승인이 우선).
    func updateAttentionDot(_ s: Snap) {
        guard let b = item.button else { return }
        let keys = attentionKeys(s)
        acked.formIntersection(keys)
        let attn = !keys.isEmpty
        let done = !attn && !doneUnseen.isEmpty && !popover.isShown
        let show = attn || done
        let pulse = (attn ? !keys.subtracting(acked).isEmpty && !popover.isShown : done)
            && !reduceMotion()
        let kind = attn ? "attention" : done ? "done" : "none"
        if kind != dotKind { logLine("dot \(kind)" + (done ? " \(doneUnseen.keys.map { keyTag("c:" + $0) }.sorted().joined(separator: ","))" : "")); dotKind = kind }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        attnDot.isHidden = !show
        if show {
            let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            attnDot.backgroundColor = (attn ? (dark ? C.amber : NSColor(srgbRed: 0.92, green: 0.62, blue: 0.0, alpha: 1))
                                            : (dark ? C.sage : SAGE_LIGHT)).cgColor
            attnDot.borderColor = (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.8)).cgColor
            // 버튼 안에서 아이콘(ICON_W×20)은 가운데 정렬 — 아이콘 안 ATTN_DOT 위치로
            let ox = (b.bounds.width - ICON_W) / 2, oy = (b.bounds.height - 20) / 2
            let y = b.isFlipped ? oy + (20 - ATTN_DOT.y) : oy + ATTN_DOT.y
            attnDot.frame = CGRect(x: ox + ATTN_DOT.x - 3.1, y: y - 3.1, width: 6.2, height: 6.2)
        }
        CATransaction.commit()
        if pulse && attnDot.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0; a.toValue = 0.25; a.duration = 1.1
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            attnDot.add(a, forKey: "pulse")
        } else if !pulse && attnDot.animation(forKey: "pulse") != nil {
            attnDot.removeAnimation(forKey: "pulse")
        }
    }

    func play(_ name: String, volume: Float = 0.5) {
        guard !name.isEmpty else { return }                       // "" = 무음
        guard let snd = NSSound(named: NSSound.Name(name)) else { logLine("sound \(name) not found"); return }
        snd.volume = volume
        snd.play()                                                // 시스템 음량·무음 설정은 NSSound 가 따른다
    }

    // 소리: 승인 대기 진입 1회(기본 켜짐), 반복(기본 꺼짐), 작업 완료(기본 켜짐, 배너 포함).
    func sounds(_ s: Snap) {
        let now = Date().timeIntervalSince1970
        // (0) 승인 대기 진입 — 전이만. 앱 시작 때 이미 대기 중인 건 기준선으로만 (소리 X),
        //     같은 대기가 폴링마다 다시 울리지 않게 키 집합 차이로, 여럿이 한꺼번에 들어와도 2초에 한 번.
        let keys = attentionKeys(s)
        let dec = attentionSoundDecision(prev: attnSeen, keys: keys, lastSound: lastAttnSound, now: now)
        if dec.play {
            lastAttnSound = now
            play(attnSound, volume: 1.0)
            logLine("attention-sound \(dec.fresh.map { keyTag("c:" + $0) }.sorted().joined(separator: ",")) sound=\(attnSound.isEmpty ? "(none)" : attnSound)")
        }
        attnSeen = keys
        // (1) 승인 대기가 N분 넘게 계속되면 다시 알림
        if repeatMin > 0 {
            for r in s.sessions where r.state == "attention" {
                let k = "\(r.sid)@\(Int(r.stateSince ?? 0))"
                let last = nudgedAt[k] ?? (r.stateSince ?? now)
                if now - last >= repeatMin * 60 {
                    nudgedAt[k] = now
                    acked.remove(k)                 // 펄스 재개
                    play(attnSound)
                    logLine("attention-repeat \(keyTag("c:" + r.sid))")
                }
            }
            nudgedAt = nudgedAt.filter { k, _ in s.sessions.contains { "\($0.sid)@\(Int($0.stateSince ?? 0))" == k } }
        }
        // (2) 오래 걸린 작업이 끝났는데 그 창을 안 보고 있을 때 — 소리 + 배너
        //     전이(working → idle)만 본다: 앱 시작 때 이미 끝나 있던 세션은 prevState 가 없어 안 알림,
        //     같은 완료(done_at)는 doneSeen 으로 한 번만.
        //     걸린 시간 = 턴 시작(idle → working/attention)부터 — 중간 승인 대기로 끊지 않는다.
        for r in s.sessions {
            let st = r.state ?? ""
            if st == "working" || st == "attention", workingSince[r.sid] == nil { workingSince[r.sid] = r.stateSince ?? now }
            if st == "idle", let done = r.doneAt, prevState[r.sid] == "working", doneSeen[r.sid] != done {
                doneSeen[r.sid] = done
                let took = done - (workingSince[r.sid] ?? done)
                let front = frontPid()
                let tag = keyTag("c:" + r.sid)
                if let why = doneNotifyDecision(enabled: doneNotify, took: took, minMinutes: doneMin,
                                                front: front, term: r.termPid) {
                    logLine("done-skip \(tag) took=\(Int(took))s reason=\(why)")
                } else {
                    play(doneSound)
                    logLine("done-notify \(tag) took=\(Int(took))s sound=\(doneSound.isEmpty ? "(none)" : doneSound) dot=\(doneDotOn) banner=\(doneBannerOn)")
                    if doneDotOn { doneUnseen[r.sid] = done }
                    if doneBannerOn { banner.post(sid: r.sid, title: doneTitle(r), body: doneBody(r, took: took), seconds: doneBannerSecs) }
                }
            }
            if st == "idle" { workingSince[r.sid] = nil }
            prevState[r.sid] = st
        }
    }

    // 안 본 완료 정리: 세션 종료 / 다시 작업 / 그 창이 맨 앞 (doneClearReason)
    func pruneDone(_ s: Snap) {
        guard !doneUnseen.isEmpty || !doneShown.isEmpty else { return }
        let front = frontPid()
        let bySid = Dictionary(s.sessions.map { ($0.sid, $0) }, uniquingKeysWith: { a, _ in a })
        for sid in Set(doneUnseen.keys).union(doneShown) {
            let r = bySid[sid]
            if let why = doneClearReason(alive: r != nil, state: r?.state, term: r?.termPid, front: front) {
                clearDone(sid, reason: why)
            }
        }
    }

    func clearDone(_ sid: String, reason: String) {
        let had = doneUnseen.removeValue(forKey: sid) != nil
        let shown = doneShown.remove(sid) != nil
        if had || shown { logLine("done-dot clear \(keyTag("c:" + sid)) reason=\(reason)") }
    }

    // 팝오버가 열려 있으면 완료는 본 것: 메뉴바 점에서 빼고 행 강조는 닫힐 때까지 유지
    func seeDoneInPopover() {
        guard !doneUnseen.isEmpty else { return }
        for sid in doneUnseen.keys.sorted() { logLine("done-dot clear \(keyTag("c:" + sid)) reason=popover") }
        doneShown.formUnion(doneUnseen.keys)
        doneUnseen.removeAll()
    }

    // 배너 제목 = 세션 목록 행 제목과 같은 표기 ("개똥이  ·  세션 이름")
    func doneTitle(_ r: SessionRow) -> String { "\(r.agent ?? "Claude")  ·  \(r.name)" }

    // 배너 본문 = "작업 완료 · 3분 12초" + 있으면 한 줄 (todo 진행 / 마지막 도구)
    func doneBody(_ r: SessionRow, took: Double) -> String {
        var b = "작업 완료 · \(fmtTook(took))"
        if let t = r.todoTotal, t > 0 {
            b += "\n✓ \(r.todoDone ?? 0)/\(t)" + (r.todoActive.map { "  ·  \($0)" } ?? "")
        } else if let tool = r.tool {
            b += "\n마지막: " + tool + (r.hint.map { "  ·  \($0)" } ?? "")
        }
        return b
    }
}

// ── 아이콘 비교 시트 (--render-icon <out.png>) ────────
// 변형 1/2/3 × (다크 / 라이트 메뉴바) × 상태 샘플, 3x 배율.
func renderIconSheet(_ out: String) {
    let samples: [(String, IconData)] = [
        ("normal", IconData(five: 16, seven: 4, cxFive: 24, cxSeven: 4)),
        ("attention", IconData(five: 41, seven: 22, cxFive: 55, cxSeven: 18, attention: true)),
        ("done", IconData(five: 41, seven: 22, cxFive: 55, cxSeven: 18, done: true)),
        ("near 80%+", IconData(five: 86, seven: 40, cxFive: 83, cxSeven: 30)),
        ("95%+", IconData(five: 97, seven: 60, cxFive: 45, cxSeven: 96)),
        ("codex down", IconData(five: 16, seven: 4, cxFive: nil, cxSeven: nil, cxDown: true)),
    ]
    let names = ["1": "1 thick", "2": "2 outline", "3": "3 glow"]
    let scale: CGFloat = 3
    let cellW: CGFloat = 70, cellH: CGFloat = 30, labelW: CGFloat = 72, headH: CGFloat = 18
    let W = labelW + CGFloat(samples.count) * cellW
    let H = headH + CGFloat(ICON_VARIANTS.count * 2) * cellH
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ col: NSColor) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                                   .foregroundColor: col]).draw(at: NSPoint(x: x, y: y))
    }
    for (i, s) in samples.enumerated() { label(s.0, labelW + CGFloat(i) * cellW + 6, H - headH + 4, .black) }
    var row = 0
    for v in ICON_VARIANTS {
        for dark in [true, false] {
            let y = H - headH - CGFloat(row + 1) * cellH
            let bg = dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
                          : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
            bg.setFill(); NSRect(x: 0, y: y, width: W, height: cellH).fill()
            label("\(names[v]!)  \(dark ? "D" : "L")", 6, y + 10, dark ? .white : .black)
            let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
            for (i, s) in samples.enumerated() {
                let x = labelW + CGFloat(i) * cellW + (cellW - ICON_W) / 2
                ap.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform(); t.translateX(by: x, yBy: y + (cellH - 20) / 2); t.concat()
                    drawIcon(v, s.1)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            row += 1
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}

// ── 진입점 ────────────────────────────────────────────
let argv = CommandLine.arguments
if argv.count >= 3 && argv[1] == "--render-icon" {
    renderIconSheet(argv[2])
    exit(0)
}
if argv.count >= 3 && argv[1] == "--focus" {
    exit(requestFocusCLI(argv[2]))
}
if argv.count >= 3 && argv[1] == "--ae-ask", let pid = Int32(argv[2]) {
    // 진단: 메뉴바 앱처럼 accessory 로 떠서 active 가 된 뒤 권한을 묻는다 (팝업이 뜰 수 있음)
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.global().async {
            let st = ghosttyPermission(pid, ask: true)
            print("ae-ask result", st)
            exit(st == noErr ? 0 : 1)
        }
    }
    a.run()
}
if argv.count >= 3 && argv[1] == "--ae-check", let pid = Int32(argv[2]) {
    // Ghostty 제어 권한 상태만 (묻지 않음): 0 허용, -1743 거부, -1744 물어봐야 함
    let d = NSAppleEventDescriptor(processIdentifier: pid)
    print("ae-permission", AEDeterminePermissionToAutomateTarget(d.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), false))
    exit(0)
}
if argv.count >= 4 && argv[1] == "--list-terms", let pid = Int32(argv[2]) {
    // 읽기 전용: 그 pid 의 terminal 수, 이름이 정확히 맞는 수 (제목 자체는 안 찍음)
    do {
        let titles = try ghosttyTerminalProp(pid, "pnam")
        let ids = try ghosttyTerminalProp(pid, "ID  ")
        print("terminals=\(titles.count) ids=\(ids.count) match=\(titles.filter { bareTitle($0) == bareTitle(argv[3]) }.count)")
    } catch { print("error", (error as NSError).code) }
    exit(0)
}
if argv.count >= 3 && argv[1] == "--test-focus", let pid = Int32(argv[2]) {
    let a = NSApplication.shared
    let t = FocusTest(pid, argv.count >= 4 ? argv[3].split(separator: ",").map(String.init) : FOCUS_STEPS)
    a.delegate = t
    a.run()
}
let app = NSApplication.shared
let ctrl = App()
app.delegate = ctrl
app.run()
