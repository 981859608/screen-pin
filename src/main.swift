import AppKit
import AVFoundation
import Carbon
import CoreImage
import ScreenCaptureKit

// MARK: - 配置

enum Config {
    static let maxPins = 3
    static let fps: Int32 = 30
    static let staleLimit: TimeInterval = 1.5
    static let minPinSize = CGSize(width: 120, height: 80)
    /// 捏合/滚轮缩放的上下限，相对"刚钉住时"的尺寸。放大只是把已经采到的像素摊大，
    /// 再往上就没有细节可给了。
    static let maxZoom: CGFloat = 4
    static let minZoom: CGFloat = 0.4
}

func say(_ message: String) {
    FileHandle.standardError.write("[ScreenPin] \(message)\n".data(using: .utf8)!)
}

// MARK: - 坐标

enum Geo {
    /// Cocoa 全局坐标 y 向上、原点在主屏左下角；CGWindowList 与 SCWindow.frame 的 y 向下、原点在主屏左上角。
    /// 选区矩形要换算成后者才能和窗口矩形对齐。
    static func toGraphics(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toCocoa(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return exact }
        return NSScreen.screens
            .map { ($0.frame.intersection(rect).width * $0.frame.intersection(rect).height, $0) }
            .max { $0.0 < $1.0 }?.1 ?? NSScreen.main
    }
}

// MARK: - 命中选区中心的窗口

struct Target {
    let window: SCWindow
    let screen: NSScreen
    /// 选区相对源窗口左上角的矩形，单位点、y 向下。
    let crop: CGRect

    func resolved(with window: SCWindow) -> Target? {
        let crop = self.crop.intersection(CGRect(origin: .zero, size: window.frame.size))
        guard crop.width >= 12, crop.height >= 12 else { return nil }
        return Target(window: window, screen: Geo.screen(containing: Geo.toCocoa(window.frame)) ?? screen, crop: crop)
    }
}

enum HitTest {
    static func onScreenWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    static func bounds(_ entry: [String: Any]) -> CGRect? {
        guard let raw = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }

    /// 普通层级的最前窗口，跳过自己的窗口（遮罩和小窗）与菜单、提示框等非标层。
    static func normalWindows() -> [(CGWindowID, CGRect)] {
        onScreenWindows().compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let rect = bounds(entry), pid != getpid(), layer == 0
            else { return nil }
            return (CGWindowID(number), rect)
        }
    }

    /// CGWindowList 不需要屏幕录制权限，用它判断源窗口还在不在，比只看帧是否停更可靠：
    /// 画面静止时 ScreenCaptureKit 根本不发新帧，光看帧会误报"源已关闭"。
    static func windowStillOnScreen(_ id: CGWindowID) -> Bool {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let info = CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] else { return false }
        return info.contains { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) == id } ?? false }
    }

    static func target(forCocoa rect: CGRect, content: SCShareableContent) -> Target? {
        let graphics = Geo.toGraphics(rect)
        let center = CGPoint(x: graphics.midX, y: graphics.midY)
        guard let id = normalWindows().first(where: { $0.1.contains(center) })?.0 else {
            say("点到的位置没有普通层级窗口")
            return nil
        }
        // 这里不再检查 SCWindow.isOnScreen：CGWindowList 返回的本来就是在屏窗口，
        // 但同源的 TextEdit 之类窗口在 SCK 清单里 isOnScreen 会是 false，白白拒掉。
        guard let source = content.windows.first(where: { $0.windowID == id }) else {
            say("窗口 \(id) 不在 ScreenCaptureKit 的清单里")
            return nil
        }
        // SCWindow.frame 和 CGWindowList 一样是左上角原点、y 向下的全局坐标，
        // 只有选区（来自 Cocoa）需要换算，这里不能再翻一次 y。
        let owner = source.frame
        let overlap = graphics.intersection(owner)
        guard overlap.width >= 12, overlap.height >= 12, let screen = Geo.screen(containing: rect) else { return nil }
        return Target(window: source, screen: screen,
                      crop: CGRect(x: overlap.minX - owner.minX, y: overlap.minY - owner.minY,
                                   width: overlap.width, height: overlap.height))
    }
}

// MARK: - 帧工具

