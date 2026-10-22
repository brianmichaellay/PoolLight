// xcode: set sdk=iOS

import SwiftUI
import UIKit
import Network
import SystemConfiguration.CaptiveNetwork

// MARK: - Networking helpers (run off the main actor)

/// Thread-safe holder for Bonjour browse results.
private final class EndpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NWEndpoint] = []

    var endpoints: [NWEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: [NWEndpoint]) {
        lock.lock(); defer { lock.unlock() }
        stored = newValue
    }
}

/// Ensures a continuation is resumed exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<String?, Never>, with value: String?) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume { continuation.resume(returning: value) }
    }
}

/// A Wi-Fi network reported by the device's scan.
struct WiFiNetwork: Hashable, Sendable {
    let ssid: String
    /// Signal strength in dBm, if the device reported one.
    let rssi: Int?

    /// Short description of the signal, for display in the picker.
    var signalDescription: String? {
        guard let rssi else { return nil }
        if rssi >= -50 { return "Excellent" }
        if rssi >= -60 { return "Good" }
        if rssi >= -70 { return "Fair" }
        return "Weak"
    }
}

enum PoolLightNetwork {
    private static let session = URLSession(configuration: .ephemeral)

    /// Performs an HTTP request against the device. Throws on connection errors.
    nonisolated static func request(
        host: String,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval
    ) async throws -> (body: String, status: Int) {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (String(data: data, encoding: .utf8) ?? "", status)
    }

    /// Parses the device's /scan reply, which is HTML <option> tags like
    /// `<option value="BLAN">BLAN (-44 dBm)</option>`. Duplicates (several access points with
    /// the same name) are collapsed to the strongest signal, and the result is sorted strongest first.
    nonisolated static func parseNetworkList(_ body: String) -> [WiFiNetwork] {
        let optionPattern = /<option\s+value="([^"]*)"[^>]*>([^<]*)<\/option>/
        let signalPattern = /\((-?\d+)\s*dBm\)/

        var strongest: [String: Int] = [:]
        var order: [String] = []
        for match in body.matches(of: optionPattern) {
            let ssid = decodeHTMLEntities(String(match.1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty else { continue }
            let rssi = body[match.range].firstMatch(of: signalPattern).flatMap { Int($0.1) } ?? Int.min
            if let existing = strongest[ssid] {
                strongest[ssid] = max(existing, rssi)
            } else {
                strongest[ssid] = rssi
                order.append(ssid)
            }
        }

        return order
            .map { WiFiNetwork(ssid: $0, rssi: strongest[$0] == Int.min ? nil : strongest[$0]) }
            .sorted { ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min) }
    }

    nonisolated private static func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Returns the IPv4 address for a host. An IP address is returned as is; a hostname is looked up.
    nonisolated static func resolveIPv4Address(of host: String) async -> String? {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil as String? }
            defer { freeaddrinfo(result) }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                return nil
            }
            return String(cString: buffer)
        }.value
    }

    /// State the device wrote into its control page (nil for anything it didn't include).
    struct DeviceState: Sendable {
        var power: Bool?
        var color: String?
        var pulseDelay: Int?
    }

    /// Reads power, selected color and pulse delay from the device's page, e.g.
    /// `<input id="power" type="checkbox" checked/>`, `<input type="radio" name="color" value="4" checked>`
    /// and `<input id="pulseDelay" ... value="500">`.
    nonisolated static func parseDeviceState(_ html: String) -> DeviceState {
        var state = DeviceState()

        if let tag = html.firstMatch(of: /<input[^>]*id="power"[^>]*>/) {
            state.power = tag.0.contains("checked")
        }

        for tag in html.matches(of: /<input[^>]*name="color"[^>]*>/) where tag.0.contains("checked") {
            if let value = tag.0.firstMatch(of: /value="(\d+)"/) {
                state.color = String(value.1)
            }
            break
        }

        if let tag = html.firstMatch(of: /<input[^>]*id="pulseDelay"[^>]*>/),
           let value = tag.0.firstMatch(of: /value="(\d+)"/) {
            state.pulseDelay = Int(value.1)
        }
        return state
    }

    /// True if the host answers /identity with "poollight".
    nonisolated static func isPoolLight(_ host: String, timeout: TimeInterval) async -> Bool {
        guard let result = try? await request(host: host, path: "/identity", timeout: timeout),
              (200..<300).contains(result.status) else { return false }
        return result.body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "poollight"
    }

    /// Checks hosts concurrently (sliding window) and returns the first one that is a Pool Light.
    nonisolated static func firstPoolLight(
        in hosts: [String],
        timeout: TimeInterval,
        maxConcurrent: Int,
        progress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            var iterator = hosts.makeIterator()
            var finished = 0

            func addNext() {
                guard let host = iterator.next() else { return }
                group.addTask { await isPoolLight(host, timeout: timeout) ? host : nil }
            }

            for _ in 0..<min(maxConcurrent, hosts.count) { addNext() }
            while let result = await group.next() {
                finished += 1
                if let result {
                    group.cancelAll()
                    return result
                }
                if let progress { await progress(finished) }
                addNext()
            }
            return nil
        }
    }

    /// Browses for _http._tcp Bonjour services and returns their endpoints.
    nonisolated static func browseBonjour(timeout: TimeInterval) async -> [NWEndpoint] {
        let box = EndpointBox()
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            box.set(results.map(\.endpoint))
        }
        browser.start(queue: .global())

        let deadline = Date().addingTimeInterval(timeout)
        var firstSeen: Date?
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if !box.endpoints.isEmpty {
                let seen = firstSeen ?? Date()
                firstSeen = seen
                // Give other services a moment to show up, then stop early
                if Date().timeIntervalSince(seen) > 0.7 { break }
            }
        }
        browser.cancel()
        return box.endpoints
    }

    /// Resolves a Bonjour endpoint to an IPv4 address by opening a connection to it.
    nonisolated static func resolveIPv4(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var address: String?
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
                       case let .ipv4(ipv4) = host {
                        // Description can carry an interface suffix like "%en0"
                        address = "\(ipv4)".components(separatedBy: "%").first
                    }
                    connection.cancel()
                    once.resume(continuation, with: address)
                case .failed, .cancelled:
                    once.resume(continuation, with: nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                connection.cancel()
                once.resume(continuation, with: nil)
            }
        }
    }
}

