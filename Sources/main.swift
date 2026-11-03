import AppKit
import Carbon
import QuartzCore
import ServiceManagement

func makeIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.lockFocus()
    let base = NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 488, height: 488), xRadius: 110, yRadius: 110)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.25, blue: 0.42, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.18, alpha: 1))!.draw(in: base, angle: -80)
    for row in 0..<3 { for col in 0..<3 {
        (row == 2 && col == 2 ? NSColor.systemMint : NSColor.white.withAlphaComponent(0.90)).setFill()
        NSBezierPath(roundedRect: NSRect(x: 100 + col * 112, y: 100 + row * 112, width: 88, height: 88), xRadius: 22, yRadius: 22).fill()
    } }
    image.unlockFocus(); return image
}

final class PadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var keyHandler: ((NSEvent) -> Void)?
    override func keyDown(with event: NSEvent) { keyHandler?(event) }
}

// A native live backdrop: samples windows behind this transparent window.
// Do not draw an opaque color behind the visual-effect view.
final class GlassTint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.17).setFill()
        bounds.fill()
    }
}

final class GlassBackdrop: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SearchShell: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        let lens = NSBezierPath(ovalIn: NSRect(x: 10, y: 14, width: 10, height: 10))
        lens.lineWidth = 1.2; lens.stroke()
        let handle = NSBezierPath(); handle.move(to: NSPoint(x: 18.5, y: 15.5))
        handle.line(to: NSPoint(x: 23, y: 11)); handle.lineWidth = 1.2; handle.stroke()
    }
}

final class PageDrag {
    var start: NSPoint?
    var moved = false
    var handler: ((CGFloat, Bool) -> Void)?
    func begin(_ event: NSEvent) { start = event.locationInWindow; moved = false }
    func update(_ event: NSEvent, ended: Bool) -> Bool {
        guard let start else { return false }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        moved = moved || hypot(dx, dy) > 8
        if moved { handler?(abs(dx) > abs(dy) ? dx : 0, ended) }
        if ended { self.start = nil }
        return moved
    }
}

final class PagingClipView: NSClipView {
    let pageDrag = PageDrag()
    var backgroundClick: (() -> Void)?
    var scrollHandler: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { pageDrag.begin(event) }
    override func mouseDragged(with event: NSEvent) { _ = pageDrag.update(event, ended: false) }
    override func mouseUp(with event: NSEvent) {
        if !pageDrag.update(event, ended: true) { backgroundClick?() }
    }
    override func scrollWheel(with event: NSEvent) { scrollHandler?(event) }
}

final class Canvas: NSView {
    var scrollHandler: ((NSEvent) -> Void)?
    var backgroundClick: (() -> Void)?
    let pageDrag = PageDrag()
    override func scrollWheel(with event: NSEvent) { scrollHandler?(event) }
    override func mouseDown(with event: NSEvent) { pageDrag.begin(event) }
    override func mouseDragged(with event: NSEvent) { _ = pageDrag.update(event, ended: false) }
    override func mouseUp(with event: NSEvent) {
        if !pageDrag.update(event, ended: true) { backgroundClick?() }
    }
}

// Render at the largest animated size on Retina before handing the image to Core Animation.
// An NSWorkspace icon often has a 32-point logical size despite containing larger representations.
func hoverRaster(_ image: NSImage, iconSize: CGFloat, backingScale: CGFloat) -> CGImage? {
    let pixels = Int(ceil(iconSize * max(1, backingScale) * 1.18))
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
               operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.cgImage
}

// Critically damped motion retains both position and velocity when the target reverses.
struct HoverMotion {
    private(set) var target: Double = 1
    private var position: Double = 1
    private var velocity: Double = 0
    private var started: Double = 0
    static let frequency = 36.0
    func sample(at time: Double) -> (position: Double, velocity: Double) {
        let t = max(0, time - started)
        let delta = position - target
        let b = velocity + Self.frequency * delta
        let decay = exp(-Self.frequency * t)
        return (target + (delta + b * t) * decay,
                (velocity - Self.frequency * b * t) * decay)
    }
    mutating func retarget(_ next: Double, at time: Double, immediately: Bool = false) {
        let state = sample(at: time)
        position = immediately ? next : state.position
        velocity = immediately ? 0 : state.velocity
        target = next; started = time
    }
}