enum FrameTool {
    static func displayImmediately(_ buffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [Any],
              let dict = attachments.first as? NSMutableDictionary else { return }
        // 不打这个标记，AVSampleBufferDisplayLayer 会按缓冲区自带时钟排帧，凭空加一层延迟。
        dict.setValue(kCFBooleanTrue, forKey: kCMSampleAttachmentKey_DisplayImmediately as String)
    }

    static func sizeOf(_ buffer: CMSampleBuffer) -> CGSize {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return .zero }
        return CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    static func looksBlack(_ buffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let row = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var brightest = 0
        for step in 1...5 {
            let offset = (height / 2) * row + (width * step / 6) * 4
            for channel in 0..<3 {
                brightest = max(brightest, Int(base.load(fromByteOffset: offset + channel, as: UInt8.self)))
            }
        }
        return brightest < 6
    }

    static func writePNG(_ buffer: CMSampleBuffer, to path: String) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 一路捕获

final class Capture: NSObject, SCStreamDelegate, SCStreamOutput {
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onStopped: (() -> Void)?
    private(set) var lastFrameAt = Date()
    private var stream: SCStream?
    private var target: Target?
    private var fps: Int32 = Config.fps
    private let queue = DispatchQueue(label: "screenpin.capture")

    func configuration(for target: Target, fps: Int32 = Config.fps) -> SCStreamConfiguration {
        let scale = target.screen.backingScaleFactor
        let crop = target.crop
        let config = SCStreamConfiguration()
        // 头文件写明：sourceRect 是点（显示器的逻辑坐标系），width/height 是像素。
        config.sourceRect = crop
        config.width = Int(crop.width * scale)
        config.height = Int(crop.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        return config
    }

    func start(target: Target) async throws {
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target.window),
                              configuration: configuration(for: target),
                              delegate: self)
        try await stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lastFrameAt = Date()
        self.target = target
        self.fps = Config.fps
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    /// 小窗被别的窗口挡得完全看不见时降帧，省 CPU 和电。
    func setVisible(_ visible: Bool) {
        guard let stream, let target, visible != (fps == Config.fps) else { return }
        fps = visible ? Config.fps : 5
        stream.updateConfiguration(configuration(for: target, fps: fps), completionHandler: nil)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer) else { return }
        lastFrameAt = Date()
        onFrame?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        say("捕获中断: \(error.localizedDescription)")
        onStopped?()
    }
}

// MARK: - 小窗等比缩放

enum PinScale {
    /// 滚轮一格约 ±15%，触摸板每个滚动单位约 ±1%（精确滚动的事件密、单步小）。
    /// deltaY 为正 = 朝下滚 = 缩小，所以这里是负号；实测方向反了就翻这两个常量的符号。
    static let wheelStep: CGFloat = -0.2
    static let trackpadStep: CGFloat = -0.014

    /// 以 anchor（全局坐标）为不动点把小窗放大/缩小 factor 倍。
    /// 倍率整体夹在最小尺寸、最大倍率和屏幕可见区之间，而不是分别夹宽高——
    /// 分轴夹会改掉长宽比，画面层 resizeAspect 就开始留黑边。
    static func zoomed(_ frame: CGRect, by factor: CGFloat, anchor: CGPoint, base: CGSize, visible: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0, base.width > 0, base.height > 0 else { return frame }
        let lower = max(Config.minPinSize.width / frame.width, Config.minPinSize.height / frame.height,
                        Config.minZoom * base.width / frame.width, Config.minZoom * base.height / frame.height)
        let upper = min(Config.maxZoom * base.width / frame.width, Config.maxZoom * base.height / frame.height,
                        visible.width / frame.width, visible.height / frame.height)
        guard upper >= lower else { return frame }
        let f = min(max(factor, lower), upper)
        guard f != 1 else { return frame }

        var out = CGRect(x: anchor.x - (anchor.x - frame.minX) * f,
                         y: anchor.y - (anchor.y - frame.minY) * f,
                         width: frame.width * f, height: frame.height * f)
        // 贴着屏幕边缘放大时窗口会探出屏幕，整体平移回来（平移不改变倍率）。
        if out.width <= visible.width { out.origin.x = min(max(out.minX, visible.minX), visible.maxX - out.width) }
        else { out.origin.x = visible.midX - out.width / 2 }
        if out.height <= visible.height { out.origin.y = min(max(out.minY, visible.minY), visible.maxY - out.height) }
        else { out.origin.y = visible.midY - out.height / 2 }
        return out
    }
}

