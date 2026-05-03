import AppKit
import Foundation

struct StateSpec {
    let row: Int?
    let durations: [Int]
}

struct FrameSource {
    let kind: String
    let frames: [NSImage]
    let width: CGFloat
    let height: CGFloat
}

struct Arguments {
    var projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var state = "idle"
    var height = 800
    var left = 900
    var top = 80
    var animationDelayMultiplier = 7.5
    var controlPath: URL?
    var rotationConfigPath: URL?
    var rotate = false
    var rotateStates = ""
    var rotationIntervalMs = 0
    var frameIntervalMs = 0
    var validateOnly = false
    var closeAfterMs = 0

    init(_ rawArgs: [String]) {
        var index = 1
        while index < rawArgs.count {
            let arg = rawArgs[index]
            func value() -> String? {
                guard index + 1 < rawArgs.count else { return nil }
                index += 1
                return rawArgs[index]
            }

            switch arg {
            case "--project-root":
                if let next = value() { projectRoot = URL(fileURLWithPath: next).standardizedFileURL }
            case "--state":
                if let next = value() { state = next }
            case "--height":
                if let next = value(), let parsed = Int(next) { height = parsed }
            case "--left":
                if let next = value(), let parsed = Int(next) { left = parsed }
            case "--top":
                if let next = value(), let parsed = Int(next) { top = parsed }
            case "--animation-delay-multiplier":
                if let next = value(), let parsed = Double(next) { animationDelayMultiplier = parsed }
            case "--control":
                if let next = value() { controlPath = URL(fileURLWithPath: next).standardizedFileURL }
            case "--rotation-config":
                if let next = value() { rotationConfigPath = URL(fileURLWithPath: next).standardizedFileURL }
            case "--rotate":
                rotate = true
            case "--rotate-states":
                if let next = value() { rotateStates = next }
            case "--rotation-interval-ms":
                if let next = value(), let parsed = Int(next) { rotationIntervalMs = parsed }
            case "--frame-interval-ms":
                if let next = value(), let parsed = Int(next) { frameIntervalMs = parsed }
            case "--validate-only":
                validateOnly = true
            case "--close-after-ms":
                if let next = value(), let parsed = Int(next) { closeAfterMs = parsed }
            default:
                break
            }

            index += 1
        }
    }
}

final class OverlayImageView: NSImageView {
    weak var overlayController: RubyOverlayController?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = overlayController?.makeContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY >= 0 ? 80 : -80
        overlayController?.setHeight((overlayController?.currentHeight ?? 800) + step)
    }

    override func keyDown(with event: NSEvent) {
        overlayController?.handleKeyDown(event)
    }
}

final class RubyOverlayController: NSObject, NSApplicationDelegate {
    private let args: Arguments
    private let fileManager = FileManager.default
    private let supportedExtensions = Set(["png", "jpg", "jpeg", "bmp", "tif", "tiff"])
    private let builtInOrder = [
        "idle",
        "running-right",
        "running-left",
        "waving",
        "jumping",
        "failed",
        "waiting",
        "running",
        "review"
    ]
    private let stateSpecs: [String: StateSpec] = [
        "idle": StateSpec(row: 0, durations: [1680, 660, 660, 840, 840, 1920]),
        "running-right": StateSpec(row: 1, durations: [120, 120, 120, 120, 120, 120, 120, 220]),
        "running-left": StateSpec(row: 2, durations: [120, 120, 120, 120, 120, 120, 120, 220]),
        "waving": StateSpec(row: 3, durations: [140, 140, 140, 280]),
        "jumping": StateSpec(row: 4, durations: [140, 140, 140, 140, 280]),
        "failed": StateSpec(row: 5, durations: [140, 140, 140, 140, 140, 140, 140, 240]),
        "waiting": StateSpec(row: 6, durations: [150, 150, 150, 150, 150, 260]),
        "running": StateSpec(row: 7, durations: [120, 120, 120, 120, 120, 220]),
        "review": StateSpec(row: 8, durations: [150, 150, 150, 150, 150, 280])
    ]

    private var stateOrder: [String] = []
    private var frameSources: [String: FrameSource] = [:]
    private var frameIndex = 0
    private var frameTimer: Timer?
    private var rotationTimer: Timer?
    private var controlTimer: Timer?
    private var rotationConfigTimer: Timer?
    private var lastControlDate: Date?
    private var lastRotationDate: Date?
    private var window: NSWindow?
    private var imageView: OverlayImageView?
    private var currentState: String
    private(set) var currentHeight: Int
    private var rotationEnabled = false
    private var rotationStates: [String] = []
    private var rotationIntervalMs = 9000
    private var frameIntervalMs = 9000
    private var delayMultiplier: Double

