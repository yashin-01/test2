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

    private static let idLock = NSLock()
    static func identity() throws -> SecIdentity {
        idLock.lock(); defer { idLock.unlock() }
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
            let lock = NSLock()
            var done = false
            let label = self.label
            let conn = self.conn
            // Se resume UNA sola vez, aunque lleguen varios estados a la vez desde hilos distintos
            let finish: (Error?) -> Void = { err in
                lock.lock(); let first = !done; done = true; lock.unlock()
                guard first else { return }
                if let err = err { conn.cancel(); c.resume(throwing: err) } else { c.resume() }
            }
            conn.stateUpdateHandler = { s in
                rlog("ATV", "\(label) estado: \(s)")
                switch s {
                case .ready: finish(nil)
                case .failed(let e), .waiting(let e): finish(e)
                case .cancelled: finish(URLError(.timedOut))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { finish(URLError(.timedOut)) }
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
            if shift > 28 { throw ATVError.protocolError("mensaje inválido") }
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

// MARK: Estado del campo de texto de la TV (lo escribe el hilo de escucha, lo lee la UI)
struct IMEValues { var ready = false; var imeCounter = 0; var fieldCounter = 0; var text: String? }
final class IMEState {
    private let box = Locked(IMEValues())
    var snapshot: IMEValues { box.get() }
    func update(_ f: @escaping (inout IMEValues) -> Void) { box.modify { f(&$0) } }
}
enum ATVEvent { case tvText(String), textRequest, unpaired }

// MARK: Sesión de control (puerto 6466). Es un actor: todo el estado de la conexión pasa por aquí,
// una sola conexión, sin accesos simultáneos.
actor ATVLink {
    private let host: String
    private let ime: IMEState
    private let emit: (ATVEvent) -> Void
    private var channel: TLSChannel?
    private var connecting: Task<TLSChannel, Error>?
    private var listener: Task<Void, Never>?

    init(host: String, ime: IMEState, emit: @escaping (ATVEvent) -> Void) {
        self.host = host; self.ime = ime; self.emit = emit
    }

    var isConnected: Bool { channel != nil }

    /// Devuelve siempre un canal vivo. Llamadas simultáneas comparten una única conexión.
    func ensure() async throws -> TLSChannel {
        if let c = channel { return c }
        if let t = connecting { return try await t.value }
        let t = Task { try await self.openChannel() }
        connecting = t
        defer { connecting = nil }
        return try await t.value
    }

    private func openChannel() async throws -> TLSChannel {
        let ch = try TLSChannel(host: host, port: 6466)
        try await ch.open()
        channel = ch
        ime.update { $0 = IMEValues() }
        listener?.cancel()
        listener = Task { await self.listen(ch) }
        try? await Task.sleep(nanoseconds: 700_000_000)   // dar tiempo al saludo inicial
        return ch
    }

    /// Escribe con un reintento: si la conexión estaba muerta, se reconecta y se vuelve a enviar.
    func write(_ m: [UInt8]) async throws {
        var last: Error = URLError(.networkConnectionLost)
        for _ in 0..<2 {
            let ch = try await ensure()
            do { try await ch.write(m); return }
            catch { last = error; drop(ch) }
        }
        throw last
    }

    private func drop(_ ch: TLSChannel) {
        if channel === ch { channel = nil; listener?.cancel(); listener = nil; ime.update { $0.ready = false } }
        ch.conn.cancel()
    }

    private func str(_ f: [Int: PB.Field], _ k: Int) -> String {
        f[k]?.b.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    private func listen(_ ch: TLSChannel) async {
        var got = 0
        while !Task.isCancelled {
            guard let m = try? await ch.readMessage() else { break }
            got += 1
            let f = PB.parse(m)

            if let imeData = f[20]?.b {            // la TV informa del campo de texto activo
                let p = PB.parse(imeData)
                let app = p[1]?.b.map { PB.parse($0) } ?? [:]
                let tfs = p[2]?.b.map { PB.parse($0) }
                let wasReady = ime.snapshot.ready
                let val = tfs.map { str($0, 2) } ?? ""
                ime.update { v in
                    if let c = app[1]?.v { v.imeCounter = c }
                    v.ready = (tfs != nil)
                    if let t = tfs { if let fc = t[1]?.v { v.fieldCounter = fc }; v.text = val } else { v.text = nil }
                }
                rlog("ATV", "IME recibido: campo \(tfs.map { "\($0.keys.sorted())" } ?? "ninguno")")
                if tfs != nil {
                    emit(.tvText(val))
                    if !wasReady { emit(.textRequest) }     // se enfocó un campo: abrir teclado
                }
            }
            if let showData = f[22]?.b {           // "Usa tu dispositivo para escribir"
                let t = PB.parse(showData)[2]?.b.map { PB.parse($0) }
                if let t = t {
                    let val = str(t, 2)
                    ime.update { v in v.ready = true; if let fc = t[1]?.v { v.fieldCounter = fc }; v.text = val }
                    emit(.tvText(val))
                }
                rlog("ATV", "la TV pide teclado (ime_show_request, con campo: \(t != nil))")
                emit(.textRequest)
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
        // Solo limpia si ESTA es todavía la conexión activa (un listener viejo ya no borra la nueva)
        let wasCurrent = (channel === ch)
        if wasCurrent { channel = nil; listener = nil; ime.update { $0.ready = false } }
        ch.conn.cancel()
        if wasCurrent && got == 0 && !Task.isCancelled {
            rlog("ATV", "la TV cerro sin responder: el emparejamiento ya no es valido, hay que emparejar de nuevo")
            emit(.unpaired)
        }
    }
}

// MARK: Android TV Remote v2 (Philips Android, Sony/TCL/Hisense/Xiaomi/Google TV...)
final class AndroidTVRemote: TVRemote, Pairable, TextCapable, AppLaunchable, TextRequestSource, TextMirror, Warmable {
    let host: String
    private let ime = IMEState()
    private let pairingBox = Locked<TLSChannel?>(nil)
    private var session: ATVLink!
    var onTextRequest: (() -> Void)?
    var onTVText: ((String) -> Void)?

    init(host: String) {
        self.host = host
        self.session = ATVLink(host: host, ime: ime) { [weak self] ev in self?.handle(ev) }
    }

    private func handle(_ ev: ATVEvent) {
        switch ev {
        case .tvText(let v): DispatchQueue.main.async { self.onTVText?(v) }
        case .textRequest: DispatchQueue.main.async { self.onTextRequest?() }
        case .unpaired: UserDefaults.standard.set(false, forKey: "atv.paired.\(host)")
        }
    }

    var paired: Bool { UserDefaults.standard.bool(forKey: "atv.paired.\(host)") }
    var isLinked: Bool { paired }
    var tvText: String? { ime.snapshot.text }

    func warmUp() async { if paired { _ = try? await session.ensure() } }

    // MARK: Teclas
    private static let codes: [RemoteKey: Int] = [.power: 26, .up: 19, .down: 20, .left: 21, .right: 22, .ok: 23,
                                                  .back: 4, .home: 3, .volUp: 24, .volDown: 25, .mute: 164]
    private func inject(_ code: Int) async throws {
        guard paired else { throw ATVError.notPaired }
        try await session.write(PB.ld(10, PB.vi(1, code) + PB.vi(2, 3)))
    }
    func send(_ k: RemoteKey) async throws {
        guard let code = Self.codes[k] else { return }
        try await inject(code)
    }

    // MARK: Texto
    // La TV INSERTA lo que se le manda en el campo (no lo reemplaza). Por eso aquí solo se envía lo NUEVO
    // (la diferencia) y los borrados se hacen con la tecla Borrar. Antes se mandaba el texto completo
    // en cada letra y la TV lo acumulaba: "h" + "ho" + "hol" + "hola" = "hhoholhola".
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

    private func sendIME(_ s: String) async throws {
        let before = ime.snapshot
        let pos = max(0, s.utf16.count - 1)
        let edit = PB.vi(1, 1) + PB.ld(2, PB.vi(1, pos) + PB.vi(2, pos) + PB.str(3, s))
        let msg = PB.ld(21, PB.vi(1, before.imeCounter) + PB.vi(2, before.fieldCounter) + PB.ld(3, edit))
        rlog("ATV", "IME enviado: \(s.count) caracteres nuevos (contadores \(before.imeCounter)/\(before.fieldCounter))")
        try await session.write(msg)
        // Esperar (máx. ~120 ms) a que la TV confirme, así el siguiente envío lleva el contador al día
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            let now = ime.snapshot
            if now.fieldCounter != before.fieldCounter || now.text != before.text { break }
        }
    }

    func typeText(_ s: String) async throws {
        guard paired else { throw ATVError.notPaired }
        guard !s.isEmpty else { return }
        _ = try await session.ensure()
        if ime.snapshot.ready { try await sendIME(s); return }
        rlog("ATV", "sin campo IME activo: se inyectan teclas")
        for ch in s.lowercased() {
            if let c = keyCode(ch) { try await inject(c) } else { rlog("ATV", "caracter no soportado: \(ch)") }
        }
    }
    func backspace(_ n: Int) async throws { for _ in 0..<n { try await inject(67) } }
    func enter() async throws { try await inject(66) }

    // MARK: Apps (deep link / paquete). La lista de apps instaladas no está disponible en este protocolo.
    let presets: [AppItem] = [AppItem(id: "https://www.netflix.com/title", name: "Netflix"), AppItem(id: "https://www.youtube.com", name: "YouTube"),
        AppItem(id: "https://app.primevideo.com", name: "Prime Video"), AppItem(id: "https://www.disneyplus.com", name: "Disney+"),
        AppItem(id: "https://open.spotify.com", name: "Spotify")]
    func installedApps() async throws -> [AppItem] { [] }
    func launch(_ app: AppItem) async throws {
        guard paired else { throw ATVError.notPaired }
        let link = app.id.contains(":") ? app.id : "market://launch?id=\(app.id)"
        rlog("ATV", "abrir app: \(link)")
        try await session.write(PB.ld(90, PB.str(1, link)))
    }

    // MARK: Emparejamiento (puerto 6467)
    private func outer(_ extra: [UInt8]) -> [UInt8] { PB.vi(1, 2) + PB.vi(2, 200) + extra }
    private func expectOK(_ m: [UInt8]) throws {
        guard PB.parse(m)[2]?.v == 200 else { throw ATVError.protocolError("la TV rechazó el emparejamiento") }
    }

    /// Cancela el emparejamiento en curso: avisa a la TV (status 400) y cierra el canal para que quite el aviso.
    func cancelPairing() {
        guard let c = pairingBox.swap(nil) else { return }
        rlog("ATV", "emparejamiento cancelado por el usuario")
        Task { try? await c.write(PB.vi(1, 2) + PB.vi(2, 400)); c.conn.cancel() }
    }

    func beginPairing() async throws {
        cancelPairing()
        let ch = try TLSChannel(host: host, port: 6467)
        try await ch.open(); pairingBox.set(ch)
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
        let pch = pairingBox.get()
        guard let ch = pch, c.count == 6, cb.count == 3,
              let mine = ATVIdentity.publicKeyDER(), let (cn, ce) = DER.rsaNE(mine), let (sn, se) = DER.rsaNE(ch.box.key)
        else { rlog("ATV", "finishPairing: datos invalidos (canal \(pch != nil), largo \(c.count))"); throw ATVError.badCode }
        var h = SHA256()
        h.update(data: cn + ce + sn + se + Array(cb.dropFirst()))
        let digest = Array(h.finalize())
        guard digest[0] == cb[0] else { rlog("ATV", "el codigo no coincide con el hash (tipeo o calculo)"); throw ATVError.badCode }
        try await ch.write(outer(PB.ld(40, PB.ld(1, digest))))
        try expectOK(try await ch.readMessage())
        UserDefaults.standard.set(true, forKey: "atv.paired.\(host)")
        ch.conn.cancel(); pairingBox.set(nil)
    }
}