/// A small preview of one of the light's 12 colors/shows, drawn to resemble the controller's buttons.
struct ColorSwatchView: View {
    let colorID: String
    var size: CGFloat = 28

    private let white = Color.white
    private let magenta = Color(red: 0.86, green: 0.15, blue: 0.62)
    private let blue = Color(red: 0.12, green: 0.38, blue: 0.95)
    private let green = Color(red: 0.10, green: 0.70, blue: 0.35)
    private let teal = Color(red: 0.05, green: 0.65, blue: 0.70)
    private let red = Color(red: 0.90, green: 0.12, blue: 0.18)
    private let orange = Color(red: 0.98, green: 0.52, blue: 0.10)
    private let gold = Color(red: 0.98, green: 0.80, blue: 0.20)
    private let purple = Color(red: 0.55, green: 0.25, blue: 0.80)
    private let navy = Color(red: 0.08, green: 0.15, blue: 0.50)

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25)
                    .stroke(Color.gray.opacity(0.45), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var content: some View {
        switch colorID {
        case "1": stripes([white, magenta, blue, green])
        case "2": stripes([red, orange, gold, green, blue, purple]).scaleEffect(1.7).rotationEffect(.degrees(35))
        case "3": stripes([purple, gold, teal, magenta, blue], vertical: false)
        case "4": stripes([blue, teal, green, teal, blue], vertical: false)
        case "5": stripes([red, white, blue, white, red], vertical: false)
        case "6": LinearGradient(colors: [orange, red, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "7": stripes([navy, gold, red, green, white, blue])
        case "8": solid(blue)
        case "9": solid(green)
        case "10": solid(red)
        case "11": solid(white)
        case "12": solid(magenta)
        default: Color.gray
        }
    }

    private func solid(_ color: Color) -> some View {
        LinearGradient(colors: [color.opacity(0.85), color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func stripes(_ colors: [Color], vertical: Bool = true) -> some View {
        Group {
            if vertical {
                HStack(spacing: 0) { ForEach(colors.indices, id: \.self) { colors[$0] } }
            } else {
                VStack(spacing: 0) { ForEach(colors.indices, id: \.self) { colors[$0] } }
            }
        }
    }
}

/// Renders swatches to images once, since menu items can only show images (not live views).
@MainActor
enum ColorSwatchImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for colorID: String) -> UIImage {
        if let cached = cache[colorID] { return cached }
        let renderer = ImageRenderer(content: ColorSwatchView(colorID: colorID))
        renderer.scale = 3
        // Original rendering keeps the colors; menus would otherwise tint the image
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
        cache[colorID] = image
        return image
    }
}

/// App info sheet.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image("AboutIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 25))
                .shadow(radius: 8)

            VStack(spacing: 6) {
                Text("J&J ColorSplash XG Light Control")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Rev \(version)")
                Text("Created by Brian Lay")
                Text("2026")
            }
            .foregroundColor(.secondary)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
    }
}

/// A circle that fills up over `duration` seconds, so a long operation doesn't look frozen.
struct OperationProgressRing: View {
    let start: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let progress = min(1, context.date.timeIntervalSince(start) / max(duration, 0.1))
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastDeviceAddress") private var lastDeviceAddress = ""
    /// Picker tag for the "Enter manually…" option
    static let manualNetworkTag = "__manual__"
    @State private var ssid = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var availableNetworks: [WiFiNetwork] = []
    @State private var selectedNetwork = ContentView.manualNetworkTag
    @State private var isScanningNetworks = false
    enum DiscoveryStage {
        case idle
        case domain
        case network
        case setup
        case connectSetup
        case reset
        case complete
    }

    @State private var selectedColor = "1"
    @State private var lightOn = true
    @State private var pulseDelay = "50"
    @State private var advancedExpanded = false
    @State private var statusMessage = "Searching for poollight.local..."
    @State private var deviceAddress: String? = nil
    /// Numeric IP of the device for display (deviceAddress may be a hostname like poollight.local)
    @State private var deviceIP: String? = nil
    /// Values just applied from the device's state; their onChange handlers shouldn't send a command
    @State private var appliedPower: Bool? = nil
    @State private var appliedColor: String? = nil
    /// A pulse command is running; the ESP32 handles these one at a time so input is locked
    @State private var isBusy = false
    @State private var operationName = ""
    @State private var operationStart = Date()
    @State private var operationDuration: TimeInterval = 0
    /// Screen position of the Light On switch, so the glow can sit behind it
    @State private var toggleFrame: CGRect = .zero
    @State private var showAbout = false
    @State private var initialDiscoveryDone = false
    @State private var isDiscovering = false
    @State private var discoveryStage: DiscoveryStage = .idle
    @State private var scanProgress: Double = 0
    @State private var showSetupForm = false
    @State private var showConnectSetup = false
    @State private var showResetInstruction = false
    // domain the ESP will register (router hostname)
    let deviceHost = "poollight"
    let deviceLocalHost = "poollight.local"
    let setupAddress = "192.168.4.1"
    let colorOptions = [
        ("1", "Peruvian Paradise"),
        ("2", "Super Nova"),
        ("3", "Northern Lights"),
        ("4", "Tidal Wave"),
        ("5", "Patriot Dream"),
        ("6", "Desert Skies"),
        ("7", "Nova"),
        ("8", "Parisian Blue"),
        ("9", "New Zealand Green"),
        ("10", "Brazilian Red"),
        ("11", "Arctic White"),
        ("12", "Miami Pink")
    ]

    var body: some View {
        NavigationView {
            Form {
                if deviceAddress == nil {
                    if showSetupForm {
                        Section(header: Text("Setup Wi-Fi")) {
                            Picker("Network", selection: $selectedNetwork) {
                                ForEach(availableNetworks, id: \.ssid) { network in
                                    if let signal = network.signalDescription {
                                        Text("\(network.ssid) — \(signal)").tag(network.ssid)
                                    } else {
                                        Text(network.ssid).tag(network.ssid)
                                    }
                                }
                                Text("Enter manually…").tag(Self.manualNetworkTag)
                            }
                            .pickerStyle(.menu)

                            if selectedNetwork == Self.manualNetworkTag {
                                TextField("SSID (for hidden networks)", text: $ssid)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            Button {
                                Task { await scanWiFiNetworks() }
                            } label: {
                                if isScanningNetworks {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text("Scanning for networks...")
                                    }
                                } else {
                                    Label("Scan for Networks", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(isScanningNetworks)

                            HStack {
                                Group {
                                    if showPassword {
                                        TextField("Password", text: $password)
                                    } else {
                                        SecureField("Password", text: $password)
                                    }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                            }

                            Button("Send Setup") {
                                sendSetupConfig()
                            }
                            .disabled(effectiveSSID.isEmpty)
                        }
                    } else if showConnectSetup {
                        Section(header: Text("Connect to LIGHT_SETUP")) {
                            Text("Please connect your device to the Wi-Fi network LIGHT_SETUP, then return to the app.")
                        }
                    } else if showResetInstruction {
                        Section(header: Text("Reset ESP32")) {
                            Text("If you cannot find the device, hold the ESP32 button for 10 seconds to reset it and try again.")
                        }
                    } else if discoveryStage == .network {
                        Section(header: Text("Scanning Local Network")) {
                            ProgressView(value: scanProgress)
                            Text(statusMessage)
                        }
                    } else if discoveryStage == .domain {
                        Section(header: Text("Looking for Pool Light")) {
                            Text(statusMessage)
                        }
                    }
                }

                if deviceAddress != nil {
                    Section {
                        if isBusy {
                            HStack(spacing: 12) {
                                OperationProgressRing(start: operationStart, duration: operationDuration)
                                    .frame(width: 28, height: 28)
                                Text(operationName)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Toggle("Light On", isOn: $lightOn)
                            .disabled(isBusy)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { frame in
                                toggleFrame = frame
                            }
                            .onChange(of: lightOn) { _, newValue in
                                if appliedPower == newValue {
                                    appliedPower = nil
                                    return
                                }
                                sendPowerCommand(on: newValue)
                            }

                        Picker(selection: $selectedColor) {
                            ForEach(colorOptions, id: \.0) { value, name in
                                Label {
                                    Text(name)
                                } icon: {
                                    Image(uiImage: ColorSwatchImages.image(for: value))
                                }
                                .tag(value)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text("Color")
                                ColorSwatchView(colorID: selectedColor)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .disabled(!lightOn || isBusy)
                        .opacity(lightOn ? 1 : 0.5)
                        .onChange(of: selectedColor) { _, newValue in
                            if appliedColor == newValue {
                                appliedColor = nil
                                return
                            }
                            sendColorCommand()
                        }

                        HStack(spacing: 12) {
                            Button("Color Lock") {
                                sendLockCommand()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(!lightOn || !isColorLockAvailable || isBusy)

                            Button("Return") {
                                sendReturnCommand()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(!lightOn || isBusy)
                        }

                        if lightOn && !isColorLockAvailable {
                            Text("Color Lock is only active for colors 1–7.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))

                    Section(header: Text("Advanced")) {
                        DisclosureGroup(isExpanded: $advancedExpanded) {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Tuning")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 12) {
                                        TextField("Pulse delay", text: $pulseDelay)
                                            .keyboardType(.numberPad)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                            .frame(width: 90)

                                        Button("Save Delay") {
                                            sendPulseDelayCommand()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isBusy)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Log")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 12) {
                                        Button("View Log") {
                                            sendViewLogCommand()
                                        }
                                        .buttonStyle(.bordered)
                                        .frame(maxWidth: .infinity)
                                        .disabled(isBusy)

                                        Button("Clear Log") {
                                            sendClearLogCommand()
                                        }
                                        .buttonStyle(.bordered)
                                        .frame(maxWidth: .infinity)
                                        .disabled(isBusy)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Device")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Text("IP Address")
                                        Spacer()
                                        Text(deviceIP ?? deviceAddress ?? "Unknown")
                                            .foregroundColor(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Button("Reset Network") {
                                        sendResetNetwork()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                    .frame(maxWidth: .infinity)
                                    .disabled(isBusy)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Advanced Settings")
                                .font(.headline)
                        }
                    }
                    .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))
                }

                Section(header: Text("Status")) {
                    Text(statusMessage)
                }
                .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))
            }
            // Deep pool-blue backdrop to match the app icon, with a light shining behind the
            // Light On switch while the light is on
            .scrollContentBackground(.hidden)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.03, green: 0.10, blue: 0.30),
                            Color(red: 0.05, green: 0.25, blue: 0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    GeometryReader { geometry in
                        let origin = geometry.frame(in: .global).origin
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color(red: 0.55, green: 0.90, blue: 1.0).opacity(0.65),
                                Color(red: 0.20, green: 0.55, blue: 1.0).opacity(0.25),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 190
                        )
                        .frame(width: 380, height: 380)
                        .position(x: toggleFrame.maxX - 40 - origin.x, y: toggleFrame.midY - origin.y)
                        .opacity(lightOn && deviceAddress != nil ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: lightOn)
                    }
                }
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
            .navigationTitle("Pool Light Control")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAbout = true
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startDiscovery()
                    } label: {
                        Label("Rescan for Device", systemImage: "arrow.clockwise")
                    }
                    .disabled(isDiscovering || isBusy)
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .onAppear(perform: performInitialDiscovery)
            .onChange(of: scenePhase) { _, phase in
                // Another app or device may have changed the light while this one was in the background
                if phase == .active, let address = deviceAddress {
                    Task { await loadDeviceState(from: address) }
                }
            }
        }
    }

    // MARK: - Commands

    /// Sends a command to the device. If the device can't be reached, discovery runs again
    /// in case its address changed. For commands that pulse the light, `busy` locks the controls
    /// until the pulses should be finished (and the device has replied).
    func sendCommand(
        _ path: String,
        method: String = "GET",
        errorLabel: String,
        success: String,
        rediscoverOnFailure: Bool = true,
        busy: (name: String, pulses: Int)? = nil,
        onSuccess: (() -> Void)? = nil
    ) {
        // The ESP32 handles pulse commands one at a time, so never start one while another runs
        guard !isBusy else { return }

        let timeout = busy.map { pulseTimeout(pulses: $0.pulses) } ?? 5
        let started = Date()
        if let busy {
            operationName = busy.name
            operationDuration = pulseDuration(pulses: busy.pulses)
            operationStart = started
            isBusy = true
        }

        Task {
            var succeeded = false
            do {
                let result = try await PoolLightNetwork.request(
                    host: currentDeviceAddress(),
                    path: path,
                    method: method,
                    timeout: timeout
                )
                if (200..<300).contains(result.status) {
                    statusMessage = success
                    succeeded = true
                } else {
                    statusMessage = "\(errorLabel) error: HTTP \(result.status)"
                }
            } catch {
                // A slow reply (timeout) or dropped connection doesn't mean the device moved, so
                // only search again when the device can't be reached at all.
                if rediscoverOnFailure && isUnreachable(error) {
                    statusMessage = "\(errorLabel) error: \(error.localizedDescription). Looking for the device again..."
                    startDiscovery()
                } else {
                    statusMessage = "\(errorLabel) error: \(error.localizedDescription)"
                }
            }

            if busy != nil {
                // The device may reply before the light finishes pulsing, so hold the lock for the full time
                if succeeded {
                    let remaining = operationDuration - Date().timeIntervalSince(started)
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                }
                isBusy = false
            }
            if succeeded { onSuccess?() }
        }
    }

    /// The SSID to send: the picked network, or the manually typed one.
    var effectiveSSID: String {
        let name = selectedNetwork == Self.manualNetworkTag ? ssid : selectedNetwork
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Asks the ESP32 (over the setup access point) for the Wi-Fi networks it can see.
    /// iOS apps can't scan for Wi-Fi themselves, so the device does the scan.
    func scanWiFiNetworks() async {
        guard !isScanningNetworks else { return }
        isScanningNetworks = true
        defer { isScanningNetworks = false }

        do {
            let result = try await PoolLightNetwork.request(host: setupAddress, path: "/scan", timeout: 20)
            guard (200..<300).contains(result.status) else {
                statusMessage = "Network scan not available (HTTP \(result.status)). Enter the network manually."
                return
            }
            let networks = PoolLightNetwork.parseNetworkList(result.body)
            availableNetworks = networks
            if networks.isEmpty {
                selectedNetwork = Self.manualNetworkTag
                statusMessage = "No networks found. Enter the network manually."
            } else {
                if !networks.contains(where: { $0.ssid == selectedNetwork }) { selectedNetwork = networks[0].ssid }
                statusMessage = "Found \(networks.count) network\(networks.count == 1 ? "" : "s")."
            }
        } catch {
            statusMessage = "Network scan failed: \(error.localizedDescription). Enter the network manually."
        }
    }

    /// How long to wait for the device to finish a pulse sequence, plus a margin.
    /// Each pulse is the pulse delay x 2 (50% duty cycle) x 1.2.
    func pulseTimeout(pulses: Int) -> TimeInterval {
        max(5, pulseDuration(pulses: pulses) + 5)
    }

    /// How long the light takes to finish a pulse sequence.
    func pulseDuration(pulses: Int) -> TimeInterval {
        let delayMs = Double(pulseDelay.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 500
        return Double(pulses) * delayMs * 2 * 1.2 / 1000
    }

    /// True for errors that mean nothing is answering at the address, as opposed to a slow or dropped reply.
    func isUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    func sendSetupConfig() {
        let encodedSSID = effectiveSSID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = "ssid=\(encodedSSID)&pass=\(encodedPassword)"

        Task {
            do {
                _ = try await PoolLightNetwork.request(
                    host: setupAddress,
                    path: "/config",
                    method: "POST",
                    body: body.data(using: .utf8),
                    contentType: "application/x-www-form-urlencoded",
                    timeout: 10
                )
            } catch {
                statusMessage = "Setup error: \(error.localizedDescription)"
                return
            }
            statusMessage = "Setup sent. Device should reboot. Waiting for device..."
            // Clear previously-known address and begin discovery once the device has rebooted
            deviceAddress = nil
            lastDeviceAddress = ""
            try? await Task.sleep(for: .seconds(6))
            await runDiscovery()
        }
    }

    func sendColorCommand() {
        guard lightOn else {
            statusMessage = "Cannot set color while light is off."
            return
        }
        let encodedColor = selectedColor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedColor
        // The light steps through one pulse per color number before the device replies
        sendCommand(
            "/color/" + encodedColor,
            errorLabel: "Color",
            success: "Color command \(selectedColor) sent.",
            busy: (name: "Changing color…", pulses: Int(selectedColor) ?? 12)
        )
    }

    func sendPowerCommand(on: Bool) {
        sendCommand(
            "/power/" + (on ? "on" : "off"),
            errorLabel: "Power",
            success: "Power \(on ? "ON" : "OFF") command sent."
        )
    }

    var isColorLockAvailable: Bool {
        if let selected = Int(selectedColor) {
            return (1...7).contains(selected)
        }
        return false
    }

    func sendLockCommand() {
        guard isColorLockAvailable else {
            statusMessage = "Color Lock requires a color between 1 and 7."
            return
        }
        // Color lock takes 13 pulses
        sendCommand(
            "/lock",
            errorLabel: "Color lock",
            success: "Color lock sent.",
            busy: (name: "Locking color…", pulses: 13)
        )
    }

    func sendReturnCommand() {
        guard lightOn else {
            statusMessage = "Cannot send return command while light is off."
            return
        }
        // Return takes 14 pulses
        sendCommand(
            "/return",
            errorLabel: "Return",
            success: "Return command sent.",
            busy: (name: "Returning…", pulses: 14)
        )
    }

    func sendPulseDelayCommand() {
        let delayValue = pulseDelay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedValue = delayValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encodedValue.isEmpty else {
            statusMessage = "Enter a valid pulse delay."
            return
        }
        sendCommand(
            "/pulse-delay/" + encodedValue,
            errorLabel: "Pulse delay",
            success: "Pulse delay set to \(delayValue) ms."
        )
    }

    func sendViewLogCommand() {
        guard !isBusy else { return }
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/log") else {
            statusMessage = "Invalid URL"
            return
        }
        // The log is a web page served by the device, so open it in the browser
        openURL(url)
        statusMessage = "Log opened in browser."
    }

    func sendClearLogCommand() {
        statusMessage = "Clearing Wi-Fi log..."
        sendCommand("/clear-log", errorLabel: "Failed to clear Wi-Fi log", success: "Wi-Fi log cleared.")
    }

    func sendResetNetwork() {
        sendCommand(
            "/reset",
            method: "POST",
            errorLabel: "Reset",
            success: "Reset command sent. Device will reboot.",
            rediscoverOnFailure: false
        ) {
            deviceAddress = nil
            lastDeviceAddress = ""
        }
    }

    func currentDeviceAddress() -> String {
        // If we discovered an address on the LAN, use it. Otherwise fallback to the setup AP fixed IP.
        return deviceAddress ?? setupAddress
    }

    // MARK: - Discovery flow

    func performInitialDiscovery() {
        guard !initialDiscoveryDone else { return }
        initialDiscoveryDone = true
        startDiscovery()
    }

    func startDiscovery() {
        guard !isDiscovering else { return }
        Task { await runDiscovery() }
    }

    /// Tries, in order: saved address, Bonjour, hostnames, subnet scan, then the setup access point.
    func runDiscovery() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }

        showSetupForm = false
        showConnectSetup = false
        showResetInstruction = false
        scanProgress = 0
        discoveryStage = .domain

        // 1. Last known address
        if !lastDeviceAddress.isEmpty {
            statusMessage = "Checking last known address..."
            if await PoolLightNetwork.isPoolLight(lastDeviceAddress, timeout: 1.5) {
                found(lastDeviceAddress, via: "saved address")
                return
            }
        }

        // 2. Bonjour
        statusMessage = "Searching with Bonjour..."
        if let address = await discoverByBonjour() {
            found(address, via: "Bonjour")
            return
        }

        // 3. Hostnames
        statusMessage = "Looking up poollight.local..."
        if let host = await PoolLightNetwork.firstPoolLight(
            in: [deviceLocalHost, deviceHost],
            timeout: 2.0,
            maxConcurrent: 2
        ) {
            found(host, via: host)
            return
        }

        // 4. Subnet scan
        if let address = await discoverByScanningNetwork() {
            found(address, via: "network scan")
            return
        }

        // 5. Setup access point
        discoveryStage = .setup
        statusMessage = "Device not found by address scan. Checking Wi-Fi connection..."

        if await isLightSetupAvailable() {
            showSetupForm = true
            statusMessage = "Connected to LIGHT_SETUP. Choose your router and enter its password."
            Task { await scanWiFiNetworks() }
            return
        }

        showConnectSetup = true
        showResetInstruction = true
        statusMessage = "Not connected to LIGHT_SETUP. If LIGHT_SETUP is available, connect to it. Otherwise reset the ESP32 by holding the button for 10 seconds."
    }

    func found(_ address: String, via method: String) {
        deviceAddress = address
        lastDeviceAddress = address
        discoveryStage = .complete
        statusMessage = "Device found at \(address) via \(method)"
        Task { await loadDeviceState(from: address) }
        Task { deviceIP = await PoolLightNetwork.resolveIPv4Address(of: address) }
    }

    /// Reads the device's current state from its web page so the toggle, color and pulse delay
    /// (and the command timeouts based on it) match what the ESP32 actually has.
    func loadDeviceState(from address: String) async {
        guard !isBusy,
              let page = try? await PoolLightNetwork.request(host: address, path: "/", timeout: 5),
              (200..<300).contains(page.status), !isBusy else { return }
        let state = PoolLightNetwork.parseDeviceState(page.body)

        // Changing these fires their onChange handlers, which would send the value straight
        // back to the device, so note what we're applying and skip those sends.
        if let power = state.power, power != lightOn {
            appliedPower = power
            lightOn = power
        }
        if let color = state.color, color != selectedColor, colorOptions.contains(where: { $0.0 == color }) {
            appliedColor = color
            selectedColor = color
        }
        if let delay = state.pulseDelay {
            pulseDelay = String(delay)
        }
    }

    func discoverByBonjour() async -> String? {
        let endpoints = await PoolLightNetwork.browseBonjour(timeout: 3)
        guard !endpoints.isEmpty else { return nil }

        // Resolve every advertised HTTP service to an IP, then check which one is the pool light
        let addresses = await withTaskGroup(of: String?.self) { group in
            for endpoint in endpoints {
                group.addTask { await PoolLightNetwork.resolveIPv4(endpoint) }
            }
            var result: [String] = []
            for await address in group {
                if let address, !result.contains(address) { result.append(address) }
            }
            return result
        }
        return await PoolLightNetwork.firstPoolLight(in: addresses, timeout: 1.5, maxConcurrent: 8)
    }

    func discoverByScanningNetwork() async -> String? {
        discoveryStage = .network
        statusMessage = "Scanning local network for the ESP32..."
        scanProgress = 0

        let prefixes: [String]
        if let prefix = getLocalIPv4Prefix() {
            prefixes = [prefix]
        } else {
            prefixes = ["192.168.1", "192.168.0", "192.168.4", "10.0.0"]
        }

        let hosts = prefixes.flatMap { prefix in (1...254).map { "\(prefix).\($0)" } }
        let total = Double(hosts.count)
        return await PoolLightNetwork.firstPoolLight(in: hosts, timeout: 1.0, maxConcurrent: 40) { finished in
            scanProgress = min(Double(finished) / total, 1.0)
        }
    }

    func getCurrentSSID() -> String? {
        if let interfaces = CNCopySupportedInterfaces() as? [String] {
            for interface in interfaces {
                if let unsafeInterfaceData = CNCopyCurrentNetworkInfo(interface as CFString) as NSDictionary?,
                   let ssid = unsafeInterfaceData[kCNNetworkInfoKeySSID as String] as? String {
                    return ssid
                }
            }
        }
        return nil
    }

    func isLightSetupAvailable() async -> Bool {
        if let ssid = getCurrentSSID(), ssid == "LIGHT_SETUP" {
            return true
        }
        if let identity = try? await PoolLightNetwork.request(host: setupAddress, path: "/identity", timeout: 1.0),
           identity.status < 500 {
            let trimmed = identity.body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed == "poollight-setup" || trimmed == "poollight"
        }
        if let page = try? await PoolLightNetwork.request(host: setupAddress, path: "/", timeout: 1.0),
           page.status < 500 {
            return page.body.lowercased().contains("light setup")
        }
        return false
    }

    func getLocalIPv4Prefix() -> String? {
        // Attempt to discover the local Wi-Fi IPv4 address and return the prefix like "192.168.1"
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddrPtr) == 0 {
            var ptr = ifaddrPtr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    // Look for "en0" (iPhone Wi-Fi) or other wifi interface names
                    if name == "en0" || name.hasPrefix("en") {
                        var addr = interface.ifa_addr.pointee
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if (getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0) {
                            address = String(cString: hostname)
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddrPtr)
        }

        if let addr = address {
            let comps = addr.split(separator: ".")
            if comps.count == 4 {
                return comps[0...2].joined(separator: ".")
            }
        }
        return nil
    }
}
