import Foundation
import Network
import Security
import CryptoKit

enum ATVError: LocalizedError {
    case notPaired, badCode, protocolError(String)
    var errorDescription: String? {
        switch self {
        case .notPaired: return "Falta emparejar con la TV"
        case .badCode: return "Código incorrecto"
        case .protocolError(let s): return "Protocolo: \(s)"
        }
    }
}


// MARK: DER mínimo (certificado autofirmado + lectura de claves RSA)
enum DER {
    static func len(_ n: Int) -> [UInt8] {
        if n < 128 { return [UInt8(n)] }
        var b: [UInt8] = []; var x = n
        while x > 0 { b.insert(UInt8(x & 0xff), at: 0); x >>= 8 }
        return [0x80 | UInt8(b.count)] + b
    }
    static func tlv(_ tag: UInt8, _ c: [UInt8]) -> [UInt8] { [tag] + len(c.count) + c }
    static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }

    /// RSAPublicKey PKCS#1 -> (modulus, exponent) sin ceros a la izquierda
    static func rsaNE(_ d: [UInt8]) -> ([UInt8], [UInt8])? {
        var i = 0
        func readLen() -> Int? {
            guard i < d.count else { return nil }
            let b = d[i]; i += 1
            if b < 128 { return Int(b) }
            let n = Int(b & 0x7f); guard i + n <= d.count else { return nil }
            var v = 0; for _ in 0..<n { v = v << 8 | Int(d[i]); i += 1 }
            return v
        }
        guard i < d.count, d[i] == 0x30 else { return nil }; i += 1
        guard readLen() != nil else { return nil }
        var ints: [[UInt8]] = []
        for _ in 0..<2 {
            guard i < d.count, d[i] == 0x02 else { return nil }; i += 1
            guard let l = readLen(), i + l <= d.count else { return nil }
            var v = Array(d[i..<i + l]); i += l
            while v.count > 1 && v[0] == 0 { v.removeFirst() }
            ints.append(v)
        }
        return (ints[0], ints[1])
    }
}

// MARK: Protobuf mínimo
enum PB {
    static func varint(_ v: Int) -> [UInt8] {
        var x = UInt64(v); var o: [UInt8] = []
        repeat { var b = UInt8(x & 0x7f); x >>= 7; if x > 0 { b |= 0x80 }; o.append(b) } while x > 0
        return o
    }
    static func vi(_ f: Int, _ v: Int) -> [UInt8] { varint(f << 3) + varint(v) }
    static func ld(_ f: Int, _ b: [UInt8]) -> [UInt8] { varint(f << 3 | 2) + varint(b.count) + b }
    static func str(_ f: Int, _ s: String) -> [UInt8] { ld(f, Array(s.utf8)) }
    struct Field { var v: Int?; var b: [UInt8]? }
    static func readVarint(_ d: [UInt8], _ i: inout Int) -> Int? {
        var r = 0, s = 0
        while i < d.count { let b = d[i]; i += 1; r |= Int(b & 0x7f) << s; if b & 0x80 == 0 { return r }; s += 7; if s > 56 { return nil } }
        return nil
    }
    static func parse(_ d: [UInt8]) -> [Int: Field] {
        var r: [Int: Field] = [:]; var i = 0
        while i < d.count {
            guard let k = readVarint(d, &i) else { break }
            let f = k >> 3, w = k & 7
            if w == 0 { guard let v = readVarint(d, &i) else { break }; r[f] = Field(v: v, b: nil) }
            else if w == 2 { guard let l = readVarint(d, &i), i + l <= d.count else { break }; r[f] = Field(v: nil, b: Array(d[i..<i + l])); i += l }
            else { break }
        }
        return r
    }
}

// MARK: Identidad (certificado cliente autofirmado, guardado en el Keychain)
enum ATVIdentity {
    static let tag = "com.remotehub.atv.identity"