// MARK: - 小窗

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 滚轮是投递到"鼠标下方的视图"的，捏合却走 first responder 链；
    /// 小窗是 nonactivating 面板，平时既不是 key 也没有 first responder，捏合事件就半路丢了。
    /// 所以在窗口这一层直接转给内容视图，不要求用户先点一下小窗。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .magnify, let root = contentView as? PinRootView {
            root.magnify(with: event)
            return
        }
        super.sendEvent(event)
    }
}

final class PinRootView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    var onClose: (() -> Void)?
    /// 刚钉住时的尺寸，缩放倍率的基准由它算出。
    var baseSize: CGSize = .zero
    /// 聚焦状态。键盘事件只发给 key 窗口，所以得让用户看得出当前按 Esc 关掉的是哪一个。
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            layer?.borderWidth = isFocused ? Self.focusRing : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            needsLayout = true
        }
    }
    private static let focusRing: CGFloat = 2
    private var tracking: NSTrackingArea?
    private var edge: Edge?
    private var dragStart = CGPoint.zero
    private var frameAtDragStart = CGRect.zero

    private struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1)
        static let right = Edge(rawValue: 2)
        static let top = Edge(rawValue: 4)
        static let bottom = Edge(rawValue: 8)
        static let none = Edge(rawValue: 0)
    }

    private static let band: CGFloat = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.font = .systemFont(ofSize: 11, weight: .bold)
        closeButton.contentTintColor = .white
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = .black
        statusLabel.isHidden = true
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 画面层要留出亮边的宽度，否则会把它整个盖住。
        displayLayer.frame = isFocused ? bounds.insetBy(dx: Self.focusRing, dy: Self.focusRing) : bounds
        closeButton.frame = CGRect(x: bounds.maxX - 20, y: bounds.maxY - 18, width: 20, height: 18)
        statusLabel.frame = CGRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18)
    }

    /// 贴边时不能让 AppKit 抢走这次拖拽去移动窗口，否则缩放和移动会同时发生。
    override var mouseDownCanMoveWindow: Bool {
        guard let window else { return true }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return edge(at: point).isEmpty && !closeButton.frame.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { if edge == nil { closeButton.isHidden = true } }

    private func edge(at point: CGPoint) -> Edge {
        var result: Edge = .none
        if point.x < Self.band { result.insert(.left) }
        if point.x > bounds.maxX - Self.band { result.insert(.right) }
        if point.y > bounds.maxY - Self.band { result.insert(.top) }
        if point.y < Self.band { result.insert(.bottom) }
        return result
    }

    @objc private func closeTapped() { onClose?() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(point) { closeTapped(); return }
        // nonactivating 面板不会自动被点成 key 窗口，而键盘事件只发给 key 窗口的 first responder，
        // 所以点一下小窗时显式聚焦，Esc / ⌘W 才有地方收。
        window?.makeKey()
        window?.makeFirstResponder(self)
        let hit = edge(at: point)
        guard !hit.isEmpty, let window else { super.mouseDown(with: event); return }
        edge = hit
        dragStart = NSEvent.mouseLocation
        frameAtDragStart = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let edge, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStart.x
        let dy = dragStart.y - now.y
        var frame = frameAtDragStart
        if edge.contains(.left) { frame.origin.x += dx }
        if edge.contains(.right) { frame.size.width += dx }
        if edge.contains(.top) { frame.origin.y -= dy; frame.size.height += dy }
        if edge.contains(.bottom) { frame.size.height -= dy }
        if frame.width < Config.minPinSize.width {
            if edge.contains(.left) { frame.origin.x = frameAtDragStart.maxX - Config.minPinSize.width }
            frame.size.width = Config.minPinSize.width
        }
        if frame.height < Config.minPinSize.height {
            if edge.contains(.bottom) { frame.origin.y = frameAtDragStart.maxY - Config.minPinSize.height }
            frame.size.height = Config.minPinSize.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        edge = nil
        super.mouseUp(with: event)
    }

    /// 触摸板双指捏合。magnification 是相对上一个事件的增量（头文件：加到当前缩放系数上），
    /// 这里当作倍率增量连乘到当前 frame，所以手势中途也不会跳。
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, windowPoint: event.locationInWindow)
    }

    /// 滚轮放在小窗上直接缩放，不需要按住修饰键。
    /// 约定朝上滚 = 放大；如果实测方向反了，改 PinScale.wheelStep 的正负号即可。
    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        guard delta != 0 else { super.scrollWheel(with: event); return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? PinScale.trackpadStep : PinScale.wheelStep
        zoom(by: exp2(delta * step), windowPoint: event.locationInWindow)
    }

    private func zoom(by factor: CGFloat, windowPoint: CGPoint?) {
        guard let window, factor != 1 else { return }
        let anchor = windowPoint.map { window.convertPoint(toScreen: $0) } ?? NSEvent.mouseLocation
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.frame ?? window.frame
        let next = PinScale.zoomed(window.frame, by: factor, anchor: anchor, base: baseSize, visible: visible)
        guard next != window.frame else { return }
        window.setFrame(next, display: true)
    }

    /// 普通 NSView 默认不接受键盘焦点，不打开它 keyDown 收不到 Esc / ⌘W。
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            closeTapped()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            closeTapped()
            return
        }
        super.keyDown(with: event)
    }

    func setStatus(_ text: String?) {
        statusLabel.isHidden = text == nil
        statusLabel.stringValue = text ?? ""
    }
}

