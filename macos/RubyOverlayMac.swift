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
    var updateConfigPath: URL?
    var versionPath: URL?
    var updateApiBaseUrl = "https://api.github.com"
    var disableUpdateCheck = false
    var rotate = false
    var mode = "assistant"
    var modeProvided = false
    var danceState = ""
    var danceFrameIntervalMs = 900
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
            case "--update-config":
                if let next = value() { updateConfigPath = URL(fileURLWithPath: next).standardizedFileURL }
            case "--version-path":
                if let next = value() { versionPath = URL(fileURLWithPath: next).standardizedFileURL }
            case "--update-api-base-url":
                if let next = value() { updateApiBaseUrl = next }
            case "--disable-update-check":
                disableUpdateCheck = true
            case "--rotate":
                rotate = true
            case "--mode":
                if let next = value() {
                    mode = next
                    modeProvided = true
                }
            case "--dance-state":
                if let next = value() { danceState = next }
            case "--dance-frame-interval-ms":
                if let next = value(), let parsed = Int(next) { danceFrameIntervalMs = parsed }
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
    private var mode = "assistant"
    private var assistantState = "idle"
    private var assistantRotationEnabled = false
    private var danceState = ""
    private var danceFrameIntervalMs = 900
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
        visibleStateOrder.filter { !isUpdateOnlyState($0) && !isDanceState($0) }
    }

    private var controlPath: URL {
        args.controlPath ?? args.projectRoot.appendingPathComponent("control.json")
    }

    private var rotationConfigPath: URL {
        args.rotationConfigPath ?? args.projectRoot.appendingPathComponent("rotation.json")
    }

    private var updateConfigPath: URL {
        args.updateConfigPath ?? args.projectRoot.appendingPathComponent("update.json")
    }

    private var versionPath: URL {
        args.versionPath ?? args.projectRoot.appendingPathComponent("VERSION")
    }

    init(arguments: Arguments) {
        self.args = arguments
        self.currentState = arguments.state
        self.currentHeight = max(120, arguments.height)
        self.delayMultiplier = min(10.0, max(0.25, arguments.animationDelayMultiplier))
        self.assistantState = arguments.state
        self.danceFrameIntervalMs = min(60000, max(250, arguments.danceFrameIntervalMs))
        super.init()
        loadFrameSources()
        self.danceState = frameSources.keys.contains(arguments.danceState) && isDanceState(arguments.danceState) ? arguments.danceState : defaultDanceState()
        loadRotationConfig()
        if arguments.rotationIntervalMs > 0 {
            setRotationInterval(arguments.rotationIntervalMs, save: false)
        }
        if arguments.frameIntervalMs > 0 {
            setFrameInterval(arguments.frameIntervalMs, save: false)
        }
        if arguments.danceFrameIntervalMs > 0 {
            setDanceFrameInterval(arguments.danceFrameIntervalMs, save: false)
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
        if arguments.modeProvided {
            setMode(arguments.mode, danceState: danceState, save: false)
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
        startStartupUpdateCheck()

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
        if mode == "dance" && isDanceState(state) {
            return Double(danceFrameIntervalMs) / 1000.0
        }

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
        if mode == "assistant" && !isDanceState(state) {
            assistantState = state
        }
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
        if let interval = intValue(control["danceFrameIntervalMs"]) {
            setDanceFrameInterval(interval, save: false)
        }
        let requestedMode = control["mode"] as? String
        let requestedDanceState = control["danceState"] as? String
        if let requestedDanceState, frameSources.keys.contains(requestedDanceState), isDanceState(requestedDanceState) {
            danceState = requestedDanceState
        }
        if let requestedMode {
            setMode(requestedMode, danceState: requestedDanceState ?? danceState, save: false)
        }
        if let state = control["state"] as? String,
           normalizeMode(requestedMode ?? "") != "dance" {
            setState(state)
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
        var modeName = mode
        var danceStateName = danceState
        var danceInterval = danceFrameIntervalMs
        var states = defaultRotationStates()

        if let config = readObject(rotationConfigPath) {
            enabled = boolValue(config["enabled"]) ?? enabled
            interval = intValue(config["intervalMs"]) ?? interval
            frameInterval = intValue(config["frameIntervalMs"]) ?? frameInterval
            modeName = (config["mode"] as? String) ?? modeName
            danceStateName = (config["danceState"] as? String) ?? danceStateName
            danceInterval = intValue(config["danceFrameIntervalMs"]) ?? danceInterval
            if let rawStates = config["states"] {
                states = stateArray(rawStates)
            }
            lastRotationDate = modificationDate(rotationConfigPath)
        }

        setRotationInterval(interval, save: false)
        setFrameInterval(frameInterval, save: false)
        setDanceFrameInterval(danceInterval, save: false)
        if frameSources.keys.contains(danceStateName), isDanceState(danceStateName) {
            danceState = danceStateName
        }
        setRotationStates(removeUpdateOnlyStates(states), save: false)
        setRotationEnabled(enabled, save: false)
        setMode(modeName, danceState: danceState, save: false)
    }

    private func defaultRotationStates() -> [String] {
        let preferred = [
            "party",
            "belly dance",
            "samba",
            "biker",
            "rogue",
            "angel",
            "sorcerer",
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
        var result = preferred.filter { frameSources.keys.contains($0) && !isUpdateOnlyState($0) && !isDanceState($0) }
        for state in stateOrder where frameSources[state]?.kind == "frames" && !result.contains(state) && !isUpdateOnlyState(state) && !isDanceState(state) {
            result.append(state)
        }
        return result
    }

    private func normalizeMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dance" ? "dance" : "assistant"
    }

    private func isDanceState(_ state: String) -> Bool {
        let normalized = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("dance-") || normalized.hasPrefix("dance ")
    }

    private func danceStates() -> [String] {
        stateOrder.filter { frameSources.keys.contains($0) && isDanceState($0) }
    }

    private func defaultDanceState() -> String {
        if !danceState.isEmpty, frameSources.keys.contains(danceState) {
            return danceState
        }
        return danceStates().first ?? ""
    }

    private func isUpdateOnlyState(_ state: String) -> Bool {
        state == "update" || state == "ruby-update"
    }

    private func removeUpdateOnlyStates(_ states: [String]) -> [String] {
        states.filter { !isUpdateOnlyState($0) }
    }

    private func stateGroupName(_ state: String) -> String {
        if isDanceState(state) {
            return "Dance"
        }

        let cosplayStates = Set([
            "angel",
            "belly dance",
            "biker",
            "cheerleader",
            "elf",
            "gala",
            "halloween",
            "rogue",
            "samba",
            "sorcerer"
        ])
        return cosplayStates.contains(state) ? "Cosplay" : "Assistant"
    }

    private func groupedStates(_ states: [String]) -> [(String, [String])] {
        let orderedGroups = ["Assistant", "Cosplay", "Dance"]
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
        if mode == "assistant" {
            assistantRotationEnabled = rotationEnabled
        }
        scheduleRotationTimer()
        if save { saveRotationConfig() }
    }

    private func setRotationStates(_ states: [String], save: Bool) {
        var clean: [String] = []
        for state in states where frameSources.keys.contains(state) && !isDanceState(state) && !clean.contains(state) {
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

    private func setDanceFrameInterval(_ intervalMs: Int, save: Bool) {
        danceFrameIntervalMs = min(60000, max(250, intervalMs))
        if mode == "dance", imageView != nil {
            scheduleFrameTimer()
        }
        if save { saveRotationConfig() }
    }

    private func setMode(_ requestedMode: String, danceState requestedDanceState: String = "", save: Bool) {
        let nextMode = normalizeMode(requestedMode)
        if nextMode == "dance" {
            let targetDanceState = frameSources.keys.contains(requestedDanceState) && isDanceState(requestedDanceState) ? requestedDanceState : defaultDanceState()
            guard !targetDanceState.isEmpty else { return }
            if mode != "dance" {
                if !isDanceState(currentState) {
                    assistantState = currentState
                }
                assistantRotationEnabled = rotationEnabled
            }
            mode = "dance"
            danceState = targetDanceState
            setRotationEnabled(false, save: false)
            setState(targetDanceState)
        } else {
            mode = "assistant"
            if isDanceState(currentState), frameSources.keys.contains(assistantState) {
                setState(assistantState)
            }
            setRotationEnabled(assistantRotationEnabled, save: false)
        }
        if save { saveRotationConfig() }
    }

    private func scheduleRotationTimer() {
        rotationTimer?.invalidate()
        guard mode == "assistant", rotationEnabled, !rotationStates.isEmpty else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Double(rotationIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
    }

    private func advanceRotation() {
        guard mode == "assistant" else { return }
        guard !rotationStates.isEmpty else { return }
        let index = rotationStates.firstIndex(of: currentState)
        let nextIndex = index.map { ($0 + 1) % rotationStates.count } ?? 0
        setState(rotationStates[nextIndex])
    }

    private func saveRotationConfig() {
        let enabledForConfig = mode == "dance" ? assistantRotationEnabled : rotationEnabled
        let object: [String: Any] = [
            "enabled": enabledForConfig,
            "intervalMs": rotationIntervalMs,
            "frameIntervalMs": frameIntervalMs,
            "mode": mode,
            "danceState": danceState,
            "danceFrameIntervalMs": danceFrameIntervalMs,
            "states": removeUpdateOnlyStates(rotationStates)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: rotationConfigPath)
        lastRotationDate = modificationDate(rotationConfigPath)
    }

    private func startStartupUpdateCheck() {
        guard !args.disableUpdateCheck else { return }
        let updateURL = updateConfigPath
        let versionURL = versionPath
        let controlURL = controlPath
        let rotationURL = rotationConfigPath
        let framesURL = frameRoot
        let apiBase = args.updateApiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var updateConfig = self.readObject(updateURL) ?? [:]
            if let enabled = self.boolValue(updateConfig["enabled"]), !enabled {
                return
            }

            let configuredRepository = (updateConfig["repository"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let repository = configuredRepository.isEmpty ? "martinsbrezauckis/ruby-overlay-mcp" : configuredRepository
            let currentVersion = self.readVersion(versionURL)
            let updateState = (updateConfig["updateState"] as? String) ?? "update"
            let fallbackStates = self.stateArray(updateConfig["fallbackStates"] ?? ["ruby-update", "deploy", "party"])
            let result = self.checkForUpdate(
                repository: repository,
                currentVersion: currentVersion,
                apiBase: apiBase
            )

            if updateConfig["repository"] == nil {
                updateConfig["repository"] = repository
            }
            updateConfig["lastCheck"] = result
            self.writeObject(updateConfig, to: updateURL)

            guard self.boolValue(result["updateAvailable"]) == true else { return }
            let availableStates = self.availableFrameStates(in: framesURL)
            let rotationConfig = self.readObject(rotationURL) ?? [:]
            let rotationStates = self.stateArray(rotationConfig["states"] ?? [])
            let noticeStates = self.selectUpdateNoticeStates(
                availableStates: availableStates,
                currentRotationStates: rotationStates,
                updateState: updateState,
                fallbackStates: fallbackStates
            )
            guard !noticeStates.isEmpty else { return }

            var control = self.readObject(controlURL) ?? [:]
            control["state"] = noticeStates[0]
            control["rotate"] = true
            control["rotationStates"] = noticeStates
            control["updateAvailable"] = true
            control["latestVersion"] = result["latestVersion"]
            control["releaseUrl"] = result["releaseUrl"]
            self.writeObject(control, to: controlURL)
        }
    }

    private func checkForUpdate(repository: String, currentVersion: String, apiBase: String) -> [String: Any] {
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        do {
            let release = try fetchGitHubObject("\(apiBase)/repos/\(repository)/releases/latest")
            let latestVersion = ((release["tag_name"] as? String) ?? (release["name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latestVersion.isEmpty else {
                return updateError(repository: repository, currentVersion: currentVersion, error: "Latest release did not include a tag_name.", releaseUrl: release["html_url"] as? String)
            }
            return [
                "checkedAt": checkedAt,
                "currentVersion": currentVersion,
                "latestVersion": latestVersion,
                "releaseName": release["name"] ?? NSNull(),
                "releaseUrl": release["html_url"] ?? NSNull(),
                "repository": repository,
                "updateAvailable": isNewerVersion(latestVersion, than: currentVersion),
                "versionSource": "release"
            ]
        } catch UpdateFetchError.httpStatus(let status) where status == 404 {
            do {
                let tags = try fetchGitHubArray("\(apiBase)/repos/\(repository)/tags?per_page=1")
                let tag = tags.first ?? [:]
                let latestVersion = (tag["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latestVersion.isEmpty else {
                    return updateError(repository: repository, currentVersion: currentVersion, error: "No GitHub releases or tags found.")
                }
                return [
                    "checkedAt": checkedAt,
                    "currentVersion": currentVersion,
                    "latestVersion": latestVersion,
                    "releaseName": latestVersion,
                    "releaseUrl": "https://github.com/\(repository)/tree/\(latestVersion)",
                    "repository": repository,
                    "updateAvailable": isNewerVersion(latestVersion, than: currentVersion),
                    "versionSource": "tag"
                ]
            } catch {
                return updateError(repository: repository, currentVersion: currentVersion, error: "GitHub tag fallback failed: \(error.localizedDescription)")
            }
        } catch UpdateFetchError.httpStatus(let status) {
            return updateError(repository: repository, currentVersion: currentVersion, error: "GitHub release check failed: HTTP \(status)")
        } catch {
            return updateError(repository: repository, currentVersion: currentVersion, error: "GitHub release check failed: \(error.localizedDescription)")
        }
    }

    private enum UpdateFetchError: Error {
        case timeout
        case httpStatus(Int)
        case invalidJSON
    }

    private func fetchGitHubObject(_ urlString: String) throws -> [String: Any] {
        let object = try fetchGitHubJSON(urlString)
        guard let dictionary = object as? [String: Any] else { throw UpdateFetchError.invalidJSON }
        return dictionary
    }

    private func fetchGitHubArray(_ urlString: String) throws -> [[String: Any]] {
        let object = try fetchGitHubJSON(urlString)
        guard let array = object as? [[String: Any]] else { throw UpdateFetchError.invalidJSON }
        return array
    }

    private func fetchGitHubJSON(_ urlString: String) throws -> Any {
        guard let url = URL(string: urlString) else { throw UpdateFetchError.invalidJSON }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RubyOverlay/\(readVersion(versionPath))", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus: Int?
        var responseError: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseStatus = (response as? HTTPURLResponse)?.statusCode
            responseError = error
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            throw UpdateFetchError.timeout
        }
        if let responseError {
            throw responseError
        }
        if let responseStatus, !(200..<300).contains(responseStatus) {
            throw UpdateFetchError.httpStatus(responseStatus)
        }
        guard let responseData,
              let object = try? JSONSerialization.jsonObject(with: responseData) else {
            throw UpdateFetchError.invalidJSON
        }
        return object
    }

    private func updateError(repository: String, currentVersion: String, error: String, releaseUrl: String? = nil) -> [String: Any] {
        [
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "currentVersion": currentVersion,
            "error": error,
            "latestVersion": NSNull(),
            "releaseUrl": releaseUrl ?? NSNull(),
            "repository": repository,
            "updateAvailable": false
        ]
    }

    private func readVersion(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "0.0.0" }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "0.0.0" : version
    }

    private func versionParts(_ version: String) -> [Int] {
        var raw = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("v") {
            raw.removeFirst()
        }
        raw = raw.components(separatedBy: "+").first ?? raw
        raw = raw.components(separatedBy: "-").first ?? raw
        var parts = raw.split(separator: ".").map { segment -> Int in
            let digits = segment.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        while parts.count < 3 {
            parts.append(0)
        }
        return parts
    }

    private func isNewerVersion(_ latestVersion: String, than currentVersion: String) -> Bool {
        let latest = versionParts(latestVersion)
        let current = versionParts(currentVersion)
        for index in 0..<max(latest.count, current.count) {
            let latestPart = index < latest.count ? latest[index] : 0
            let currentPart = index < current.count ? current[index] : 0
            if latestPart > currentPart { return true }
            if latestPart < currentPart { return false }
        }
        return false
    }

    private func availableFrameStates(in root: URL) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            guard let files = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            return files.contains { supportedExtensions.contains($0.pathExtension.lowercased()) } ? entry.lastPathComponent : nil
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func selectUpdateNoticeStates(availableStates: [String], currentRotationStates: [String], updateState: String, fallbackStates: [String]) -> [String] {
        let available = Set(availableStates)
        var candidates: [String] = []
        func addCandidate(_ value: String) {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !candidates.contains(name) {
                candidates.append(name)
            }
        }

        let normalized = updateState.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "ruby-update" {
            addCandidate("update")
            addCandidate("ruby-update")
        } else {
            addCandidate(normalized.isEmpty ? "update" : normalized)
            if normalized == "update" {
                addCandidate("ruby-update")
            }
        }
        fallbackStates.forEach(addCandidate)

        var selected: [String] = []
        if let notice = candidates.first(where: { available.contains($0) }) {
            selected.append(notice)
        }
        for state in currentRotationStates where available.contains(state) && !selected.contains(state) {
            selected.append(state)
        }
        return selected
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

        let modeMenu = NSMenu()
        let assistant = NSMenuItem(title: "Assistant mode", action: #selector(selectMode(_:)), keyEquivalent: "")
        assistant.target = self
        assistant.representedObject = "assistant"
        assistant.state = mode == "assistant" ? .on : .off
        modeMenu.addItem(assistant)

        let dance = NSMenuItem(title: "Dance mode", action: #selector(selectMode(_:)), keyEquivalent: "")
        dance.target = self
        dance.representedObject = "dance"
        dance.state = mode == "dance" ? .on : .off
        dance.isEnabled = !danceStates().isEmpty
        modeMenu.addItem(dance)

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let currentDanceStates = danceStates()
        if !currentDanceStates.isEmpty {
            let danceStateMenu = NSMenu()
            for state in currentDanceStates {
                let item = NSMenuItem(title: state, action: #selector(selectDanceState(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state
                item.state = state == danceState ? .on : .off
                danceStateMenu.addItem(item)
            }
            let danceStateItem = NSMenuItem(title: "Dance set", action: nil, keyEquivalent: "")
            danceStateItem.submenu = danceStateMenu
            menu.addItem(danceStateItem)
        }

        let danceSpeedMenu = NSMenu()
        let danceCurrent = NSMenuItem(title: "Current: \(formatDanceFrameInterval())", action: nil, keyEquivalent: "")
        danceCurrent.isEnabled = false
        danceSpeedMenu.addItem(danceCurrent)
        danceSpeedMenu.addItem(.separator())
        for interval in [750, 900, 1000, 1250] {
            let item = NSMenuItem(title: "\(Double(interval) / 1000.0) seconds", action: #selector(selectDanceFrameInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = interval == danceFrameIntervalMs ? .on : .off
            danceSpeedMenu.addItem(item)
        }
        let danceSpeedItem = NSMenuItem(title: "Dance speed", action: nil, keyEquivalent: "")
        danceSpeedItem.submenu = danceSpeedMenu
        menu.addItem(danceSpeedItem)

        menu.addItem(.separator())

        let rotateItem = NSMenuItem(title: "Auto rotate", action: #selector(toggleRotate(_:)), keyEquivalent: "")
        rotateItem.target = self
        rotateItem.state = rotationEnabled ? .on : .off
        rotateItem.isEnabled = mode == "assistant" && !rotationStates.isEmpty
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

        let shortcut = NSMenuItem(title: "Create desktop shortcut", action: #selector(createDesktopShortcut), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)

        let close = NSMenuItem(title: "Close", action: #selector(closeOverlay), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        if isDanceState(state) {
            setMode("dance", danceState: state, save: true)
            return
        }
        setMode("assistant", save: false)
        setState(state)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let requestedMode = sender.representedObject as? String else { return }
        setMode(requestedMode, danceState: danceState, save: true)
    }

    @objc private func selectDanceState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        setMode("dance", danceState: state, save: true)
    }

    @objc private func selectDanceFrameInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Int else { return }
        setDanceFrameInterval(interval, save: true)
    }

    @objc private func toggleRotate(_ sender: NSMenuItem) {
        setRotationEnabled(!rotationEnabled, save: true)
    }

    @objc private func toggleRotationState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? String else { return }
        guard !isUpdateOnlyState(state) && !isDanceState(state) else { return }
        var next = rotationStates.filter { $0 != state }
        if !rotationStates.contains(state) {
            next.append(state)
        }
        setRotationStates(next, save: true)
    }

    @objc private func toggleRotationGroup(_ sender: NSMenuItem) {
        guard let states = sender.representedObject as? [String] else { return }
        let cleanStates = removeUpdateOnlyStates(states).filter { !isDanceState($0) }
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

    @objc private func createDesktopShortcut() {
        do {
            let shortcutPath = try writeDesktopShortcut()
            let alert = NSAlert()
            alert.messageText = "Desktop shortcut created"
            alert.informativeText = shortcutPath.path
            alert.runModal()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not create desktop shortcut"
            alert.runModal()
        }
    }

    private func writeDesktopShortcut() throws -> URL {
        let desktop = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        let shortcutPath = desktop.appendingPathComponent("Ruby Overlay.command")
        var arguments = "--height \(currentHeight) --state \(shellQuote(currentState))"
        if mode == "dance" {
            arguments += " --mode dance --dance-state \(shellQuote(danceState)) --dance-frame-interval-ms \(danceFrameIntervalMs)"
        }
        if rotationEnabled {
            arguments += " --rotate"
        }
        let launcher = args.projectRoot
            .appendingPathComponent("macos", isDirectory: true)
            .appendingPathComponent("Run-RubyOverlay.command")
        let content = """
        #!/bin/zsh
        set -e
        cd \(shellQuote(args.projectRoot.path))
        nohup \(shellQuote(launcher.path)) \(arguments) >/dev/null 2>&1 &

        """
        try content.write(to: shortcutPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shortcutPath.path)
        return shortcutPath
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
                let state = visible[value - 1]
                if isDanceState(state) {
                    setMode("dance", danceState: state, save: false)
                } else {
                    setMode("assistant", save: false)
                    setState(state)
                }
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

    private func formatDanceFrameInterval() -> String {
        if danceFrameIntervalMs % 1000 == 0 {
            return "\(danceFrameIntervalMs / 1000) seconds"
        }
        return String(format: "%.3g seconds", Double(danceFrameIntervalMs) / 1000.0)
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

    private func writeObject(_ object: [String: Any], to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            return
        }
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
