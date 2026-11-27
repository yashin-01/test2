import Foundation
import Network

/// Wake-on-LAN: paquete mágico UDP (6×FF + 16×MAC) por broadcast. Despierta TVs apagadas/en reposo profundo.
func sendWoL(mac: String, ip: String) async {
    let hex = mac.filter { $0.isHexDigit }
    guard hex.count == 12 else { rlog("WOL", "MAC inválida"); return }
    var bytes: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let n = hex.index(i, offsetBy: 2)
        bytes.append(UInt8(hex[i..<n], radix: 16) ?? 0); i = n
    }
    let packet = Data([UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes })
    var targets = ["255.255.255.255"]
    let p = ip.split(separator: ".")
    if p.count == 4 { targets.append("\(p[0]).\(p[1]).\(p[2]).255") }
    for t in targets {
        for port: UInt16 in [9, 7] {
            let c = NWConnection(host: NWEndpoint.Host(t), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            c.start(queue: .global())
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let once = Locked(false)
                let fin: () -> Void = { if !once.modify({ let was = $0; $0 = true; return was }) { k.resume() } }
                c.send(content: packet, completion: .contentProcessed { _ in fin() })
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { fin() }
            }
            c.cancel()
            rlog("WOL", "paquete enviado a \(t):\(port)")
        }
    }
}

private let macTries = Locked<[String: Int]>([:])

private func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

/// Aprende la MAC de la TV mientras está encendida (la TV la informa por su API local) y la guarda para Wake-on-LAN.
func learnMAC(_ tv: TV) async {
    let key = "mac.\(tv.host)"
    if let m = UserDefaults.standard.string(forKey: key), !m.isEmpty { return }
    let n = macTries.modify { d -> Int in d[tv.host, default: 0] += 1; return d[tv.host] ?? 0 }
    guard n <= 3 else { return }
    var mac: String?
    switch tv.brand {
    case .androidTV, .philips:      // Chromecast integrado (Google TV / Android TV / Philips)
        if let r = try? await httpFull("GET", "http://\(tv.host):8008/setup/eureka_info?options=detail"),
           let j = try? JSONSerialization.jsonObject(with: Data(r.1.utf8)) as? [String: Any] { mac = j["mac_address"] as? String }
    case .samsung:
        if let r = try? await httpFull("GET", "http://\(tv.host):8001/api/v2/"),
           let j = try? JSONSerialization.jsonObject(with: Data(r.1.utf8)) as? [String: Any],
           let d = j["device"] as? [String: Any] { mac = d["wifiMac"] as? String }
    case .roku:
        if let r = try? await httpFull("GET", "http://\(tv.host):8060/query/device-info") {
            mac = between(r.1, "<wifi-mac>", "</wifi-mac>") ?? between(r.1, "<ethernet-mac>", "</ethernet-mac>")
        }
    default: break
    }
    if let m = mac, m.filter({ $0.isHexDigit }).count == 12 {
        UserDefaults.standard.set(m, forKey: key)
        rlog("WOL", "MAC aprendida automáticamente")
    } else {
        rlog("WOL", "no pude leer la MAC de la TV (intento \(n))")
    }
}