// MARK: - 一个置顶小窗

final class Pin: NSObject, NSWindowDelegate {
    let panel: PinPanel
    let target: Target
    private let root = PinRootView(frame: .zero)
    private let capture = Capture()
    private var watchdog: Timer?
    private var framesSeen = 0
    private var blackFrames = 0
    private var protected = false
    private let startedAt = Date()
    private(set) var isClosed = false

    init(target: Target) {
        self.target = target
        self.panel = PinPanel(contentRect: CGRect(origin: .zero, size: target.crop.size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()

        panel.contentView = root
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.delegate = self
        panel.initialFirstResponder = root
        panel.setFrame(frameOrigin(target: target), display: false)

        root.baseSize = target.crop.size
        root.onClose = { [weak self] in self?.close() }
        capture.onFrame = { [weak self] buffer in self?.handle(buffer) }
        capture.onStopped = { [weak self] in self?.markStale() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStale() }

        Task { @MainActor in
            do { try await self.capture.start(target: target) }
            catch { say("启动捕获失败: \(error.localizedDescription)") }
        }
    }

    private func frameOrigin(target: Target) -> CGRect {
        let visible = target.screen.visibleFrame
        let size = target.crop.size
        // 选区接近整屏时右上角会算出负坐标，所以夹住左/下边界，别让小窗跑出屏幕。
        return CGRect(x: max(visible.minX, visible.maxX - size.width - 16),
                      y: max(visible.minY, visible.maxY - size.height - 16),
                      width: size.width, height: size.height)
    }

    private func handle(_ buffer: CMSampleBuffer) {
        FrameTool.displayImmediately(buffer)
        let black = FrameTool.looksBlack(buffer)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            if self.framesSeen < 10 {
                self.framesSeen += 1
                if black { self.blackFrames += 1 }
            }
            let renderer = self.root.displayLayer.sampleBufferRenderer
            if renderer.isReadyForMoreMediaData { renderer.enqueue(buffer) }
        }
    }

    private func checkStale() {
        guard !isClosed, !protected else { return }
        if framesSeen == 0 {
            if Date().timeIntervalSince(startedAt) > 2 { root.setStatus("没有画面：权限未授予或该窗口不可捕获") }
            return
        }
        if framesSeen >= 10, blackFrames >= 10 {
            protected = true
            root.setStatus("画面全黑：可能是受保护的视频")
            return
        }
        let silent = Date().timeIntervalSince(capture.lastFrameAt) > Config.staleLimit
        if silent, !HitTest.windowStillOnScreen(target.window.windowID) { root.setStatus("源窗口已关闭") }
        else { root.setStatus(nil) }
    }

    private func markStale() {
        DispatchQueue.main.async { [weak self] in self?.root.setStatus("源窗口已关闭") }
    }

    func restart(with window: SCWindow) {
        guard let next = target.resolved(with: window) else { markStale(); return }
        Task { @MainActor in
            await self.capture.stop()
            try? await self.capture.start(target: next)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        watchdog?.invalidate()
        root.displayLayer.sampleBufferRenderer.flush()
        Task { await capture.stop() }
        panel.orderOut(nil)
        AppController.shared?.pinClosed(self)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        capture.setVisible(panel.occlusionState.contains(.visible))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panel.makeFirstResponder(root)
        root.isFocused = true
    }

    func windowDidResignKey(_ notification: Notification) { root.isFocused = false }
}

// MARK: - 框选遮罩

final class SelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var selection: CGRect?
    private var start: CGPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.appendRect(selection) }
        dim.windingRule = .evenOdd
        dim.fill()

