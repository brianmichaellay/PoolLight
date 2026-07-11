import SwiftUI
import SystemConfiguration.CaptiveNetwork

@main
struct LightControlApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var ssid = ""
    @State private var password = ""
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
    @State private var initialDiscoveryDone = false
    @State private var discoveryStage: DiscoveryStage = .idle
    @State private var scanProgress: Double = 0
    @State private var showSetupForm = false
    @State private var showConnectSetup = false
    @State private var showResetInstruction = false
    // domain the ESP will register (router hostname)
    let deviceHost = "poollight"
    let deviceLocalHost = "poollight.local"
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
                            TextField("SSID", text: $ssid)
                            SecureField("Password", text: $password)
                            Button("Send Setup") {
                                sendSetupConfig()
                            }
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
                        Section(header: Text("Looking up poollight.local")) {
                            Text(statusMessage)
                        }
                    }
                }

                if deviceAddress != nil {
                    Section(header: Text("Change Pool Light")) {
                        Toggle("Light On", isOn: $lightOn)
                            .onChange(of: lightOn) { _, newValue in
                                sendPowerCommand(on: newValue)
                            }

                        Picker("Color", selection: $selectedColor) {
                            ForEach(colorOptions, id: \.0) { value, name in
                                Text(name).tag(value)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .disabled(!lightOn)
                        .opacity(lightOn ? 1 : 0.5)
                        .onChange(of: selectedColor) { _, _ in
                            sendColorCommand()
                        }

                        HStack(spacing: 12) {
                            Button("Color Lock") {
                                sendLockCommand()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(!isColorLockAvailable)

                            Button("Return") {
                                sendReturnCommand()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }

                        if !isColorLockAvailable {
                            Text("Color Lock is only active for colors 1–7.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section(header: Text("Advanced")) {
                        DisclosureGroup(isExpanded: $advancedExpanded) {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    TextField("Pulse delay", text: $pulseDelay)
                                        .keyboardType(.numberPad)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .frame(width: 90)

                                    Button("Save Delay") {
                                        sendPulseDelayCommand()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                Button("Reset Network") {
                                    sendResetNetwork()
                                }
                                .buttonStyle(.borderedProminent)
                                .foregroundColor(.red)
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Advanced Settings")
                                .font(.headline)
                        }
                    }
                }

                Section(header: Text("Status")) {
                    Text(statusMessage)
                }
            }
            .navigationTitle("Pool Light Control")
            .onAppear(perform: performInitialDiscovery)
        }
    }

    func sendSetupConfig() {
        guard let url = URL(string: "http://192.168.4.1/config") else {
            statusMessage = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body = "ssid=\(ssid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&pass=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Setup error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Setup sent. Device should reboot. Waiting for device..."
                // Clear previously-known address and begin discovery
                deviceAddress = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    discoverDeviceAfterSetup()
                }
            }
        }.resume()
    }

    func sendColorCommand() {
        guard lightOn else {
            statusMessage = "Cannot set color while light is off."
            return
        }
        let encodedColor = selectedColor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedColor
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/color/" + encodedColor) else {
            statusMessage = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Color error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Color command \(selectedColor) sent."
            }
        }.resume()
    }

    func sendPowerCommand(on: Bool) {
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/power/" + (on ? "on" : "off")) else {
            statusMessage = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Power error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Power \(on ? "ON" : "OFF") command sent."
            }
        }.resume()
    }

    func discoverDeviceOnNetwork(afterSetup: Bool = false) {
        if afterSetup {
            Thread.sleep(forTimeInterval: 3)
        }
        DispatchQueue.main.async {
            self.discoveryStage = .domain
            self.statusMessage = "Looking up poollight.local..."
        }
        if self.discoverByDomain() {
            return
        }
        self.discoverByScanningNetwork()
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

    func isLightSetupAvailable() -> Bool {
        if let ssid = getCurrentSSID(), ssid == "LIGHT_SETUP" {
            return true
        }
        if let identity = fetchURLBody("http://192.168.4.1/identity", timeout: 1.0) {
            let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed == "poollight-setup" || trimmed == "poollight"
        }
        if let setupPage = fetchURLBody("http://192.168.4.1/", timeout: 1.0) {
            return setupPage.lowercased().contains("light setup")
        }
        return false
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
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/lock") else {
            statusMessage = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Color lock error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Color lock sent."
            }
        }.resume()
    }

    func sendReturnCommand() {
        guard lightOn else {
            statusMessage = "Cannot send return command while light is off."
            return
        }
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/return") else {
            statusMessage = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Return error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Return command sent."
            }
        }.resume()
    }

    func sendPulseDelayCommand() {
        let delayValue = pulseDelay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedValue = delayValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encodedValue.isEmpty else {
            statusMessage = "Enter a valid pulse delay."
            return
        }
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/pulse-delay/" + encodedValue) else {
            statusMessage = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Pulse delay error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Pulse delay set to \(delayValue) ms."
            }
        }.resume()
    }

    func sendResetNetwork() {
        guard let url = URL(string: "http://" + currentDeviceAddress() + "/reset") else {
            statusMessage = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    statusMessage = "Reset error: \(error.localizedDescription)"
                    return
                }
                statusMessage = "Reset command sent. Device will reboot."
                deviceAddress = nil
            }
        }.resume()
    }

    func currentDeviceAddress() -> String {
        // If we discovered an address on the LAN, use it. Otherwise fallback to the setup AP fixed IP.
        return deviceAddress ?? "192.168.4.1"
    }

    // MARK: - Discovery flow
    func discoverDeviceAfterSetup() {
        // Give the device a short time to reboot and connect to the router
        Thread.sleep(forTimeInterval: 3)
        discoverDeviceOnNetwork(afterSetup: true)
    }

    func performInitialDiscovery() {
        guard !initialDiscoveryDone else { return }
        initialDiscoveryDone = true
        discoveryStage = .domain
        statusMessage = "Looking up poollight.local..."
        DispatchQueue.global(qos: .userInitiated).async {
            if self.discoverByDomain() {
                return
            }
            self.discoverByScanningNetwork()
        }
    }

    func discoverByDomain() -> Bool {
        if let addr = tryConnectByDomain() {
            DispatchQueue.main.async {
                self.deviceAddress = addr
                self.discoveryStage = .complete
                self.statusMessage = "Device found at \(addr) via poollight.local"
            }
            return true
        }
        return false
    }

    func discoverByScanningNetwork() {
        DispatchQueue.main.async {
            self.discoveryStage = .network
            self.statusMessage = "Scanning local network for the ESP32..."
            self.scanProgress = 0
            self.showSetupForm = false
            self.showConnectSetup = false
            self.showResetInstruction = false
        }

        let prefixes: [String]
        if let prefix = getLocalIPv4Prefix() {
            prefixes = [prefix]
        } else {
            prefixes = ["192.168.1", "192.168.0", "192.168.4", "10.0.0"]
        }

        var foundAddress: String? = nil
        let totalHosts = prefixes.count * 254
        var scannedHosts = 0

        for prefix in prefixes {
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                if validatePoolLightHost(host, timeout: 0.4) {
                    foundAddress = host
                    break
                }
                scannedHosts += 1
                DispatchQueue.main.async {
                    self.scanProgress = min(Double(scannedHosts) / Double(totalHosts), 1.0)
                }
            }
            if foundAddress != nil {
                break
            }
        }

        if let found = foundAddress {
            DispatchQueue.main.async {
                self.deviceAddress = found
                self.discoveryStage = .complete
                self.statusMessage = "Device found at \(found) via network scan"
            }
            return
        }

        DispatchQueue.main.async {
            self.discoveryStage = .setup
            self.statusMessage = "Device not found by address scan. Checking Wi-Fi connection..."
        }

        if isLightSetupAvailable() {
            DispatchQueue.main.async {
                self.showSetupForm = true
                self.statusMessage = "Connected to LIGHT_SETUP. Enter your router SSID and password."
            }
            return
        }

        DispatchQueue.main.async {
            self.showConnectSetup = true
            self.showResetInstruction = true
            self.statusMessage = "Not connected to LIGHT_SETUP. If LIGHT_SETUP is available, connect to it. Otherwise reset the ESP32 by holding the button for 10 seconds."
        }
    }

    func tryConnectByDomain() -> String? {
        // Try local mDNS name first, then plain hostname
        let candidates = [deviceLocalHost, deviceHost]
        for host in candidates {
            if validatePoolLightHost(host, timeout: 2.0) {
                return host
            }
        }
        return nil
    }

    func validatePoolLightHost(_ host: String, timeout: TimeInterval) -> Bool {
        guard let body = fetchURLBody("http://\(host)/identity", timeout: timeout) else {
            return false
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "poollight"
    }

    func fetchURLBody(_ urlString: String, timeout: TimeInterval) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let sem = DispatchSemaphore(value: 0)
        var bodyResult: String? = nil

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let resp = response as? HTTPURLResponse, resp.statusCode >= 200 && resp.statusCode < 500 {
                bodyResult = String(data: data, encoding: .utf8)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return bodyResult
    }

    func isESP32DeviceResponse(_ body: String?) -> Bool {
        guard let body = body else { return false }
        let lower = body.lowercased()
        return lower.contains("id=\"colorform\"") || lower.contains("action=\"/color\"") || lower.contains("poollight.local") || lower.contains("power")
    }

    func fetchURL(_ urlString: String, timeout: TimeInterval) -> Bool? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let sem = DispatchSemaphore(value: 0)
        var success: Bool = false

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let _ = data, let resp = response as? HTTPURLResponse, resp.statusCode >= 200 && resp.statusCode < 500 {
                success = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return success
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

    func scanNetwork(prefix: String) -> String? {
        for i in 1...254 {
            let candidate = "http://\(prefix).\(i)/"
            if let ok = fetchURL(candidate, timeout: 0.4), ok {
                // return the bare host ip
                let ip = "\(prefix).\(i)"
                return ip
            }
        }
        return nil
    }
}
