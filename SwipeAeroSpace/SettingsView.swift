import SwiftUI

struct SettingsView: View {
    @AppStorage("threshold") private static var swipeThreshold: Double = 1.0
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natrual") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false
    @AppStorage("fingers") private var fingers: String = "Three"
    @AppStorage("multiSwipe") private var multiSwipeEnabled: Bool = true
    @AppStorage("maxSteps") private var maxSteps: Int = 5
    @AppStorage("swipeUpOverview") private var swipeUpOverviewEnabled: Bool = true
    @AppStorage("swipeUpFingers") private var swipeUpFingers: String = "Three"
    @AppStorage("gestureLeftEnabled") private var gestureLeftEnabled: Bool = true
    @AppStorage("gestureRightEnabled") private var gestureRightEnabled: Bool = true
    @AppStorage("gestureUpEnabled") private var gestureUpEnabled: Bool = true
    @AppStorage("gestureDownEnabled") private var gestureDownEnabled: Bool = true
    @AppStorage("gestureTapEnabled") private var gestureTapEnabled: Bool = true
    @AppStorage("gestureOptLeftEnabled") private var gestureOptLeftEnabled: Bool = true
    @AppStorage("gestureOptRightEnabled") private var gestureOptRightEnabled: Bool = true
    @AppStorage("gestureOptUpEnabled") private var gestureOptUpEnabled: Bool = true
    @AppStorage("gestureOptDownEnabled") private var gestureOptDownEnabled: Bool = true

    @State private var numberFormatter: NumberFormatter = {
        var nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf
    }()

    let fingerOptions = ["Three", "Four"]

    var swipeManager: SwipeManager
    @ObservedObject var socketInfo: SocketInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: - Connection
            sectionHeader("Connection")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(socketInfo.socketConnected ? .green : .red)
                    Text(socketInfo.socketConnected ? "Connected to AeroSpace" : "Not connected")
                }
                if !socketInfo.socketConnected {
                    Button("Reconnect") {
                        swipeManager.connectSocket(reconnect: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - Horizontal Swipe
            sectionHeader("Horizontal Swipe")
            VStack(alignment: .leading, spacing: 12) {
                settingRow(
                    title: "Sensitivity",
                    description: "Lower values require less finger movement to switch. Default: 1.0"
                ) {
                    TextField(
                        "Sensitivity",
                        value: SettingsView.$swipeThreshold,
                        formatter: numberFormatter,
                        prompt: Text("1.0")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                }

                settingRow(
                    title: "Number of Fingers",
                    description: "How many fingers trigger a horizontal workspace switch"
                ) {
                    Picker("", selection: $fingers) {
                        ForEach(fingerOptions, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                }

                settingRow(
                    title: "Natural Swipe",
                    description: "Swipe direction matches finger movement, like trackpad scrolling"
                ) {
                    Toggle("", isOn: $naturalSwipe)
                        .labelsHidden()
                }

                settingRow(
                    title: "Wrap Around",
                    description: "Swiping past the last workspace jumps back to the first"
                ) {
                    Toggle("", isOn: $wrapWorkspace)
                        .labelsHidden()
                }

                settingRow(
                    title: "Skip Empty",
                    description: "Only land on workspaces that have windows"
                ) {
                    Toggle("", isOn: $skipEmpty)
                        .labelsHidden()
                }

                settingRow(
                    title: "Multi-Workspace Swipe",
                    description: "Longer swipes jump multiple workspaces in one gesture"
                ) {
                    Toggle("", isOn: $multiSwipeEnabled)
                        .labelsHidden()
                }

                if multiSwipeEnabled {
                    settingRow(
                        title: "Max per Swipe: \(maxSteps)",
                        description: "Maximum number of workspaces a single swipe can jump"
                    ) {
                        Slider(
                            value: Binding(
                                get: { Double(maxSteps) },
                                set: { maxSteps = Int($0) }
                            ),
                            in: 2...9,
                            step: 1
                        )
                        .frame(maxWidth: 140)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - Vertical Swipe
            sectionHeader("Vertical Swipe")
            VStack(alignment: .leading, spacing: 12) {
                settingRow(
                    title: "Show Workspace Overview",
                    description: swipeUpOverviewEnabled
                        ? "Swipe up to see all workspaces and their apps."
                        : "Off: swipe up focuses the next monitor; swipe down toggles back-and-forth between workspaces."
                ) {
                    Toggle("", isOn: $swipeUpOverviewEnabled)
                        .labelsHidden()
                }

                if swipeUpOverviewEnabled {
                    settingRow(
                        title: "Number of Fingers",
                        description: "How many fingers trigger the workspace overview"
                    ) {
                        Picker("", selection: $swipeUpFingers) {
                            ForEach(fingerOptions, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 140)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - Gestures
            sectionHeader("Gestures")
            VStack(alignment: .leading, spacing: 12) {
                gestureRow("3F Left",         "Switch to prev workspace",      $gestureLeftEnabled)
                gestureRow("3F Right",        "Switch to next workspace",      $gestureRightEnabled)
                gestureRow("3F Up",           "Focus next monitor",            $gestureUpEnabled)
                gestureRow("3F Down",         "Back-and-forth workspace",      $gestureDownEnabled)
                gestureRow("3F Tap",          "Toggle floating layout",        $gestureTapEnabled)
                gestureRow("⌥ + 3F Left",    "Move window to prev workspace", $gestureOptLeftEnabled)
                gestureRow("⌥ + 3F Right",   "Move window to next workspace", $gestureOptRightEnabled)
                gestureRow("⌥ + 3F Up",      "Move window to next monitor",   $gestureOptUpEnabled)
                gestureRow("⌥ + 3F Down",    "Close window",                  $gestureOptDownEnabled)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            sectionDivider()

            // MARK: - General
            sectionHeader("General")
            VStack(alignment: .leading, spacing: 12) {
                LaunchAtLogin.Toggle {
                    Text("Launch at Login")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .padding(.vertical, 8)
        .frame(width: 600)
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func sectionDivider() -> some View {
        Divider()
            .padding(.horizontal, 24)
    }

    private func settingRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
    }

    private func gestureRow(_ title: String, _ description: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 110, alignment: .leading)
            }
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var swipeManager = SwipeManager()
    static var previews: some View {
        SettingsView(
            swipeManager: swipeManager,
            socketInfo: swipeManager.socketInfo
        )
    }
}
