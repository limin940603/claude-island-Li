// ClaudeIsland · macOS 版灵动岛 daemon(Swift/AppKit)
// 对标 Windows 的 daemon.ps1:毛玻璃胶囊 + 小熊圆头像(彩环+光晕)+ 呼吸/弹跳
// + 轮询 events.jsonl + 展开多会话面板 + 菜单栏(静默/配置/退出)+ config。
// 运行时文件沿用 ~/.claude/hooks/claude-island/;资产用 --assets <路径> 传入(install.sh 拷好)。
import AppKit
import Darwin

// MARK: - 路径
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let runDir = home.appendingPathComponent(".claude/hooks/claude-island")
    static let events = runDir.appendingPathComponent("events.jsonl")
    static let config = runDir.appendingPathComponent("config.json")
    static let pos = runDir.appendingPathComponent("pos.json")
    static let pidFile = runDir.appendingPathComponent(".daemon.pid")
    static var assets = runDir.appendingPathComponent("assets") // 可被 --assets 覆盖
}

// MARK: - 状态色板(与 daemon.ps1 一致)
let StateColors: [String: NSColor] = [
    "idle":      NSColor(hex: "#A89F95"),
    "done":      NSColor(hex: "#2FA84F"),
    "authorize": NSColor(hex: "#2B7FD4"),
    "waiting":   NSColor(hex: "#E8A24A"),
    "error":     NSColor(hex: "#D64545"),
]
func colorFor(_ state: String) -> NSColor { StateColors[state] ?? StateColors["idle"]! }

let SoundOf: [String: String] = [
    "chime": "chime.mp3", "notification": "notification.mp3", "error": "error.mp3", "pop": "pop.mp3",
]

extension NSColor {
    convenience init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "FF" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 24) & 0xff) / 255
        let g = CGFloat((v >> 16) & 0xff) / 255
        let b = CGFloat((v >> 8) & 0xff) / 255
        let a = CGFloat(v & 0xff) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - 配置
final class Config {
    var silent = false
    var volume = 0.6
    var muteStates: [String] = []
    func load() {
        guard let data = try? Data(contentsOf: Paths.config),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let s = o["silent"] as? Bool { silent = s }
        if let v = (o["volume"] as? NSNumber)?.doubleValue { volume = v }
        if let m = o["muteStates"] as? [String] { muteStates = m }
    }
    func save() {
        let o: [String: Any] = ["silent": silent, "volume": volume, "muteStates": muteStates]
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
            try? data.write(to: Paths.config)
        }
    }
}

// MARK: - 事件
struct IslandEvent {
    let ts: Double, state: String, title: String, sub: String, sound: String, project: String
}
func readEvents() -> [IslandEvent] {
    guard let text = try? String(contentsOf: Paths.events, encoding: .utf8) else { return [] }
    var out: [IslandEvent] = []
    for raw in text.split(separator: "\n") {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        guard let d = t.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
        out.append(IslandEvent(
            ts: (o["ts"] as? NSNumber)?.doubleValue ?? 0,
            state: (o["state"] as? String) ?? "idle",
            title: (o["title"] as? String) ?? "",
            sub: (o["sub"] as? String) ?? "",
            sound: (o["sound"] as? String) ?? "",
            project: (o["project"] as? String) ?? ""))
    }
    return out
}
func relTime(_ ts: Double) -> String {
    if ts <= 0 { return "" }
    let now = Date().timeIntervalSince1970 * 1000
    let s = Int(max(0, now - ts) / 1000)
    if s < 60 { return "刚刚" }
    let m = s / 60; if m < 60 { return "\(m) 分钟前" }
    let h = m / 60; if h < 24 { return "\(h) 小时前" }
    return "\(h / 24) 天前"
}

// 头像缓存
var bearCache: [String: NSImage] = [:]
func bearImage(_ state: String) -> NSImage? {
    if let c = bearCache[state] { return c }
    let url = Paths.assets.appendingPathComponent("bear-\(state).png")
    let img = NSImage(contentsOf: url)
    if let img = img { bearCache[state] = img }
    return img
}

// 顶部左上原点的翻转视图(便于 y 从上往下手工布局)
final class FlippedView: NSView { override var isFlipped: Bool { true } }