    private var assetsRoot: URL {
        args.projectRoot.appendingPathComponent("assets", isDirectory: true)
    }

    private var frameRoot: URL {
        assetsRoot.appendingPathComponent("frames", isDirectory: true)
    }

    private var spritesheetPath: URL {
        assetsRoot.appendingPathComponent("ruby-spritesheet.png")
    }

    private var visibleStateOrder: [String] {
        let visible = stateOrder.filter { frameSources[$0]?.kind == "frames" }
        return visible.isEmpty ? stateOrder : visible
    }

    private var visibleRotationStateOrder: [String] {
        visibleStateOrder.filter { !isUpdateOnlyState($0) }
    }

    private var controlPath: URL {
        args.controlPath ?? args.projectRoot.appendingPathComponent("control.json")
    }

    private var rotationConfigPath: URL {
        args.rotationConfigPath ?? args.projectRoot.appendingPathComponent("rotation.json")
    }

    init(arguments: Arguments) {
        self.args = arguments
        self.currentState = arguments.state
        self.currentHeight = max(120, arguments.height)
        self.delayMultiplier = min(10.0, max(0.25, arguments.animationDelayMultiplier))
        super.init()
        loadFrameSources()
        loadRotationConfig()
        if arguments.rotationIntervalMs > 0 {
            setRotationInterval(arguments.rotationIntervalMs, save: false)
        }
        if arguments.frameIntervalMs > 0 {
            setFrameInterval(arguments.frameIntervalMs, save: false)
        }
        if !arguments.rotateStates.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setRotationStates(parseStateList(arguments.rotateStates), save: false)
        }
        if arguments.rotate {
            setRotationEnabled(true, save: false)
        }
        if !frameSources.keys.contains(currentState) {
            currentState = stateOrder.first ?? "idle"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if args.validateOnly {
            validateAndExit()
            return
        }

        createWindow()
        setState(currentState)
        scheduleFrameTimer()
        scheduleRotationTimer()
        startPolling()

        if args.closeAfterMs > 0 {
            Timer.scheduledTimer(withTimeInterval: Double(args.closeAfterMs) / 1000.0, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
    }

    private func loadFrameSources() {
        frameSources.removeAll()
        stateOrder.removeAll()

        let atlas = loadAtlas()
        for name in builtInOrder {
            if let source = loadFrameFolder(name: name) {
                frameSources[name] = source
                stateOrder.append(name)
            } else if let source = loadAtlasSource(name: name, atlas: atlas) {
                frameSources[name] = source
                stateOrder.append(name)
            }
        }

        guard let directories = try? fileManager.contentsOfDirectory(
            at: frameRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directory in directories.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = directory.lastPathComponent
            guard !frameSources.keys.contains(name), let source = loadFrameFolder(name: name) else {
                continue
            }
            frameSources[name] = source
            stateOrder.append(name)
        }
    }

    private func loadFrameFolder(name: String) -> FrameSource? {
        let directory = frameRoot.appendingPathComponent(name, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var frames: [NSImage] = []
        var maxWidth: CGFloat = 0
        var maxHeight: CGFloat = 0

        for file in files.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard supportedExtensions.contains(file.pathExtension.lowercased()), let loaded = loadImage(file) else {
                continue
            }
            frames.append(loaded.image)
            maxWidth = max(maxWidth, loaded.width)
            maxHeight = max(maxHeight, loaded.height)
        }

        guard !frames.isEmpty else {
            return nil
        }

        return FrameSource(kind: "frames", frames: frames, width: maxWidth, height: maxHeight)
    }

    private func loadImage(_ url: URL) -> (image: NSImage, width: CGFloat, height: CGFloat)? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        return (NSImage(cgImage: cgImage, size: size), CGFloat(cgImage.width), CGFloat(cgImage.height))
    }

    private func loadAtlas() -> CGImage? {
        guard let image = NSImage(contentsOf: spritesheetPath) else {
            return nil
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func loadAtlasSource(name: String, atlas: CGImage?) -> FrameSource? {
        guard let atlas = atlas,
              let spec = stateSpecs[name],
              let row = spec.row,
              atlas.width % 8 == 0,
              atlas.height % 9 == 0 else {
            return nil
        }

        let cellWidth = atlas.width / 8
        let cellHeight = atlas.height / 9
        var frames: [NSImage] = []
        for index in 0..<spec.durations.count {
            let rect = CGRect(
                x: CGFloat(index * cellWidth),
                y: CGFloat(row * cellHeight),
                width: CGFloat(cellWidth),
                height: CGFloat(cellHeight)
            )
            guard let cropped = atlas.cropping(to: rect) else {
                continue
            }
            frames.append(NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cellWidth), height: CGFloat(cellHeight))))
        }

        guard !frames.isEmpty else {
            return nil
        }

        return FrameSource(kind: "atlas", frames: frames, width: CGFloat(cellWidth), height: CGFloat(cellHeight))
    }