        if let selection {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            "\(Int(selection.width)) × \(Int(selection.height))".draw(
                at: CGPoint(x: selection.minX, y: selection.minY - 16),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                 .foregroundColor: NSColor.white])
        } else {
            let hint = "拖框选中要置顶的区域，单击取消"
            let size = hint.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 40),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                       .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = CGRect(origin: start ?? .zero, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                           width: abs(now.x - start.x), height: abs(now.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selection
        start = nil
        selection = nil
        needsDisplay = true
        guard let rect, rect.width > 12, rect.height > 12, let window else { onCancel?(); return }
        onFinish?(window.convertToScreen(rect))
    }
}

final class SelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false
        contentView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - 全局快捷键

/// 用 Carbon 热键而不是事件监听：Carbon 不额外要"辅助功能"授权就能全局收键。
/// 代价是修饰键只认 command/option/control/shift，没有 Fn——但 Apple 键盘默认把 F1/F2 当亮度键，
/// 按住 fn 才发出真正的 F2 键码，所以注册"无修饰键的 F2"，按 fn+F2 正好触发。
/// （如果系统设置里勾了"将 F1、F2 等键用作标准功能键"，单按 F2 也会触发。）
enum HotKey {
    private static let keycode = UInt32(kVK_F2)
    private static let modifiers = UInt32(0)
    private static var registration: EventHotKeyRef?

    static var onPress: (() -> Void)?

    @discardableResult
    static func install() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyFired, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5350494E), id: 1)   // 'SPIN'
        guard RegisterEventHotKey(keycode, modifiers, id, GetEventDispatcherTarget(), 0, &ref) == noErr,
              let ref else { return false }
        registration = ref
        return true
    }
}

/// Carbon 的回调不能捕获上下文，动作挂在 HotKey.onPress 上；它由主线程事件循环派发。
private func hotKeyFired(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    HotKey.onPress?()
    return noErr
}

// MARK: - 主控制器

final class AppController: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppController?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var selectionWindows: [SelectionWindow] = []
    private var busy = false
    var pins: [Pin] = []

    override init() {
        super.init()
        AppController.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "ScreenPin")
            image?.isTemplate = true
            button.image = image
        }
        HotKey.onPress = { [weak self] in self?.beginSelection() }
        let hotKeyReady = HotKey.install()
        statusItem.menu = buildMenu(hotKeyReady: hotKeyReady)
        if !hotKeyReady { flash("fn+F2 注册失败") }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        say("已启动。菜单栏图标 = 图钉")
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            flash("需要屏幕录制权限，授权后请重开")
        }
    }

    private func buildMenu(hotKeyReady: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "框选新区域" + (hotKeyReady ? "    fn+F2" : ""),
                     action: #selector(beginSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关闭全部小窗", action: #selector(closeAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新申请屏幕录制权限", action: #selector(requestPermission), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ScreenPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        return menu
    }

    @objc private func requestPermission() {
        CGRequestScreenCaptureAccess()
        flash(CGPreflightScreenCaptureAccess() ? "权限已有" : "授权后请退出重开")
    }

    private func flash(_ message: String) {
        say(message)
        guard let button = statusItem.button else { return }
        let original = button.title
        button.title = " " + message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { button.title = original }
    }

    @objc private func beginSelection() {
        guard !busy else { return }
        guard pins.count < Config.maxPins else { flash("最多同时钉 \(Config.maxPins) 个"); return }
        busy = true
        selectionWindows = NSScreen.screens.map { screen in
            let window = SelectionWindow(screen: screen)
            (window.contentView as? SelectionView)?.onFinish = { [weak self] rect in self?.finish(rect) }
            (window.contentView as? SelectionView)?.onCancel = { [weak self] in self?.dismiss() }
            window.orderFrontRegardless()
            return window
        }
    }

    private func dismiss() {
        selectionWindows.forEach { $0.orderOut(nil) }
        selectionWindows = []
        busy = false
    }

    private func finish(_ rect: CGRect) {
        Task { @MainActor in
            defer { self.dismiss() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let target = HitTest.target(forCocoa: rect, content: content) else {
                    self.flash("这里没有可钉住的窗口")
                    return
                }
                let pin = Pin(target: target)
                self.pins.append(pin)
                pin.panel.orderFrontRegardless()
            } catch {
                say("SCShareableContent 失败: \(error.localizedDescription)")
                self.flash("屏幕录制权限不足")
            }
        }
    }

    @objc private func closeAll() {
        pins.forEach { $0.close() }
    }

    func pinClosed(_ pin: Pin) {
        pins.removeAll { $0 === pin }
    }

    @objc private func screensChanged() {
        Task { @MainActor in
            guard !self.pins.isEmpty else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for pin in self.pins {
                if let window = content.windows.first(where: { $0.windowID == pin.target.window.windowID }) {
                    pin.restart(with: window)
                }
            }
        }
    }
}