    // Respaldo en archivo: el emparejamiento sobrevive a re-firmas (si el Keychain se pierde, se restaura desde aquí)
    private static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("atv", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func save(priv: SecKey, cert: Data) {
        var e: Unmanaged<CFError>?
        if let k = SecKeyCopyExternalRepresentation(priv, &e) as Data? {
            try? k.write(to: dir.appendingPathComponent("key.der")); try? cert.write(to: dir.appendingPathComponent("cert.der"))
            rlog("ATV", "identidad respaldada en archivo")
        }
    }
    static func restore() -> SecIdentity? {
        guard let kd = try? Data(contentsOf: dir.appendingPathComponent("key.der")),
              let cd = try? Data(contentsOf: dir.appendingPathComponent("cert.der")) else { return nil }
        var e: Unmanaged<CFError>?
        let ka: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(kd as CFData, ka as CFDictionary, &e), let cert = SecCertificateCreateWithData(nil, cd as CFData) else { return nil }
        let kq: [CFString: Any] = [kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrApplicationTag: Data(tag.utf8), kSecAttrIsPermanent: true]
        let cq: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: cert, kSecAttrLabel: tag]
        _ = SecItemAdd(kq as CFDictionary, nil); _ = SecItemAdd(cq as CFDictionary, nil)
        rlog("ATV", "identidad restaurada desde archivo")
        return lookup()
    }

    static func lookup() -> SecIdentity? {
        let q: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecAttrLabel: tag, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let ref = r else { return nil }
        return (ref as! SecIdentity)
    }

    static func identity() throws -> SecIdentity {
        if let id = lookup() { return id }
        if let id = restore() { return id }
        rlog("ATV", "creando identidad RSA 2048 + certificado autofirmado")
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Data(tag.utf8)]]
        var e: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &e), let pub = SecKeyCopyPublicKey(priv),
              let pubData = SecKeyCopyExternalRepresentation(pub, &e) as Data? else { throw ATVError.protocolError("no se pudo crear la clave") }
        let sigAlg = DER.seq(DER.tlv(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), [0x05, 0x00])
        let name = DER.seq(DER.tlv(0x31, DER.seq(DER.tlv(0x06, [0x55, 0x04, 0x03]), DER.tlv(0x0C, Array("atvremote".utf8)))))
        let validity = DER.seq(DER.tlv(0x17, Array("200101000000Z".utf8)), DER.tlv(0x17, Array("490101000000Z".utf8)))
        let spki = DER.seq(DER.seq(DER.tlv(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), [0x05, 0x00]),
                           DER.tlv(0x03, [0x00] + [UInt8](pubData)))
        let tbs = DER.seq([0xA0, 0x03, 0x02, 0x01, 0x02], DER.tlv(0x02, [0x01, 0x23, 0x45, 0x67]), sigAlg, name, validity, name, spki)
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &e) as Data? else {
            throw ATVError.protocolError("no se pudo firmar el certificado") }
        let cert = DER.seq(tbs, sigAlg, DER.tlv(0x03, [0x00] + [UInt8](sig)))
        guard let c = SecCertificateCreateWithData(nil, Data(cert) as CFData) else { throw ATVError.protocolError("certificado inválido") }
        let addQ: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: c, kSecAttrLabel: tag]
        let st = SecItemAdd(addQ as CFDictionary, nil)
        rlog("ATV", "certificado guardado en Keychain: OSStatus \(st)")
        save(priv: priv, cert: Data(cert))
        guard let id = lookup() else { throw ATVError.protocolError("identidad no encontrada en Keychain") }
        return id
    }

    static func publicKeyDER() -> [UInt8]? {
        guard let id = try? identity() else { return nil }
        var c: SecCertificate?
        SecIdentityCopyCertificate(id, &c)
        guard let cert = c, let k = SecCertificateCopyKey(cert), let d = SecKeyCopyExternalRepresentation(k, nil) as Data? else { return nil }
        return [UInt8](d)
    }
}

// MARK: Canal TLS con mensajes prefijados por varint
final class KeyBox { var key: [UInt8] = [] }

final class TLSChannel {
    let conn: NWConnection
    let box: KeyBox
    let label: String
    private var buf: [UInt8] = []