    private func createWindow() {
        let source = frameSources[currentState] ?? frameSources[stateOrder.first ?? ""]
        let width = source.map { CGFloat(currentHeight) * $0.width / max(1, $0.height) } ?? 420
        let height = CGFloat(currentHeight)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let y = screen.maxY - CGFloat(args.top) - height
        let frame = NSRect(x: CGFloat(args.left), y: y, width: width, height: height)

        let overlayWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.level = .floating
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlayWindow.isMovableByWindowBackground = true
        overlayWindow.title = "Ruby Overlay"

        let view = OverlayImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.overlayController = self
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        overlayWindow.contentView = view
        overlayWindow.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)

        self.window = overlayWindow
        self.imageView = view
    }

    private func durations(for state: String) -> [Int] {
        let base = stateSpecs[state]?.durations ?? [180]
        let count = frameSources[state]?.frames.count ?? 1
        var result: [Int] = []
        for index in 0..<count {
            result.append(index < base.count ? base[index] : base[base.count - 1])
        }
        return result
    }

    private func scaledDuration(_ milliseconds: Int) -> TimeInterval {
        max(0.016, Double(milliseconds) * delayMultiplier / 1000.0)
    }

    private func frameDuration(for state: String, index: Int) -> TimeInterval {
        if frameSources[state]?.kind == "frames" {
            return Double(frameIntervalMs) / 1000.0
        }

        let currentDurations = durations(for: state)
        let duration = currentDurations[min(index, currentDurations.count - 1)]
        return scaledDuration(duration)
    }

    private func setState(_ state: String) {
        guard frameSources[state] != nil else { return }
        currentState = state
        frameIndex = 0
        setHeight(currentHeight)
        setFrame()
        scheduleFrameTimer()
    }

    func setHeight(_ newHeight: Int) {
        currentHeight = min(1600, max(120, newHeight))
        guard let source = frameSources[currentState],
              let overlayWindow = window,
              let view = imageView else {
            return
        }
        let width = CGFloat(currentHeight) * source.width / max(1, source.height)
        let size = NSSize(width: width, height: CGFloat(currentHeight))
        view.frame = NSRect(origin: .zero, size: size)
        overlayWindow.setContentSize(size)
    }

    private func setFrame() {
        guard let source = frameSources[currentState], !source.frames.isEmpty else {
            return
        }
        if frameIndex >= source.frames.count {
            frameIndex = 0
        }
        imageView?.image = source.frames[frameIndex]
    }

    private func scheduleFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: frameDuration(for: currentState, index: frameIndex), repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func advanceFrame() {
        let currentDurations = durations(for: currentState)
        frameIndex = (frameIndex + 1) % max(1, currentDurations.count)
        setFrame()
        scheduleFrameTimer()
    }

    private func startPolling() {
        lastControlDate = modificationDate(controlPath)
        lastRotationDate = modificationDate(rotationConfigPath)

        controlTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.applyControlIfNeeded()
        }
        rotationConfigTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.applyRotationConfigIfNeeded()
        }
    }

    private func applyControlIfNeeded() {
        guard let modified = modificationDate(controlPath) else { return }
        if let last = lastControlDate, modified <= last {
            return
        }
        lastControlDate = modified

        guard let control = readObject(controlPath) else {
            return
        }

        if let state = control["state"] as? String {
            setState(state)
        }
        if let height = intValue(control["height"]) {
            setHeight(height)
        }
        if let topmost = boolValue(control["topmost"]) {
            window?.level = topmost ? .floating : .normal
        }
        if let left = doubleValue(control["left"]), let overlayWindow = window {
            overlayWindow.setFrameOrigin(NSPoint(x: left, y: overlayWindow.frame.origin.y))
        }
        if let top = doubleValue(control["top"]), let overlayWindow = window {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            overlayWindow.setFrameOrigin(NSPoint(x: overlayWindow.frame.origin.x, y: screen.maxY - top - overlayWindow.frame.height))
        }
        if let states = control["rotationStates"] {
            setRotationStates(stateArray(states), save: false)
        }
        if let interval = intValue(control["rotationIntervalMs"]) {
            setRotationInterval(interval, save: false)
        }
        if let interval = intValue(control["frameIntervalMs"]) {
            setFrameInterval(interval, save: false)
        }
        if let rotate = boolValue(control["rotate"]) ?? boolValue(control["rotationEnabled"]) {
            setRotationEnabled(rotate, save: false)
        }
    }

    private func applyRotationConfigIfNeeded() {
        guard let modified = modificationDate(rotationConfigPath) else { return }
        if let last = lastRotationDate, modified <= last {
            return
        }
        loadRotationConfig()
    }

    private func loadRotationConfig() {
        var enabled = false
        var interval = rotationIntervalMs
        var frameInterval = frameIntervalMs
        var states = defaultRotationStates()

        if let config = readObject(rotationConfigPath) {
            enabled = boolValue(config["enabled"]) ?? enabled
            interval = intValue(config["intervalMs"]) ?? interval
            frameInterval = intValue(config["frameIntervalMs"]) ?? frameInterval
            if let rawStates = config["states"] {
                states = stateArray(rawStates)
            }
            lastRotationDate = modificationDate(rotationConfigPath)
        }

        setRotationInterval(interval, save: false)
        setFrameInterval(frameInterval, save: false)
        setRotationStates(removeUpdateOnlyStates(states), save: false)
        setRotationEnabled(enabled, save: false)
    }

    private func defaultRotationStates() -> [String] {
        let preferred = [
            "party",
            "biker",
            "idle",
            "waiting",
            "waving",
            "review",
            "code review ready",
            "debugging",
            "deploy",
            "cheerleader",
            "gala",
            "elf",
            "halloween",
            "jumping",
            "failed",
            "playfull",
            "personal attention"
        ]
        var result = preferred.filter { frameSources.keys.contains($0) && !isUpdateOnlyState($0) }
        for state in stateOrder where frameSources[state]?.kind == "frames" && !result.contains(state) && !isUpdateOnlyState(state) {
            result.append(state)
        }
        return result
    }

    private func isUpdateOnlyState(_ state: String) -> Bool {
        state == "update" || state == "ruby-update"
    }

    private func removeUpdateOnlyStates(_ states: [String]) -> [String] {
        states.filter { !isUpdateOnlyState($0) }
    }

    private func stateGroupName(_ state: String) -> String {
        let cosplayStates = Set([
            "angel",
            "biker",
            "cheerleader",
            "elf",
            "gala",
            "halloween",
            "rogue",
            "sorcerer"
        ])
        return cosplayStates.contains(state) ? "Cosplay" : "Assistant"
    }

    private func groupedStates(_ states: [String]) -> [(String, [String])] {
        let orderedGroups = ["Assistant", "Cosplay"]
        var groups: [String: [String]] = [:]
        for state in states {
            groups[stateGroupName(state), default: []].append(state)
        }
        return orderedGroups.compactMap { group in
            guard let states = groups[group], !states.isEmpty else { return nil }
            return (group, states)
        }
    }

    private func setRotationEnabled(_ enabled: Bool, save: Bool) {
        rotationEnabled = enabled && !rotationStates.isEmpty
        scheduleRotationTimer()
        if save { saveRotationConfig() }
    }

    private func setRotationStates(_ states: [String], save: Bool) {
        var clean: [String] = []
        for state in states where frameSources.keys.contains(state) && !clean.contains(state) {
            clean.append(state)
        }
        rotationStates = clean
        if rotationStates.isEmpty {
            rotationEnabled = false
        }
        scheduleRotationTimer()
        if save { saveRotationConfig() }
    }

    private func setRotationInterval(_ intervalMs: Int, save: Bool) {
        rotationIntervalMs = min(60000, max(1500, intervalMs))
        scheduleRotationTimer()
        if save { saveRotationConfig() }
    }

    private func setFrameInterval(_ intervalMs: Int, save: Bool) {
        frameIntervalMs = min(60000, max(500, intervalMs))
        if imageView != nil {
            scheduleFrameTimer()
        }
        if save { saveRotationConfig() }
    }

    private func scheduleRotationTimer() {
        rotationTimer?.invalidate()
        guard rotationEnabled, !rotationStates.isEmpty else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Double(rotationIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
    }

    private func advanceRotation() {
        guard !rotationStates.isEmpty else { return }
        let index = rotationStates.firstIndex(of: currentState)
        let nextIndex = index.map { ($0 + 1) % rotationStates.count } ?? 0
        setState(rotationStates[nextIndex])
    }

    private func saveRotationConfig() {
        let object: [String: Any] = [
            "enabled": rotationEnabled,
            "intervalMs": rotationIntervalMs,
            "frameIntervalMs": frameIntervalMs,
            "states": removeUpdateOnlyStates(rotationStates)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: rotationConfigPath)
        lastRotationDate = modificationDate(rotationConfigPath)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        for (groupName, states) in groupedStates(visibleStateOrder) {
            let groupMenu = NSMenu()
            for state in states {
                let item = NSMenuItem(title: state, action: #selector(selectState(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state
                groupMenu.addItem(item)
            }
            let groupItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            groupItem.submenu = groupMenu
            menu.addItem(groupItem)
        }

        menu.addItem(.separator())

        let rotateItem = NSMenuItem(title: "Auto rotate", action: #selector(toggleRotate(_:)), keyEquivalent: "")
        rotateItem.target = self
        rotateItem.state = rotationEnabled ? .on : .off
        rotateItem.isEnabled = !rotationStates.isEmpty
        menu.addItem(rotateItem)

        let rotationStatesMenu = NSMenu()
        for (groupName, states) in groupedStates(visibleRotationStateOrder) {
            let groupMenu = NSMenu()
            let selectedCount = states.filter { rotationStates.contains($0) }.count
            let allItem = NSMenuItem(title: "All (\(selectedCount)/\(states.count))", action: #selector(toggleRotationGroup(_:)), keyEquivalent: "")
            allItem.target = self
            allItem.representedObject = states
            allItem.state = selectedCount == states.count ? .on : .off
            groupMenu.addItem(allItem)
            groupMenu.addItem(.separator())

            for state in states {
                let item = NSMenuItem(title: state, action: #selector(toggleRotationState(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state
                item.state = rotationStates.contains(state) ? .on : .off
                groupMenu.addItem(item)
            }

            let groupItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            groupItem.submenu = groupMenu
            rotationStatesMenu.addItem(groupItem)
        }
        let rotationStatesItem = NSMenuItem(title: "Rotation states", action: nil, keyEquivalent: "")
        rotationStatesItem.submenu = rotationStatesMenu
        menu.addItem(rotationStatesItem)

        let intervalMenu = NSMenu()
        let current = NSMenuItem(title: "Current: \(formatRotationInterval())", action: nil, keyEquivalent: "")
        current.isEnabled = false
        intervalMenu.addItem(current)
        intervalMenu.addItem(.separator())
        for interval in [5000, 9000, 15000, 30000] {
            let item = NSMenuItem(title: "\(interval / 1000) seconds", action: #selector(selectRotationInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = interval == rotationIntervalMs ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalMenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom...", action: #selector(showCustomRotationInterval), keyEquivalent: "")
        custom.target = self
        intervalMenu.addItem(custom)

        let intervalItem = NSMenuItem(title: "Rotation interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let frameIntervalMenu = NSMenu()
        let frameCurrent = NSMenuItem(title: "Current: \(formatFrameInterval())", action: nil, keyEquivalent: "")
        frameCurrent.isEnabled = false
        frameIntervalMenu.addItem(frameCurrent)
        frameIntervalMenu.addItem(.separator())
        for interval in [1500, 3000, 4500, 6000, 9000] {
            let item = NSMenuItem(title: "\(Double(interval) / 1000.0) seconds", action: #selector(selectFrameInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = interval == frameIntervalMs ? .on : .off
            frameIntervalMenu.addItem(item)
        }
        frameIntervalMenu.addItem(.separator())
        let customFrame = NSMenuItem(title: "Custom...", action: #selector(showCustomFrameInterval), keyEquivalent: "")
        customFrame.target = self
        frameIntervalMenu.addItem(customFrame)

        let frameIntervalItem = NSMenuItem(title: "Frame interval", action: nil, keyEquivalent: "")
        frameIntervalItem.submenu = frameIntervalMenu
        menu.addItem(frameIntervalItem)

        menu.addItem(.separator())

        for size in [420, 600, 800, 1000, 1300] {
            let item = NSMenuItem(title: "Height \(size)", action: #selector(selectHeight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let topmost = NSMenuItem(title: "Always on top", action: #selector(toggleTopmost(_:)), keyEquivalent: "")
        topmost.target = self
        topmost.state = window?.level == .floating ? .on : .off
        menu.addItem(topmost)

        let close = NSMenuItem(title: "Close", action: #selector(closeOverlay), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        setState(state)
    }

    @objc private func toggleRotate(_ sender: NSMenuItem) {
        setRotationEnabled(!rotationEnabled, save: true)
    }

    @objc private func toggleRotationState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        guard !isUpdateOnlyState(state) else { return }
        var next = rotationStates.filter { $0 != state }
        if !rotationStates.contains(state) {
            next.append(state)
        }
        setRotationStates(next, save: true)
    }

    @objc private func toggleRotationGroup(_ sender: NSMenuItem) {
        guard let states = sender.representedObject as? [String] else { return }
        let cleanStates = removeUpdateOnlyStates(states)
        let allSelected = cleanStates.allSatisfy { rotationStates.contains($0) }
        var next = rotationStates.filter { !cleanStates.contains($0) }
        if !allSelected {
            for state in cleanStates where frameSources.keys.contains(state) && !next.contains(state) {
                next.append(state)
            }
        }
        setRotationStates(next, save: true)
    }

    @objc private func selectRotationInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Int else { return }
        setRotationInterval(interval, save: true)
    }

    @objc private func selectFrameInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Int else { return }
        setFrameInterval(interval, save: true)
    }

    @objc private func showCustomRotationInterval() {
        let alert = NSAlert()
        alert.messageText = "Rotation interval"
        alert.informativeText = "Seconds between state changes, from 1.5 to 60."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(format: "%.3g", Double(rotationIntervalMs) / 1000.0)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let seconds = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds >= 1.5,
              seconds <= 60 else {
            return
        }
        setRotationInterval(Int((seconds * 1000).rounded()), save: true)
    }

    @objc private func showCustomFrameInterval() {
        let alert = NSAlert()
        alert.messageText = "Frame interval"
        alert.informativeText = "Seconds each pose image stays visible, from 0.5 to 60."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(format: "%.3g", Double(frameIntervalMs) / 1000.0)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let seconds = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds >= 0.5,
              seconds <= 60 else {
            return
        }
        setFrameInterval(Int((seconds * 1000).rounded()), save: true)
    }

    @objc private func selectHeight(_ sender: NSMenuItem) {
        guard let height = sender.representedObject as? Int else { return }
        setHeight(height)
    }

    @objc private func toggleTopmost(_ sender: NSMenuItem) {
        guard let overlayWindow = window else { return }
        overlayWindow.level = overlayWindow.level == .floating ? .normal : .floating
    }

    @objc private func closeOverlay() {
        NSApp.terminate(nil)
    }

    func handleKeyDown(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers else { return }
        switch key {
        case "\u{1b}":
            NSApp.terminate(nil)
        case "+", "=":
            setHeight(currentHeight + 80)
        case "-", "_":
            setHeight(currentHeight - 80)
        case "1"..."9":
            let visible = visibleStateOrder
            if let value = Int(key), value - 1 < visible.count {
                setState(visible[value - 1])
            }
        default:
            break
        }
    }

    private func validateAndExit() {
        for state in stateOrder {
            guard let source = frameSources[state] else { continue }
            print("\(state): \(source.kind), \(source.frames.count) frame(s), \(Int(source.width))x\(Int(source.height))")
        }
        print("RubyOverlay macOS validation OK.")
        NSApp.terminate(nil)
    }

    private func formatRotationInterval() -> String {
        if rotationIntervalMs % 1000 == 0 {
            return "\(rotationIntervalMs / 1000) seconds"
        }
        return String(format: "%.3g seconds", Double(rotationIntervalMs) / 1000.0)
    }

    private func formatFrameInterval() -> String {
        if frameIntervalMs % 1000 == 0 {
            return "\(frameIntervalMs / 1000) seconds"
        }
        return String(format: "%.3g seconds", Double(frameIntervalMs) / 1000.0)
    }

    private func parseStateList(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func stateArray(_ raw: Any) -> [String] {
        if let strings = raw as? [String] {
            return strings
        }
        if let rawString = raw as? String {
            return parseStateList(rawString)
        }
        return []
    }

    private func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func modificationDate(_ url: URL) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let double = raw as? Double { return Int(double) }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    private func boolValue(_ raw: Any?) -> Bool? {
        if let bool = raw as? Bool { return bool }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

let arguments = Arguments(CommandLine.arguments)
let app = NSApplication.shared
let controller = RubyOverlayController(arguments: arguments)
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()
