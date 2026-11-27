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