func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}
func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = NSFont.systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.backgroundColor = .clear
    f.isBordered = false
    f.isEditable = false
    f.lineBreakMode = .byTruncatingTail
    return f
}

// MARK: - 胶囊视图(处理毛玻璃 + 小熊层 + 文本 + 徽章 + 拖动/点击)
final class PillView: FlippedView {
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?

    let fx = NSVisualEffectView()
    let avatarHost = FlippedView()          // 56x56 容器
    let avatarGroup = CALayer()             // 中心锚点组层,弹跳缩放挂它
    let discLayer = CALayer()
    let bearLayer = CALayer()               // 呼吸缩放挂它
    let ringLayer = CALayer()               // 描边环 + 光晕
    let titleField: NSTextField
    let subField: NSTextField
    let badgeWrap = FlippedView()
    let badgeField: NSTextField

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var didDrag = false

    let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let subFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)

    override init(frame: NSRect) {
        titleField = makeLabel("AI问老李", size: 15, weight: .semibold, color: NSColor(hex: "#F6F1EA"))
        subField = makeLabel("就绪", size: 12.5, weight: .regular, color: NSColor(hex: "#B4A99D"))
        badgeField = makeLabel("", size: 12, weight: .bold, color: .white)
        badgeField.alignment = .center
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // 让所有点击都落在 PillView(子视图/文本不拦截 —— Peon-Ping 坑 #6)
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func build() {
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 26
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        addSubview(fx)

        avatarHost.wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        discLayer.frame = CGRect(x: 4, y: 4, width: 48, height: 48)
        discLayer.cornerRadius = 24
        discLayer.backgroundColor = NSColor(hex: "#FCFAF7").cgColor

        bearLayer.frame = CGRect(x: 4, y: 4, width: 48, height: 48)
        bearLayer.cornerRadius = 24
        bearLayer.masksToBounds = true
        bearLayer.contentsGravity = .resizeAspectFill
        bearLayer.contentsScale = scale

        ringLayer.frame = CGRect(x: 3.25, y: 3.25, width: 49.5, height: 49.5)
        ringLayer.cornerRadius = 24.75
        ringLayer.borderWidth = 3
        ringLayer.borderColor = colorFor("idle").cgColor
        ringLayer.backgroundColor = NSColor.clear.cgColor
        ringLayer.shadowColor = colorFor("idle").cgColor
        ringLayer.shadowRadius = 12
        ringLayer.shadowOpacity = 0.6
        ringLayer.shadowOffset = .zero

        avatarGroup.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        avatarGroup.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        avatarGroup.position = CGPoint(x: 28, y: 28)
        avatarGroup.addSublayer(discLayer)
        avatarGroup.addSublayer(bearLayer)
        avatarGroup.addSublayer(ringLayer)
        avatarHost.layer?.addSublayer(avatarGroup)
        addSubview(avatarHost)

        addSubview(titleField)
        addSubview(subField)

        badgeWrap.wantsLayer = true
        badgeWrap.layer?.cornerRadius = 11
        badgeWrap.addSubview(badgeField)
        addSubview(badgeWrap)
        badgeWrap.isHidden = true

        setBear("idle")
        startBreathing()
    }

    func setBear(_ state: String) {
        if let img = bearImage(state) { bearLayer.contents = img }
    }

    private var unread = 0
    func setBadge(_ n: Int) {
        unread = n
        if n <= 0 { badgeWrap.isHidden = true }
        else { badgeWrap.isHidden = false; badgeField.stringValue = n >= 9 ? "9+" : "\(n)" }
    }

    // 应用一个状态:换色/换熊/换字/弹跳
    func apply(state: String, title: String, sub: String) {
        let c = colorFor(state)
        ringLayer.borderColor = c.cgColor
        ringLayer.shadowColor = c.cgColor
        badgeWrap.layer?.backgroundColor = c.cgColor
        titleField.stringValue = title.isEmpty ? "AI问老李" : title
        subField.stringValue = sub
        setBear(state)
        pop()
        layoutPill()
    }

    // 手工测量宽度布局(固定高 68,宽随内容)
    @discardableResult
    func layoutPill() -> NSSize {
        let padL: CGFloat = 8, avatar: CGFloat = 56, gap: CGFloat = 13, padR: CGFloat = 18
        let H: CGFloat = 68
        let tW = max(textWidth(titleField.stringValue, titleFont),
                     textWidth(subField.stringValue.isEmpty ? " " : subField.stringValue, subFont))
        let textW = min(max(tW, 44), 240)
        let showBadge = !badgeWrap.isHidden
        let badgeBlock: CGFloat = showBadge ? (12 + 22) : 0
        let W = padL + avatar + gap + textW + badgeBlock + padR
        frame = NSRect(x: 0, y: 0, width: W, height: H)
        fx.frame = bounds
        avatarHost.frame = NSRect(x: padL, y: (H - 56) / 2, width: 56, height: 56)
        let tx = padL + avatar + gap
        titleField.frame = NSRect(x: tx, y: 15, width: textW, height: 20)
        subField.frame = NSRect(x: tx, y: 38, width: textW, height: 16)
        if showBadge {
            let bx = W - padR - 22
            badgeWrap.frame = NSRect(x: bx, y: (H - 22) / 2, width: 22, height: 22)
            badgeField.frame = badgeWrap.bounds
        }
        return frame.size
    }

    // MARK: 动效
    func pop() {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.8; a.toValue = 1.0
        a.damping = 9; a.stiffness = 170; a.initialVelocity = 6; a.mass = 0.7
        a.duration = a.settlingDuration
        avatarGroup.add(a, forKey: "pop")
    }
    func startBreathing() {
        let br = CABasicAnimation(keyPath: "transform.scale")
        br.fromValue = 0.92; br.toValue = 1.0; br.duration = 1.6
        br.autoreverses = true; br.repeatCount = .infinity
        br.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bearLayer.add(br, forKey: "breathe")
        let gl = CABasicAnimation(keyPath: "shadowOpacity")
        gl.fromValue = 0.5; gl.toValue = 1.0; gl.duration = 1.6
        gl.autoreverses = true; gl.repeatCount = .infinity
        gl.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ringLayer.add(gl, forKey: "glow")
    }

    // MARK: 拖动 vs 点击(Peon-Ping 坑 #8:阈值去重)
    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x, dy = now.y - dragStartMouse.y
        if abs(dx) > 4 || abs(dy) > 4 { didDrag = true }
        window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag { onDragEnd?() } else { onClick?() }
    }
}

