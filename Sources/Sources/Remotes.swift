import Foundation

// MARK: Roku (ECP, puerto 8060, sin emparejar)
struct RokuRemote: TVRemote, TextCapable, AppLaunchable {
    let host: String
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "Power", .up: "Up", .down: "Down", .left: "Left", .right: "Right", .ok: "Select",
            .back: "Back", .home: "Home", .volUp: "VolumeUp", .volDown: "VolumeDown", .mute: "VolumeMute"]
        guard let key = m[k] else { return }
        try await http("POST", "http://\(host):8060/keypress/\(key)")
    }
    func typeText(_ s: String) async throws {
        for ch in s {
            let enc = String(ch).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            try await http("POST", "http://\(host):8060/keypress/Lit_\(enc)")
        }
    }
    func backspace(_ n: Int) async throws { for _ in 0..<n { try await http("POST", "http://\(host):8060/keypress/Backspace") } }
    func enter() async throws { try await http("POST", "http://\(host):8060/keypress/Enter") }

    var presets: [AppItem] { [AppItem(id: "12", name: "Netflix"), AppItem(id: "837", name: "YouTube"), AppItem(id: "13", name: "Prime Video"),
                              AppItem(id: "291097", name: "Disney+"), AppItem(id: "61322", name: "Max"), AppItem(id: "2285", name: "Hulu")] }
    func installedApps() async throws -> [AppItem] {
        let (_, xml) = try await httpFull("GET", "http://\(host):8060/query/apps")
        let re = try NSRegularExpression(pattern: #"<app id="([^"]+)"[^>]*>([^<]*)</app>"#)
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
            AppItem(id: ns.substring(with: $0.range(at: 1)), name: ns.substring(with: $0.range(at: 2)).replacingOccurrences(of: "&amp;", with: "&"))
        }
    }
    func launch(_ app: AppItem) async throws { try await http("POST", "http://\(host):8060/launch/\(app.id)") }
}

