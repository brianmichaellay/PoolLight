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
        // Transparent trailing padding adds space between the swatch and its name, since menus don't allow setting label spacing
        let renderer = ImageRenderer(content: ColorSwatchView(colorID: colorID).padding(.trailing, 10))
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastDeviceAddress") private var lastDeviceAddress = ""
    /// Picker tag for the "Enter manually…" option
    static let manualNetworkTag = "__manual__"
    static let defaultSetupNote = "Choose your home Wi-Fi network and enter its password. The light controller will restart and join it."
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
    /// Pulse delay when its field was focused, so it's only sent if it changed
    @State private var pulseDelayBeforeEdit = ""
    @FocusState private var pulseDelayFocused: Bool
    @State private var navigationPath = NavigationPath()
    /// Detail shown under the connection row, e.g. the discovery step or how the device was found
    @State private var statusMessage = "Searching for poollight.local…"
    /// Note under the Wi-Fi setup section
    @State private var setupNote = ""
    @State private var errorTitle = ""
    @State private var errorMessage: String? = nil
    /// Briefly shown with a checkmark after a command succeeds
    @State private var confirmation: String? = nil
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
    @State private var showResetConfirmation = false
    @State private var showClearLogConfirmation = false
    /// Log entries from the device, oldest first; nil until loaded
    @State private var logEntries: [(time: String, message: String)]? = nil
    @State private var isLoadingLog = false
    @State private var initialDiscoveryDone = false
    @State private var isDiscovering = false
    @State private var discoveryStage: DiscoveryStage = .idle
    @State private var scanProgress: Double = 0
    @State private var showSetupForm = false
    @State private var showConnectSetup = false
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
        NavigationStack(path: $navigationPath) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        if isDiscovering {
                            ProgressView()
                            Text("Searching…")
                        } else {
                            // On LIGHT_SETUP the device is reachable, but only for Wi-Fi setup
                            let connected = deviceAddress != nil || showSetupForm
                            Circle()
                                .fill(connected ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(connected ? "Connected" : "Not Connected")
                        }
                        Spacer()
                        if let deviceAddress, !isDiscovering {
                            Text(deviceIP ?? deviceAddress)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        } else if showSetupForm && !isDiscovering {
                            Text("Setup Only")
                                .foregroundColor(.secondary)
                        }
                    }
                    if isDiscovering && discoveryStage == .network {
                        ProgressView(value: scanProgress)
                    }
                } footer: {
                    Text(statusMessage)
                }
                .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))

                if deviceAddress == nil {
                    if showSetupForm {
                        Section {
                            Picker("Network", selection: $selectedNetwork) {
                                ForEach(availableNetworks, id: \.ssid) { network in
                                    if let signal = network.signalDescription {
                                        Text("\(network.ssid) — \(signal)").tag(network.ssid)
                                    } else {
                                        Text(network.ssid).tag(network.ssid)
                                    }
                                }
                                Text("Enter Manually…").tag(Self.manualNetworkTag)
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
                                        Text("Scanning for networks…")
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

                            Button("Connect") {
                                sendSetupConfig()
                            }
                            .disabled(effectiveSSID.isEmpty)
                        } header: {
                            Text("Set Up Wi-Fi")
                        } footer: {
                            Text(setupNote)
                        }
                    } else if showConnectSetup {
                        // The light on the controller tells which state it's in
                        Section {
                            troubleshootingRow(
                                "Light Flashing",
                                systemImage: "light.max",
                                "It's in setup mode.\n1. In Settings, connect to the Wi-Fi network LIGHT_SETUP.\n2. Come back to this app and tap \(Image(systemName: "arrow.clockwise")) in the top-right corner."
                            )
                            troubleshootingRow(
                                "Light Off",
                                systemImage: "lightbulb.slash",
                                "It's trying to join your Wi-Fi. If you just set it up and the password was wrong, it will start flashing within 2 minutes. If it stays off, hold its button for 10 seconds until the light flashes. If your router was just restarted, wait a few minutes instead."
                            )
                            troubleshootingRow(
                                "Light Solid",
                                systemImage: "lightbulb.fill",
                                "It's connected to your Wi-Fi. Make sure you're on the same Wi-Fi network, then tap \(Image(systemName: "arrow.clockwise"))."
                            )
                        } header: {
                            Text("Check the Light on the Controller")
                        } footer: {
                            Text("Still not found? In Settings › Privacy & Security › Local Network, make sure this app is turned on.")
                        }
                        .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))
                    }
                }

                if deviceAddress != nil {
                    Section {
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
                            Text("Color")
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

                        Button {
                            sendLockCommand()
                        } label: {
                            HStack {
                                Label("Color Lock", systemImage: "lock.fill")
                                    // Extra dimming so disabled rows don't read as white on the dark background
                                    .opacity(!lightOn || !isColorLockAvailable || isBusy ? 0.4 : 1)
                                Spacer()
                                if lightOn && !isColorLockAvailable {
                                    Text("Colors 1–7 only")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!lightOn || !isColorLockAvailable || isBusy)

                        Button {
                            sendReturnCommand()
                        } label: {
                            Label("Return to Locked Color", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!lightOn || isBusy)
                        .opacity(!lightOn || isBusy ? 0.4 : 1)
                    }
                    .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))

                    Section {
                        NavigationLink(value: "advanced") {
                            Label("Advanced Settings", systemImage: "gearshape")
                        }
                    }
                    .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))
                }
            }
            // Deep pool-blue backdrop to match the app icon, with a light shining behind the
            // Light On switch while the light is on
            .scrollContentBackground(.hidden)
            .background(
                ZStack {
                    poolBackdrop

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
                            endRadius: 70
                        )
                        .frame(width: 140, height: 140)
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
            .navigationDestination(for: String.self) { page in
                if page == "log" {
                    logPage
                } else {
                    advancedSettings
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .onChange(of: deviceAddress) { _, address in
                // The Advanced screen only applies to a connected device (e.g. after Reset Network)
                if address == nil {
                    navigationPath = NavigationPath()
                }
            }
            .onAppear(perform: performInitialDiscovery)
            .onChange(of: scenePhase) { _, phase in
                // Another app or device may have changed the light while this one was in the background
                if phase == .active, let address = deviceAddress {
                    Task { await loadDeviceState(from: address) }
                }
                // Coming back from Settings after joining LIGHT_SETUP, so look for the device right away
                if phase == .active, deviceAddress == nil, showConnectSetup, !isBusy {
                    startDiscovery()
                }
            }
        }
        // Progress and confirmations float over the screen so they don't push the layout down
        .overlay {
            if isBusy {
                VStack(spacing: 14) {
                    OperationProgressRing(start: operationStart, duration: operationDuration)
                        .frame(width: 56, height: 56)
                    Text(operationName)
                        .foregroundColor(.secondary)
                }
                .padding(28)
                .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
                .transition(.opacity)
            } else if let confirmation {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text(confirmation)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: 280)
                .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .animation(.easeInOut(duration: 0.2), value: confirmation)
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func troubleshootingRow(_ title: String, systemImage: String, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Deep pool-blue gradient to match the app icon.
    private var poolBackdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.03, green: 0.10, blue: 0.30),
                Color(red: 0.05, green: 0.25, blue: 0.55)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var advancedSettings: some View {
        Form {
            Section {
                HStack {
                    Text("Pulse Delay")
                    Spacer()
                    TextField("50", text: $pulseDelay)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(.secondary)
                        .frame(width: 80)
                        .focused($pulseDelayFocused)
                    Text("ms")
                        .foregroundColor(.secondary)
                }
                .disabled(isBusy)
            } header: {
                Text("Relay")
            } footer: {
                Text("Relay on/off time per pulse.")
            }
            .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))

            Section(header: Text("Log")) {
                NavigationLink(value: "log") {
                    Label("View Log", systemImage: "doc.text")
                }
            }
            .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))

            Section(header: Text("Network")) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Network", systemImage: "wifi.exclamationmark")
                }
                .disabled(isBusy)
                .alert("Reset Network?", isPresented: $showResetConfirmation) {
                    Button("Reset", role: .destructive) {
                        sendResetNetwork()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The light controller will forget its Wi-Fi settings and reboot into setup mode. You'll need to set up Wi-Fi again.")
                }
            }
            .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))
        }
        .scrollContentBackground(.hidden)
        .background(poolBackdrop.ignoresSafeArea())
        .navigationTitle("Advanced Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The number pad has no return key, so give it a Done button
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    pulseDelayFocused = false
                }
            }
        }
        .onChange(of: pulseDelayFocused) { _, focused in
            if focused {
                pulseDelayBeforeEdit = pulseDelay
            } else if pulseDelay != pulseDelayBeforeEdit {
                sendPulseDelayCommand()
            }
        }
    }

    private var logPage: some View {
        Form {
            Section {
                if let logEntries {
                    ForEach(Array(logEntries.enumerated().reversed()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                            if !entry.time.isEmpty {
                                Text(entry.time)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                } else if isLoadingLog {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Couldn't load the log.")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Newest First")
            } footer: {
                Text("Times are since the light controller last started. Pull down to refresh.")
            }
            .listRowBackground(Color(red: 0.06, green: 0.10, blue: 0.20).opacity(0.55))
        }
        .scrollContentBackground(.hidden)
        .background(poolBackdrop.ignoresSafeArea())
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // In the toolbar so it stays visible however long the log is
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearLogConfirmation = true
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }
                .tint(.red)
                .disabled(isBusy || logEntries == nil)
            }
        }
        .alert("Clear Log?", isPresented: $showClearLogConfirmation) {
            Button("Clear", role: .destructive) {
                sendClearLogCommand()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The light controller's log will be permanently erased.")
        }
        .refreshable {
            await loadLog()
        }
        .task {
            await loadLog()
        }
    }

    // MARK: - Commands

    /// Sends a command to the device. If the device can't be reached, discovery runs again
    /// in case its address changed. For commands that pulse the light, `busy` locks the controls
    /// until the pulses should be finished (and the device has replied).
    func sendCommand(
        _ path: String,
        method: String = "GET",
        errorTitle: String,
        success: String? = nil,
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
                    succeeded = true
                } else {
                    showError(errorTitle, "The light controller replied with error \(result.status).")
                }
            } catch {
                // A slow reply (timeout) or dropped connection doesn't mean the device moved, so
                // only search again when the device can't be reached at all.
                if rediscoverOnFailure && isUnreachable(error) {
                    showError(errorTitle, "\(error.localizedDescription) Looking for the light controller again.")
                    startDiscovery()
                } else {
                    showError(errorTitle, error.localizedDescription)
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
            if succeeded {
                if let success { confirm(success) }
                onSuccess?()
            }
        }
    }

    func showError(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    /// Shows a checkmark with `message` for a moment.
    func confirm(_ message: String) {
        confirmation = message
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if confirmation == message { confirmation = nil }
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
                selectedNetwork = Self.manualNetworkTag
                setupNote = "Couldn't scan for networks. Enter your network name manually."
                return
            }
            let networks = PoolLightNetwork.parseNetworkList(result.body)
            availableNetworks = networks
            if networks.isEmpty {
                selectedNetwork = Self.manualNetworkTag
                setupNote = "No networks found. Enter your network name manually."
            } else {
                if !networks.contains(where: { $0.ssid == selectedNetwork }) { selectedNetwork = networks[0].ssid }
                setupNote = Self.defaultSetupNote
            }
        } catch {
            selectedNetwork = Self.manualNetworkTag
            setupNote = "Couldn't scan for networks. Enter your network name manually."
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
                showError("Couldn't Connect", error.localizedDescription)
                return
            }
            statusMessage = "Wi-Fi settings sent. Waiting for the light controller to restart…"
            // Clear previously-known address and begin discovery once the device has rebooted.
            // Leaving setup first makes discovery search the home network, not LIGHT_SETUP.
            deviceAddress = nil
            lastDeviceAddress = ""
            showSetupForm = false

            // Give the device time to restart and join the home network before searching for it
            let joinWait: TimeInterval = 20
            operationName = "Joining Wi-Fi…"
            operationDuration = joinWait
            operationStart = Date()
            isBusy = true
            try? await Task.sleep(for: .seconds(joinWait))
            isBusy = false
            await runDiscovery()
        }
    }

    func sendColorCommand() {
        guard lightOn else { return }
        let encodedColor = selectedColor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedColor
        // The light steps through one pulse per color number before the device replies
        sendCommand(
            "/color/" + encodedColor,
            errorTitle: "Couldn't Change Color",
            success: "Color set to \(colorName(selectedColor))",
            busy: (name: "Changing color…", pulses: Int(selectedColor) ?? 12)
        )
    }

    func sendPowerCommand(on: Bool) {
        sendCommand(
            "/power/" + (on ? "on" : "off"),
            errorTitle: "Couldn't Turn Light \(on ? "On" : "Off")"
        )
    }

    func colorName(_ id: String) -> String {
        colorOptions.first { $0.0 == id }?.1 ?? "color \(id)"
    }

    var isColorLockAvailable: Bool {
        if let selected = Int(selectedColor) {
            return (1...7).contains(selected)
        }
        return false
    }

    func sendLockCommand() {
        guard isColorLockAvailable else { return }
        // Color lock takes 13 pulses
        sendCommand(
            "/lock",
            errorTitle: "Couldn't Lock Color",
            success: "Color locked",
            busy: (name: "Locking color…", pulses: 13)
        )
    }

    func sendReturnCommand() {
        guard lightOn else { return }
        // Return takes 14 pulses
        sendCommand(
            "/return",
            errorTitle: "Couldn't Return to Locked Color",
            success: "Returned to locked color",
            busy: (name: "Returning…", pulses: 14)
        )
    }

    func sendPulseDelayCommand() {
        let delayValue = pulseDelay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedValue = delayValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encodedValue.isEmpty else {
            showError("Invalid Pulse Delay", "Enter the delay in milliseconds.")
            return
        }
        sendCommand(
            "/pulse-delay/" + encodedValue,
            errorTitle: "Couldn't Save Pulse Delay",
            success: "Pulse delay set to \(delayValue) ms"
        )
    }

    /// Reads the device's log, which is plain text with one entry per line, e.g. `12345ms connected`.
    func loadLog() async {
        isLoadingLog = true
        defer { isLoadingLog = false }
        do {
            let result = try await PoolLightNetwork.request(host: currentDeviceAddress(), path: "/log", timeout: 5)
            guard (200..<300).contains(result.status) else {
                showError("Couldn't Load Log", "The light controller replied with error \(result.status).")
                return
            }
            logEntries = result.body
                .split(whereSeparator: \.isNewline)
                .map { line in
                    if let match = line.wholeMatch(of: /(\d+)ms (.*)/), let ms = Int(match.1) {
                        return (time: formatUptime(ms), message: String(match.2))
                    }
                    return (time: "", message: String(line))
                }
        } catch {
            showError("Couldn't Load Log", error.localizedDescription)
        }
    }

    /// Formats milliseconds since boot as h:mm:ss.
    func formatUptime(_ ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    func sendClearLogCommand() {
        sendCommand("/clear-log", errorTitle: "Couldn't Clear Log", success: "Log cleared") {
            Task { await loadLog() }
        }
    }

    func sendResetNetwork() {
        sendCommand(
            "/reset",
            method: "POST",
            errorTitle: "Couldn't Reset Network",
            success: "Network reset. The light controller is restarting.",
            rediscoverOnFailure: false
        ) {
            deviceAddress = nil
            lastDeviceAddress = ""
            statusMessage = "The light controller is restarting in setup mode."
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

        // If the app was already showing setup, the user most likely just joined LIGHT_SETUP,
        // where the device is at a fixed address, so check there before searching the network
        let expectingSetup = showConnectSetup || showSetupForm

        showSetupForm = false
        showConnectSetup = false
        scanProgress = 0
        discoveryStage = .domain

        if expectingSetup {
            statusMessage = "Checking for LIGHT_SETUP…"
            if await isLightSetupAvailable() {
                showSetup()
                return
            }
        }

        // 1. Last known address
        if !lastDeviceAddress.isEmpty {
            statusMessage = "Checking the last known address…"
            if await PoolLightNetwork.isPoolLight(lastDeviceAddress, timeout: 1.5) {
                found(lastDeviceAddress, via: "saved address")
                return
            }
        }

        // 2. Bonjour
        statusMessage = "Searching with Bonjour…"
        if let address = await discoverByBonjour() {
            found(address, via: "Bonjour")
            return
        }

        // 3. Hostnames
        statusMessage = "Looking up poollight.local…"
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
        statusMessage = "Not found on this network. Checking for LIGHT_SETUP…"

        if await isLightSetupAvailable() {
            showSetup()
            return
        }

        showConnectSetup = true
        statusMessage = "Couldn't find the light controller on this network."
    }

    func showSetup() {
        discoveryStage = .setup
        showSetupForm = true
        statusMessage = "Connected to the light controller's LIGHT_SETUP network."
        setupNote = Self.defaultSetupNote
        Task { await scanWiFiNetworks() }
    }

    func found(_ address: String, via method: String) {
        deviceAddress = address
        lastDeviceAddress = address
        discoveryStage = .complete
        statusMessage = "Found via \(method)"
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
        statusMessage = "Scanning the local network…"
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