// MARK: - 展开面板视图(最近 6 条多会话)
final class PanelBuilder {
    static let width: CGFloat = 322
    static func build(events: [IslandEvent], unread: Int,
                      onClear: @escaping () -> Void, onReadAll: @escaping () -> Void) -> NSView {
        let rowH: CGFloat = 52, headerH: CGFloat = 46, footerH: CGFloat = 42
        let rows = Array(events.suffix(6).reversed())
        let bodyH = CGFloat(max(rows.count, 1)) * rowH
        let total = headerH + 1 + bodyH + 1 + footerH
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        root.wantsLayer = true
        root.layer?.cornerRadius = 20
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor(hex: "#161310E6").cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor

        // header
        let title = makeLabel("灵动岛", size: 13.5, weight: .bold, color: NSColor(hex: "#F6F1EA"))
        title.frame = NSRect(x: 16, y: 14, width: 60, height: 18); root.addSubview(title)
        let un = makeLabel("\(unread) 条未读", size: 11, weight: .regular, color: NSColor(hex: "#B4A99D"))
        let uw = textWidth(un.stringValue, un.font!) + 16
        let unBg = FlippedView(frame: NSRect(x: 84, y: 12, width: uw, height: 20))
        unBg.wantsLayer = true; unBg.layer?.cornerRadius = 9
        unBg.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        un.frame = NSRect(x: 8, y: 3, width: uw - 16, height: 14); unBg.addSubview(un); root.addSubview(unBg)
        let clear = makeButton("清空", color: NSColor(hex: "#8A8178")) { onClear() }
        clear.frame = NSRect(x: width - 52, y: 12, width: 40, height: 20); root.addSubview(clear)

        addSeparator(to: root, y: headerH)

        // rows
        var y = headerH + 1
        if rows.isEmpty {
            let empty = makeLabel("暂无消息", size: 12, weight: .regular, color: .gray)
            empty.frame = NSRect(x: 16, y: y + 14, width: 200, height: 16); root.addSubview(empty)
        }
        for e in rows {
            root.addSubview(rowView(e, y: y, rowH: rowH))
            y += rowH
        }

        addSeparator(to: root, y: headerH + 1 + bodyH)

        let readAll = makeButton("全部已读", color: NSColor(hex: "#CFC6BB")) { onReadAll() }
        readAll.frame = NSRect(x: 16, y: total - footerH + 12, width: 80, height: 18); root.addSubview(readAll)
        return root
    }

