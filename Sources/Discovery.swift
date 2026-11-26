import Foundation
import Network
import Darwin

/// Descubrimiento en 3 capas: Bonjour + SSDP (multicast) + escaneo unicast de la subred.
/// Si iOS bloquea el multicast (sin entitlement), el escaneo unicast cubre la misma función.
final class Discovery: ObservableObject {
    @Published var found: [TV] = []
    @Published var scanning = false
    private var browsers: [NWBrowser] = []
    let types = ["_androidtvremote2._tcp", "_airplay._tcp", "_googlecast._tcp", "_samsungmsf._tcp", "_philipstv_s_rpc._tcp", "_philipstv_h_rpc._tcp"]

    func start() {
        stop(); scanning = true
        for t in types {
            let b = NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
            b.stateUpdateHandler = { s in rlog("BONJOUR", "\(t) estado: \(s)") }
            b.browseResultsChangedHandler = { [weak self] results, _ in
                rlog("BONJOUR", "\(t): \(results.count) servicios")
                for r in results { if case let .service(name, _, _, _) = r.endpoint { self?.resolve(r.endpoint, name: name, type: t) } }
            }
            b.start(queue: .global()); browsers.append(b)
        }
        DispatchQueue.global().async { [weak self] in self?.ssdp() }
        Task { await self.scanSubnet(); await MainActor.run { self.scanning = false } }
    }
    func stop() { browsers.forEach { $0.cancel() }; browsers = [] }

    private func add(_ ip: String, _ name: String, _ brand: Brand) {
        DispatchQueue.main.async {
            if let i = self.found.firstIndex(where: { $0.host == ip }) {
                if brand == .philips { self.found[i].brand = .philips }
            } else { rlog("DISC", "nuevo \(ip) \(brand.rawValue) '\(name)'"); self.found.append(TV(name: name, host: ip, brand: brand)) }
        }
    }

    private func brandFrom(_ s: String) -> Brand? {
        let n = s.lowercased()
        if n.contains("philips") { return .philips }
        if n.contains("roku") { return .roku }
        if n.contains("samsung") { return .samsung }
        if n.contains("webos") || n.contains("lge") || n.contains("lg ") { return .lg }
        if n.contains("bravia") || n.contains("sony") { return .sony }
        return nil
    }

    // MARK: Bonjour
    private func resolve(_ ep: NWEndpoint, name: String, type: String) {
        let p = NWParameters.tcp
        (p.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: ep, using: p)
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                if case let .hostPort(h, _)? = c.currentPath?.remoteEndpoint {
                    var ip = "\(h)"; if let i = ip.firstIndex(of: "%") { ip = String(ip[..<i]) }
                    let b = self?.brandFrom(name) ?? (type.contains("androidtvremote2") ? .androidTV : .roku)
                    self?.add(ip, name, b)
                }
                c.cancel()
            case .failed: c.cancel()
            default: break
            }
        }
        c.start(queue: .global())
    }

    // MARK: SSDP (requiere entitlement multicast; si falla, se ignora)
    @discardableResult
    func ssdp() -> (sent: Int, err: String, replies: Int) {
        let s = socket(AF_INET, SOCK_DGRAM, 0); guard s >= 0 else { rlog("SSDP", "socket() fallo"); return (-1, "socket", 0) }
        defer { close(s) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, msg, msg.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent > 0 else {
            let n = errno; let e = String(cString: strerror(n))
            rlog("SSDP", "sendto multicast FALLO: \(e) (errno \(n)) -> multicast bloqueado, sin entitlement")
            return (-1, e, 0)
        }
        rlog("SSDP", "M-SEARCH enviado (\(sent) bytes), escuchando 4s")
        var count = 0
        let end = Date().addingTimeInterval(4)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < end {
            var from = sockaddr_in(); var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buf, buf.count, 0, $0, &fl) }
            }
            if n <= 0 { usleep(100_000); continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); var a = from.sin_addr
            inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf); count += 1
            let server = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("server:") }) ?? ""
            rlog("SSDP", "respuesta de \(ip) \(server)")
            if let b = brandFrom(text) { add(ip, b.rawValue, b) }
        }
        rlog("SSDP", "fin: \(count) respuestas")
        return (sent, "", count)
    }

    // MARK: Escaneo unicast de la subred /24 (no necesita entitlement)
    func localIPv4() -> UInt32? {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return nil }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let c = p {
            let i = c.pointee
            if let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), String(cString: i.ifa_name) == "en0" {
                let sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                return UInt32(bigEndian: sin.sin_addr.s_addr)
            }
            p = i.ifa_next
        }
        return nil
    }
    func ipString(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }

    func portOpen(_ ip: String, _ port: UInt16) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let lock = NSLock(); var done = false
            func finish(_ ok: Bool) {
                lock.lock(); defer { lock.unlock() }
                if done { return }; done = true; conn.cancel(); c.resume(returning: ok)
            }
            conn.stateUpdateHandler = { s in
                switch s { case .ready: finish(true); case .failed, .waiting: finish(false); default: break }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { finish(false) }
        }
    }

    func scanSubnet() async {
        guard let me = localIPv4() else { rlog("SCAN", "sin IPv4 en en0"); return }
        let base = me & 0xFFFF_FF00
        rlog("SCAN", "escaneando \(ipString(base)).0/24 desde \(ipString(me))")
        let ports: [(UInt16, Brand)] = [(8060, .roku), (8001, .samsung), (3000, .lg), (1925, .philips), (6466, .androidTV)]
        for start in stride(from: 1, to: 255, by: 24) {
            await withTaskGroup(of: Void.self) { g in
                for h in start..<min(start + 24, 255) {
                    let addr = base | UInt32(h); if addr == me { continue }
                    let ip = ipString(addr)
                    for (port, brand) in ports {
                        g.addTask { if await self.portOpen(ip, port) { self.add(ip, "\(brand.rawValue) \(ip)", brand) } }
                    }
                }
            }
        }
    }
}