final class FolderDropPreview: NSView {
    private let picture = CALayer()
    private var motion = HoverMotion()
    init(frame: NSRect, iconFrame: NSRect, raster: CGImage?, backingScale: CGFloat) {
        super.init(frame: frame); wantsLayer = true
        layer?.masksToBounds = false
        picture.frame = iconFrame
        picture.contents = raster
        picture.contentsScale = backingScale
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .linear
        picture.shouldRasterize = false
        picture.contentsGravity = .resizeAspect
        layer?.addSublayer(picture)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(frame: NSRect, iconFrame: NSRect, raster: CGImage?, backingScale: CGFloat) {
        self.frame = frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Updating bounds/position preserves an in-flight transform.
        picture.bounds = NSRect(origin: .zero, size: iconFrame.size)
        picture.position = NSPoint(x: iconFrame.midX, y: iconFrame.midY)
        picture.contents = raster; picture.contentsScale = backingScale
        CATransaction.commit()
    }
    func setEnlarged(_ enlarged: Bool) {
        let target = enlarged ? 1.18 : 1.0
        guard motion.target != target else { return }
        let now = CACurrentMediaTime()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion.retarget(target, at: now, immediately: reduced)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.transform = CATransform3DMakeScale(CGFloat(target), CGFloat(target), 1)
        if reduced {
            picture.removeAnimation(forKey: "hoverScale")
        } else {
            // Sample the same continuous trajectory for Core Animation, with a shared clock.
            // A reversal changes the destination without resetting velocity to zero.
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            let duration = 0.4
            let steps = 96
            animation.values = (0...steps).map {
                motion.sample(at: now + duration * Double($0) / Double(steps)).position
            }
            animation.duration = duration
            animation.beginTime = picture.convertTime(now, from: nil)
            animation.calculationMode = .linear
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            picture.add(animation, forKey: "hoverScale")
        }
        CATransaction.commit()
    }

}

final class AppTile: NSButton {
    var record: ApplicationRecord
    var icon: NSImage { didSet { if icon !== oldValue { cachedHoverRaster = nil } } }
    private var cachedHoverRaster: CGImage?
    private var cachedHoverPixels = 0
    @discardableResult func prepareHoverRaster(backingScale: CGFloat) -> CGImage? {
        let size = max(24, min(88, bounds.width - 28, bounds.height - 43))
        let pixels = Int(ceil(size * max(1, backingScale) * 1.18))
        if cachedHoverRaster == nil || cachedHoverPixels != pixels {
            cachedHoverRaster = hoverRaster(icon, iconSize: size, backingScale: backingScale)
            cachedHoverPixels = pixels
        }
        return cachedHoverRaster
    }
    var highlightedSelection = false { didSet { needsDisplay = true } }
    var hover = false { didSet { if hover != oldValue { updateIconEmphasis() } } }
    private var area: NSTrackingArea?
    var selectionEditing = false
    var checked = false
    var dropPreview: FolderDropPreview?
    private var dropActive = false
    func showDropPreview() {
        guard !dropActive else { return }
        dropActive = true; updateIconEmphasis()
    }
    func clearDropPreview() {
        guard dropActive else { return }
        dropActive = false; updateIconEmphasis()
    }
    func prepareIconPresentation(backingScale: CGFloat) {
        let size = max(24, min(88, bounds.width - 28, bounds.height - 43))
        let frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size + 22) / 2, width: size, height: size)
        let raster = prepareHoverRaster(backingScale: backingScale)
        if let preview = dropPreview {
            preview.update(frame: bounds, iconFrame: frame, raster: raster, backingScale: backingScale)
        } else {
            let preview = FolderDropPreview(frame: bounds, iconFrame: frame, raster: raster, backingScale: backingScale)
            addSubview(preview); dropPreview = preview; needsDisplay = true
        }
    }
    private func updateIconEmphasis() {
        if dropPreview == nil {
            prepareIconPresentation(backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        }
        // Keep one image layer at both sizes, avoiding a redraw/overlay swap on every exit.
        dropPreview?.setEnlarged(hover || dropActive)
    }

    var reorderHandler: ((AppTile, NSPoint, Bool) -> Void)?
    private var reorderMoved = false
    let pageDrag = PageDrag()
    override func mouseDown(with event: NSEvent) {
        reorderMoved = false; pageDrag.begin(event); highlight(true); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let reorderHandler, let start = pageDrag.start {
            if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 8 { reorderMoved = true }
            if reorderMoved { reorderHandler(self, event.locationInWindow, false) }
        } else { _ = pageDrag.update(event, ended: false) }
        highlight(false); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if reorderMoved {
            reorderHandler?(self, event.locationInWindow, true); pageDrag.start = nil
            highlight(false); return
        }
        let dragged = pageDrag.update(event, ended: true)
        highlight(false); needsDisplay = true
        if !dragged && bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }
    init(record: ApplicationRecord, icon: NSImage) {
        self.record = record; self.icon = icon
        super.init(frame: .zero)
        wantsLayer = true
        title = record.name; isBordered = false; toolTip = record.name + "\n" + record.url.path
        setAccessibilityLabel(record.name)
        setAccessibilityHelp("打开应用")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard area == nil else { return }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func draw(_ dirtyRect: NSRect) {
        if highlightedSelection {
            NSColor.white.withAlphaComponent(0.19).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 16, yRadius: 16).fill()
        }
        let size = max(24, min(88, bounds.width - 28, bounds.height - 43))
        if dropPreview == nil { icon.draw(in: NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size + 22) / 2, width: size, height: size)) }
        if selectionEditing {
            let badge = NSRect(x: bounds.midX + size / 2 - 10, y: (bounds.height + size + 22) / 2 - 18, width: 25, height: 25)
            (checked ? NSColor.systemBlue : NSColor.darkGray).setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 1, dy: 1)); ring.lineWidth = 1.5; ring.stroke()
            if checked { ("✓" as NSString).draw(at: NSPoint(x: badge.minX + 5, y: badge.minY + 2), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]) }
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let textRect = NSRect(x: 5, y: 8, width: bounds.width - 10, height: 25)
        (record.name as NSString).draw(in: textRect, withAttributes: [.font: NSFont.systemFont(ofSize: bounds.height < 100 ? 11 : 13, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    }
}

final class ShortcutRecorder: NSButton {
    var recording = false
    var captured: ((UInt32, UInt32, String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        if event.keyCode == 53 { recording = false; title = "点击录制快捷键"; return }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
        var modifiers: UInt32 = 0, label = ""
        if f.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if f.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if f.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if f.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += event.keyCode == 49 ? " Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        recording = false; title = label; captured?(UInt32(event.keyCode), modifiers, label)
    }
}

enum LaunchContext {
    static func isBackground(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        let reason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    var prefs = Preferences.load()
    var catalog: [ApplicationRecord] = []
    var filtered: [ApplicationRecord] = []
    var icons: [String: NSImage] = [:]
    var tiles: [AppTile] = []
    var page = 0, selection = 0
    var isScanning = false, scanAgain = false, lastScan = Date.distantPast
    var pad: PadWindow!
    var canvas: Canvas!
    var search: NSSearchField!
    var searchShell: SearchShell!
    var grid: PagingClipView!
    var pageStrip: NSView!
    var dots: NSView!
    var statusLabel: NSTextField!
    var emptyLabel: NSTextField!
    var settings: NSWindow?
    var editingSelection = false
    var selectionDone: NSButton!
    var dragGhost: NSImageView?
    var reorderPath: String?
    var reorderTarget: String?
    var reorderEdgeSince: TimeInterval = 0
    var reorderEdge = 0
    var activeFolder: String?
    var folderBack: NSButton!
    var folderTitle: NSTextField!
    var folderDissolve: NSButton!
    var dragOrder: [String] = []
    var dragSlots: [NSRect] = []
    var folderHover: String?
    var folderReady = false
    var insertionTimer: Timer?
    var insertionTarget: String?
    var folderTimer: Timer?
    var displayedCatalog: [ApplicationRecord] {
        if editingSelection { return catalog }
        if !(search?.stringValue ?? "").isEmpty && activeFolder == nil { return prefs.visibleApplications(catalog) }
        return prefs.groupedApplications(catalog, inside: activeFolder)
    }
    var selectionButton: NSButton?
    var shortcutStatus: NSTextField?
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var hotKeyError: String?
    var timer: Timer?
    var lastCorner: String?
    var cornerSince = Date.distantPast
    var cornerFired = false
    var scrollAccum: CGFloat = 0
    var lastScroll = Date.distantPast
    var lastTurn = Date.distantPast
    var pageOffset: CGFloat = 0
    var dragBase: CGFloat = 0
    var draggingPage = false
    var dragSampleX: CGFloat = 0
    var dragSampleTime: TimeInterval = 0
    var pageVelocity: CGFloat = 0
    var pageAnimating = false
    var pageAnimationID = 0
    var activatingApp = false
    var padRequestedVisible = false
    var transitionID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let backgroundLaunch = LaunchContext.isBackground(NSAppleEventManager.shared().currentAppleEvent)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: url)
        }
        NSApp.setActivationPolicy(prefs.showDock ? .regular : .accessory)
        setupMenu(); buildPad(); installHotKey(); scan()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        if !backgroundLaunch {
            if prefs.enabled { showPad() } else { showSettings() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { togglePad(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    func applicationDidResignActive(_ notification: Notification) {
        if pad?.isVisible == true && !activatingApp { hidePad() }
    }
    func setupMenu() {
        let main = NSMenu()
        let root = NSMenuItem(); main.addItem(root)
        let appMenu = NSMenu(); root.submenu = appMenu
        appMenu.addItem(action("关于 LaunchDeck", #selector(about), key: ""))
        appMenu.addItem(action("设置…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(action("退出 LaunchDeck", #selector(quit), key: "q"))
        let edit = NSMenuItem(); edit.title = "编辑"; main.addItem(edit)
        let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
        for (title, sel, key) in [("剪切", "cut:", "x"), ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(sel), keyEquivalent: key))
        }
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchDeck")
        statusItem.button?.toolTip = "LaunchDeck · 应用启动台"
        let menu = NSMenu()
        menu.addItem(action("打开启动台", #selector(togglePad), key: ""))
        menu.addItem(action("刷新应用列表", #selector(refresh), key: ""))
        menu.addItem(action("设置…", #selector(showSettings), key: ""))
        menu.addItem(.separator()); menu.addItem(action("退出 LaunchDeck", #selector(quit), key: ""))
        statusItem.menu = menu
    }
    func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; return item
    }
    func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
        let value = NSTextField(labelWithString: text); value.font = .systemFont(ofSize: size); value.textColor = color; return value
    }
    func buildPad() {
        pad = PadWindow(contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        pad.title = "LaunchDeck 启动台"; pad.isReleasedWhenClosed = false
        pad.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1); pad.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        pad.backgroundColor = .clear; pad.isOpaque = false; pad.hasShadow = false
        pad.appearance = NSAppearance(named: .darkAqua)
        canvas = Canvas(frame: pad.contentView!.bounds); canvas.autoresizingMask = [.width, .height]
        pad.contentView = canvas
        let backdrop = GlassBackdrop(frame: canvas.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.isEmphasized = false
        canvas.addSubview(backdrop)
        let tint = GlassTint(frame: canvas.bounds)
        tint.autoresizingMask = [.width, .height]
        canvas.addSubview(tint)
        search = NSSearchField(frame: .zero)
        search.isBezeled = false; search.drawsBackground = false
        (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        searchShell = SearchShell(frame: .zero)
        canvas.addSubview(searchShell)
        search.placeholderAttributedString = NSAttributedString(string: "搜索", attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.75), .font: NSFont.systemFont(ofSize: 13)])
        search.textColor = .white
        search.font = .systemFont(ofSize: 13); search.focusRingType = .none; search.delegate = self
        search.sendsSearchStringImmediately = true; search.setAccessibilityLabel("搜索应用")
        searchShell.addSubview(search)
        grid = PagingClipView(); grid.drawsBackground = false; grid.wantsLayer = true; grid.layer?.masksToBounds = true; canvas.addSubview(grid)
        pageStrip = NSView(); pageStrip.wantsLayer = true
        pageStrip.layer?.masksToBounds = false; grid.documentView = pageStrip
        dots = NSView(); canvas.addSubview(dots)
        statusLabel = label("正在读取应用…", size: 11, color: .secondaryLabelColor); statusLabel.alignment = .center; statusLabel.isHidden = true; canvas.addSubview(statusLabel)
        emptyLabel = label("未找到应用", size: 21, color: .secondaryLabelColor); emptyLabel.alignment = .center; canvas.addSubview(emptyLabel)
        let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")!, target: self, action: #selector(showSettings))
        settingsButton.isBordered = false; settingsButton.toolTip = "设置"; settingsButton.identifier = NSUserInterfaceItemIdentifier("settings")
        canvas.addSubview(settingsButton)
        canvas.scrollHandler = { [weak self] event in self?.scroll(event) }
        canvas.backgroundClick = { [weak self] in if self?.editingSelection != true { self?.hidePad() } }
        canvas.pageDrag.handler = { [weak self] dx, ended in self?.dragPage(dx, ended: ended) }
        grid.pageDrag.handler = canvas.pageDrag.handler
        grid.backgroundClick = canvas.backgroundClick
        grid.scrollHandler = canvas.scrollHandler
        selectionDone = NSButton(title: "完成并显示已选", target: self, action: #selector(finishSelection))
        selectionDone.bezelStyle = .rounded; canvas.addSubview(selectionDone)
        folderBack = NSButton(title: "‹ 返回（拖到此处移出）", target: self, action: #selector(closeFolder))
        folderBack.bezelStyle = .rounded; canvas.addSubview(folderBack)
        folderTitle = NSTextField(); folderTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        folderTitle.alignment = .center; folderTitle.target = self; folderTitle.action = #selector(renameFolder)
        folderTitle.setAccessibilityLabel("文件夹名称，回车保存"); canvas.addSubview(folderTitle)
        folderDissolve = NSButton(title: "解散文件夹", target: self, action: #selector(dissolveFolder))
        folderDissolve.bezelStyle = .rounded; canvas.addSubview(folderDissolve)
        pad.keyHandler = { [weak self] event in self?.handleKey(event) }
    }
    @objc func togglePad() {
        if !prefs.enabled { showSettings(); return }
        if padRequestedVisible { hidePad() } else { showPad() }
    }
    func showPad() {
        guard prefs.enabled else { return }
        let wasVisible = pad.isVisible
        transitionID += 1
        padRequestedVisible = true
        pad.ignoresMouseEvents = false
        if !wasVisible { pad.alphaValue = 0 }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main!
        pad.setFrame(screen.frame, display: false)
        search.stringValue = ""; page = 0; selection = 0; filtered = displayedCatalog
        scrollAccum = 0; render()
        NSApp.activate(ignoringOtherApps: true); pad.makeKeyAndOrderFront(nil); pad.makeFirstResponder(search)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pad.animator().alphaValue = 1
        }
        if Date().timeIntervalSince(lastScan) > 10 { scan() }
    }
    func hidePad() {
        clearFolderHover()
        insertionTimer?.invalidate(); insertionTimer = nil; insertionTarget = nil
        folderTimer?.invalidate(); folderTimer = nil; folderHover = nil; folderReady = false
        dragGhost?.removeFromSuperview(); dragGhost = nil; reorderPath = nil; reorderTarget = nil
        tiles.forEach { $0.hover = false; $0.alphaValue = 1 }
        cancelPageAnimation(); draggingPage = false
        guard padRequestedVisible else { return }
        padRequestedVisible = false
        transitionID += 1
        let id = transitionID
        // Let clicks reach the newly focused app while the overlay fades away.
        pad.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            pad.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.transitionID == id, !self.padRequestedVisible else { return }
            self.pad.orderOut(nil)
            self.pad.alphaValue = 1
        }
    }
    @objc func screenChanged() { if pad.isVisible { showPad() } }
    @objc func refresh() { scan() }
    func scan() {
        if isScanning { scanAgain = true; return }
        isScanning = true; statusLabel?.stringValue = "正在更新应用列表…"
        DispatchQueue.global(qos: .userInitiated).async {
            let next = Catalog.scan()
            DispatchQueue.main.async {
                if self.draggingPage || self.pageAnimating || self.reorderPath != nil {
                    self.isScanning = false
                    // Keep the existing view and data stable until the gesture finishes.
                    self.lastScan = Date().addingTimeInterval(-55)
                    return
                }
                var updated = self.prefs
                if updated.includeNewApplications(next) {
                    do {
                        try updated.save()
                        self.prefs = updated
                        self.selectionButton?.title = "选择应用…（已选 \(updated.selectedApplicationPaths?.count ?? 0) 个）"
                    } catch {
                        self.showError("新应用选择未保存", detail: error.localizedDescription)
                    }
                }
                self.catalog = next; self.lastScan = Date(); self.isScanning = false
                let livePaths = Set(next.map { $0.url.path }); self.icons = self.icons.filter { livePaths.contains($0.key) }
                self.filtered = Catalog.search(self.displayedCatalog, query: self.search.stringValue)
                self.page = LayoutMath.clampedPage(self.page, items: self.filtered.count, capacity: self.prefs.rows * self.prefs.columns)
                self.selection = min(self.selection, max(0, self.filtered.count - 1)); self.render()
                if self.scanAgain { self.scanAgain = false; self.scan() }
            }
        }
    }
    func render() {
        guard canvas != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        cancelPageAnimation()
        draggingPage = false; pageOffset = 0
        grid.bounds.origin = .zero
        let b = canvas.bounds
        let screen = pad.screen
        let safeTop = max(24, screen?.safeAreaInsets.top ?? 0)
        searchShell.frame = NSRect(x: (b.width - min(280, b.width - 60)) / 2, y: b.height - max(72, safeTop + 24) - 36, width: min(280, b.width - 60), height: 36)
        search.frame = NSRect(x: 30, y: 9, width: searchShell.bounds.width - 42, height: 18)
        let inset = max(24, min(90, b.width * 0.045))
        // Match the reference's compact upper grid instead of filling down to the footer.
        let gridTop = searchShell.frame.minY - 30
        let gridHeight = min(max(120, gridTop - 88), b.height * 0.675)
        grid.frame = NSRect(x: 0, y: gridTop - gridHeight, width: b.width, height: gridHeight)
        dots.frame = NSRect(x: 40, y: 44, width: b.width - 80, height: 28)
        statusLabel.frame = NSRect(x: 40, y: 17, width: b.width - 80, height: 18)
        emptyLabel.frame = NSRect(x: 30, y: b.height / 2, width: b.width - 60, height: 36)
        canvas.subviews.first(where: { $0.identifier?.rawValue == "settings" })?.frame = NSRect(x: b.width - 52, y: b.height - safeTop - 52, width: 28, height: 28)
        selectionDone.frame = NSRect(x: b.width - 245, y: b.height - safeTop - 54, width: 180, height: 32)
        selectionDone.isHidden = !editingSelection
        folderBack.frame = NSRect(x: 35, y: b.height - safeTop - 54, width: 195, height: 32)
        folderTitle.frame = NSRect(x: b.midX - 150, y: b.height - safeTop - 50, width: 300, height: 28)
        folderDissolve.frame = NSRect(x: b.width - 220, y: b.height - safeTop - 54, width: 150, height: 32)
        for view in [folderBack as NSView, folderTitle as NSView, folderDissolve as NSView] { view.isHidden = activeFolder == nil || editingSelection }
        if let key = activeFolder { folderTitle.stringValue = prefs.folder(for: key)?.name ?? "文件夹" }
        // One continuous document; both pages share the same clipping viewport.
        let stride = canvas.bounds.width
        let documentPages = LayoutMath.pageCount(items: filtered.count, capacity: prefs.rows * prefs.columns)
        pageStrip.frame = NSRect(x: 0, y: 0, width: stride * CGFloat(documentPages), height: grid.bounds.height)
        setPageOffset(0)
        let reusable = Dictionary(uniqueKeysWithValues: tiles.map { ($0.record.url.path, $0) })
        dots.subviews.forEach { $0.removeFromSuperview() }; tiles.removeAll()
        let capacity = prefs.rows * prefs.columns
        page = LayoutMath.clampedPage(page, items: filtered.count, capacity: capacity)
        let pages = LayoutMath.pageCount(items: filtered.count, capacity: capacity)
        let start = 0
        let end = filtered.count
        let cellW = (grid.bounds.width - inset * 2) / CGFloat(prefs.columns), cellH = grid.bounds.height / CGFloat(prefs.rows)
        if start < end {
            for index in start..<end {
                let app = filtered[index]
                let image = prefs.folder(for: app.url.path).map { folderIcon($0) } ?? icons[app.url.path] ?? NSWorkspace.shared.icon(forFile: app.url.path)
                icons[app.url.path] = image
                let tile = reusable[app.url.path] ?? AppTile(record: app, icon: image); tile.record = app; tile.icon = image; tile.title = app.name; tile.setAccessibilityLabel(app.name); tile.tag = index; tile.target = self; tile.action = #selector(launch(_:))
                tile.selectionEditing = editingSelection
                tile.checked = (prefs.selectedApplicationPaths ?? []).contains(app.url.path)
                tile.setAccessibilityHelp(editingSelection ? (tile.checked ? "已选择，点击取消" : "未选择，点击勾选") : "打开应用")
                tile.reorderHandler = !editingSelection && search.stringValue.isEmpty
                    ? { [weak self] tile, point, ended in self?.reorder(tile, point: point, ended: ended) } : nil
                tile.pageDrag.handler = { [weak self] dx, ended in self?.dragPage(dx, ended: ended) }
                let offset = index % capacity
                let pageX = CGFloat(index / capacity) * stride + inset
                let tileW = min(170, cellW), tileH = min(145, cellH)
                tile.frame = NSRect(x: pageX + CGFloat(offset % prefs.columns) * cellW + (cellW - tileW) / 2, y: grid.bounds.height - CGFloat(offset / prefs.columns + 1) * cellH + (cellH - tileH) / 2, width: tileW, height: tileH)
                if index / capacity == page || tile.dropPreview != nil { tile.prepareIconPresentation(backingScale: pad.backingScaleFactor) }
                tile.highlightedSelection = index == selection && !search.stringValue.isEmpty
                if tile.superview !== pageStrip { pageStrip.addSubview(tile) }; tiles.append(tile)
            }
        }
        let retained = Set(tiles.map { ObjectIdentifier($0) })
        pageStrip.subviews.filter { !retained.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        tiles.forEach { $0.displayIfNeeded() }
        emptyLabel.stringValue = prefs.onlySelectedApplications == true && (prefs.selectedApplicationPaths ?? []).isEmpty && search.stringValue.isEmpty
            ? "尚未选择应用，请在设置中选择要显示的应用" : "未找到应用"
        emptyLabel.isHidden = !filtered.isEmpty || isScanning
        if pages > 1 {
            let maxDots = max(3, Int(dots.bounds.width / 24))
            let first = min(max(0, page - maxDots / 2), max(0, pages - maxDots))
            let count = min(maxDots, pages)
            for p in first..<(first + count) {
                let button = NSButton(title: p == page ? "●" : "○", target: self, action: #selector(goPage(_:)))
                button.isBordered = false; button.font = .systemFont(ofSize: 17); button.contentTintColor = p == page ? .white : .gray
                button.tag = p; button.setAccessibilityLabel("第 \(p + 1) 页，共 \(pages) 页")
                button.frame = NSRect(x: (dots.bounds.width - CGFloat(count * 24)) / 2 + CGFloat((p - first) * 24), y: 0, width: 24, height: 26)
                dots.addSubview(button)
            }
        }
        if editingSelection {
            statusLabel.stringValue = "点击图标勾选 · 已选择 \(prefs.selectedApplicationPaths?.count ?? 0) 个 · 拖动空白处或滚动翻页"
            return
        }
        statusLabel.stringValue = isScanning ? "正在更新应用列表…" : "\(filtered.count) 个应用  ·  第 \(page + 1) / \(pages) 页  ·  Esc 关闭"
        if prefs.onlySelectedApplications == true && search.stringValue.isEmpty { statusLabel.stringValue += "  ·  拖动图标排序" }
    }
    func setPageOffset(_ offset: CGFloat) {
        pageOffset = offset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grid.setBoundsOrigin(NSPoint(x: CGFloat(page) * canvas.bounds.width - offset, y: 0))
        CATransaction.commit()
    }
    func cancelPageAnimation() {
        pageAnimationID += 1
        if pageAnimating, let visible = grid?.layer?.presentation() {
            pageOffset = CGFloat(page) * canvas.bounds.width - visible.bounds.origin.x
        }
        pageAnimating = false
        grid?.layer?.removeAnimation(forKey: "pageSlide")
        if pageStrip != nil { setPageOffset(pageOffset) }
    }
    func dragPage(_ dx: CGFloat, ended: Bool) {
        guard padRequestedVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !draggingPage {
            cancelPageAnimation()
            draggingPage = true; dragBase = pageOffset
            dragSampleX = 0; dragSampleTime = now; pageVelocity = 0
        }
        let dt = now - dragSampleTime
        if dt > 0.001 {
            let speed = (dx - dragSampleX) / dt
            // Retain the final motion briefly across a mouse-up at the same position.
            if dx != dragSampleX { pageVelocity = speed }
            else if dt > 0.12 { pageVelocity = 0 }
        }
        dragSampleX = dx; dragSampleTime = now
        let pages = LayoutMath.pageCount(items: filtered.count, capacity: prefs.rows * prefs.columns)
        let raw = dragBase + dx
        let atEdge = (page == 0 && raw > 0) || (page == pages - 1 && raw < 0)
        let width = canvas.bounds.width
        let offset = atEdge ? raw * 0.18 / (1 + abs(raw) / width) : max(-width, min(width, raw))
        setPageOffset(offset)
        if ended {
            draggingPage = false
            let projected = offset + max(-2200, min(2200, pageVelocity)) * 0.14
            let shouldTurn = !atEdge && abs(dx) > 16 && abs(projected) > width * 0.18
            let target = shouldTurn ? page + (projected < 0 ? 1 : -1) : page
            settlePage(to: target)
        }
    }
    func settlePage(to requested: Int) {
        cancelPageAnimation()
        let target = LayoutMath.clampedPage(requested, items: filtered.count, capacity: prefs.rows * prefs.columns)
        let start = pageOffset
        let destination = CGFloat(page - target) * canvas.bounds.width
        let duration: TimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
        if duration == 0 {
            page = target; selection = page * prefs.rows * prefs.columns; render(); return
        }
        pageAnimating = true
        let animationID = pageAnimationID
        let animation = CABasicAnimation(keyPath: "bounds.origin.x")
        animation.fromValue = CGFloat(page) * canvas.bounds.width - start
        animation.toValue = CGFloat(target) * canvas.bounds.width
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.pageAnimationID == animationID, self.pageAnimating else { return }
            self.pageAnimating = false
            self.page = target; self.selection = target * self.prefs.rows * self.prefs.columns
            self.render()
        }
        setPageOffset(destination)
        grid.layer?.add(animation, forKey: "pageSlide")
        CATransaction.commit()
    }
    @objc func goPage(_ sender: NSButton) { turn(to: sender.tag) }
    func turn(to next: Int) {
        let target = LayoutMath.clampedPage(next, items: filtered.count, capacity: prefs.rows * prefs.columns)
        guard target != page else { return }
        if abs(target - page) > 1 {
            page = target; selection = page * prefs.rows * prefs.columns; render()
        } else { settlePage(to: target) }
    }
    func scroll(_ event: NSEvent) {
        let now = Date()
        if event.momentumPhase != [] { return }
        guard now.timeIntervalSince(lastTurn) > 0.32 else { return }
        if now.timeIntervalSince(lastScroll) > 0.2 { scrollAccum = 0 }
        lastScroll = now
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccum += delta * (event.hasPreciseScrollingDeltas ? 1 : 12)
        let threshold = CGFloat(100 - prefs.sensitivity * 75)
        if abs(scrollAccum) > threshold {
            turn(to: page + (scrollAccum < 0 ? 1 : -1)); scrollAccum = 0; lastTurn = now
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === search else { return }
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        filtered = Catalog.search(displayedCatalog, query: search.stringValue); page = 0; selection = 0; render()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch NSStringFromSelector(commandSelector) {
        case "cancelOperation:": if activeFolder != nil { closeFolder() } else { hidePad() }; return true
        case "insertNewline:": launchSelection(); return true
        case "moveDown:": moveSelection(prefs.columns); return true
        case "moveUp:": moveSelection(-prefs.columns); return true
        case "moveRight:": if search.stringValue.isEmpty { moveSelection(1); return true }; return false
        case "moveLeft:": if search.stringValue.isEmpty { moveSelection(-1); return true }; return false
        case "pageDown:": turn(to: page + 1); return true
        case "pageUp:": turn(to: page - 1); return true
        default: return false
        }
    }
    func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53: if activeFolder != nil { closeFolder() } else { hidePad() }
        case 36, 76: launchSelection()
        case 123: moveSelection(-1)
        case 124: moveSelection(1)
        case 125: moveSelection(prefs.columns)
        case 126: moveSelection(-prefs.columns)
        default: pad.makeFirstResponder(search)
        }
    }
    func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = min(max(0, selection + delta), filtered.count - 1)
        page = selection / (prefs.rows * prefs.columns); render()
        tiles.forEach { $0.highlightedSelection = $0.tag == selection }
    }
    func launchSelection() { if editingSelection { if tiles.indices.contains(selection) { launch(tiles[selection]) }; return }; if filtered.indices.contains(selection) { open(filtered[selection]) } }
    @objc func launch(_ sender: AppTile) {
        if editingSelection {
            let path = sender.record.url.path
            update { p in
                var chosen = p.selectedApplicationPaths ?? []
                if chosen.contains(path) { chosen.remove(path) }
                else { chosen.insert(path); if !(p.selectedApplicationOrder ?? []).contains(path) { p.selectedApplicationOrder = (p.selectedApplicationOrder ?? []) + [path] } }
                p.selectedApplicationPaths = chosen
            }
        } else { open(sender.record) }
    }
    func open(_ record: ApplicationRecord) {
        if prefs.folder(for: record.url.path) != nil {
            activeFolder = record.url.path; search.stringValue = ""; page = 0; selection = 0
            filtered = displayedCatalog; render(); return
        }
        guard !activatingApp, !pageAnimating, !draggingPage else { return }
        activatingApp = true
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: record.url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                self.activatingApp = false
                if let error { self.showError("无法打开“\(record.name)”", detail: error.localizedDescription); self.scan() }
                else { self.hidePad() }
            }
        }
    }
    func installHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        hotKeyError = nil
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer -> OSStatus in
                guard let pointer else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<Controller>.fromOpaque(pointer).takeUnretainedValue()
                DispatchQueue.main.async { owner.togglePad() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        if prefs.enabled {
            let id = EventHotKeyID(signature: 0x4C44434B, id: 1)
            let result = RegisterEventHotKey(prefs.keyCode, prefs.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
            if result != noErr { hotKeyError = "快捷键注册失败（\(result)），可能已被其他应用占用。请录制其他组合。" }
        }
        shortcutStatus?.stringValue = hotKeyError ?? "\(prefs.shortcutName) · 包含 ⌘、⌥ 或 ⌃；Esc 取消录制"
        shortcutStatus?.textColor = hotKeyError == nil ? .secondaryLabelColor : .systemOrange
    }
    func tick() {
        if Date().timeIntervalSince(lastScan) > 60 && !isScanning { scan() }
        guard prefs.enabled, prefs.corner != 0, settings?.isVisible != true else { lastCorner = nil; return }
        let p = NSEvent.mouseLocation
        var cornerKey: String?
        for (i, screen) in NSScreen.screens.enumerated() {
            let r = screen.frame, zone: CGFloat = 5
            let left = p.x >= r.minX && p.x <= r.minX + zone, right = p.x >= r.maxX - zone && p.x <= r.maxX
            let top = p.y >= r.maxY - zone && p.y <= r.maxY, bottom = p.y >= r.minY && p.y <= r.minY + zone
            let active = (prefs.corner == 1 && left && top) || (prefs.corner == 2 && right && top) || (prefs.corner == 3 && left && bottom) || (prefs.corner == 4 && right && bottom)
            if active { cornerKey = "\(i)-\(prefs.corner)"; break }
        }
        if cornerKey != lastCorner { lastCorner = cornerKey; cornerSince = Date(); cornerFired = false }
        if cornerKey != nil && !cornerFired && Date().timeIntervalSince(cornerSince) > 0.25 {
            cornerFired = true; togglePad()
        }
    }
    func update(_ edit: (inout Preferences) -> Void) {
        let old = prefs
        edit(&prefs); prefs.validate()
        do { try prefs.save() }
        catch { prefs = old; showError("设置未保存", detail: error.localizedDescription); settings?.close(); settings = nil; showSettings(); return }
        NSApp.setActivationPolicy(prefs.showDock ? .regular : .accessory)
        installHotKey()
        filtered = Catalog.search(displayedCatalog, query: search?.stringValue ?? "")
        page = LayoutMath.clampedPage(page, items: filtered.count, capacity: prefs.rows * prefs.columns)
        selection = min(selection, max(0, filtered.count - 1))
        selectionButton?.title = "选择应用…（已选 \(prefs.selectedApplicationPaths?.count ?? 0) 个）"
        if !prefs.enabled { hidePad() }
        else if pad.isVisible { render() }
    }
    @objc func showSettings() {
        hidePad()
        if let settings { NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 690), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "LaunchDeck 设置 · 1.0.22"; w.isReleasedWhenClosed = false; w.center(); settings = w
        let content = w.contentView!
        let heading = label("让应用触手可及", size: 24); heading.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.frame = NSRect(x: 32, y: 528, width: 540, height: 34); content.addSubview(heading)
        let sub = label("独立启动台 · 设置仅影响 LaunchDeck", color: .secondaryLabelColor); sub.frame = NSRect(x: 32, y: 501, width: 540, height: 24); content.addSubview(sub)
        func row(_ title: String, y: CGFloat, control: NSView) {
            let text = label(title); text.frame = NSRect(x: 34, y: y + 3, width: 190, height: 24); content.addSubview(text)
            control.frame = NSRect(x: 270, y: y, width: 310, height: 30); content.addSubview(control)
        }
        func check(_ value: Bool, tag: Int) -> NSButton {
            let b = NSButton(checkboxWithTitle: "开启", target: self, action: #selector(settingToggle(_:))); b.state = value ? .on : .off; b.tag = tag; return b
        }
        row("启动台", y: 450, control: check(prefs.enabled, tag: 1))
        row("显示在程序坞", y: 408, control: check(prefs.showDock, tag: 2))
        let recorder = ShortcutRecorder(title: prefs.shortcutName, target: self, action: #selector(recordShortcut(_:))); recorder.bezelStyle = .rounded
        recorder.captured = { [weak self] key, mods, name in self?.update { $0.keyCode = key; $0.modifiers = mods; $0.shortcutName = name } }
        row("切换快捷键", y: 366, control: recorder)
        shortcutStatus = label(hotKeyError ?? "包含 ⌘、⌥ 或 ⌃；Esc 取消录制", size: 11, color: hotKeyError == nil ? .secondaryLabelColor : .systemOrange)
        shortcutStatus!.frame = NSRect(x: 34, y: 324, width: 548, height: 36); shortcutStatus!.maximumNumberOfLines = 2; content.addSubview(shortcutStatus!)
        let corner = NSPopUpButton(); corner.addItems(withTitles: ["无", "左上角", "右上角", "左下角", "右下角"]); corner.selectItem(at: prefs.corner); corner.tag = 3; corner.target = self; corner.action = #selector(popupChanged(_:))
        row("触发角", y: 286, control: corner)
        let slider = NSSlider(value: prefs.sensitivity, minValue: 0, maxValue: 1, target: self, action: #selector(sensitivityChanged(_:))); slider.isContinuous = false; slider.setAccessibilityLabel("滚动灵敏度，低到高")
        row("滚动灵敏度  低 → 高", y: 244, control: slider)
        let rows = NSPopUpButton(); rows.addItems(withTitles: (2...8).map(String.init)); rows.selectItem(withTitle: "\(prefs.rows)"); rows.tag = 4; rows.target = self; rows.action = #selector(popupChanged(_:))
        row("网格行数", y: 202, control: rows)
        let columns = NSPopUpButton(); columns.addItems(withTitles: (3...12).map(String.init)); columns.selectItem(withTitle: "\(prefs.columns)"); columns.tag = 5; columns.target = self; columns.action = #selector(popupChanged(_:))
        row("网格列数", y: 160, control: columns)
        row("随系统启动", y: 118, control: check(SMAppService.mainApp.status == .enabled, tag: 6))
        for view in content.subviews { view.frame.origin.y += 100 }
        let mode = NSPopUpButton()
        mode.addItems(withTitles: ["全部应用（默认）", "仅显示已选择的应用"])
        mode.selectItem(at: prefs.onlySelectedApplications == true ? 1 : 0)
        mode.target = self; mode.action = #selector(displayModeChanged(_:))
        mode.setAccessibilityLabel("应用显示模式")
        row("显示内容", y: 164, control: mode)
        let choose = NSButton(title: "选择应用…（已选 \(prefs.selectedApplicationPaths?.count ?? 0) 个）", target: self, action: #selector(chooseApplications))
        choose.bezelStyle = .rounded; selectionButton = choose
        row("应用选择", y: 122, control: choose)
        let note = label("菜单栏始终保留设置入口。方向键、Enter 启动为增强功能。", size: 11, color: .secondaryLabelColor)
        note.frame = NSRect(x: 34, y: 76, width: 550, height: 24); content.addSubview(note)
        let openButton = NSButton(title: "打开启动台", target: self, action: #selector(openFromSettings)); openButton.bezelStyle = .rounded
        openButton.frame = NSRect(x: 430, y: 25, width: 150, height: 34); content.addSubview(openButton)
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
    @objc func displayModeChanged(_ sender: NSPopUpButton) {
        update { $0.onlySelectedApplications = sender.indexOfSelectedItem == 1 }
        sender.selectItem(at: prefs.onlySelectedApplications == true ? 1 : 0)
    }
    @objc func chooseApplications() {
        settings?.orderOut(nil); activeFolder = nil; editingSelection = true; showPad()
    }
    @objc func finishSelection() {
        editingSelection = false
        update { $0.onlySelectedApplications = true }
        // Rebuild settings next time so its mode control reflects the change.
        settings?.close(); settings = nil
        search.stringValue = ""; filtered = displayedCatalog; page = 0; selection = 0; render()
    }
    func folderIcon(_ folder: AppFolder) -> NSImage {
        let visible = folder.paths.filter { prefs.onlySelectedApplications != true || (prefs.selectedApplicationPaths ?? []).contains($0) }
        let members = visible.prefix(9).map { icons[$0] ?? NSWorkspace.shared.icon(forFile: $0) }
        return NSImage(size: NSSize(width: 88, height: 88), flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 88, height: 88), xRadius: 18, yRadius: 18).fill()
            for (index, icon) in members.enumerated() {
                icon.draw(in: NSRect(x: 8 + (index % 3) * 25, y: 57 - (index / 3) * 25, width: 22, height: 22))
            }
            return true
        }
    }

    @objc func closeFolder() {
        activeFolder = nil; search.stringValue = ""; page = 0; selection = 0; filtered = displayedCatalog; render()
    }
    @objc func renameFolder() {
        guard let key = activeFolder else { return }
        let name = folderTitle.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { render(); return }
        update { p in if let i = p.folders?.firstIndex(where: { $0.key == key }) { p.folders![i].name = String(name.prefix(60)) } }
        pad.makeFirstResponder(search)
    }
    @objc func dissolveFolder() {
        guard let key = activeFolder else { return }
        activeFolder = nil
        update { $0.dissolveFolder(key) }
        closeFolder()
    }
    func showFolderHover(target: String, source: String, ready: Bool) {
        guard let tile = tiles.first(where: { $0.record.url.path == target }) else { return }
        tile.showDropPreview()
        dragGhost?.alphaValue = 0.6
    }
    func clearFolderHover() {
        tiles.filter { $0.dropPreview != nil }.forEach { $0.clearDropPreview() }
        if folderHover != nil { dragGhost?.alphaValue = 1 }
        if folderReady {
            tiles.forEach { $0.highlightedSelection = false }
            statusLabel.stringValue = "拖动图标调整位置 · 停在图标中心可组成文件夹"
        }
        folderTimer?.invalidate(); folderTimer = nil; folderHover = nil; folderReady = false
    }
    func animateDragOrder() {
        let positions = Dictionary(uniqueKeysWithValues: dragOrder.enumerated().map { ($0.element, $0.offset) })
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for candidate in tiles {
                if let index = positions[candidate.record.url.path], dragSlots.indices.contains(index) {
                    candidate.animator().frame = dragSlots[index]
                }
            }
        }
    }
    func reorder(_ tile: AppTile, point: NSPoint, ended: Bool) {
        if reorderPath == nil {
            cancelPageAnimation(); reorderPath = tile.record.url.path
            dragOrder = filtered.map { $0.url.path }; dragSlots = tiles.map { $0.frame }
            let ghost = NSImageView(frame: NSRect(x: 0, y: 0, width: 88, height: 88))
            ghost.image = tile.icon; ghost.imageScaling = .scaleProportionallyUpOrDown
            canvas.addSubview(ghost); dragGhost = ghost; tile.alphaValue = 0.25
        }
        guard let source = reorderPath else { return }
        let local = canvas.convert(point, from: nil)
        dragGhost?.frame.origin = NSPoint(x: local.x - 44, y: local.y - 44)
        let location = pageStrip.convert(point, from: nil)
        let capacity = prefs.rows * prefs.columns
        let indices = dragSlots.indices.filter { $0 / capacity == page }
        let closest = indices.min { hypot(dragSlots[$0].midX - location.x, dragSlots[$0].midY - location.y) < hypot(dragSlots[$1].midX - location.x, dragSlots[$1].midY - location.y) }
        if let index = closest, dragOrder.indices.contains(index), grid.frame.contains(local) {
            let target = dragOrder[index]
            let slot = dragSlots[index]
            // A deliberate center hover groups; passing through / slot edges inserts.
            let center = LayoutMath.folderHoverRect(slot)
            let canGroup = activeFolder == nil && prefs.folder(for: source) == nil && source != target && center.contains(location)
            if canGroup {
                insertionTimer?.invalidate(); insertionTimer = nil; insertionTarget = nil
                if folderHover != target {
                    clearFolderHover(); folderHover = target
                    showFolderHover(target: target, source: source, ready: false)
                    folderTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                        guard let self, self.reorderPath == source, self.folderHover == target else { return }
                        self.folderReady = true
                        self.showFolderHover(target: target, source: source, ready: true)
                        self.statusLabel.stringValue = "松开以创建文件夹或加入文件夹"
                    }
                    if let timer = folderTimer { RunLoop.main.add(timer, forMode: .common) }
                }
            } else {
                clearFolderHover()
                if !ended, source != target, insertionTarget != target {
                    insertionTimer?.invalidate(); insertionTarget = target
                    insertionTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
                        guard let self, self.reorderPath == source, self.folderHover == nil,
                              let from = self.dragOrder.firstIndex(of: source), let to = self.dragOrder.firstIndex(of: target) else { return }
                        self.dragOrder.remove(at: from); self.dragOrder.insert(source, at: to)
                        self.animateDragOrder()
                    }
                    if let timer = insertionTimer { RunLoop.main.add(timer, forMode: .common) }
                }
            }
            reorderTarget = target
        } else { clearFolderHover(); insertionTimer?.invalidate(); insertionTimer = nil; insertionTarget = nil }
        // Edge hover continues to use the shared viewport, preserving the live layout.
        let edge = local.x < 45 ? -1 : (local.x > canvas.bounds.width - 45 ? 1 : 0)
        let now = ProcessInfo.processInfo.systemUptime
        if edge != reorderEdge { reorderEdge = edge; reorderEdgeSince = now }
        if !ended && edge != 0 && now - reorderEdgeSince > 0.5 {
            page = LayoutMath.clampedPage(page + edge, items: filtered.count, capacity: capacity)
            setPageOffset(0); reorderEdgeSince = now
        }
        if ended {
            insertionTimer?.invalidate(); insertionTimer = nil; insertionTarget = nil
            let grouping = folderReady ? folderHover : nil
            let order = dragOrder
            let dropTarget = reorderTarget
            let moveOut = activeFolder != nil && folderBack.frame.contains(local)
            clearFolderHover(); dragGhost?.removeFromSuperview(); dragGhost = nil
            reorderPath = nil; reorderTarget = nil; reorderEdge = 0
            tiles.forEach { $0.alphaValue = 1; $0.highlightedSelection = false }
            if moveOut, let key = activeFolder {
                update { $0.removeFromFolder(source, key: key) }
                if prefs.folder(for: key) == nil { closeFolder() }
            } else if grid.frame.contains(local) {
                update { p in
                    if let grouping { p.group(source, onto: grouping, rootOrder: order) }
                    else {
                        var result = order
                        // A quick center drop is insertion, never accidental grouping.
                        if let target = dropTarget, let from = result.firstIndex(of: source), let to = result.firstIndex(of: target), from != to {
                            result.remove(at: from); result.insert(source, at: to)
                        }
                        p.saveOrder(result, inside: activeFolder)
                    }
                }
            } else { render() }
        }
    }
    @objc func openFromSettings() { settings?.orderOut(nil); if prefs.enabled { showPad() } else { showError("启动台已关闭", detail: "请先开启启动台。") } }
    @objc func recordShortcut(_ button: ShortcutRecorder) { button.recording = true; button.title = "按下组合键…"; button.window?.makeFirstResponder(button) }
    @objc func settingToggle(_ button: NSButton) {
        let on = button.state == .on
        if button.tag == 6 {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status == .requiresApproval { showError("需要系统确认", detail: "请在系统设置 → 通用 → 登录项中允许 LaunchDeck。") }
            } catch { showError("无法更改登录项", detail: error.localizedDescription) }
            button.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else { update { if button.tag == 1 { $0.enabled = on } else { $0.showDock = on } } }
    }
    @objc func popupChanged(_ button: NSPopUpButton) {
        update { p in
            switch button.tag { case 3: p.corner = button.indexOfSelectedItem; case 4: p.rows = Int(button.titleOfSelectedItem ?? "5") ?? 5; default: p.columns = Int(button.titleOfSelectedItem ?? "7") ?? 7 }
        }
    }
    @objc func sensitivityChanged(_ slider: NSSlider) { update { $0.sensitivity = slider.doubleValue } }
    func showError(_ title: String, detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        if let window = settings, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    @objc func about() { showError("LaunchDeck 1.0.22", detail: "独立 macOS 应用启动台\n中文、拼音及首字母搜索 · 可配置网格 · 快捷键 · 触发角\n本地处理，不上传应用列表。") }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--startup-test") {
    func launchEvent(_ reason: OSType?, id: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let reason { event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: keyAEPropData) }
        return event
    }
    precondition(!LaunchContext.isBackground(nil))
    precondition(!LaunchContext.isBackground(launchEvent(nil)))
    precondition(LaunchContext.isBackground(launchEvent(keyAELaunchedAsLogInItem)))
    precondition(LaunchContext.isBackground(launchEvent(keyAELaunchedAsServiceItem)))
    precondition(!LaunchContext.isBackground(launchEvent(keyAELaunchedAsLogInItem, id: AEEventID(kAEReopenApplication))))
    print("PASS: login/service startup stays background; manual launch and Dock reopen stay interactive")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") { runTests(); exit(0) }
if CommandLine.arguments.contains("--hover-raster-test") {
    for item in Catalog.scan() {
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        for scale: CGFloat in [1, 2] {
            let raster = hoverRaster(icon, iconSize: 88, backingScale: scale)!
            precondition(raster.width >= Int(ceil(88 * scale * 1.18)))
            precondition(raster.height == raster.width)
        }
    }
    print("PASS: all catalog hover rasters cover maximum animated size at 1x and 2x")
    exit(0)
}
if CommandLine.arguments.contains("--catalog-test") {
    let items = Catalog.scan()
    precondition(!items.isEmpty)
    precondition(Set(items.map { $0.url.path }).count == items.count)
    print("PASS: catalog \(items.count) applications, unique canonical paths")
    print("Chinese query: \(Catalog.search(items, query: "计算").map(\.name))")
    print("Pinyin query: \(Catalog.search(items, query: "jisuan").map(\.name))")
    exit(0)
}
let application = NSApplication.shared
if CommandLine.arguments.contains("--icon"), let path = CommandLine.arguments.last {
    let img = makeIcon(); let bitmap = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)); exit(0)
}
let controller = Controller()
application.delegate = controller
application.run()
