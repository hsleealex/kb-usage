// Claude 사용 한도 메뉴바 앱.
//
// 메뉴바:  "5h 54%"  (30분+ 미갱신이면 ⚠ + 주황)
// 클릭  :  팝오버에 위젯 디자인 (5시간 / 주간 % · 게이지 · 리셋 · 신선도)
//
// 데이터: statusline.py 가 갱신하는 ~/developer/kb-usage/rate_limits.json
//
// 빌드:  swiftc -O menubar.swift -o kb-usage-menubar
// 실행:  ./kb-usage-menubar &

import AppKit
import Foundation

let RL_PATH = ("~/developer/kb-usage/rate_limits.json" as NSString).expandingTildeInPath
let MU_PATH = ("~/developer/kb-usage/model_usage.json" as NSString).expandingTildeInPath
let SESS_DIR = ("~/developer/kb-usage/sessions" as NSString).expandingTildeInPath
let SESSION_STALE = 90.0      // 이보다 안 갱신된 세션은 죽은 걸로 보고 숨김
let MAX_SESSIONS = 3
let POLL_SECONDS = 2.0        // 평상시 파일 폴링
let POPOVER_TICK = 1.0        // 팝오버 열려있을 때 (카운트다운 부드럽게)
let STALE_SECONDS = 1800.0

// ── 팔레트 (위젯과 동일) ──────────────────────────────
enum C {
    static let bg      = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)
    static let text    = NSColor(srgbRed: 0.910, green: 0.902, blue: 0.890, alpha: 1)
    static let dim     = NSColor(srgbRed: 0.478, green: 0.471, blue: 0.459, alpha: 1)
    static let faint   = NSColor(srgbRed: 0.353, green: 0.345, blue: 0.333, alpha: 1)
    static let accent  = NSColor(srgbRed: 0.851, green: 0.463, blue: 0.341, alpha: 1)
    static let track   = NSColor(srgbRed: 0.133, green: 0.118, blue: 0.110, alpha: 1)
    static let hair    = NSColor(srgbRed: 0.196, green: 0.184, blue: 0.176, alpha: 1)
}

struct Win { var pct: Double?; var resetsAt: Double?; var etaAt: Double? }
struct ModelRow { var id: String; var label: String; var tokens: Double; var cost: Double }
struct SessionRow {
    var name: String; var model: String?
    var ctxPct: Double?; var ctxSize: Double?; var cost: Double?
    var linesAdd: Double?; var linesDel: Double?; var durationMs: Double?
    var startedAt: Double; var updatedAt: Double
    var sid: String
}
struct Snap {
    var five = Win(); var seven = Win(); var spend = Win()
    var capturedAt: Double?; var missing = false
    var weekly: [ModelRow] = []       // 주간창 모델별 (cost 내림차순, model_usage.json)
    var lastModel: String?            // 로그상 가장 최근에 쓴 모델 라벨
    var muCapturedAt: Double?
    var sessions: [SessionRow] = []   // 표시할 세션 (started_at 순 최대 MAX_SESSIONS)
    var sessionsTotal = 0             // 살아있는 세션 전체 수 (표시 못 한 것 안내용)
}

// 세션 스냅샷은 세션마다 자기 파일에 쓴다 (context/cost 는 세션별 값이라
// 한 파일을 공유하면 서로 덮어쓴다). 신선한 것만, started_at 고정 정렬.
func readSessions() -> ([SessionRow], Int) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: SESS_DIR) else { return ([], 0) }
    let now = Date().timeIntervalSince1970
    var rows: [SessionRow] = []
    for n in names where n.hasSuffix(".json") {
        let p = (SESS_DIR as NSString).appendingPathComponent(n)
        guard let d = fm.contents(atPath: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { continue }
        let up = (o["updated_at"] as? Double) ?? 0
        if now - up > SESSION_STALE { continue }
        rows.append(SessionRow(name: (o["name"] as? String) ?? "?",
                               model: o["model"] as? String,
                               ctxPct: o["context_pct"] as? Double,
                               ctxSize: o["context_size"] as? Double,
                               cost: o["cost_usd"] as? Double,
                               linesAdd: o["lines_added"] as? Double,
                               linesDel: o["lines_removed"] as? Double,
                               durationMs: o["duration_ms"] as? Double,
                               startedAt: (o["started_at"] as? Double) ?? up,
                               updatedAt: up,
                               sid: (o["session_id"] as? String) ?? n))
    }
    // 먼저 시작한 세션이 위 — 갱신마다 순서가 튀지 않게 startedAt 고정 정렬
    rows.sort { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.sid < $1.sid }
    return (Array(rows.prefix(MAX_SESSIONS)), rows.count)
}

