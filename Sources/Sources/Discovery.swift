import Foundation
import Network
import Darwin

func tcpOpen(_ ip: String, _ port: UInt16, timeout: Double = 0.8) async -> Bool {
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
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}

/// ¿La TV está encendida y accesible? (algún puerto de control abierto)
func quickOnline(_ tv: TV) async -> Bool {
    let ports: [UInt16]
    switch tv.brand {
    case .roku: ports = [8060]
    case .samsung: ports = [8001, 8002]
    case .lg: ports = [3001, 3000]
    case .sony: ports = [80]
    case .philips: ports = [6466, 1925, 1926]
    case .androidTV: ports = [6466]
    case .ir: ports = [80]
    }
    return await withTaskGroup(of: Bool.self) { g -> Bool in
        for p in ports { g.addTask { await tcpOpen(tv.host, p) } }
        for await ok in g { if ok { g.cancelAll(); return true } }
        return false
    }
}

/// Descubrimiento: Bonjour + SSDP + escaneo de subred. Todo candidato pasa por identify(),
/// que consulta la propia TV (API de Roku, Samsung, Philips, Sony…) para saber marca y nombre.
final class Discovery: ObservableObject {
    @Published var found: [TV] = []
    @Published var scanning = false
    private var browsers: [NWBrowser] = []
    private var seen = Set<String>()
    private var hints: [String: (String?, Brand?)] = [:]
    private let seenLock = NSLock()
    let types = ["_androidtvremote2._tcp", "_airplay._tcp", "_googlecast._tcp", "_samsungmsf._tcp", "_philipstv_s_rpc._tcp", "_philipstv_h_rpc._tcp"]

