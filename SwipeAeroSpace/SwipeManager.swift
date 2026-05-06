import Cocoa
import Foundation
import Socket
import SwiftUI
import os

enum Direction {
    case next
    case prev

    var value: String {
        switch self {
        case .next:
            "next"
        case .prev:
            "prev"
        }
    }
}

enum GestureState {
    case began
    case changed
    case ended
    case cancelled
}

enum SwipeAxis {
    case undecided
    case horizontal
    case vertical
}

enum SwipeError: Error {
    case SocketError(String)
    case CommandFail(String)
    case Unknown(String)
}

public struct ClientRequest: Codable, Sendable {
    public let command: String
    public let args: [String]
    public let stdin: String
    public let windowId: UInt32?
    public let workspace: String?

    public init(
        args: [String],
        stdin: String,
        windowId: UInt32?,
        workspace: String?
    ) {
        self.command = ""
        self.args = args
        self.stdin = stdin
        self.windowId = windowId
        self.workspace = workspace
    }
}

public struct ServerAnswer: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let serverVersionAndHash: String

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        serverVersionAndHash: String
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.serverVersionAndHash = serverVersionAndHash
    }
}

class SocketInfo: ObservableObject {
    @Published var socketConnected: Bool = false
}

extension Result {
    public var isSuccess: Bool {
        switch self {
        case .success: true
        case .failure: false
        }
    }
}

class SwipeManager {
    // user settings
    @AppStorage("threshold") private var swipeThreshold: Double = 1.0
    private var internalThreshold: Float { Float(swipeThreshold) * 0.05 }
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natrual") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false
    @AppStorage("fingers") private var fingers: String = "Three"
    @AppStorage("multiSwipe") private var multiSwipeEnabled: Bool = true
    @AppStorage("maxSteps") private var maxSteps: Int = 5
    @AppStorage("swipeUpOverview") private var swipeUpOverviewEnabled: Bool = true
    @AppStorage("swipeUpFingers") private var swipeUpFingers: String = "Three"
    // Per-gesture enable/disable. Each defaults to true so out-of-the-box
    // behavior matches the full gesture set; users disable individual ones
    // they find disruptive.
    @AppStorage("gestureLeftEnabled") private var gestureLeftEnabled: Bool = true
    @AppStorage("gestureRightEnabled") private var gestureRightEnabled: Bool = true
    @AppStorage("gestureUpEnabled") private var gestureUpEnabled: Bool = true
    @AppStorage("gestureDownEnabled") private var gestureDownEnabled: Bool = true
    @AppStorage("gestureTapEnabled") private var gestureTapEnabled: Bool = true
    @AppStorage("gestureOptLeftEnabled") private var gestureOptLeftEnabled: Bool = true
    @AppStorage("gestureOptRightEnabled") private var gestureOptRightEnabled: Bool = true
    @AppStorage("gestureOptUpEnabled") private var gestureOptUpEnabled: Bool = true
    @AppStorage("gestureOptDownEnabled") private var gestureOptDownEnabled: Bool = true

    // Tap thresholds in normalized trackpad units (0..1) and seconds.
    // Below internalThreshold * 0.3 the axis stays .undecided, so we treat
    // the gesture as a stationary tap when both timing and motion are tight.
    private var gestureStartTime: TimeInterval = 0
    private let tapMaxDuration: TimeInterval = 0.2
    private let tapMaxMovement: Float = 0.025

    // Option-swipe state. Captured once per gesture at .began so the modifier
    // doesn't flicker mid-swipe. optHorizontalFired enforces fire-once-per-
    // gesture (move-node-to-workspace shouldn't repeat with multiSwipe).
    private var modifierOptionAtGestureStart: Bool = false
    private var optHorizontalFired: Bool = false

    // Chevron deduplication — processTouches fires 60+/sec; only push the
    // controller when the displayed text actually changes.
    private var lastChevronText: String?

    var socketInfo = SocketInfo()

    private var eventTap: CFMachPort? = nil
    private var accDisX: Float = 0
    private var accDisY: Float = 0
    private var swipeUpFired: Bool = false
    private var firedPosition: Int = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var state: GestureState = .ended
    private var swipeAxis: SwipeAxis = .undecided
    private var activeFingerCount: Int = 0
    private var gestureFocusDone: Bool = false
    private var pendingSwipeWork: DispatchWorkItem? = nil
    private var socket: Socket? = nil
    private let workQueue = DispatchQueue(label: "swipe.workspace", qos: .userInteractive)
    private let overlayController = OverlayPanelController()

