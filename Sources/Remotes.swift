import Foundation

// MARK: Roku (ECP, puerto 8060, sin emparejar)
struct RokuRemote: TVRemote {
    let host: String
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "Power", .up: "Up", .down: "Down", .left: "Left", .right: "Right", .ok: "Select",
            .back: "Back", .home: "Home", .volUp: "VolumeUp", .volDown: "VolumeDown", .mute: "VolumeMute"]
        try await http("POST", "http://\(host):8060/keypress/\(m[k]!)")
    }
}

// MARK: Sony Bravia (IRCC). En la TV: Red doméstica > Control IP > Clave precompartida = 0000
struct SonyRemote: TVRemote {
    let host: String
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "AAAAAQAAAAEAAAAVAw==", .up: "AAAAAQAAAAEAAAB0Aw==", .down: "AAAAAQAAAAEAAAB1Aw==",
            .left: "AAAAAQAAAAEAAAA0Aw==", .right: "AAAAAQAAAAEAAAAzAw==", .ok: "AAAAAQAAAAEAAABlAw==", .back: "AAAAAgAAAJcAAAAjAw==",
            .home: "AAAAAQAAAAEAAABgAw==", .volUp: "AAAAAQAAAAEAAAASAw==", .volDown: "AAAAAQAAAAEAAAATAw==", .mute: "AAAAAQAAAAEAAAAUAw=="]
        let xml = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>\(m[k]!)</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>
        """
        let psk = UserDefaults.standard.string(forKey: "sony.psk") ?? "0000"
        try await http("POST", "http://\(host)/sony/ircc", body: Data(xml.utf8), headers: [
            "Content-Type": "text/xml; charset=UTF-8",
            "SOAPACTION": "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"", "X-Auth-PSK": psk])
    }
}

// MARK: Philips: JointSpace (1925) para modelos clásicos; si no responde, usa Android TV Remote v2 (requiere emparejar)
final class PhilipsRemote: TVRemote, Pairable {
    let host: String
    private let atv: AndroidTVRemote
    init(host: String) { self.host = host; self.atv = AndroidTVRemote(host: host) }
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
}

// MARK: Samsung Tizen (WebSocket seguro 8002; la TV pide aceptar la 1ª vez)
final class SamsungRemote: TVRemote {
    let host: String
    private var task: URLSessionWebSocketTask?
    init(host: String) { self.host = host }
    private func connect() async throws {
        let tk = UserDefaults.standard.string(forKey: "samsung.\(host)") ?? ""
        let name = Data("RemoteHub".utf8).base64EncodedString()
        var u = "wss://\(host):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if !tk.isEmpty { u += "&token=\(tk)" }
        rlog("SAMSUNG", "conectando wss://\(host):8002 (token guardado: \(tk.isEmpty ? "no" : "si"))")
        let t = lanSession.webSocketTask(with: URL(string: u)!); t.resume(); task = t
        if case .string(let s) = try await t.receive() {
            let j = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
            rlog("SAMSUNG", "evento: \(j["event"] as? String ?? "?")")
            if let d = j["data"] as? [String: Any], let new = d["token"] as? String {
                UserDefaults.standard.set(new, forKey: "samsung.\(host)"); rlog("SAMSUNG", "token recibido y guardado")
            }
        }
    }
    func send(_ k: RemoteKey) async throws {
        let m: [RemoteKey: String] = [.power: "KEY_POWER", .up: "KEY_UP", .down: "KEY_DOWN", .left: "KEY_LEFT", .right: "KEY_RIGHT",
            .ok: "KEY_ENTER", .back: "KEY_RETURN", .home: "KEY_HOME", .volUp: "KEY_VOLUP", .volDown: "KEY_VOLDOWN", .mute: "KEY_MUTE"]
        if task == nil { try await connect() }
        let msg = #"{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"\#(m[k]!)","Option":"false","TypeOfRemote":"SendRemoteKey"}}"#
        do { try await task!.send(.string(msg)) } catch { task = nil; throw error }
    }
}

// MARK: LG webOS (wss 3001; la TV pide aceptar la 1ª vez)
final class LGRemote: TVRemote {
    let host: String
    private var task: URLSessionWebSocketTask?
    private var pointer: URLSessionWebSocketTask?
    init(host: String) { self.host = host }

    private func sendJSON(_ o: [String: Any]) async throws {
        let d = try JSONSerialization.data(withJSONObject: o)
        try await task!.send(.string(String(data: d, encoding: .utf8)!))
    }
    private func recvJSON() async throws -> [String: Any] {
        if case .string(let s) = try await task!.receive(),
           let j = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { return j }
        return [:]
    }
    private func connect() async throws {
        rlog("LG", "conectando wss://\(host):3001")
        let t = lanSession.webSocketTask(with: URL(string: "wss://\(host):3001")!); t.resume(); task = t
        var payload: [String: Any] = ["pairingType": "PROMPT", "manifest": ["manifestVersion": 1,
            "permissions": ["CONTROL_AUDIO", "CONTROL_POWER", "CONTROL_MOUSE_AND_KEYBOARD_INPUT", "CONTROL_INPUT_TEXT"]]]
        if let key = UserDefaults.standard.string(forKey: "lg.\(host)") { payload["client-key"] = key }
        try await sendJSON(["type": "register", "id": "reg", "payload": payload])
        while true {
            let j = try await recvJSON()
            if j["type"] as? String == "registered" {
                if let k = (j["payload"] as? [String: Any])?["client-key"] as? String { UserDefaults.standard.set(k, forKey: "lg.\(host)") }
                rlog("LG", "registrado"); break
            }
            if j["type"] as? String == "error" { rlog("LG", "error de registro: \(j["error"] as? String ?? "?")"); throw URLError(.userAuthenticationRequired) }
        }
        try await sendJSON(["type": "request", "id": "ptr", "uri": "ssap://com.webos.service.networkinput/getPointerInputSocket"])
        for _ in 0..<10 {
            let j = try await recvJSON()
            if let p = (j["payload"] as? [String: Any])?["socketPath"] as? String {
                let ps = lanSession.webSocketTask(with: URL(string: p)!); ps.resume(); pointer = ps; rlog("LG", "pointer socket listo"); return
            }
        }
        throw URLError(.cannotConnectToHost)
    }
    func send(_ k: RemoteKey) async throws {
        if task == nil { try await connect() }
        do {
            if k == .power {
                try await sendJSON(["type": "request", "id": "off", "uri": "ssap://system/turnOff"]); return
            }
            let m: [RemoteKey: String] = [.up: "UP", .down: "DOWN", .left: "LEFT", .right: "RIGHT", .ok: "ENTER", .back: "BACK",
                .home: "HOME", .volUp: "VOLUMEUP", .volDown: "VOLUMEDOWN", .mute: "MUTE"]
            try await pointer!.send(.string("type:button\nname:\(m[k]!)\n\n"))
        } catch { task = nil; pointer = nil; throw error }
    }
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
