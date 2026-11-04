import AppKit
import AVFoundation
import Carbon
import CoreImage
import ScreenCaptureKit

// MARK: - 配置

enum Config {
    static let maxPins = 3
    static let staleLimit: TimeInterval = 1.5
    static let minPinSize = CGSize(width: 24, height: 16)
    /// 捏合/滚轮缩放的上下限，相对"刚钉住时"的尺寸。放大只是把已经采到的像素摊大，
    /// 再往上就没有细节可给了。
    static let maxZoom: CGFloat = 4
    static let minZoom: CGFloat = 0.08
    /// 帧率只给这几个档位：小于 15 明显卡顿，大于 120 采集端也不会有更多帧。
    static let fpsChoices: [Int32] = [15, 24, 30, 60, 120]
    /// 框选矩形的最小边长，也是"这算不算一次有效框选"的门槛；再小就误触了。
    static let minSelectionSide: CGFloat = 12
    static let handleSize: CGFloat = 6
    /// 手柄的命中半径比画出来的方块大一圈，不然很难点中。
    static let handleHit: CGFloat = 9
}

/// 用户可改的偏好，直接落在 UserDefaults 上。键名改了老用户的设置会丢，所以别动。
/// 读的时候都用 object 判一下有没有存过，否则 bool 的"没存过"会被当成 false，默认值就写不进去了。
enum Prefs {
    private static let d = UserDefaults.standard

    private static func flag(_ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
    }

    /// 双击跳回源 App 之后是否顺手关掉这颗小窗。
    static var closeOnReveal: Bool {
        get { flag("closeOnReveal", true) }
        set { d.set(newValue, forKey: "closeOnReveal") }
    }

    /// 按原屏幕的像素密度采集（Retina 上是 2 倍像素）。关掉后帧只有逻辑尺寸，省 CPU 但会糊。
    static var nativePixels: Bool {
        get { flag("nativePixels", true) }
        set { d.set(newValue, forKey: "nativePixels") }
    }

    static var fps: Int32 {
        get { d.object(forKey: "fps") == nil ? 60 : Int32(max(1, d.integer(forKey: "fps"))) }
        set { d.set(Int(newValue), forKey: "fps") }
    }
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

