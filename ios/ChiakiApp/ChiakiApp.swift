import Security
import SwiftUI

@main
struct ChiakiApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct Host: Codable {
    var address: String
    var ps5: Bool
    var registKey: Data
    var morning: Data
    var nickname: String
}

/// The paired console lives in the Keychain, its regist key is a credential.
enum HostStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "chiaki.host",
    ]

    static func load() -> Host? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Host.self, from: data)
    }

    static func save(_ host: Host) {
        clear()
        var q = query
        q[kSecValueData as String] = (try? JSONEncoder().encode(host)) ?? Data()
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

// C callbacks can't capture, so they go through the singleton.
private let logCb: CBLogCb = { _, msg in
    let line = String(cString: msg!)
    DispatchQueue.main.async { AppModel.shared.appendLog(line) }
}

private let registCb: CBRegistCb = { ok, key, morning, nickname, _ in
    let result: (Data, Data, String)? = ok ? (Data(bytes: key!, count: Int(CB_KEY_SIZE)),
                       Data(bytes: morning!, count: Int(CB_KEY_SIZE)),
                       String(cString: nickname!)) : nil
    DispatchQueue.main.async { AppModel.shared.registFinished(result) }
}

private let videoCb: CBVideoCb = { buf, len, _ in
    AppModel.shared.video.decode(UnsafeBufferPointer(start: buf, count: len))
}

private let eventCb: CBEventCb = { type, msg, _ in
    let text = msg.map { String(cString: $0) }
    DispatchQueue.main.async { AppModel.shared.sessionEvent(type, text) }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var host = HostStore.load()
    @Published var status = ""
    @Published var log: [String] = []
    @Published var streaming = false
    @Published var needsLoginPin = false

    let video = VideoDecoder()
    private let gamepad = Gamepad()
    private var regist: OpaquePointer?
    private var pendingHost: (address: String, ps5: Bool)?
    private var session: OpaquePointer?

    private init() {
        let err = cb_init(logCb)
        if err != 0 { status = "chiaki_lib_init failed (\(err))" }
        gamepad.onChange = { [weak self] pad in
            guard let session = self?.session else { return }
            Gamepad.send(pad, to: session)
        }
    }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func pair(address: String, ps5: Bool, accountId: String, pin: String) {
        guard regist == nil else { return }
        guard let account = Data(base64Encoded: accountId.trimmingCharacters(in: .whitespaces)),
              account.count == Int(CB_PSN_ACCOUNT_ID_SIZE) else {
            status = "PSN account ID must be base64 of 8 bytes"
            return
        }
        guard pin.count == 8, let pinValue = UInt32(pin) else {
            status = "PIN must be 8 digits"
            return
        }
        pendingHost = (address, ps5)
        status = "Pairing…"
        regist = account.withUnsafeBytes {
            cb_regist_start(address, ps5, $0.bindMemory(to: UInt8.self).baseAddress, pinValue, registCb, nil)
        }
        if regist == nil { status = "Failed to start pairing" }
    }

    func registFinished(_ result: (Data, Data, String)?) {
        if let regist { cb_regist_free(regist) }
        regist = nil
        guard let result, let pending = pendingHost else {
            status = "Pairing failed, check IP, PIN and account ID"
            return
        }
        let host = Host(address: pending.address, ps5: pending.ps5, registKey: result.0, morning: result.1, nickname: result.2)
        HostStore.save(host)
        self.host = host
        status = "Paired with \(host.nickname)"
    }

    func forget() {
        HostStore.clear()
        host = nil
    }

    func startStream() {
        guard let host, session == nil else { return }
        video.reset()
        session = host.registKey.withUnsafeBytes { key in
            host.morning.withUnsafeBytes { morning in
                cb_session_start(host.address, host.ps5,
                                 key.bindMemory(to: UInt8.self).baseAddress,
                                 morning.bindMemory(to: UInt8.self).baseAddress,
                                 videoCb, eventCb, nil)
            }
        }
        guard session != nil else {
            status = "Failed to start session"
            return
        }
        status = "Connecting…"
        streaming = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stopStream() {
        if let session { cb_session_free(session) }
        session = nil
        streaming = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func sendLoginPin(_ pin: String) {
        if let session { cb_session_set_login_pin(session, pin) }
    }

    func sessionEvent(_ type: CBEventType, _ msg: String?) {
        switch type {
        case CB_EVENT_CONNECTED: status = "Connected"
        case CB_EVENT_LOGIN_PIN_REQUEST: needsLoginPin = true
        case CB_EVENT_QUIT:
            stopStream()
            status = "Session ended: \(msg ?? "unknown")"
        default: break
        }
    }
}

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var address = ""
    @State private var ps5 = true
    @State private var accountId = ""
    @State private var pin = ""
    @State private var loginPin = ""

    var body: some View {
        Group {
            if model.streaming {
                ZStack(alignment: .topTrailing) {
                    VideoView(videoLayer: model.video.layer).ignoresSafeArea()
                    Button("Stop") { model.stopStream() }
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
                .statusBarHidden()
            } else {
                NavigationView { form.navigationTitle("Chiaki") }
                    .navigationViewStyle(.stack)
            }
        }
        .alert("Console login PIN", isPresented: $model.needsLoginPin) {
            TextField("PIN", text: $loginPin).keyboardType(.numberPad)
            Button("OK") { model.sendLoginPin(loginPin) }
        }
    }

    private var form: some View {
        Form {
            if let host = model.host {
                Section("Console") {
                    Text("\(host.nickname) (\(host.address))")
                    Button("Start stream") { model.startStream() }
                    Button("Forget console", role: .destructive) { model.forget() }
                }
            } else {
                Section("Pair console") {
                    TextField("Console IP, e.g. 192.168.1.20", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    Toggle("PS5", isOn: $ps5)
                    TextField("PSN account ID (base64)", text: $accountId)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("PIN from console", text: $pin).keyboardType(.numberPad)
                    Button("Pair") { model.pair(address: address, ps5: ps5, accountId: accountId, pin: pin) }
                }
            }
            if !model.status.isEmpty {
                Section("Status") { Text(model.status) }
            }
            Section("Log") {
                ForEach(Array(model.log.suffix(100).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
    }
}