// MARK: Sony Bravia (IRCC + appControl). En la TV: Red doméstica > Control IP > Clave precompartida = 0000
struct SonyRemote: TVRemote, AppLaunchable {
    let host: String
    private var psk: String { UserDefaults.standard.string(forKey: "sony.psk") ?? "0000" }
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "AAAAAQAAAAEAAAAVAw==", .up: "AAAAAQAAAAEAAAB0Aw==", .down: "AAAAAQAAAAEAAAB1Aw==",
            .left: "AAAAAQAAAAEAAAA0Aw==", .right: "AAAAAQAAAAEAAAAzAw==", .ok: "AAAAAQAAAAEAAABlAw==", .back: "AAAAAgAAAJcAAAAjAw==",
            .home: "AAAAAQAAAAEAAABgAw==", .volUp: "AAAAAQAAAAEAAAASAw==", .volDown: "AAAAAQAAAAEAAAATAw==", .mute: "AAAAAQAAAAEAAAAUAw=="]
        let xml = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>\(m[k]!)</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>
        """
        try await http("POST", "http://\(host)/sony/ircc", body: Data(xml.utf8), headers: [
            "Content-Type": "text/xml; charset=UTF-8",
            "SOAPACTION": "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"", "X-Auth-PSK": psk])
    }
    var presets: [AppItem] { [] }
    func installedApps() async throws -> [AppItem] {
        let body = Data(#"{"method":"getApplicationList","id":1,"params":[],"version":"1.0"}"#.utf8)
        let (_, t) = try await httpFull("POST", "http://\(host)/sony/appControl", body: body, headers: ["X-Auth-PSK": psk, "Content-Type": "application/json"])
        guard let j = try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let r = (j["result"] as? [Any])?.first as? [[String: Any]] else { return [] }
        return r.compactMap { a in
            guard let n = a["title"] as? String, let u = a["uri"] as? String else { return nil }
            return AppItem(id: u, name: n)
        }
    }
    func launch(_ app: AppItem) async throws {
        let b = jsonStr(["method": "setActiveApp", "id": 1, "params": [["uri": app.id]], "version": "1.0"] as [String: Any])
        try await http("POST", "http://\(host)/sony/appControl", body: Data(b.utf8), headers: ["X-Auth-PSK": psk, "Content-Type": "application/json"])
    }
}

// MARK: Philips: JointSpace (1925) para modelos clásicos; si no responde, Android TV Remote v2 (requiere emparejar)
final class PhilipsRemote: TVRemote, Pairable, TextCapable, AppLaunchable, TextRequestSource, TextMirror, Warmable {
    let host: String
    private let atv: AndroidTVRemote
    init(host: String) { self.host = host; self.atv = AndroidTVRemote(host: host) }

    var isLinked: Bool { atv.isLinked }
    var onTextRequest: (() -> Void)? { get { atv.onTextRequest } set { atv.onTextRequest = newValue } }
    var onTVText: ((String) -> Void)? { get { atv.onTVText } set { atv.onTVText = newValue } }
    var tvText: String? { atv.tvText }
    var replacesText: Bool { atv.paired && atv.replacesText }

    func send(_ k: RemoteKey) async throws {
        if atv.paired { try await atv.send(k); return }
        let m: [RemoteKey: String] = [.power: "Standby", .up: "CursorUp", .down: "CursorDown", .left: "CursorLeft", .right: "CursorRight",
            .ok: "Confirm", .back: "Back", .home: "Home", .volUp: "VolumeUp", .volDown: "VolumeDown", .mute: "Mute"]
        let body = Data(#"{"key":"\#(m[k]!)"}"#.utf8)
        for v in ["6", "1"] {
            if let s = try? await http("POST", "http://\(host):1925/\(v)/input/key", body: body), s == 200 { return }
        }
        throw ATVError.notPaired
    }
    func beginPairing() async throws { try await atv.beginPairing() }
    func finishPairing(code: String) async throws { try await atv.finishPairing(code: code) }
    func cancelPairing() { atv.cancelPairing() }
    func warmUp() async { await atv.warmUp() }

    func typeText(_ s: String) async throws { guard atv.paired else { throw ATVError.notPaired }; try await atv.typeText(s) }
    func backspace(_ n: Int) async throws { guard atv.paired else { throw ATVError.notPaired }; try await atv.backspace(n) }
    func enter() async throws { guard atv.paired else { throw ATVError.notPaired }; try await atv.enter() }
    var presets: [AppItem] { atv.presets }
    func installedApps() async throws -> [AppItem] { [] }
    func launch(_ app: AppItem) async throws { guard atv.paired else { throw ATVError.notPaired }; try await atv.launch(app) }
}

// MARK: Samsung Tizen (WebSocket seguro 8002; la TV pide aceptar la 1ª vez)
final class SamsungRemote: TVRemote, Pairable, TextCapable, AppLaunchable, Warmable {
    let host: String
    private let gate = ConnectionGate<URLSessionWebSocketTask>()
    private let inflight = Locked<URLSessionWebSocketTask?>(nil)
    init(host: String) { self.host = host }

    var isLinked: Bool { !(UserDefaults.standard.string(forKey: "samsung.\(host)") ?? "").isEmpty }
    var needsCode: Bool { false }
    var replacesText: Bool { true }

    private func openSocket() async throws -> URLSessionWebSocketTask {
        let tk = UserDefaults.standard.string(forKey: "samsung.\(host)") ?? ""
        let name = Data("RemoteHub".utf8).base64EncodedString()
        var u = "wss://\(host):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if !tk.isEmpty { u += "&token=\(tk)" }
        guard let url = URL(string: u) else { throw URLError(.badURL) }
        rlog("SAMSUNG", "conectando wss://\(host):8002 (token guardado: \(tk.isEmpty ? "no" : "si"))")
        let t = lanSession.webSocketTask(with: url); t.resume()
        inflight.set(t)
        do {
            if case .string(let s) = try await t.receive() {
                let j = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
                rlog("SAMSUNG", "evento: \(j["event"] as? String ?? "?")")
                if let d = j["data"] as? [String: Any], let new = d["token"] as? String {
                    UserDefaults.standard.set(new, forKey: "samsung.\(host)"); rlog("SAMSUNG", "token recibido y guardado")
                }
            }
        } catch { t.cancel(with: .goingAway, reason: nil); throw error }
        return t
    }
    private func socket() async throws -> URLSessionWebSocketTask { try await gate.get { try await self.openSocket() } }

    func beginPairing() async throws {
        if let old = await gate.reset() { old.cancel(with: .goingAway, reason: nil) }
        _ = try await socket()
    }
    func cancelPairing() {
        inflight.get()?.cancel(with: .goingAway, reason: nil)
        Task { if let t = await gate.reset() { t.cancel(with: .goingAway, reason: nil) } }
    }
    func warmUp() async { if isLinked, await gate.current == nil { _ = try? await socket() } }

    /// Envía con un reintento: si el socket estaba muerto, reconecta y vuelve a enviar. Sin force-unwrap.
    private func sendRaw(_ json: String) async throws {
        var last: Error = URLError(.cannotConnectToHost)
        for _ in 0..<2 {
            let t = try await socket()
            do { try await t.send(.string(json)); return }
            catch { last = error; await gate.drop(t); t.cancel(with: .goingAway, reason: nil) }
        }
        throw last
    }
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "KEY_POWER", .up: "KEY_UP", .down: "KEY_DOWN", .left: "KEY_LEFT", .right: "KEY_RIGHT",
            .ok: "KEY_ENTER", .back: "KEY_RETURN", .home: "KEY_HOME", .volUp: "KEY_VOLUP", .volDown: "KEY_VOLDOWN", .mute: "KEY_MUTE"]
        guard let key = m[k] else { return }
        try await sendRaw(#"{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"\#(key)","Option":"false","TypeOfRemote":"SendRemoteKey"}}"#)
    }

    // Texto: SendInputString (experimental; se asume que reemplaza el contenido del campo)
    func typeText(_ s: String) async throws {
        let b64 = Data(s.utf8).base64EncodedString()
        try await sendRaw(#"{"method":"ms.remote.control","params":{"Cmd":"\#(b64)","DataOfCmd":"base64","TypeOfRemote":"SendInputString"}}"#)
    }
    func backspace(_ n: Int) async throws {}
    func enter() async throws { try await send(.ok) }

    // Apps
    var presets: [AppItem] { [AppItem(id: "11101200001", name: "Netflix"), AppItem(id: "111299001912", name: "YouTube"),
        AppItem(id: "3201910019365", name: "Prime Video"), AppItem(id: "3201901017640", name: "Disney+"), AppItem(id: "3201606009684", name: "Spotify")] }
    func installedApps() async throws -> [AppItem] {
        try await sendRaw(#"{"method":"ms.channel.emit","params":{"data":"","event":"ed.installedApp.get","to":"host"}}"#)
        guard let t = await gate.current else { return [] }
        let timer = Task { try? await Task.sleep(nanoseconds: 6_000_000_000); t.cancel(with: .goingAway, reason: nil) }
        defer { timer.cancel() }
        do {
            for _ in 0..<40 {
                guard case .string(let s) = try await t.receive(),
                      let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
                if j["event"] as? String == "ed.installedApp.get" {
                    let arr = ((j["data"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
                    return arr.compactMap { a in
                        guard let id = a["appId"] as? String, let n = a["name"] as? String else { return nil }
                        return AppItem(id: id, name: n)
                    }
                }
            }
        } catch { await gate.drop(t); throw error }
        return []
    }
    func launch(_ app: AppItem) async throws {
        let m = jsonStr(["method": "ms.channel.emit", "params": ["event": "ed.apps.launch", "to": "host",
                         "data": ["action_type": "DEEP_LINK", "appId": app.id]]] as [String: Any])
        try await sendRaw(m)
        _ = try? await http("POST", "http://\(host):8001/api/v2/applications/\(app.id)")
    }
}

// MARK: LG webOS (wss 3001; la TV pide aceptar la 1ª vez). Incluye cursor real (pointer socket)
final class LGSession {
    let task: URLSessionWebSocketTask
    let pointer: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask, pointer: URLSessionWebSocketTask) { self.task = task; self.pointer = pointer }
    func close() { task.cancel(with: .goingAway, reason: nil); pointer.cancel(with: .goingAway, reason: nil) }
}

final class LGRemote: TVRemote, Pairable, TextCapable, AppLaunchable, PointerCapable, Warmable {
    let host: String
    private let gate = ConnectionGate<LGSession>()
    private let inflight = Locked<URLSessionWebSocketTask?>(nil)
    init(host: String) { self.host = host }

    var isLinked: Bool { UserDefaults.standard.string(forKey: "lg.\(host)") != nil }
    var needsCode: Bool { false }

    private static func sendJSON(_ t: URLSessionWebSocketTask, _ o: [String: Any]) async throws {
        let d = try JSONSerialization.data(withJSONObject: o)
        try await t.send(.string(String(decoding: d, as: UTF8.self)))
    }
    private static func recvJSON(_ t: URLSessionWebSocketTask) async throws -> [String: Any] {
        if case .string(let s) = try await t.receive(),
           let j = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { return j }
        return [:]
    }

    private func openSession() async throws -> LGSession {
        rlog("LG", "conectando wss://\(host):3001")
        guard let url = URL(string: "wss://\(host):3001") else { throw URLError(.badURL) }
        let t = lanSession.webSocketTask(with: url); t.resume()
        inflight.set(t)
        do {
            var payload: [String: Any] = ["pairingType": "PROMPT", "manifest": ["manifestVersion": 1,
                "permissions": ["CONTROL_AUDIO", "CONTROL_POWER", "CONTROL_MOUSE_AND_KEYBOARD_INPUT", "CONTROL_INPUT_TEXT", "LAUNCH", "LAUNCH_WEBAPP", "READ_INSTALLED_APPS"]]]
            if let key = UserDefaults.standard.string(forKey: "lg.\(host)") { payload["client-key"] = key }
            try await Self.sendJSON(t, ["type": "register", "id": "reg", "payload": payload])
            while true {
                let j = try await Self.recvJSON(t)
                if j["type"] as? String == "registered" {
                    if let k = (j["payload"] as? [String: Any])?["client-key"] as? String { UserDefaults.standard.set(k, forKey: "lg.\(host)") }
                    rlog("LG", "registrado"); break
                }
                if j["type"] as? String == "error" { rlog("LG", "error de registro: \(j["error"] as? String ?? "?")"); throw URLError(.userAuthenticationRequired) }
            }
            try await Self.sendJSON(t, ["type": "request", "id": "ptr", "uri": "ssap://com.webos.service.networkinput/getPointerInputSocket"])
            for _ in 0..<10 {
                let j = try await Self.recvJSON(t)
                if let p = (j["payload"] as? [String: Any])?["socketPath"] as? String, let pu = URL(string: p) {
                    let ps = lanSession.webSocketTask(with: pu); ps.resume(); rlog("LG", "pointer socket listo")
                    return LGSession(task: t, pointer: ps)
                }
            }
            throw URLError(.cannotConnectToHost)
        } catch { t.cancel(with: .goingAway, reason: nil); throw error }
    }
    private func session() async throws -> LGSession { try await gate.get { try await self.openSession() } }
    private func fail(_ s: LGSession) async { await gate.drop(s); s.close() }

    /// Ejecuta con la sesión viva; si estaba muerta, reconecta y reintenta una vez.
    private func withSession(_ body: (LGSession) async throws -> Void) async throws {
        var last: Error = URLError(.cannotConnectToHost)
        for _ in 0..<2 {
            let s = try await session()
            do { try await body(s); return } catch { last = error; await fail(s) }
        }
        throw last
    }

    func beginPairing() async throws {
        if let old = await gate.reset() { old.close() }
        _ = try await session()
    }
    func cancelPairing() {
        inflight.get()?.cancel(with: .goingAway, reason: nil)
        Task { if let s = await gate.reset() { s.close() } }
    }
    func warmUp() async { if isLinked, await gate.current == nil { _ = try? await session() } }

    @discardableResult
    private func call(_ uri: String, _ payload: [String: Any] = [:], wait: Bool = false) async throws -> [String: Any] {
        let s = try await session()
        let id = "c\(Int.random(in: 1000...9999))"
        var m: [String: Any] = ["type": "request", "id": id, "uri": uri]
        if !payload.isEmpty { m["payload"] = payload }
        do {
            try await Self.sendJSON(s.task, m)
            guard wait else { return [:] }
            let timer = Task { try? await Task.sleep(nanoseconds: 6_000_000_000); s.task.cancel(with: .goingAway, reason: nil) }
            defer { timer.cancel() }
            for _ in 0..<200 {
                let j = try await Self.recvJSON(s.task)
                if j["id"] as? String == id { return (j["payload"] as? [String: Any]) ?? [:] }
            }
        } catch { await fail(s); throw error }
        return [:]
    }

    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.up: "UP", .down: "DOWN", .left: "LEFT", .right: "RIGHT", .ok: "ENTER", .back: "BACK",
            .home: "HOME", .volUp: "VOLUMEUP", .volDown: "VOLUMEDOWN", .mute: "MUTE"]
        try await withSession { s in
            if k == .power { try await Self.sendJSON(s.task, ["type": "request", "id": "off", "uri": "ssap://system/turnOff"]); return }
            guard let name = m[k] else { return }
            try await s.pointer.send(.string("type:button\nname:\(name)\n\n"))
        }
    }
    func moveCursor(dx: Int, dy: Int) async throws {
        try await withSession { s in try await s.pointer.send(.string("type:move\ndx:\(dx)\ndy:\(dy)\ndown:0\n\n")) }
    }
    func click() async throws {
        try await withSession { s in try await s.pointer.send(.string("type:click\n\n")) }
    }

    func typeText(_ s: String) async throws { try await call("ssap://com.webos.service.ime/insertText", ["text": s, "replace": 0]) }
    func backspace(_ n: Int) async throws { try await call("ssap://com.webos.service.ime/deleteCharacters", ["count": n]) }
    func enter() async throws { try await call("ssap://com.webos.service.ime/sendEnterKey") }

    var presets: [AppItem] { [AppItem(id: "netflix", name: "Netflix"), AppItem(id: "youtube.leanback.v4", name: "YouTube"),
        AppItem(id: "amazon", name: "Prime Video"), AppItem(id: "com.disney.disneyplus-prod", name: "Disney+"), AppItem(id: "spotify-beehive", name: "Spotify")] }
    func installedApps() async throws -> [AppItem] {
        let p = try await call("ssap://com.webos.applicationManager/listLaunchPoints", wait: true)
        let pts = (p["launchPoints"] as? [[String: Any]]) ?? []
        return pts.compactMap { a in
            guard let id = a["id"] as? String, let t = a["title"] as? String else { return nil }
            return AppItem(id: id, name: t)
        }
    }
    func launch(_ app: AppItem) async throws { try await call("ssap://system.launcher/launch", ["id": app.id]) }
}

// MARK: Blaster IR por WiFi con Tasmota (códigos de ejemplo protocolo SAMSUNG; falta base IRDB)
struct TasmotaIRRemote: TVRemote {
    let host: String
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "E0E040BF", .up: "E0E006F9", .down: "E0E08679", .left: "E0E0A659", .right: "E0E046B9",
            .ok: "E0E016E9", .back: "E0E01AE5", .home: "E0E09E61", .volUp: "E0E0E01F", .volDown: "E0E0D02F", .mute: "E0E0F00F"]
        let cmd = #"IRSend {"Protocol":"SAMSUNG","Bits":32,"Data":"0x\#(m[k]!)"}"#
        let q = cmd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cmd
        try await http("GET", "http://\(host)/cm?cmnd=\(q)")
    }
}