    static func rowView(_ e: IslandEvent, y: CGFloat, rowH: CGFloat) -> NSView {
        let c = colorFor(e.state)
        let row = FlippedView(frame: NSRect(x: 7, y: y, width: width - 14, height: rowH))
        // 色条
        let bar = FlippedView(frame: NSRect(x: 4, y: 10, width: 3, height: rowH - 20))
        bar.wantsLayer = true; bar.layer?.cornerRadius = 1.5; bar.layer?.backgroundColor = c.cgColor
        row.addSubview(bar)
        // 圆熊
        let av = FlippedView(frame: NSRect(x: 15, y: (rowH - 34) / 2, width: 34, height: 34))
        av.wantsLayer = true
        let disc = CALayer(); disc.frame = av.bounds; disc.cornerRadius = 17; disc.backgroundColor = NSColor(hex: "#FCFAF7").cgColor
        let bl = CALayer(); bl.frame = av.bounds; bl.cornerRadius = 17; bl.masksToBounds = true
        bl.contentsGravity = .resizeAspectFill; bl.contents = bearImage(e.state)
        bl.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let rl = CALayer(); rl.frame = av.bounds; rl.cornerRadius = 17; rl.borderWidth = 1.6; rl.borderColor = c.cgColor
        av.layer?.addSublayer(disc); av.layer?.addSublayer(bl); av.layer?.addSublayer(rl)
        row.addSubview(av)
        // 文本
        let t = makeLabel(e.title, size: 13.5, weight: .semibold, color: NSColor(hex: "#F6F1EA"))
        t.frame = NSRect(x: 60, y: 8, width: width - 90, height: 18); row.addSubview(t)
        let meta = [e.project, relTime(e.ts)].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        let m = makeLabel(meta, size: 11.5, weight: .regular, color: NSColor(hex: "#B4A99D"))
        m.frame = NSRect(x: 60, y: 28, width: width - 90, height: 16); row.addSubview(m)
        return row
    }

    static func addSeparator(to v: NSView, y: CGFloat) {
        let s = FlippedView(frame: NSRect(x: 0, y: y, width: width, height: 1))
        s.wantsLayer = true; s.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        v.addSubview(s)
    }
    static func makeButton(_ s: String, color: NSColor, action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: s, target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: s, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 12.5)])
        b.onClick = action
        return b
    }
}