    /// 把矩形整体平移回 visible 内；比可见区还大就居中。只平移，不动尺寸。
    static func clamp(_ rect: CGRect, into visible: CGRect) -> CGRect {
        var out = rect
        out.origin.x = out.width <= visible.width ? min(max(out.minX, visible.minX), visible.maxX - out.width)
                                                 : visible.midX - out.width / 2
        out.origin.y = out.height <= visible.height ? min(max(out.minY, visible.minY), visible.maxY - out.height)
                                                   : visible.midY - out.height / 2
        return out
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
        guard crop.width >= Config.minSelectionSide, crop.height >= Config.minSelectionSide else { return nil }
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
        guard overlap.width >= Config.minSelectionSide, overlap.height >= Config.minSelectionSide,
              let screen = Geo.screen(containing: rect) else { return nil }
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
    private var fps: Int32 = Prefs.fps
    private let queue = DispatchQueue(label: "screenpin.capture")

    func configuration(for target: Target, fps: Int32 = Prefs.fps) -> SCStreamConfiguration {
        let scale = Prefs.nativePixels ? target.screen.backingScaleFactor : 1
        let crop = target.crop
        let config = SCStreamConfiguration()
        // 头文件写明：sourceRect 是点（显示器的逻辑坐标系），width/height 是像素。
        // 取整用四舍五入而不是截断：小窗的长宽比是按 sourceRect 的点尺寸定的，
        // 帧的像素尺寸越贴近它，resizeAspect 越不会补出黑边。
        config.sourceRect = crop
        config.width = Int((crop.width * scale).rounded())
        config.height = Int((crop.height * scale).rounded())
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
        self.fps = Prefs.fps
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    /// 小窗被别的窗口挡得完全看不见时降帧，省 CPU 和电。
    func setVisible(_ visible: Bool) {
        guard let stream, let target, visible != (fps == Prefs.fps) else { return }
        fps = visible ? Prefs.fps : 5
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

    /// 倍率的合法区间：上下限都按"刚钉住时的尺寸"来定，所以倍率是唯一的自由度。
    static func clamp(_ zoom: CGFloat, base: CGSize, visible: CGRect) -> CGFloat {
        let lower = max(Config.minPinSize.width / base.width, Config.minPinSize.height / base.height, Config.minZoom)
        let upper = min(Config.maxZoom, visible.width / base.width, visible.height / base.height)
        guard upper > lower else { return lower }
        return min(max(zoom, lower), upper)
    }

    /// 把小窗摆成 base × zoom 的尺寸，并让 anchor（全局坐标）在小窗内的相对位置保持不变。
    /// 尺寸一律从 base 算、不从当前 frame 反推：当前 frame 已经被屏幕像素网格取整过，
    /// 反复放大缩小时那点零头会累成长宽比偏差，resizeAspect 就冒出黑边。
    static func frame(base: CGSize, zoom: CGFloat, anchor: CGPoint, inside current: CGRect, visible: CGRect) -> CGRect {
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        guard current.width > 0, current.height > 0 else { return CGRect(origin: current.origin, size: size) }
        let out = CGRect(x: anchor.x - (anchor.x - current.minX) / current.width * size.width,
                         y: anchor.y - (anchor.y - current.minY) / current.height * size.height,
                         width: size.width, height: size.height)
        // 贴边放大时会探出屏幕，整体平移回来——平移不动尺寸，也就不动长宽比。
        return Geo.clamp(out, into: visible)
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
    /// 双击小窗时跳回源 App。
    var onReveal: (() -> Void)?
    /// 刚钉住时的尺寸，缩放倍率的基准由它算出。
    var baseSize: CGSize = .zero
    /// 相对 baseSize 的倍率。尺寸一律由 baseSize × 倍率得出，不从当前 frame 反推。
    private var zoomLevel: CGFloat = 1
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
        // 小窗可以缩得很小，按钮得跟着缩：一颗固定 20pt 的 ✕ 会盖住整块画面，
        // 鼠标一碰就误关，而且那时已经没有地方能按住拖动了。
        let side = max(6, min(bounds.width * 0.5, bounds.height * 0.5, 20))
        closeButton.font = .systemFont(ofSize: max(6, min(11, side * 0.6)), weight: .bold)
        closeButton.frame = CGRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
        statusLabel.frame = CGRect(x: 0, y: bounds.midY - 9, width: bounds.width, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    @objc private func closeTapped() { onClose?() }

    override func mouseDown(with event: NSEvent) {
        if closeButton.frame.contains(convert(event.locationInWindow, from: nil)) { closeTapped(); return }
        // 双击的判定靠第二下的 clickCount == 2；这里直接返回，不再往下走拖动，
        // 否则跳回源 App 的同时还会顺手把小窗拽偏一点。
        if event.clickCount >= 2 { onReveal?(); return }
        // nonactivating 面板不会自动被点成 key 窗口，而键盘事件只发给 key 窗口的 first responder，
        // 所以点一下小窗时显式聚焦，Esc / ⌘W 才有地方收。
        window?.makeKey()
        window?.makeFirstResponder(self)
        // 交给 AppKit 的 isMovableByWindowBackground：鼠标按在画面任意处都能直接拖走。
        super.mouseDown(with: event)
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
        guard let window, factor != 1, baseSize.width > 0, baseSize.height > 0 else { return }
        let anchor = windowPoint.map { window.convertPoint(toScreen: $0) } ?? NSEvent.mouseLocation
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.frame ?? window.frame
        zoomLevel = PinScale.clamp(zoomLevel * factor, base: baseSize, visible: visible)
        let next = PinScale.frame(base: baseSize, zoom: zoomLevel, anchor: anchor, inside: window.frame, visible: visible)
        guard next != window.frame else { return }
        window.setFrame(next, display: true)
    }

    /// 重新钉住时（换屏幕、源窗口自己改了尺寸）裁剪尺寸变了但小窗尺寸没变，
    /// 把当前实际尺寸认作新的 1x 基线。基线必须对齐实际尺寸，
    /// 否则下一次缩放会把窗口硬拽回旧基线算出来的尺寸。
    func resetZoomBaseline() {
        guard let window else { return }
        baseSize = window.frame.size
        zoomLevel = 1
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
        root.onReveal = { [weak self] in self?.revealSource() }
        capture.onFrame = { [weak self] buffer in self?.handle(buffer) }
        capture.onStopped = { [weak self] in self?.markStale() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStale() }

        Task { @MainActor in
            do { try await self.capture.start(target: target) }
            catch { say("启动捕获失败: \(error.localizedDescription)") }
        }
    }

    private func frameOrigin(target: Target) -> CGRect {
        // 钉在选区原来就在的位置：小窗看起来是"就地变成一块实时画面"，不会跳到屏幕右上角。
        // crop 是相对源窗口左上角的、y 向下的量，所以要拼回全局坐标再翻成 Cocoa 的左下角原点。
        let owner = target.window.frame
        let graphics = CGRect(x: owner.minX + target.crop.minX, y: owner.minY + target.crop.minY,
                              width: target.crop.width, height: target.crop.height)
        return CGRect(origin: Geo.toCocoa(graphics).origin, size: target.crop.size)
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
        root.resetZoomBaseline()
        Task { @MainActor in
            await self.capture.stop()
            try? await self.capture.start(target: next)
        }
    }

    /// 双击小窗跳回源 App：把它调到前台，屏幕焦点回到原来那块内容所在的软件上。
    /// 走 NSRunningApplication 而不是 Accessibility API，后者要额外申请"辅助功能"授权，
    /// 为一个跳转动作多要一个权限不值得。
    /// 命中选区中心时取的就是那个位置最靠前的普通层窗口，所以把该 App 调到前台后，
    /// 露出来的正是当初框住的那一页。
    private func revealSource() {
        let pid = target.window.owningApplication?.processID ?? 0
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else {
            say("跳转失败：源 App 已退出（pid \(pid)）")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate(options: [])
        // 跳回去之后这颗小窗通常就没用了（它盖住的正是那块内容），所以默认关掉；设置里可以关这个行为。
        if Prefs.closeOnReveal { close() }
    }

    /// 质量相关的偏好改了要重建这一路捕获。
    /// 不走 restart(with:)：那条会把缩放基线重置回 1x，用户会看到小窗尺寸突然跳一下。
    func reconfigure() {
        guard !isClosed else { return }
        let target = self.target
        Task { @MainActor in
            await self.capture.stop()
            try? await self.capture.start(target: target)
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

/// 选区的 8 个调节手柄。命名按屏幕视觉方向（n 是上边），Cocoa 坐标里上边是 maxY。
enum ResizeHandle: CaseIterable {
    case nw, n, ne, e, se, s, sw, w

    var movesMinX: Bool { self == .nw || self == .w || self == .sw }
    var movesMaxX: Bool { self == .ne || self == .e || self == .se }
    var movesMinY: Bool { self == .sw || self == .s || self == .se }
    var movesMaxY: Bool { self == .nw || self == .n || self == .ne }

    /// 手柄画在哪儿，也用来算命中距离。
    static func center(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .nw: return CGPoint(x: rect.minX, y: rect.maxY)
        case .n: return CGPoint(x: rect.midX, y: rect.maxY)
        case .ne: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .e: return CGPoint(x: rect.maxX, y: rect.midY)
        case .se: return CGPoint(x: rect.maxX, y: rect.minY)
        case .s: return CGPoint(x: rect.midX, y: rect.minY)
        case .sw: return CGPoint(x: rect.minX, y: rect.minY)
        case .w: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// 角优先：角同时也是两条边的端点，先试边就会把"拉角"误判成"只动一条边"。
    static func hit(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> ResizeHandle? {
        for handle in [ResizeHandle.nw, .ne, .se, .sw] {
            let center = self.center(handle, in: rect)
            let dx = point.x - center.x, dy = point.y - center.y
            if dx * dx + dy * dy <= tolerance * tolerance { return handle }
        }
        let slack = tolerance + max(rect.width, rect.height) / 2
        for handle in [ResizeHandle.n, .e, .s, .w] {
            switch handle {
            case .n: if abs(point.y - rect.maxY) <= tolerance, abs(point.x - rect.midX) <= slack { return handle }
            case .s: if abs(point.y - rect.minY) <= tolerance, abs(point.x - rect.midX) <= slack { return handle }
            case .w: if abs(point.x - rect.minX) <= tolerance, abs(point.y - rect.midY) <= slack { return handle }
            case .e: if abs(point.x - rect.maxX) <= tolerance, abs(point.y - rect.midY) <= slack { return handle }
            default: break
            }
        }
        return nil
    }

    /// 以对角/对边为锚把这条边拖到 point。拉过锚点就停在最小边长，不翻转成反向矩形。
    func resize(_ rect: CGRect, to point: CGPoint, minSide: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if movesMinX { minX = min(point.x, maxX - minSide) }
        if movesMaxX { maxX = max(point.x, minX + minSide) }
        if movesMinY { minY = min(point.y, maxY - minSide) }
        if movesMaxY { maxY = max(point.y, minY + minSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var cursor: NSCursor {
        switch self {
        case .nw, .se: return SelectionCursor.northwestSoutheast
        case .ne, .sw: return SelectionCursor.northeastSouthwest
        case .e, .w: return .resizeLeftRight
        case .n, .s: return .resizeUpDown
        }
    }
}

/// macOS 没提供对角方向的拉伸光标，两个对角各画一枚 16×16 的双头箭头。
enum SelectionCursor {
    static let northwestSoutheast = arrow(from: CGPoint(x: 3.5, y: 12.5), to: CGPoint(x: 12.5, y: 3.5))
    static let northeastSouthwest = arrow(from: CGPoint(x: 3.5, y: 3.5), to: CGPoint(x: 12.5, y: 12.5))

    private static func arrow(from a: CGPoint, to b: CGPoint) -> NSCursor {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let ux = dx / length, uy = dy / length
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        for (tip, sign) in [(a, -1.0), (b, 1.0)] {
            for angle in [0.44, -0.44] {
                let wx = (ux * sign * CGFloat(cos(angle)) - uy * sign * CGFloat(sin(angle))) * 4.5
                let wy = (ux * sign * CGFloat(sin(angle)) + uy * sign * CGFloat(cos(angle))) * 4.5
                path.move(to: tip)
                path.line(to: CGPoint(x: tip.x + wx, y: tip.y + wy))
            }
        }
        path.lineWidth = 3
        NSColor.white.setStroke()
        path.stroke()
        path.lineWidth = 1.4
        NSColor.black.setStroke()
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: CGPoint(x: 8, y: 8))
    }
}

/// 纯几何排版，不碰屏幕和字体，`--seltest` 可以直接算。
enum SelectionLayout {
    static let pillWidth: CGFloat = 64
    static let pillHeight: CGFloat = 26
    static let gap: CGFloat = 8
    static let offset: CGFloat = 12

    /// 遮罩窗的 frame 恰好等于所在屏的 frame，所以 view-local 就是全局减去屏原点。
    static func toLocal(_ rect: CGRect, origin: CGPoint) -> CGRect {
        rect.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    static func toGlobal(_ rect: CGRect, origin: CGPoint) -> CGRect {
        rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    static func toLocal(_ point: CGPoint, origin: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// 确定/取消这一组按钮优先放在选区下方、右端与选区对齐；下方放不下就翻到上方，
    /// 再放不下落进选区内部底边。available 是"选区底边中点所在那块屏"的 frame，
    /// 所以整组按钮始终在一块屏上、也始终点得到。
    static func pills(rect: CGRect, in available: CGRect) -> (ok: CGRect, cancel: CGRect) {
        let group = pillWidth * 2 + gap
        let x = min(max(rect.maxX - group, available.minX + 4),
                    max(available.maxX - 4 - group, available.minX + 4))
        let candidates = [rect.minY - offset - pillHeight, rect.maxY + offset, rect.minY + offset]
        let y = candidates.first { $0 >= available.minY + 4 && $0 + pillHeight <= available.maxY - 4 }
            ?? max(available.minY + 4, min(candidates[0], available.maxY - 4 - pillHeight))
        return (CGRect(x: x, y: y, width: pillWidth, height: pillHeight),
                CGRect(x: x + pillWidth + gap, y: y, width: pillWidth, height: pillHeight))
    }
}

/// 选区状态存在 view 之外：遮罩是每块屏一个窗，矩形却能跨屏拖，
/// 状态挂在某个 view 上时另一块屏的遮罩既画不出来也接不住拖拽。
/// 这里一律用 Cocoa 全局坐标，view 只负责换算成本地矩形。
final class SelectionModel {
    enum Phase { case drawing, adjusting }
    enum DragMode { case move, resize(ResizeHandle) }

    var phase: Phase = .drawing
    private(set) var rect: CGRect?
    private(set) var pills: (ok: CGRect, cancel: CGRect)?
    var hint: String?
    var pending = false
    /// 每次确认自增：屏幕清单是异步取的，回来时对不上号就说明用户已经改过或取消了，这一枪不能放。
    private(set) var session = 0
    private var drag: (mode: DragMode, start: CGPoint, origin: CGRect)?
    private var drawStart: CGPoint?

    var screenFrame: ((CGRect) -> CGRect)?
    var onLayout: (() -> Void)?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    func startDraw(at point: CGPoint) {
        phase = .drawing
        rect = CGRect(origin: point, size: .zero)
        drawStart = point
        pills = nil
        hint = nil
        drag = nil
        onLayout?()
    }

    func dragDraw(to point: CGPoint) {
        guard let start = drawStart else { return }
        rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                      width: abs(point.x - start.x), height: abs(point.y - start.y))
        onLayout?()
    }

    /// 松手：够大就进入调整态，太小按"单击"处理。
    func endDraw(minSide: CGFloat) -> Bool {
        drawStart = nil
        guard let rect, rect.width > minSide, rect.height > minSide else { return false }
        phase = .adjusting
        relayout()
        onLayout?()
        return true
    }

    func beginAdjust(_ mode: DragMode, at point: CGPoint) {
        guard let rect, phase == .adjusting else { return }
        drag = (mode, point, rect)
    }

    func dragAdjust(to point: CGPoint) {
        guard let drag else { return }
        switch drag.mode {
        case .resize(let handle):
            rect = handle.resize(drag.origin, to: point, minSide: Config.minSelectionSide)
        case .move:
            let moved = drag.origin.offsetBy(dx: point.x - drag.start.x, dy: point.y - drag.start.y)
            // 以"选区中心落在哪块屏"决定它属于哪块屏：跨过中线才整体挪过去，
            // 不会出现一半卡在两块屏之间的黑区里。
            let host = screenFrame?(CGRect(x: moved.midX, y: moved.midY, width: 1, height: 1)) ?? moved
            rect = Geo.clamp(moved, into: host)
        }
        relayout()
        onLayout?()
    }

    func endAdjust() {
        drag = nil
    }

    var isAdjusting: Bool { phase == .adjusting && rect != nil && drag == nil }

    func beginSession() -> Int {
        session += 1
        return session
    }

    func fail(_ message: String) {
        pending = false
        hint = message
        onLayout?()
    }

    private func relayout() {
        guard let rect, phase == .adjusting else { pills = nil; return }
        hint = nil
        let host = screenFrame?(CGRect(x: rect.midX, y: rect.minY, width: 1, height: 1)) ?? rect
        pills = SelectionLayout.pills(rect: rect, in: host)
    }
}

final class SelectionView: NSView {
    var model: SelectionModel?
    private var pushedCursor = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// view-local → 全局：遮罩窗覆盖整块屏，所以就是加回屏原点。
    private var screenOrigin: CGPoint { window?.frame.origin ?? .zero }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x + screenOrigin.x, y: local.y + screenOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        NSColor.black.withAlphaComponent(0.35).setFill()
        let dim = NSBezierPath(rect: bounds)
        let selection = model.rect.map { SelectionLayout.toLocal($0, origin: screenOrigin) }
        if let selection { dim.appendRect(selection) }
        dim.windingRule = .evenOdd
        dim.fill()

        guard let selection else {
            let hint = "拖框选中要置顶的区域，松手后可继续调整"
            let size = hint.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 40),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                       .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            return
        }

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        let sizeText = "\(Int(selection.width)) × \(Int(selection.height))"
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        // 调整态下选区下方要留给按钮，尺寸数字挪到左上角，免得两样东西叠在一起。
        let labelY = model.phase == .drawing ? selection.minY - 16 : selection.maxY + 4
        sizeText.draw(at: CGPoint(x: selection.minX, y: labelY), withAttributes: sizeAttrs)
        guard model.phase == .adjusting else { return }

        let side = Config.handleSize
        NSColor.white.setFill()
        for handle in ResizeHandle.allCases {
            let center = SelectionLayout.toLocal(ResizeHandle.center(handle, in: model.rect ?? .zero),
                                                 origin: screenOrigin)
            NSBezierPath(rect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)).fill()
        }
        guard let pills = model.pills else { return }
        let ok = SelectionLayout.toLocal(pills.ok, origin: screenOrigin)
        let cancel = SelectionLayout.toLocal(pills.cancel, origin: screenOrigin)
        drawPill("确定", in: ok, filled: true)
        drawPill("取消", in: cancel, filled: false)
        if let hint = model.hint {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.systemRed,
            ]
            let size = hint.size(withAttributes: attrs)
            // 提示写在按钮组左边：这一行只在失败时出现，插在按钮和选区之间会跟选区边框叠在一起。
            let x = max(ok.minX - 10 - size.width, bounds.minX + 4)
            hint.draw(at: CGPoint(x: x, y: ok.midY - size.height / 2), withAttributes: attrs)
        }
    }

    private func drawPill(_ title: String, in rect: CGRect, filled: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if filled {
            NSColor.white.withAlphaComponent(0.95).setFill()
            path.fill()
        } else {
            NSColor.white.withAlphaComponent(0.22).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: filled ? NSColor.black.withAlphaComponent(0.85) : NSColor.white,
        ]
        let size = title.size(withAttributes: attrs)
        title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = globalPoint(event)
        guard let rect = model.rect, model.phase == .adjusting else {
            model.startDraw(at: point)
            return
        }
        if model.pending { return }
        if let pills = model.pills {
            if pills.ok.contains(point) { model.onFinish?(rect); return }
            if pills.cancel.contains(point) { model.onCancel?(); return }
        }
        // 双击选区内部等同于点「确定」：这套遮罩不抢键盘焦点，所以确认只给鼠标。
        if event.clickCount >= 2, rect.contains(point) { model.onFinish?(rect); return }
        if let handle = ResizeHandle.hit(point, in: rect, tolerance: Config.handleHit) {
            model.beginAdjust(.resize(handle), at: point)
            handle.cursor.push()
            pushedCursor = true
            return
        }
        if rect.contains(point) {
            model.beginAdjust(.move, at: point)
            NSCursor.openHand.push()
            pushedCursor = true
            return
        }
        // 框外按下：重新框选；接着单击（没拖出尺寸）就是取消整个取框。
        model.startDraw(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = globalPoint(event)
        switch model.phase {
        case .drawing: model.dragDraw(to: point)
        case .adjusting: model.dragAdjust(to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        switch model.phase {
        case .drawing:
            if !model.endDraw(minSide: Config.minSelectionSide) { model.onCancel?() }
        case .adjusting:
            model.endAdjust()
        }
    }

    /// 光标形状走 AppKit 的 cursor rect：遮罩窗不是 key window，mouseMoved 本来就不保证送到这儿。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
        guard let model, model.isAdjusting, let rect = model.rect else { return }
        let local = SelectionLayout.toLocal(rect, origin: screenOrigin)
        addCursorRect(local, cursor: .openHand)
        if let pills = model.pills {
            addCursorRect(SelectionLayout.toLocal(pills.ok, origin: screenOrigin), cursor: .pointingHand)
            addCursorRect(SelectionLayout.toLocal(pills.cancel, origin: screenOrigin), cursor: .pointingHand)
        }
        let reach = Config.handleHit
        for handle in ResizeHandle.allCases {
            let center = SelectionLayout.toLocal(ResizeHandle.center(handle, in: rect), origin: screenOrigin)
            addCursorRect(CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2),
                          cursor: handle.cursor)
        }
    }
}

/// 遮罩故意不做 key 窗口：一做就会把键盘焦点从被框选的 App 那儿抢走，
/// 带"失焦就暂停"内容的窗口会闪一下。`Esc` 因此走全局热键，见 HotKey.installEscape。
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

// MARK: - 设置窗口

/// 代码搭的小表单，不引 xib 也不引 SwiftUI：保持单文件、只链系统框架。
final class SettingsWindow: NSWindow {
    private let closeOnRevealToggle = NSButton(checkboxWithTitle: "双击跳回主应用后自动关闭小窗", target: nil, action: nil)
    private let nativePixelsToggle = NSButton(checkboxWithTitle: "像素与原屏幕一致（高清）", target: nil, action: nil)
    private let fpsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsLabel = NSTextField(labelWithString: "帧率")
    private let note = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 460, height: 200),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "ScreenPin 设置"
        isReleasedWhenClosed = false
        // 普通窗口会被自己那些置顶小窗盖住（它们在屏蔽层之上），设置窗也得浮起来才点得到。
        level = .floating

        closeOnRevealToggle.target = self
        closeOnRevealToggle.action = #selector(closeOnRevealChanged(_:))
        nativePixelsToggle.target = self
        nativePixelsToggle.action = #selector(nativePixelsChanged(_:))
        fpsPopUp.target = self
        fpsPopUp.action = #selector(fpsChanged(_:))
        fpsPopUp.addItems(withTitles: Config.fpsChoices.map { String($0) })

        note.stringValue = "改帧率或高清像素会立刻重启已有小窗的画面，小窗的尺寸和缩放不变。"
            + "屏幕本身只有 60Hz 时，选 120 也不会多出帧来。"
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420

        let fpsRow = NSStackView(views: [fpsLabel, fpsPopUp])
        fpsRow.orientation = .horizontal
        fpsRow.spacing = 8

        let stack = NSStackView(views: [Self.heading("交互"), closeOnRevealToggle,
                                        Self.heading("质量配置"), nativePixelsToggle, fpsRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: closeOnRevealToggle)
        stack.setCustomSpacing(16, after: fpsRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])

        syncFromPrefs()
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func syncFromPrefs() {
        closeOnRevealToggle.state = Prefs.closeOnReveal ? .on : .off
        nativePixelsToggle.state = Prefs.nativePixels ? .on : .off
        fpsPopUp.selectItem(at: Config.fpsChoices.firstIndex(of: Prefs.fps) ?? Config.fpsChoices.count - 1)
    }

    @objc private func closeOnRevealChanged(_ sender: NSButton) { Prefs.closeOnReveal = sender.state == .on }

    @objc private func nativePixelsChanged(_ sender: NSButton) {
        Prefs.nativePixels = sender.state == .on
        AppController.shared?.applyQualityToPins()
    }

    @objc private func fpsChanged(_ sender: NSPopUpButton) {
        Prefs.fps = Config.fpsChoices[max(0, min(sender.indexOfSelectedItem, Config.fpsChoices.count - 1))]
        AppController.shared?.applyQualityToPins()
    }
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
    private static var escapeRegistration: EventHotKeyRef?

    static var onPress: (() -> Void)?
    /// `Esc` 只在取框那几秒里归我们，平时不抢：全局热键会吃掉按键，源 App 就收不到了。
    static var onEscape: (() -> Void)?

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

    /// 遮罩不是 key 窗口（那样会把源 App 的键盘焦点抢走），所以 `Esc` 只能走全局热键这一条路，
    /// 好处是不需要辅助功能授权，代价是只在取框期间生效。
    @discardableResult
    static func installEscape() -> Bool {
        guard escapeRegistration == nil else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5350494E), id: 2)
        guard RegisterEventHotKey(UInt32(kVK_Escape), modifiers, id, GetEventDispatcherTarget(), 0, &ref) == noErr,
              let ref else { return false }
        escapeRegistration = ref
        return true
    }

    static func removeEscape() {
        if let escapeRegistration { UnregisterEventHotKey(escapeRegistration) }
        escapeRegistration = nil
    }
}

/// Carbon 的回调不能捕获上下文，动作挂在 HotKey.onPress / onEscape 上；它由主线程事件循环派发。
private func hotKeyFired(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                 nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    if read == noErr && hotKeyID.id == 2 {
        HotKey.onEscape?()
    } else {
        HotKey.onPress?()
    }
    return noErr
}

// MARK: - 主控制器

final class AppController: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppController?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var selectionWindows: [SelectionWindow] = []
    private var selectionModel: SelectionModel?
    private var settingsWindow: SettingsWindow?
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
        HotKey.onEscape = { [weak self] in self?.cancelSelection() }
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
        // 开发用：不用点菜单栏就能把设置窗打开，方便截图核对排版。
        if CommandLine.arguments.contains("--settings") { showSettings() }
        // 开发用：直接把遮罩开到调整态，截图核对选区、手柄和按钮的排版。
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--selshow=") })?
            .dropFirst("--selshow=".count) {
            let numbers = raw.split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 4 else {
                say("selshow 参数应为 --selshow=x,y,w,h（Cocoa 全局坐标，单位点）")
                return
            }
            showSelection(rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        }
    }

    private func buildMenu(hotKeyReady: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "框选新区域" + (hotKeyReady ? "    fn+F2" : ""),
                     action: #selector(beginSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关闭全部小窗", action: #selector(closeAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新申请屏幕录制权限", action: #selector(requestPermission), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ScreenPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        return menu
    }

    @objc private func requestPermission() {
        CGRequestScreenCaptureAccess()
        flash(CGPreflightScreenCaptureAccess() ? "权限已有" : "授权后请退出重开")
    }

    @objc private func showSettings() {
        let window = settingsWindow ?? SettingsWindow()
        settingsWindow = window
        window.syncFromPrefs()
        window.center()
        // accessory 应用没有主菜单，窗口不主动 activate 会只是冒出来、拿不到键盘焦点。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 质量项（像素密度、帧率）改了，让所有在跑的小窗立刻按新配置重建捕获。
    func applyQualityToPins() { pins.forEach { $0.reconfigure() } }

    private func flash(_ message: String) {
        say(message)
        guard let button = statusItem.button else { return }
        let original = button.title
        button.title = " " + message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { button.title = original }
    }

    /// 开发用：直接跳到调整态并画上给定选区，让没有真实鼠标的机器也能截图核对排版。
    func showSelection(rect: CGRect) {
        beginSelection()
        guard let model = selectionModel else { return }
        model.startDraw(at: rect.origin)
        model.dragDraw(to: CGPoint(x: rect.maxX, y: rect.maxY))
        guard model.endDraw(minSide: Config.minSelectionSide) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if !HitTest.normalWindows().contains(where: { $0.1.contains(center) }) {
            model.fail("这里没有可钉住的窗口")
        }
    }

    @objc private func beginSelection() {
        guard !busy else { return }
        guard pins.count < Config.maxPins else { flash("最多同时钉 \(Config.maxPins) 个"); return }
        busy = true
        let model = SelectionModel()
        model.screenFrame = { rect in (Geo.screen(containing: rect) ?? NSScreen.main)?.frame ?? rect }
        model.onLayout = { [weak self] in self?.refreshSelectionOverlay() }
        model.onFinish = { [weak self] rect in self?.confirm(rect) }
        model.onCancel = { [weak self] in self?.dismiss() }
        selectionModel = model
        selectionWindows = NSScreen.screens.map { screen in
            let window = SelectionWindow(screen: screen)
            (window.contentView as? SelectionView)?.model = model
            window.orderFrontRegardless()
            return window
        }
        // 取框这几秒里把 Esc 借过来当取消键；注册失败也只是退回"点按钮取消"，不影响主流程。
        if !HotKey.installEscape() { say("Esc 热键注册失败，取消只能点按钮或单击框外") }
    }

    /// 选区一变，每块屏上的遮罩都要重画，光标区域也要跟着重新登记。
    private func refreshSelectionOverlay() {
        for window in selectionWindows {
            guard let view = window.contentView else { continue }
            view.needsDisplay = true
            window.invalidateCursorRects(for: view)
        }
    }

    private func dismiss() {
        HotKey.removeEscape()
        selectionWindows.forEach { $0.orderOut(nil) }
        selectionWindows = []
        selectionModel = nil
        busy = false
    }

    /// 全局热键是常驻回调，取框已经结束时收到的那一次要丢掉，不能顺手关掉别的东西。
    private func cancelSelection() {
        guard busy, selectionModel != nil else { return }
        dismiss()
    }

    /// 确认截取：命中失败时不关遮罩、不清选区，只把原因写在按钮旁边，让用户接着改。
    private func confirm(_ rect: CGRect) {
        guard let model = selectionModel, !model.pending else { return }
        model.pending = true
        let session = model.beginSession()
        Task { @MainActor in
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard self.selectionModel === model, model.session == session else { return }
            guard let content else {
                model.fail("屏幕录制权限不足，授权后要退出重开")
                return
            }
            guard let target = HitTest.target(forCocoa: rect, content: content) else {
                model.fail("这里没有可钉住的窗口")
                return
            }
            self.dismiss()
            let pin = Pin(target: target)
            self.pins.append(pin)
            pin.panel.orderFrontRegardless()
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

// MARK: - 构建期自测：框选的几何（手柄命中、拉伸下限、平移钳制、按钮排版）

/// 全是纯算术，不需要屏幕录制权限、也不需要真实鼠标：这台机器合成不了点击事件，
/// 所以把手柄会不会翻转、按钮会不会跑到屏外这类问题放在这里验，剩下的留给肉眼。
enum SelTest {
    static func run() -> Int32 {
        var failures: [String] = []
        func check(_ label: String, _ ok: Bool) { if !ok { failures.append(label) } }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

        let base = CGRect(x: 100, y: 100, width: 200, height: 200) // x: 100…300，y: 100…300
        let min = Config.minSelectionSide
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

        for handle in [ResizeHandle.nw, .ne, .se, .sw] {
            let up = handle.resize(base, to: CGPoint(x: -500, y: -500), minSide: min)
            let down = handle.resize(base, to: CGPoint(x: 5000, y: 5000), minSide: min)
            check("\(handle) 拖过头只停在最小边长", up.width >= min && up.height >= min)
            check("\(handle) 反方向同样不翻转", down.width >= min && down.height >= min)
        }
        check("角优先于边", ResizeHandle.hit(CGPoint(x: 300, y: 300), in: base,
                                             tolerance: Config.handleHit) == .ne)
        check("边中点命中边", ResizeHandle.hit(CGPoint(x: 200, y: 300), in: base,
                                               tolerance: Config.handleHit) == .n)
        check("框内不命中手柄", ResizeHandle.hit(CGPoint(x: 200, y: 200), in: base,
                                                 tolerance: Config.handleHit) == nil)

        let nw = ResizeHandle.nw.resize(base, to: CGPoint(x: 150, y: 250), minSide: min)
        check("拖 nw 时对角 se 不动", close(nw.maxX, base.maxX) && close(nw.minY, base.minY))
        check("拖 nw 同时改宽和高", close(nw.width, 150) && close(nw.height, 150))
        let e = ResizeHandle.e.resize(base, to: CGPoint(x: 400, y: 500), minSide: min)
        check("拖 e 只改宽不改高", close(e.width, 300) && close(e.height, base.height))

        let pushed = Geo.clamp(CGRect(x: 900, y: -50, width: 200, height: 200), into: screen)
        check("拖出屏外的选区整体平移回来", close(pushed.minX, 800) && close(pushed.minY, 0)
              && close(pushed.width, 200))
        let huge = Geo.clamp(CGRect(x: 0, y: 0, width: 1200, height: 900), into: screen)
        check("比屏大时居中且不动尺寸", close(huge.width, 1200) && close(huge.midX, 500)
              && close(huge.midY, 300))

        let above = SelectionLayout.pills(rect: CGRect(x: 100, y: 40, width: 200, height: 200), in: screen)
        check("底边放不下按钮就翻到选区上方", close(above.ok.minY, 240 + SelectionLayout.offset)
              && above.ok.maxY > 240 && above.ok.intersects(screen) && above.cancel.maxX < screen.maxX)
        check("按钮组右端与选区右端对齐", close(above.cancel.maxX, 300))
        let insideRect = CGRect(x: 100, y: 40, width: 200, height: 200)
        let tight = SelectionLayout.pills(rect: insideRect, in: CGRect(x: 0, y: 0, width: 1000, height: 220))
        check("上下都放不下就落进选区内部", insideRect.contains(tight.ok.origin) && insideRect.contains(
            CGPoint(x: tight.cancel.maxX - 1, y: tight.cancel.maxY - 1)))
        let leftEdge = SelectionLayout.pills(rect: CGRect(x: 10, y: 300, width: 40, height: 100), in: screen)
        check("贴左边时按钮组不越屏", leftEdge.ok.minX >= screen.minX && leftEdge.cancel.maxX <= screen.maxX)

        let secondary = CGPoint(x: -1920, y: 100)
        let roundTrip = SelectionLayout.toGlobal(SelectionLayout.toLocal(base, origin: secondary),
                                                 origin: secondary)
        check("副屏原点上全局/本地往返一致", roundTrip == base)

        failures.forEach { say("seltest 失败: \($0)") }
        say("seltest 完成，\(failures.isEmpty ? "全部通过" : "\(failures.count) 项失败")")
        return failures.isEmpty ? 0 : 1
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

if arguments.contains("--seltest") {
    exit(SelTest.run())
} else if arguments.contains("--snaptest") {
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