// MARK: - 构建期自测：确定 sourceRect 的单位与方向

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    var buffer: CMSampleBuffer?
    private let sem = DispatchSemaphore(value: 0)
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, self.buffer == nil else { return }
        self.buffer = buffer
        sem.signal()
    }
    func wait(_ seconds: TimeInterval) -> CMSampleBuffer? {
        sem.wait(timeout: .now() + seconds) == .success ? buffer : nil
    }
}

enum Probe {
    static func run() async {
        say("屏幕录制权限 = \(CGPreflightScreenCaptureAccess())")
        let cgWindows = HitTest.normalWindows()
        say("普通层级窗口 \(cgWindows.count) 个: \(cgWindows.prefix(3).map { "\($0.0)\($0.1)" })")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            say("SCShareableContent 失败: \(error.localizedDescription)")
            exit(2)
        }
        say("SCShareableContent 窗口 \(content.windows.count) 个")

        guard let (id, cgBounds) = cgWindows.first,
              let window = content.windows.first(where: { $0.windowID == id }),
              let screen = Geo.screen(containing: Geo.toCocoa(cgBounds)) else {
            say("snaptest: 两侧窗口清单对不上，无法确定源窗口")
            exit(2)
        }
        let scale = screen.backingScaleFactor
        say("窗口 id=\(id) CG框=\(cgBounds) SC框=\(window.frame) scale=\(scale)")

        let quarter = CGRect(x: 0, y: 0, width: cgBounds.width / 4, height: cgBounds.height / 4)
        let variants: [(String, CGRect?, CGSize)] = [
            ("ref", nil, CGSize(width: cgBounds.width * scale, height: cgBounds.height * scale)),
            ("crop-topleft", quarter, CGSize(width: quarter.width * scale, height: quarter.height * scale)),
        ]

        for (label, rect, outSize) in variants {
            let config = SCStreamConfiguration()
            config.width = Int(outSize.width)
            config.height = Int(outSize.height)
            if let rect { config.sourceRect = rect }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            config.queueDepth = 3
            config.showsCursor = false
            config.capturesAudio = false

            let sink = Sink()
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: sink)
            try? await stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe"))
            do {
                try await stream.startCapture()
                if let buffer = sink.wait(3) {
                    let path = "/tmp/screenpin_\(label.replacingOccurrences(of: "-", with: "_")).png"
                    FrameTool.writePNG(buffer, to: path)
                    say("snaptest [\(label)] rect=\(String(describing: rect)) 输出=\(FrameTool.sizeOf(buffer)) -> \(path)")
                } else {
                    say("snaptest [\(label)] 没收到帧")
                }
                try? await stream.stopCapture()
            } catch {
                say("snaptest [\(label)] 失败: \(error.localizedDescription)")
            }
        }
        exit(0)
    }
}

// MARK: - 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
let arguments = CommandLine.arguments

if arguments.contains("--snaptest") {
    Task { await Probe.run() }
} else if let raw = arguments.first(where: { $0.hasPrefix("--autopin=") })?.dropFirst("--autopin=".count) {
    let numbers = raw.split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4 else {
        say("autopin 参数应为 --autopin=x,y,w,h（Cocoa 全局坐标，单位点）")
        exit(2)
    }
    let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    Task { @MainActor in
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let content, let target = HitTest.target(forCocoa: rect, content: content) else {
            say("autopin: 找不到窗口 \(rect)")
            exit(2)
        }
        let pin = Pin(target: target)
        controller.pins.append(pin)
        pin.panel.orderFrontRegardless()
        say("autopin 已钉住 \(rect)")
    }
}

app.run()