    private var logger: Logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "Info"
    )

    private func runCommand(args: [String], stdin: String, retry: Bool = false)
        -> Result<String, SwipeError>
    {
        guard let socket = socket else {
            return .failure(.SocketError("No socket created"))
        }
        do {
            let request = try JSONEncoder().encode(
                ClientRequest(args: args, stdin: stdin, windowId: nil, workspace: nil)
            )
            try socket.write(from: request)
            let _ = try Socket.wait(
                for: [socket],
                timeout: 0,
                waitForever: true
            )
            var answer = Data()
            try socket.read(into: &answer)
            let result = try JSONDecoder().decode(
                ServerAnswer.self,
                from: answer
            )
            if result.exitCode != 0 {
                return .failure(.CommandFail(result.stderr))
            }
            return .success(result.stdout)

        } catch let error {
            guard let socketError = error as? Socket.Error else {
                return .failure(.Unknown(error.localizedDescription))
            }
            // if we encouter the socket error
            // try reconnect the socket and rerun the command only once.
            if retry {
                return .failure(.SocketError(socketError.localizedDescription))
            }
            logger.info("Trying reconnect socket...")
            connectSocket(reconnect: true)
            return runCommand(args: args, stdin: stdin, retry: true)
        }
    }

    private func getNonEmptyWorkspaces() -> Result<String, SwipeError> {
        let args = [
            "list-workspaces", "--monitor", "focused", "--empty", "no",
        ]
        return runCommand(args: args, stdin: "")
    }

    func showWorkspaceOverview() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            // Phase 1: quick query (3 socket calls) — show immediately
            let (shellWorkspaces, originalWs, focusedMonitorId) = self.queryWorkspacesShell()
            let originalWsOpt: String? = originalWs.isEmpty ? nil : originalWs

            let makeCallbacks: () -> (
                onSelect: (String) -> Void,
                onPreview: (String) -> Void,
                onRevert: () -> Void
            ) = { [weak self] in
                (
                    onSelect: { wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onPreview: { wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onRevert: {
                        guard let originalWs = originalWsOpt else { return }
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", originalWs], stdin: "")
                        }
                    }
                )
            }

            let cb = makeCallbacks()
            DispatchQueue.main.async {
                self.overlayController.show(
                    workspaces: shellWorkspaces,
                    focusedMonitorId: focusedMonitorId,
                    onSelect: cb.onSelect,
                    onPreview: cb.onPreview,
                    onRevert: cb.onRevert
                )
            }

            // Phase 2: fetch window details and update in place
            let fullWorkspaces = self.queryWindows(for: shellWorkspaces)
            DispatchQueue.main.async {
                guard self.overlayController.isVisible else { return }
                self.overlayController.update(workspaces: fullWorkspaces)
            }
        }
    }

    /// Quick query: workspace names, monitors, focused state (4 socket calls)
    /// Returns (workspaces, focusedWorkspaceName, focusedMonitorId)
    private func queryWorkspacesShell() -> ([WorkspaceInfo], String, String?) {
        let focusedResult = runCommand(
            args: ["list-workspaces", "--focused"], stdin: ""
        )
        let focusedWs = (try? focusedResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""

        // Get the monitor ID for the focused workspace
        let focusedMonitorResult = runCommand(
            args: ["list-workspaces", "--focused", "--format", "%{monitor-id}"],
            stdin: ""
        )
        let focusedMonitorId = (try? focusedMonitorResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let monitorResult = runCommand(
            args: [
                "list-monitors", "--format", "%{monitor-id}|%{monitor-name}",
            ],
            stdin: ""
        )
        var monitorNames: [String: String] = [:]
        if let monitorOutput = try? monitorResult.get() {
            for line in monitorOutput.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                if parts.count == 2 {
                    monitorNames[String(parts[0])] = String(parts[1])
                }
            }
        }

        let allResult = runCommand(
            args: [
                "list-workspaces", "--monitor", "all", "--empty", "no",
                "--format", "%{workspace}|%{monitor-id}",
            ],
            stdin: ""
        )
        guard let allOutput = try? allResult.get() else { return ([], focusedWs, focusedMonitorId) }

        let workspaces: [WorkspaceInfo] = allOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = String(parts[0])
            let monitorId = String(parts[1])
            return WorkspaceInfo(
                id: name,
                windows: [],
                isFocused: name == focusedWs,
                monitorId: monitorId,
                monitorName: monitorNames[monitorId] ?? "Monitor \(monitorId)"
            )
        }
        return (workspaces, focusedWs, focusedMonitorId)
    }

    /// Fetch window details for a list of workspaces (1 socket call per workspace)
    private func queryWindows(for workspaces: [WorkspaceInfo]) -> [WorkspaceInfo] {
        return workspaces.map { ws in
            let winResult = runCommand(
                args: [
                    "list-windows", "--workspace", ws.id,
                    "--format", "%{app-name}|%{window-title}",
                ],
                stdin: ""
            )
            let windows: [WindowInfo]
            if let winOutput = try? winResult.get(),
                !winOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                windows = winOutput.split(separator: "\n").enumerated().map {
                    idx, line in
                    let parts = line.split(separator: "|", maxSplits: 1)
                    return WindowInfo(
                        id: "\(ws.id)-\(idx)",
                        appName: parts.first.map(String.init) ?? "Unknown",
                        windowTitle: parts.count > 1
                            ? String(parts[1]) : ""
                    )
                }
            } else {
                windows = []
            }
            return WorkspaceInfo(
                id: ws.id,
                windows: windows,
                isFocused: ws.isFocused,
                monitorId: ws.monitorId,
                monitorName: ws.monitorName
            )
        }
    }

    @discardableResult
    private func switchWorkspace(direction: Direction) -> Result<
        String, SwipeError
    > {

        var res = runCommand(
            args: ["list-workspaces", "--monitor", "mouse", "--visible"],
            stdin: ""
        )
        guard let mouse_on = try? res.get() else {
            return res
        }
        res = runCommand(args: ["workspace", mouse_on], stdin: "")
        guard (try? res.get()) != nil else {
            return res
        }

        var args = ["workspace", direction.value]
        if wrapWorkspace {
            args.append("--wrap-around")
        }
        var stdin = ""
        if skipEmpty {
            res = getNonEmptyWorkspaces()
            guard let ws = try? res.get() else {
                return res
            }
            stdin = ws
            if stdin != "" {
                // explicitly insert '--stdin'
                args.append("--stdin")
            }
        }
        return runCommand(args: args, stdin: stdin)
    }

    func nextWorkspace() {
        switch switchWorkspace(direction: .next) {
        case .success: return
        case .failure(let err): logger.error("\(err.localizedDescription)")
        }
    }

    func prevWorkspace() {
        switch switchWorkspace(direction: .prev) {
        case .success: return
        case .failure(let err): logger.error("\(err.localizedDescription)")
        }

    }

    func connectSocket(reconnect: Bool = false) {
        if socket != nil && !reconnect {
            logger.warning("socket is connected")
            return
        }

        let socket_path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        do {
            socket = try Socket.create(
                family: .unix,
                type: .stream,
                proto: .unix
            )
            try socket?.connect(to: socket_path)
            socketInfo.socketConnected = true
            logger.info("connect to socket \(socket_path)")
        } catch let error {
            logger.error("Unexpected error: \(error.localizedDescription)")
        }
    }

    func start() {
        if eventTap != nil {
            logger.warning("SwipeManager is already started")
            return
        }
        logger.info("SwipeManager start")
        // Tap gesture events for our handlers, plus scroll-wheel and swipe so
        // we can swallow them while a 3F gesture is in progress. macOS emits
        // both gesture and scroll/swipe streams during a 3F swipe; without
        // this, the underlying app still receives momentum/back-forward.
        let mask = NSEvent.EventTypeMask.gesture.rawValue
            | NSEvent.EventTypeMask.scrollWheel.rawValue
            | NSEvent.EventTypeMask.swipe.rawValue
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, cgEvent, me in
                let wrapper = Unmanaged<SwipeManager>.fromOpaque(me!)
                    .takeUnretainedValue()
                return wrapper.eventHandler(
                    proxy: proxy,
                    eventType: type,
                    cgEvent: cgEvent
                )
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if eventTap == nil {
            logger.error("SwipeManager couldn't create event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            runLoopSource,
            CFRunLoopMode.commonModes
        )
        CGEvent.tapEnable(tap: eventTap!, enable: true)

        connectSocket()
    }

    func stop() {
        logger.info("stop the app")
        socket?.close()
    }

    private func eventHandler(
        proxy: CGEventTapProxy,
        eventType: CGEventType,
        cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue,
            let nsEvent = NSEvent(cgEvent: cgEvent)
        {
            touchEventHandler(nsEvent)
        } else if eventType == .scrollWheel
            || eventType.rawValue == NSEvent.EventType.swipe.rawValue
        {
            // While a 3F gesture is in progress, swallow scroll/swipe events so
            // the underlying app doesn't also scroll the view or do its own
            // back/forward navigation. Pass through otherwise (2F scrolls etc).
            if state == .began && (activeFingerCount == 3 || activeFingerCount == 4) {
                return nil
            }
        } else if eventType == .tapDisabledByUserInput
            || eventType == .tapDisabledByTimeout
        {
            logger.info("SwipeManager tap disabled \(eventType.rawValue)")
            CGEvent.tapEnable(tap: eventTap!, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()

        // Sometimes there are empty touch events that we have to skip. There are no empty touch events if Mission Control or App Expose use 3-finger swipes though.
        if touches.isEmpty {
            return
        }
        let touchesCount =
            touches.allSatisfy({ $0.phase == .ended }) ? 0 : touches.count
        if touchesCount == 0 {
            stopGesture()
        } else {
            processTouches(touches: touches, count: touchesCount)
        }
    }

    private func stopGesture() {
        if state == .began {
            state = .ended
            let elapsed = ProcessInfo.processInfo.systemUptime - gestureStartTime
            let totalMovement: Float = hypot(accDisX, accDisY)
            if gestureTapEnabled
                && activeFingerCount == 3
                && swipeAxis == .undecided
                && elapsed < tapMaxDuration
                && totalMovement < tapMaxMovement
                && !modifierOptionAtGestureStart
            {
                handleTap()
                clearEventState()
                return
            }
            if swipeAxis != .vertical {
                handleGesture()
            }
            clearEventState()
        }
    }

    private func handleTap() {
        showToast("Float toggle")
        workQueue.async { [weak self] in
            _ = self?.runCommand(args: ["layout", "floating", "tiling"], stdin: "")
        }
    }

    private func showToast(_ label: String) {
        // Action fired — chevron's job is done; hand off to the toast.
        overlayController.hideChevron()
        lastChevronText = nil
        overlayController.showToast(label: label, duration: 0.8)
    }

    private func processTouches(touches: Set<NSTouch>, count: Int) {
        let hFingerCount = fingers == "Three" ? 3 : 4
        let vFingerCount = swipeUpFingers == "Three" ? 3 : 4
        if state != .began && (count == hFingerCount || count == vFingerCount) {
            state = .began
            activeFingerCount = count
            gestureStartTime = ProcessInfo.processInfo.systemUptime
            modifierOptionAtGestureStart = NSEvent.modifierFlags.contains(.option)
        }
        // Update finger count while axis is still undecided — touch count
        // can fluctuate as fingers land, so use the latest stable count
        if state == .began && swipeAxis == .undecided {
            activeFingerCount = count
        }
        if state == .began {
            let (disX, disY) = swipeDistance(touches: touches)
            accDisX += disX
            accDisY += disY

            // Lock axis once we have enough movement
            if swipeAxis == .undecided {
                let threshold = internalThreshold * 0.3
                if abs(accDisX) > threshold || abs(accDisY) > threshold {
                    swipeAxis =
                        abs(accDisY) > abs(accDisX) ? .vertical : .horizontal
                }
            }

            // Chevron buildup indicator. Appears once axis locks and tracks
            // the dominant direction. Deduped against lastChevronText to keep
            // SwiftUI updates off the per-frame path. Hidden when an action
            // fires (showToast handoff) or when the gesture clears.
            if swipeAxis != .undecided {
                let prefix = modifierOptionAtGestureStart ? "⌥ " : ""
                let arrow: String
                if swipeAxis == .horizontal {
                    arrow = accDisX >= 0 ? "→" : "←"
                } else {
                    arrow = accDisY >= 0 ? "↑" : "↓"
                }
                let text = prefix + arrow
                if text != lastChevronText {
                    lastChevronText = text
                    overlayController.showChevron(text: text)
                }
            }

            // Vertical swipes: option (window ops) > overview HUD (legacy) > direct commands.
            // Holding option ALWAYS routes to the option branch — individual
            // gesture toggles gate command firing per direction. We never fall
            // through from a disabled option-gesture to the non-option handler.
            if swipeAxis == .vertical && activeFingerCount == vFingerCount {
                let threshold = internalThreshold * 0.5
                if modifierOptionAtGestureStart {
                    // ⌥ + 3F UP -> move-node-to-monitor next.
                    // ⌥ + 3F DOWN -> close.
                    if !swipeUpFired && accDisY > threshold {
                        swipeUpFired = true
                        if gestureOptUpEnabled {
                            showToast("⌥ ↑ Move to monitor")
                            workQueue.async { [weak self] in
                                _ = self?.runCommand(args: ["move-node-to-monitor", "next"], stdin: "")
                            }
                        }
                    } else if !swipeUpFired && accDisY < -threshold {
                        swipeUpFired = true
                        if gestureOptDownEnabled {
                            showToast("⌥ ↓ Close")
                            workQueue.async { [weak self] in
                                _ = self?.runCommand(args: ["close"], stdin: "")
                            }
                        }
                    }
                } else if swipeUpOverviewEnabled {
                    if !swipeUpFired && accDisY > threshold {
                        swipeUpFired = true
                        if !overlayController.isVisible {
                            showWorkspaceOverview()
                        }
                    }
                    // Mid-gesture: swipe back down dismisses when accDisY reverses
                    if swipeUpFired && accDisY < threshold * 0.5 {
                        swipeUpFired = false
                        DispatchQueue.main.async { [weak self] in
                            self?.overlayController.dismiss()
                        }
                    }
                    // New gesture: swipe down dismisses if overlay is already open
                    if !swipeUpFired && accDisY < -threshold
                        && overlayController.isVisible
                    {
                        swipeUpFired = true
                        DispatchQueue.main.async { [weak self] in
                            self?.overlayController.dismiss()
                        }
                    }
                } else {
                    // 3F UP -> focus next monitor. 3F DOWN -> workspace-back-and-forth.
                    // Fire-once-per-gesture; reset is handled in clearEventState().
                    if !swipeUpFired && accDisY > threshold {
                        swipeUpFired = true
                        if gestureUpEnabled {
                            showToast("Monitor →")
                            workQueue.async { [weak self] in
                                _ = self?.runCommand(args: ["focus-monitor", "next"], stdin: "")
                            }
                        }
                    } else if !swipeUpFired && accDisY < -threshold {
                        swipeUpFired = true
                        if gestureDownEnabled {
                            showToast("⇄")
                            workQueue.async { [weak self] in
                                _ = self?.runCommand(args: ["workspace-back-and-forth"], stdin: "")
                            }
                        }
                    }
                }
            }

            // Horizontal swipes: option (move window) > multiSwipe (live workspace switch).
            // Non-multi branch (no option, multiSwipe off) is handled in handleGesture().
            if swipeAxis == .horizontal && modifierOptionAtGestureStart {
                let threshold = internalThreshold
                if !optHorizontalFired {
                    if accDisX > threshold {
                        let dir = naturalSwipe ? "prev" : "next"
                        optHorizontalFired = true
                        let enabled = dir == "next" ? gestureOptRightEnabled : gestureOptLeftEnabled
                        if enabled {
                            showToast(dir == "next" ? "⌥ → Move next" : "⌥ ← Move prev")
                            workQueue.async { [weak self] in
                                _ = self?.runCommand(
                                    args: ["move-node-to-workspace", "--wrap-around", dir],
                                    stdin: ""
                                )
                            }
                        }
                    } else if accDisX < -threshold {
                        let dir = naturalSwipe ? "next" : "prev"
                        optHorizontalFired = true
                        let enabled = dir == "next" ? gestureOptRightEnabled : gestureOptLeftEnabled
                        if enabled {
                            showToast(dir == "next" ? "⌥ → Move next" : "⌥ ← Move prev")
                            workQueue.async { [weak self] in
                                _ = self?.runCommand(
                                    args: ["move-node-to-workspace", "--wrap-around", dir],
                                    stdin: ""
                                )
                            }
                        }
                    }
                }
            } else if swipeAxis == .horizontal && multiSwipeEnabled {
                let threshold = internalThreshold
                let rawPosition = Int(accDisX / threshold)
                let targetPosition = max(-maxSteps, min(maxSteps, rawPosition))
                let delta = targetPosition - firedPosition

                if delta != 0 {
                    let direction: Direction
                    if delta > 0 {
                        direction = naturalSwipe ? .prev : .next
                    } else {
                        direction = naturalSwipe ? .next : .prev
                    }
                    firedPosition = targetPosition

                    // Cancel any in-flight work — we either dispatch new work
                    // below or the user moved into a disabled direction.
                    pendingSwipeWork?.cancel()

                    let dirEnabled = direction == .next ? gestureRightEnabled : gestureLeftEnabled
                    guard dirEnabled else {
                        // Direction disabled by Settings — consume delta silently.
                        return
                    }

                    showToast(direction == .next ? "Workspace →" : "Workspace ←")
                    let stepsToFire = abs(delta)

                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }

                        // Focus the workspace under the cursor once per gesture
                        if !self.gestureFocusDone {
                            let res = self.runCommand(
                                args: ["list-workspaces", "--monitor", "mouse", "--visible"],
                                stdin: ""
                            )
                            if let mouseWs = try? res.get() {
                                _ = self.runCommand(args: ["workspace", mouseWs], stdin: "")
                            }
                            self.gestureFocusDone = true
                        }

                        // Fire only the lean next/prev calls
                        for _ in 0..<stepsToFire {
                            var args = ["workspace", direction.value]
                            var stdin = ""
                            if self.wrapWorkspace {
                                args.append("--wrap-around")
                            }
                            if self.skipEmpty {
                                if let ws = try? self.getNonEmptyWorkspaces().get(), !ws.isEmpty {
                                    stdin = ws
                                    args.append("--stdin")
                                }
                            }
                            switch self.runCommand(args: args, stdin: stdin) {
                            case .success: continue
                            case .failure(let err):
                                self.logger.error("\(err.localizedDescription)")
                                return
                            }
                        }
                    }
                    pendingSwipeWork = workItem
                    workQueue.async(execute: workItem)
                }
            }
        }
    }

    private func clearEventState() {
        accDisX = 0
        accDisY = 0
        firedPosition = 0
        swipeUpFired = false
        optHorizontalFired = false
        swipeAxis = .undecided
        activeFingerCount = 0
        gestureFocusDone = false
        prevTouchPositions.removeAll()
        // Hide chevron if it was shown but no action ever fired.
        if lastChevronText != nil {
            overlayController.hideChevron()
            lastChevronText = nil
        }
    }

    private func handleGesture() {
        // If multi-swipe is enabled, switches already fired live during the gesture
        if multiSwipeEnabled {
            return
        }
        // option was held — option-swipe path already fired (or chose not to) mid-gesture;
        // never fall back to a regular workspace switch when the user held option.
        if modifierOptionAtGestureStart {
            return
        }
        let threshold = internalThreshold
        if abs(accDisX) < threshold {
            return
        }
        let direction: Direction =
            if naturalSwipe {
                accDisX < 0 ? .next : .prev
            } else {
                accDisX < 0 ? .prev : .next
            }
        let dirEnabled = direction == .next ? gestureRightEnabled : gestureLeftEnabled
        guard dirEnabled else { return }
        showToast(direction == .next ? "Workspace →" : "Workspace ←")
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: direction) {
            case .success: return
            case .failure(let err):
                self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    private func swipeDistance(touches: Set<NSTouch>) -> (Float, Float) {
        var allRight = true
        var allLeft = true
        var allUp = true
        var allDown = true
        var sumDisX = Float(0)
        var sumDisY = Float(0)
        var activeTouches = 0
        for touch in touches {
            let (disX, disY) = touchDistance(touch)
            allRight = allRight && disX >= 0
            allLeft = allLeft && disX <= 0
            allUp = allUp && disY >= 0
            allDown = allDown && disY <= 0
            sumDisX += disX
            sumDisY += disY

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] =
                    touch.normalizedPosition
                activeTouches += 1
            }
        }

        // Average across fingers so threshold behaves consistently
        // regardless of finger count
        let count = max(activeTouches, 1)
        var resultX = sumDisX / Float(count)
        var resultY = sumDisY / Float(count)

        // All fingers should move in the same direction for each axis.
        if !allRight && !allLeft {
            resultX = 0
        }
        if !allUp && !allDown {
            resultY = 0
        }

        return (resultX, resultY)
    }

    private func touchDistance(_ touch: NSTouch) -> (Float, Float) {
        guard let prevPosition = prevTouchPositions["\(touch.identity)"] else {
            return (0, 0)
        }
        let position = touch.normalizedPosition
        return (
            Float(position.x - prevPosition.x),
            Float(position.y - prevPosition.y)
        )
    }
}