func readSnap() -> Snap {
    var s = Snap()
    guard let data = FileManager.default.contents(atPath: RL_PATH) else { s.missing = true; return s }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
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
    if let mdata = FileManager.default.contents(atPath: MU_PATH),
       let mroot = try? JSONSerialization.jsonObject(with: mdata) as? [String: Any] {
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

    (s.sessions, s.sessionsTotal) = readSessions()
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
func fmtTok(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
    return String(format: "%.0f", n)
}
// "Opus 5" -> "Opus" (세션 줄이 좁아서 첫 단어만)
func shortModel(_ s: String?) -> String? {
    guard let s = s, let first = s.split(separator: " ").first else { return nil }
    return String(first)
}
func clip(_ s: String, _ n: Int) -> String {
    return s.count > n ? String(s.prefix(max(1, n - 1))) + "…" : s
}
func fmtDur(_ ms: Double) -> String {
    let s = Int(ms / 1000)
    if s < 60 { return "\(s)s" }
    let m = s / 60
    return m < 60 ? "\(m)m" : String(format: "%dh%02dm", m / 60, m % 60)
}

// ── 팝오버 뷰 (위젯 디자인) ───────────────────────────
let VIEW_W: CGFloat = 300
let VIEW_H: CGFloat = 212        // 초기/최소 높이 — 모델 리스트가 붙으면 draw 에서 늘린다

final class UsageView: NSView {
    var snap = Snap()
    var measuredHeight: CGFloat = VIEW_H
    var onHeightChange: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: VIEW_W, height: measuredHeight) }

    func attr(_ s: String, _ size: CGFloat, _ color: NSColor,
              weight: NSFont.Weight = .regular, tracking: CGFloat = 0) -> NSAttributedString {
        var f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let d = f.fontDescriptor.withDesign(.rounded) { f = NSFont(descriptor: d, size: size) ?? f }
        return NSAttributedString(string: s, attributes: [
            .font: f, .foregroundColor: color, .tracking: tracking,
        ])
    }

    func fillColor(_ pct: Double?) -> NSColor {
        guard let p = pct else { return C.accent }
        if p >= 95 { return NSColor.systemRed }
        if p >= 80 { return NSColor.systemOrange }
        return C.accent
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

    func rightText(_ s: NSAttributedString, _ y: CGFloat, _ padX: CGFloat) {
        s.draw(at: NSPoint(x: bounds.width - padX - s.size().width, y: y))
    }

    override func draw(_ dirty: NSRect) {
        C.bg.setFill(); bounds.fill()
        let now = Date().timeIntervalSince1970
        let stale = (snap.capturedAt.map { now - $0 > STALE_SECONDS }) ?? false
        let padX: CGFloat = 20
        let gW = bounds.width - 2 * padX
        var y: CGFloat = 18

        // 한도 소진 ETA 한 줄. 페이스가 잡히면 항상 표시하되, 리셋보다 이르면
        // 주황(경고), 리셋이 먼저면 흐리게(여유). eta_at 없으면(거의 안 씀) 생략.
        func etaLine(_ win: Win) {
            guard let eta = win.etaAt, let reset = win.resetsAt, eta > now else { return }
            let urgent = eta < reset - 60
            attr("est. \(fmtLeft(eta - now)) to limit", 10,
                 urgent ? C.accent : C.faint, tracking: 0.2)
                .draw(at: NSPoint(x: padX, y: y))
            y += 14
        }

        // ── 5시간 ──
        attr("5H LIMIT", 11, C.dim, weight: .medium, tracking: 1.6).draw(at: NSPoint(x: padX, y: y))
        if let r = snap.five.resetsAt, snap.five.pct != nil {
            rightText(attr("resets \(fmtLeft(r - now))", 12, C.accent), y - 1, padX)
        }
        y += 15
        if let p = snap.five.pct {
            attr("\(Int(p.rounded()))%", 46, C.text, weight: .bold, tracking: -1)
                .draw(at: NSPoint(x: padX - 1, y: y))
            y += 55
        } else {
            attr("idle", 34, C.faint, weight: .bold, tracking: -0.5)
                .draw(at: NSPoint(x: padX - 1, y: y + 6))
            attr("no session in the last 5h", 10, C.dim, tracking: 0.4)
                .draw(at: NSPoint(x: padX, y: y + 48))
            y += 62
        }
        gauge((snap.five.pct ?? 0) / 100, NSRect(x: padX, y: y, width: gW, height: 6), fillColor(snap.five.pct))
        y += 8
        etaLine(snap.five)

        // ── 구분선 ──
        y += 10
        C.hair.setFill(); NSRect(x: padX, y: y, width: gW, height: 1).fill()
        y += 12

        // ── 주간 ──
        attr("WEEKLY", 11, C.dim, weight: .medium, tracking: 1.6).draw(at: NSPoint(x: padX, y: y))
        if let r = snap.seven.resetsAt {
            rightText(attr("resets \(fmtWhen(r))", 12, C.accent), y - 1, padX)
        }
        y += 12
        if let p = snap.seven.pct {
            attr("\(Int(p.rounded()))%", 30, C.dim, weight: .bold, tracking: -0.5)
                .draw(at: NSPoint(x: padX - 1, y: y))
            y += 40
        } else {
            attr("idle", 18, C.dim, weight: .medium).draw(at: NSPoint(x: padX - 1, y: y + 4))
            y += 28
        }
        gauge((snap.seven.pct ?? 0) / 100, NSRect(x: padX, y: y, width: gW, height: 5), fillColor(snap.seven.pct))
        y += 8
        etaLine(snap.seven)
        y -= 3

        // ── 살아있는 세션별 컨텍스트 (sessions/*.json) ──
        if !snap.sessions.isEmpty {
            y += 12
            C.hair.setFill(); NSRect(x: padX, y: y, width: gW, height: 1).fill()
            y += 12
            attr("SESSIONS", 11, C.dim, weight: .medium, tracking: 1.6)
                .draw(at: NSPoint(x: padX, y: y))
            rightText(attr("CONTEXT LEFT", 9, C.faint, tracking: 0.6), y + 1, padX)
            y += 18
            for s in snap.sessions {
                var label = clip(s.name, 14)
                if let m = shortModel(s.model) { label += "  ·  " + m }
                attr(label, 12, C.text).draw(at: NSPoint(x: padX, y: y))
                // 우측 줄1: 남은 컨텍스트 (토큰). size 없으면 % 폴백
                var right = ""
                if let p = s.ctxPct, let sz = s.ctxSize, sz > 0 {
                    right = "\(fmtTok(sz * (100 - p) / 100)) left"
                } else if let p = s.ctxPct {
                    right = "\(Int(p.rounded()))% used"
                }
                if !right.isEmpty { rightText(attr(right, 11, C.dim), y + 1, padX) }
                y += 15
                gauge((s.ctxPct ?? 0) / 100, NSRect(x: padX, y: y, width: gW, height: 5),
                      fillColor(s.ctxPct))
                y += 11
                // 줄3: 코드 변경량 + 세션 시간 (좌), compact 임박 (우)
                var sub = ""
                if let a = s.linesAdd, let d = s.linesDel, a + d > 0 { sub = "+\(Int(a)) −\(Int(d))" }
                if let ms = s.durationMs, ms > 1000 {
                    sub += sub.isEmpty ? fmtDur(ms) : "  ·  \(fmtDur(ms))"
                }
                if !sub.isEmpty { attr(sub, 9, C.faint, tracking: 0.3).draw(at: NSPoint(x: padX, y: y)) }
                if let p = s.ctxPct, p >= 85 {
                    rightText(attr("compact 임박", 9, NSColor.systemOrange, tracking: 0.3), y, padX)
                }
                y += 14
            }
            if snap.sessionsTotal > snap.sessions.count {
                attr("+\(snap.sessionsTotal - snap.sessions.count) more running", 9, C.faint, tracking: 0.6)
                    .draw(at: NSPoint(x: padX, y: y))
                y += 13
            }
            y -= 3
        }

        // ── 주간 모델별 (model_usage.json) ──
        if !snap.weekly.isEmpty {
            y += 12
            C.hair.setFill(); NSRect(x: padX, y: y, width: gW, height: 1).fill()
            y += 12
            attr("BY MODEL / WEEK", 11, C.dim, weight: .medium, tracking: 1.6)
                .draw(at: NSPoint(x: padX, y: y))
            rightText(attr("SHARE", 9, C.faint, tracking: 0.6), y + 1, padX)
            y += 18
            let totTok = max(1, snap.weekly.reduce(0.0) { $0 + $1.tokens })
            for row in snap.weekly.prefix(4) {
                let share = row.tokens / totTok
                attr(clip(row.label, 9), 12, C.text).draw(at: NSPoint(x: padX, y: y))
                let barX = padX + 74
                let barW = gW - 74 - 42
                gauge(share, NSRect(x: barX, y: y + 3, width: barW, height: 5), C.accent)
                // 소넷·오퍼스는 Max 구독이라 $ 가 가상치 → share % 만.
                // 종량 과금(페이블 등)일 때만 실제 청구액 표시.
                let rt = row.id.hasPrefix("claude-fable")
                    ? String(format: "$%.0f", row.cost)
                    : "\(Int((share * 100).rounded()))%"
                rightText(attr(rt, 11, C.dim), y + 1, padX)
                y += 18
            }
        }

        // ── 신선도 ──
        y += 12
        C.hair.setFill(); NSRect(x: padX, y: y, width: gW, height: 1).fill()
        y += 12
        var foot = "no data — run Claude Code"
        if let c = snap.capturedAt { foot = "updated \(fmtAgo(now - c))" + (stale ? "  ·  stale" : "") }
        if let lm = snap.lastModel, !lm.isEmpty { foot += "  ·  via \(lm)" }
        attr(foot.uppercased(), 9, stale ? C.accent : C.dim, tracking: 0.8)
            .draw(at: NSPoint(x: padX, y: y))
        y += 14

        // ── 높이 확정 (세션/모델 줄 수에 따라 팝오버가 늘고 준다) ──
        // 동기 호출: 콜백이 popover.contentSize 를 바로 키운다. 뷰가 커지면
        // 다음 runloop 에 재draw 되지만 그땐 needed == measuredHeight 라 재진입 없음.
        let needed = max(VIEW_H, ceil(y))
        if abs(needed - measuredHeight) > 0.5 {
            measuredHeight = needed
            onHeightChange?(needed)
        }
    }
}

// ── 앱 ────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let view = UsageView(frame: NSRect(x: 0, y: 0, width: VIEW_W, height: VIEW_H))
    var timer: Timer?
    var fastTimer: Timer?
    var heightConstraint: NSLayoutConstraint?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        item.length = 30   // 아이콘만 — 폭 완전 고정, 안 흔들림

        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: VIEW_W).isActive = true
        let hc = view.heightAnchor.constraint(equalToConstant: VIEW_H)
        hc.isActive = true
        heightConstraint = hc
        view.onHeightChange = { [weak self] h in
            self?.heightConstraint?.constant = h
            self?.popover.contentSize = NSSize(width: VIEW_W, height: h)
        }

        let vc = NSViewController()
        vc.view = view
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: VIEW_W, height: VIEW_H)
        popover.behavior = .transient

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: POLL_SECONDS, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            fastTimer?.invalidate(); fastTimer = nil
        } else {
            refresh()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // 팝오버가 화면에 붙은 뒤 한 번 더 그려서 (동기) 높이를 즉시 확정.
            // 세션 수가 바뀐 직후에도 첫 프레임부터 아래 섹션이 안 잘리게.
            view.displayIfNeeded()
            fastTimer?.invalidate()
            fastTimer = Timer.scheduledTimer(withTimeInterval: POPOVER_TICK, repeats: true) {
                [weak self] _ in self?.refresh()
            }
        }
    }

    func refresh() {
        let s = readSnap()
        view.snap = s
        view.needsDisplay = true

        let now = Date().timeIntervalSince1970
        let stale = (s.capturedAt.map { now - $0 > STALE_SECONDS }) ?? false

        // 메뉴바 = 이중 링 아이콘 (안=5시간, 밖=주간) — 숫자 없음, 안 흔들림
        item.button?.image = ringIcon(five: s.five.pct, seven: s.seven.pct,
                                      stale: stale || s.missing)
        item.button?.image?.isTemplate = false
        item.button?.title = ""
    }

    // 사용률에 따른 색: 80%↑ 주황, 95%↑ 빨강
    func level(_ pct: Double?, stale: Bool) -> NSColor {
        if stale { return .systemOrange }
        guard let p = pct else { return .tertiaryLabelColor }
        if p >= 95 { return .systemRed }
        if p >= 80 { return .systemOrange }
        return .labelColor
    }

    func ringIcon(five: Double?, seven: Double?, stale: Bool) -> NSImage {
        let sz: CGFloat = 20
        let fiveColor = level(five, stale: stale)
        let sevenColor = level(seven, stale: stale)
        return NSImage(size: NSSize(width: sz, height: sz), flipped: false) { _ in
            let c = NSPoint(x: sz / 2, y: sz / 2)
            let lw: CGFloat = 2.0
            let rOuter: CGFloat = sz / 2 - 2.0
            let rInner: CGFloat = rOuter - lw - 1.6

            func ring(_ r: CGFloat, _ pct: Double?, _ color: NSColor) {
                let track = NSBezierPath()
                track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
                track.lineWidth = lw
                color.withAlphaComponent(0.20).setStroke()
                track.stroke()
                guard let p = pct else { return }
                let end = 90 - 360 * CGFloat(min(1, max(0, p / 100)))
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: end,
                              clockwise: true)
                arc.lineWidth = lw
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }

            ring(rOuter, seven, sevenColor)          // 바깥 = 주간
            if five == nil {
                let d: CGFloat = 3.2                  // 5시간 idle → 가운데 점
                fiveColor.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - d/2, y: c.y - d/2, width: d, height: d)).fill()
            } else {
                ring(rInner, five, fiveColor)         // 안쪽 = 5시간
            }
            return true
        }
    }
}

let app = NSApplication.shared
let ctrl = App()
app.delegate = ctrl
app.run()