    func start() {
        stop(); scanning = true; found = []
        resetState()
        for t in types {
            let b = NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
            b.stateUpdateHandler = { s in rlog("BONJOUR", "\(t) estado: \(s)") }
            b.browseResultsChangedHandler = { [weak self] results, _ in
                rlog("BONJOUR", "\(t): \(results.count) servicios")
                for r in results {
                    guard case let .service(name, _, _, _) = r.endpoint else { continue }
                    var md = "", fn = ""
                    if case let .bonjour(txt) = r.metadata { md = txt.dictionary["md"] ?? ""; fn = txt.dictionary["fn"] ?? "" }
                    self?.resolve(r.endpoint, svcName: name, md: md, fn: fn)
                }
            }
            b.start(queue: .global()); browsers.append(b)
        }
        DispatchQueue.global().async { [weak self] in self?.ssdp() }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await self.scanSubnet()
            await MainActor.run { self.scanning = false }
        }
    }
    func stop() { browsers.forEach { $0.cancel() }; browsers = [] }

    private func resetState() { seenLock.lock(); seen.removeAll(); hints.removeAll(); seenLock.unlock() }
    private func setHint(_ ip: String, _ name: String?, _ brand: Brand?) { seenLock.lock(); hints[ip] = (name, brand); seenLock.unlock() }
    private func claim(_ ip: String) -> (Bool, (String?, Brand?)) {
        seenLock.lock(); defer { seenLock.unlock() }
        return (seen.insert(ip).inserted, hints[ip] ?? (nil, nil))
    }

    func brandFrom(_ s: String) -> Brand? {
        let n = s.lowercased()
        if n.contains("philips") { return .philips }
        if n.contains("roku") { return .roku }
        if n.contains("samsung") { return .samsung }
        if n.contains("webos") || n.contains("lge") || n.contains("lg ") { return .lg }
        if n.contains("bravia") || n.contains("sony") { return .sony }
        return nil
    }

    private func xmlTag(_ n: String, _ s: String) -> String? {
        guard let a = s.range(of: "<\(n)>"), let b = s.range(of: "</\(n)>", range: a.upperBound..<s.endIndex) else { return nil }
        let v = String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v.replacingOccurrences(of: "&amp;", with: "&")
    }
    private func jsonObj(_ s: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }

    // MARK: identificación de marca y nombre
    func identify(_ ip: String, hintName: String?, hintBrand: Brand?) async -> TV? {
        var opened = Set<UInt16>()
        await withTaskGroup(of: (UInt16, Bool).self) { g in
            for p in [UInt16(8060), 8001, 3000, 3001, 1925, 1926, 6466] { g.addTask { (p, await tcpOpen(ip, p)) } }
            for await (p, ok) in g where ok { opened.insert(p) }
        }
        guard !opened.isEmpty else { return nil }

        if opened.contains(8060) {
            var n = hintName ?? "Roku"
            if let r = try? await httpFull("GET", "http://\(ip):8060/query/device-info") {
                n = xmlTag("friendly-device-name", r.1) ?? xmlTag("user-device-name", r.1) ?? xmlTag("model-name", r.1) ?? n
            }
            return TV(name: n, host: ip, brand: .roku)
        }
        if opened.contains(8001) {
            var n = hintName ?? "Samsung TV"
            if let r = try? await httpFull("GET", "http://\(ip):8001/api/v2/"), let j = jsonObj(r.1),
               let d = j["device"] as? [String: Any], let nm = d["name"] as? String { n = nm }
            return TV(name: n, host: ip, brand: .samsung)
        }
        if opened.contains(3001) || (opened.contains(3000) && hintBrand == .lg) {
            return TV(name: hintName ?? "LG TV", host: ip, brand: .lg)
        }
        if opened.contains(1925) || opened.contains(1926) || hintBrand == .philips {
            for url in ["https://\(ip):1926/6/system", "http://\(ip):1925/6/system", "http://\(ip):1925/1/system"] {
                if let r = try? await httpFull("GET", url), r.0 == 200, let j = jsonObj(r.1), let n = j["name"] as? String {
                    return TV(name: hintName ?? "Philips \(n)", host: ip, brand: .philips)
                }
            }
            if hintBrand == .philips { return TV(name: hintName ?? "Philips TV", host: ip, brand: .philips) }
        }
        if opened.contains(6466) {
            let body = Data(#"{"method":"getInterfaceInformation","id":1,"params":[],"version":"1.0"}"#.utf8)
            if let r = try? await httpFull("POST", "http://\(ip)/sony/system", body: body, headers: ["Content-Type": "application/json"]),
               r.0 == 200, let j = jsonObj(r.1), let res = (j["result"] as? [Any])?.first as? [String: Any] {
                let m = (res["modelName"] as? String) ?? "BRAVIA"
                return TV(name: hintName ?? "Sony \(m)", host: ip, brand: .androidTV)
            }
            return TV(name: hintName ?? "Android TV (\(ip))", host: ip, brand: .androidTV)
        }
        return nil
    }

    func identifyAndAdd(_ ip: String) async {
        let (isNew, h) = claim(ip)
        guard isNew else { return }
        guard let tv = await identify(ip, hintName: h.0, hintBrand: h.1) else { return }
        rlog("DISC", "\(tv.host) -> \(tv.brand.rawValue) '\(tv.name)'")
        await MainActor.run { self.found.append(tv) }
    }

    // MARK: Bonjour
    private func resolve(_ ep: NWEndpoint, svcName: String, md: String, fn: String) {
        let p = NWParameters.tcp
        (p.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: ep, using: p)
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                if case let .hostPort(h, _)? = c.currentPath?.remoteEndpoint {
                    var ip = "\(h)"; if let i = ip.firstIndex(of: "%") { ip = String(ip[..<i]) }
                    let label = fn.isEmpty ? (md.isEmpty ? nil : md) : fn
                    self?.setHint(ip, label, self?.brandFrom(md + " " + fn + " " + svcName))
                    Task { await self?.identifyAndAdd(ip) }
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
            setHint(ip, nil, brandFrom(text))
            Task { await self.identifyAndAdd(ip) }
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
    func portOpen(_ ip: String, _ port: UInt16) async -> Bool { await tcpOpen(ip, port) }

    func scanSubnet() async {
        guard let me = localIPv4() else { rlog("SCAN", "sin IPv4 en en0"); return }
        let base = me & 0xFFFF_FF00
        rlog("SCAN", "escaneando \(ipString(base)).0/24 desde \(ipString(me))")
        let ports: [UInt16] = [8060, 8001, 3001, 1925, 1926, 6466]
        for start in stride(from: 1, to: 255, by: 24) {
            await withTaskGroup(of: Void.self) { g in
                for h in start..<min(start + 24, 255) {
                    let addr = base | UInt32(h); if addr == me { continue }
                    let ip = ipString(addr)
                    g.addTask {
                        let hit = await withTaskGroup(of: Bool.self) { pg -> Bool in
                            for p in ports { pg.addTask { await tcpOpen(ip, p, timeout: 0.6) } }
                            for await ok in pg { if ok { pg.cancelAll(); return true } }
                            return false
                        }
                        if hit { await self.identifyAndAdd(ip) }
                    }
                }
            }
        }
        rlog("SCAN", "terminado")
    }
}