    init(host: String, port: UInt16) throws {
        let box = KeyBox(); self.box = box; self.label = "\(host):\(port)"
        rlog("ATV", "preparando TLS \(host):\(port)")
        let id = try ATVIdentity.identity()
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let sid = sec_identity_create(id) { sec_protocol_options_set_local_identity(sec, sid) }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let c = chain.first,
               let k = SecCertificateCopyKey(c), let d = SecKeyCopyExternalRepresentation(k, nil) as Data? { box.key = [UInt8](d) }
            complete(true)
        }, DispatchQueue.global())
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            let label = self.label
            conn.stateUpdateHandler = { s in
                rlog("ATV", "\(label) estado: \(s)")
                guard !done else { return }
                switch s {
                case .ready: done = true; c.resume()
                case .failed(let e), .waiting(let e): done = true; c.resume(throwing: e)
                case .cancelled: done = true; c.resume(throwing: URLError(.timedOut))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if !done { self.conn.cancel() } }
        }
    }

    private func readBytes(_ n: Int) async throws -> [UInt8] {
        while buf.count < n {
            let d: Data = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                    if let err = err { c.resume(throwing: err) }
                    else if let data = data, !data.isEmpty { c.resume(returning: data) }
                    else { c.resume(throwing: URLError(.networkConnectionLost)) }
                }
            }
            buf += d
        }
        let r = Array(buf.prefix(n)); buf.removeFirst(n); return r
    }

    func readMessage() async throws -> [UInt8] {
        var len = 0, shift = 0
        while true {
            let b = try await readBytes(1)[0]
            len |= Int(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        let m = try await readBytes(len)
        rlog("ATV", "\(label) <- \(m.count)B campos \(PB.parse(m).keys.sorted())")
        return m
    }

    func write(_ m: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            rlog("ATV", "\(label) -> \(m.count)B campos \(PB.parse(m).keys.sorted())")
            conn.send(content: Data(PB.varint(m.count) + m), completion: .contentProcessed { e in
                if let e = e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }
}

// MARK: Android TV Remote v2 (Philips Android, Sony/TCL/Hisense/Xiaomi/Google TV...)
final class AndroidTVRemote: TVRemote, Pairable, TextCapable, AppLaunchable, TextRequestSource, TextMirror, Warmable {
    let host: String
    private var pairing: TLSChannel?
    private var ctl: TLSChannel?
    private var listener: Task<Void, Never>?
    init(host: String) { self.host = host }

    var paired: Bool { UserDefaults.standard.bool(forKey: "atv.paired.\(host)") }
    var isLinked: Bool { paired }
    var onTextRequest: (() -> Void)?
    var onTVText: ((String) -> Void)?
    var tvText: String? { imeText }
    private var imeCounter = 0
    private var fieldCounter = 0
    private var imeText: String?
    private var imeReady = false

    /// Cancela el emparejamiento en curso: avisa a la TV (status 400) y cierra el canal para que quite el aviso.
    func cancelPairing() {
        guard let c = pairing else { return }
        pairing = nil
        rlog("ATV", "emparejamiento cancelado por el usuario")
        Task { try? await c.write(PB.vi(1, 2) + PB.vi(2, 400)); c.conn.cancel() }
    }
    func warmUp() async { if paired, ctl == nil { try? await connectControl() } }

    // Texto: se inyectan teclas Android (a-z, 0-9 y algunos signos; sin mayúsculas)
    private func keyCode(_ ch: Character) -> Int? {
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 97...122: return 29 + Int(a) - 97
        case 48...57: return 7 + Int(a) - 48
        case 32: return 62
        case 46: return 56
        case 44: return 55
        case 45: return 69
        case 64: return 77
        case 47: return 76
        default: return nil
        }
    }
    private func inject(_ code: Int) async throws {
        if ctl == nil { try await connectControl(); try await Task.sleep(nanoseconds: 800_000_000) }
        do { try await ctl!.write(PB.ld(10, PB.vi(1, code) + PB.vi(2, 3))) } catch { ctl = nil; listener?.cancel(); throw error }
    }
    /// Con campo de texto activo en la TV se usa el canal IME (texto completo, como la app oficial);
    /// si no, se inyectan teclas sueltas.
    var replacesText: Bool { imeReady }
    private func sendIME(_ s: String) async throws {
        if ctl == nil { try await connectControl(); try await Task.sleep(nanoseconds: 800_000_000) }
        let pos = max(0, s.count - 1)
        let edit = PB.vi(1, 1) + PB.ld(2, PB.vi(1, pos) + PB.vi(2, pos) + PB.str(3, s))
        let msg = PB.ld(21, PB.vi(1, imeCounter) + PB.vi(2, fieldCounter) + PB.ld(3, edit))
        rlog("ATV", "IME enviado: \(s.count) caracteres (contadores \(imeCounter)/\(fieldCounter))")
        do { try await ctl!.write(msg) } catch { ctl = nil; listener?.cancel(); throw error }
        imeText = s
    }
    func typeText(_ s: String) async throws {
        if imeReady { try await sendIME(s); return }
        rlog("ATV", "sin campo IME activo: se inyectan teclas")
        for ch in s.lowercased() {
            if let c = keyCode(ch) { try await inject(c) } else { rlog("ATV", "caracter no soportado: \(ch)") }
        }
    }
    func backspace(_ n: Int) async throws { for _ in 0..<n { try await inject(67) } }
    func enter() async throws { try await inject(66) }

    // Apps (deep link / paquete). La lista de apps instaladas no está disponible en este protocolo.
    let presets: [AppItem] = [AppItem(id: "https://www.netflix.com/title", name: "Netflix"), AppItem(id: "https://www.youtube.com", name: "YouTube"),
        AppItem(id: "https://app.primevideo.com", name: "Prime Video"), AppItem(id: "https://www.disneyplus.com", name: "Disney+"),
        AppItem(id: "https://open.spotify.com", name: "Spotify")]
    func installedApps() async throws -> [AppItem] { [] }
    func launch(_ app: AppItem) async throws {
        if ctl == nil { try await connectControl(); try await Task.sleep(nanoseconds: 800_000_000) }
        let link = app.id.contains(":") ? app.id : "market://launch?id=\(app.id)"
        rlog("ATV", "abrir app: \(link)")
        do { try await ctl!.write(PB.ld(90, PB.str(1, link))) } catch { ctl = nil; listener?.cancel(); throw error }
    }
    private func outer(_ extra: [UInt8]) -> [UInt8] { PB.vi(1, 2) + PB.vi(2, 200) + extra }
    private func expectOK(_ m: [UInt8]) throws {
        guard PB.parse(m)[2]?.v == 200 else { throw ATVError.protocolError("la TV rechazó el emparejamiento") }
    }

    func beginPairing() async throws {
        cancelPairing()
        let ch = try TLSChannel(host: host, port: 6467)
        try await ch.open(); pairing = ch
        try await ch.write(outer(PB.ld(10, PB.str(1, "atvremote") + PB.str(2, "RemoteHub"))))
        try expectOK(try await ch.readMessage())
        let enc = PB.vi(1, 3) + PB.vi(2, 6)   // HEXADECIMAL, 6 símbolos
        try await ch.write(outer(PB.ld(20, PB.ld(1, enc) + PB.vi(3, 1))))
        _ = try await ch.readMessage()
        try await ch.write(outer(PB.ld(30, PB.ld(1, enc) + PB.vi(2, 1))))
        try expectOK(try await ch.readMessage())
    }

    func finishPairing(code: String) async throws {
        let c = code.trimmingCharacters(in: .whitespaces)
        var cb: [UInt8] = []
        var idx = c.startIndex
        while idx < c.endIndex, let nx = c.index(idx, offsetBy: 2, limitedBy: c.endIndex), let b = UInt8(c[idx..<nx], radix: 16) { cb.append(b); idx = nx }
        guard let ch = pairing, c.count == 6, cb.count == 3,
              let mine = ATVIdentity.publicKeyDER(), let (cn, ce) = DER.rsaNE(mine), let (sn, se) = DER.rsaNE(ch.box.key)
        else { rlog("ATV", "finishPairing: datos invalidos (canal \(pairing != nil), largo \(c.count))"); throw ATVError.badCode }
        var h = SHA256()
        h.update(data: cn + ce + sn + se + Array(cb.dropFirst()))
        let digest = Array(h.finalize())
        guard digest[0] == cb[0] else { rlog("ATV", "el codigo no coincide con el hash (tipeo o calculo)"); throw ATVError.badCode }
        try await ch.write(outer(PB.ld(40, PB.ld(1, digest))))
        try expectOK(try await ch.readMessage())
        UserDefaults.standard.set(true, forKey: "atv.paired.\(host)")
        ch.conn.cancel(); pairing = nil
    }

    private func connectControl() async throws {
        guard paired else { throw ATVError.notPaired }
        imeReady = false
        let ch = try TLSChannel(host: host, port: 6466)
        try await ch.open(); ctl = ch
        listener = Task { [weak self] in await self?.listen(ch) }
    }

    private func listen(_ ch: TLSChannel) async {
        var got = 0
        while !Task.isCancelled {
            guard let m = try? await ch.readMessage() else { break }
            got += 1
            let f = PB.parse(m)
            if let imeData = f[20]?.b {
                let ime = PB.parse(imeData)
                let app = ime[1]?.b.map { PB.parse($0) } ?? [:]
                let tfs = ime[2]?.b.map { PB.parse($0) }
                if let c = app[1]?.v { imeCounter = c }
                imeReady = (tfs != nil)
                rlog("ATV", "IME recibido: app_info \(app.keys.sorted()) campo \(tfs.map { "\($0.keys.sorted())" } ?? "ninguno")")
                if let t = tfs {
                    if let fc = t[1]?.v { fieldCounter = fc }
                    let val = t[2]?.b.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
                    imeText = val
                    rlog("ATV", "campo de texto activo (contador \(fieldCounter), \(val.count) caracteres)")
                    DispatchQueue.main.async { self.onTVText?(val) }
                }
            }
            if let showData = f[22]?.b {
                let t = PB.parse(showData)[2]?.b.map { PB.parse($0) }
                if let t = t {
                    imeReady = true
                    if let fc = t[1]?.v { fieldCounter = fc }
                    let val = t[2]?.b.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
                    imeText = val
                    DispatchQueue.main.async { self.onTVText?(val) }
                }
                rlog("ATV", "la TV pide teclado (ime_show_request, con campo: \(t != nil))")
                DispatchQueue.main.async { self.onTextRequest?() }
            }
            if f[1] != nil {
                let info = PB.str(1, "iPhone") + PB.str(2, "RemoteHub") + PB.vi(3, 1) + PB.str(4, "1") + PB.str(5, "com.remotehub.app") + PB.str(6, "1.0")
                try? await ch.write(PB.ld(1, PB.vi(1, 622) + PB.ld(2, info)))
            } else if f[2] != nil {
                try? await ch.write(PB.ld(2, PB.vi(1, 622)))
            } else if let p = f[8]?.b {
                try? await ch.write(PB.ld(9, PB.vi(1, PB.parse(p)[1]?.v ?? 0)))
            }
        }
        if got == 0 && !Task.isCancelled {
            UserDefaults.standard.set(false, forKey: "atv.paired.\(host)")
            rlog("ATV", "la TV cerro sin responder: el emparejamiento ya no es valido, hay que emparejar de nuevo")
        }
        ctl = nil
    }

    func send(_ k: RemoteKey) async throws {
        if ctl == nil { try await connectControl(); try await Task.sleep(nanoseconds: 800_000_000) }
        let codes: [RemoteKey: Int] = [.power: 26, .up: 19, .down: 20, .left: 21, .right: 22, .ok: 23, .back: 4, .home: 3, .volUp: 24, .volDown: 25, .mute: 164]
        do { try await ctl!.write(PB.ld(10, PB.vi(1, codes[k]!) + PB.vi(2, 3))) }
        catch { ctl = nil; listener?.cancel(); throw error }
    }
}