final class ClosureButton: NSButton {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - App 主体
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config()
    var statusItem: NSStatusItem!
    var pillWindow: NSPanel!
    var pillView: PillView!
    var panelWindow: NSPanel!
    var poller: Timer?
    var collapseTimer: Timer?
    var lastTs: Double = 0
    var unread = 0
    var panelOpen = false

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: Paths.runDir, withIntermediateDirectories: true)
        singleInstanceGuard()
        config.load()
        buildPill()
        buildStatusItem()
        positionPill()
        pillWindow.orderFront(nil)
        NSApp.setActivationPolicy(.accessory) // 建完 UI 再切(Peon-Ping 坑 #2)
        // 启动读一次 + 400ms 轮询
        handleTick()
        poller = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.handleTick() }
    }

    func singleInstanceGuard() {
        if let s = try? String(contentsOf: Paths.pidFile),
           let old = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), old > 0, kill(old, 0) == 0 {
            exit(0)
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: Paths.pidFile, atomically: true, encoding: .utf8)
    }

    func buildPill() {
        pillView = PillView(frame: NSRect(x: 0, y: 0, width: 240, height: 68))
        pillView.layoutPill()
        let panel = NSPanel(contentRect: pillView.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.contentView = pillView
        pillWindow = panel
        pillView.onClick = { [weak self] in self?.togglePanel() }
        pillView.onDragEnd = { [weak self] in self?.savePos() }
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = bearImage("idle") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "🐻"
        }
        let menu = NSMenu()
        let silent = NSMenuItem(title: "静默(只弹不响)", action: #selector(toggleSilent), keyEquivalent: "")
        silent.target = self; silent.state = config.silent ? .on : .off
        menu.addItem(silent)
        let cfg = NSMenuItem(title: "打开配置文件…", action: #selector(openConfig), keyEquivalent: "")
        cfg.target = self; menu.addItem(cfg)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func toggleSilent(_ sender: NSMenuItem) {
        config.silent.toggle(); sender.state = config.silent ? .on : .off; config.save()
    }
    @objc func openConfig() { config.save(); NSWorkspace.shared.open(Paths.config) }
    @objc func quit() { try? FileManager.default.removeItem(at: Paths.pidFile); NSApp.terminate(nil) }

    // MARK: 轮询
    func handleTick() {
        let all = readEvents()
        let new = all.filter { $0.ts > lastTs }
        guard !new.isEmpty else { return }
        lastTs = new.map { $0.ts }.max() ?? lastTs
        config.load()
        let visible = new.filter { !config.muteStates.contains($0.state) }
        guard !visible.isEmpty else { return }
        unread += visible.count
        pillView.setBadge(unread)
        apply(visible.last!)
    }

    func apply(_ e: IslandEvent) {
        let subLine = [e.project, e.sub].filter { !$0.isEmpty }.joined(separator: " · ")
        pillView.apply(state: e.state, title: e.title, sub: subLine)
        // 宽度变化后重新居中窗口(保持左上角 y 不变)
        let origin = pillWindow.frame.origin
        pillWindow.setContentSize(pillView.frame.size)
        pillWindow.setFrameOrigin(origin)
        pillWindow.invalidateShadow()
        if !config.silent { playSound(e.sound) }
    }

    var currentSound: NSSound?
    func playSound(_ key: String) {
        guard let f = SoundOf[key] else { return }
        let url = Paths.assets.appendingPathComponent("sfx/\(f)")
        if let s = NSSound(contentsOf: url, byReference: true) {
            s.volume = Float(config.volume); currentSound = s; s.play()
        }
    }

    // MARK: 位置
    func positionPill() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        var x = vf.midX - pillWindow.frame.width / 2
        var y = vf.maxY - pillWindow.frame.height - 12
        if let d = try? Data(contentsOf: Paths.pos),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let px = (o["x"] as? NSNumber)?.doubleValue, let py = (o["y"] as? NSNumber)?.doubleValue {
            x = px; y = py
        }
        pillWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }
    func savePos() {
        let o: [String: Any] = ["x": pillWindow.frame.origin.x, "y": pillWindow.frame.origin.y]
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: Paths.pos) }
    }

    // MARK: 展开面板
    func togglePanel() {
        if panelOpen { closePanel() } else { openPanel() }
    }
    func openPanel() {
        unread = 0; pillView.setBadge(0)
        let content = PanelBuilder.build(events: readEvents(), unread: unread,
            onClear: { [weak self] in self?.clearAll() },
            onReadAll: { [weak self] in self?.closePanel() })
        if panelWindow == nil {
            panelWindow = NSPanel(contentRect: content.frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            panelWindow.level = .floating
            panelWindow.isOpaque = false
            panelWindow.backgroundColor = .clear
            panelWindow.hasShadow = true
            panelWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        panelWindow.setContentSize(content.frame.size)
        panelWindow.contentView = content
        // 放到 pill 正下方居中
        let pf = pillWindow.frame
        let px = pf.midX - content.frame.width / 2
        let py = pf.minY - content.frame.height - 8
        panelWindow.setFrameOrigin(NSPoint(x: px, y: py))
        panelWindow.invalidateShadow()
        panelWindow.orderFront(nil)
        panelOpen = true
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.closePanel() }
    }
    func closePanel() {
        panelWindow?.orderOut(nil); panelOpen = false; collapseTimer?.invalidate()
    }
    func clearAll() {
        try? "".write(to: Paths.events, atomically: true, encoding: .utf8)
        unread = 0; pillView.setBadge(0); closePanel()
    }
}

// MARK: - 入口
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--assets"), i + 1 < args.count {
    Paths.assets = URL(fileURLWithPath: args[i + 1])
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
