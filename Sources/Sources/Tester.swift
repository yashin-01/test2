import SwiftUI
import Network

struct TestResult: Identifiable { let id = UUID(); let name: String; let ok: Bool?; let detail: String }
struct ShareItem: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

final class Counter {
    private var counts: [String: Int] = [:]; private var states: [String: String] = [:]; private let lock = NSLock()
    func setCount(_ k: String, _ v: Int) { lock.lock(); counts[k] = v; lock.unlock() }
    func setState(_ k: String, _ v: String) { lock.lock(); states[k] = v; lock.unlock() }
    func snapshot() -> ([String: Int], [String: String]) { lock.lock(); defer { lock.unlock() }; return (counts, states) }
}

func wsPing(_ url: String) async -> (Bool, String) {
    guard let u = URL(string: url) else { return (false, "URL inválida") }
    let t = lanSession.webSocketTask(with: u); t.resume()
    return await withCheckedContinuation { (c: CheckedContinuation<(Bool, String), Never>) in
        let lock = NSLock(); var done = false
        func fin(_ r: (Bool, String)) {
            lock.lock(); defer { lock.unlock() }
            if done { return }; done = true; t.cancel(with: .goingAway, reason: nil); c.resume(returning: r)
        }
        t.sendPing { e in fin(e == nil ? (true, "handshake OK") : (false, e!.localizedDescription)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { fin((false, "timeout 5s")) }
    }
}

@MainActor
final class Tester: ObservableObject {
    @Published var results: [TestResult] = []
    @Published var running = false

    func record(_ name: String, _ ok: Bool?, _ detail: String) {
        results.append(TestResult(name: name, ok: ok, detail: detail))
        rlog("TEST", "\(ok == nil ? "INFO" : (ok! ? "OK  " : "FAIL")) \(name): \(detail)")
    }
    private func snip(_ s: String, _ n: Int = 180) -> String { String(s.replacingOccurrences(of: "\n", with: " ").prefix(n)) }

    // MARK: Red
    func runNetwork(_ disc: Discovery) async {
        running = true; defer { running = false }
        results = []; rlog("TEST", "=== PRUEBAS DE RED ===")
        record("Dispositivo", nil, Log.shared.deviceLine())
        if let ip = disc.localIPv4() { record("WiFi / IPv4 (en0)", true, disc.ipString(ip)) }
        else { record("WiFi / IPv4 (en0)", false, "sin IPv4 en en0: conéctate por WiFi") }

        let cnt = Counter(); var bs: [NWBrowser] = []
        for t in disc.types {
            let b = NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
            b.stateUpdateHandler = { s in cnt.setState(t, "\(s)") }
            b.browseResultsChangedHandler = { r, _ in cnt.setCount(t, r.count) }
            b.start(queue: .global()); bs.append(b)
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        bs.forEach { $0.cancel() }
        let (counts, states) = cnt.snapshot()
        let denied = states.values.contains { $0.contains("65570") || $0.lowercased().contains("noauth") }
        record("Permiso Red local", !denied, denied ? "DENEGADO: Ajustes > RemoteHub > Red local" : "sin bloqueo detectado")
        for t in disc.types { let n = counts[t] ?? 0; record("Bonjour \(t)", n > 0 ? true : nil, "\(n) servicios · estado \(states[t] ?? "?")") }

        let r = await Task.detached { disc.ssdp() }.value
        if r.sent > 0 { record("SSDP multicast", r.replies > 0 ? true : nil, "enviado OK (el entitlement funciona), \(r.replies) respuestas") }
        else { record("SSDP multicast", false, "bloqueado: \(r.err). Sin entitlement; el escaneo de subred lo reemplaza") }

        await disc.scanSubnet()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let f = disc.found
        record("Escaneo de subred /24", f.isEmpty ? nil : true,
               f.isEmpty ? "0 dispositivos con puertos de TV abiertos" : f.map { "\($0.host) (\($0.brand.rawValue))" }.joined(separator: ", "))
        record("Fin de pruebas de red", nil, "Comparte el log desde esta pantalla")
    }

    // MARK: Una TV
    private func probe(_ name: String, _ method: String, _ url: String, body: String? = nil, headers: [String: String] = [:]) async {
        do {
            let (s, b) = try await httpFull(method, url, body: body.map { Data($0.utf8) }, headers: headers)
            record(name, (200..<300).contains(s), "HTTP \(s) · \(snip(b))")
        } catch {
            let e = error as NSError
            record(name, false, "\(e.domain) \(e.code): \(e.localizedDescription)")
        }
    }

    private func atvChecks(_ tv: TV) async {
        do { _ = try ATVIdentity.identity(); record("Identidad cliente (Keychain)", true, "certificado listo") }
        catch { record("Identidad cliente (Keychain)", false, error.localizedDescription); return }
        record("Emparejado guardado", nil, UserDefaults.standard.bool(forKey: "atv.paired.\(tv.host)") ? "sí" : "no")
        for port in [UInt16(6467), UInt16(6466)] {
            do {
                let ch = try TLSChannel(host: tv.host, port: port)
                try await ch.open()
                record("TLS \(port) handshake", true, "OK · clave servidor \(ch.box.key.count)B · RSA legible: \(DER.rsaNE(ch.box.key) != nil)")
                ch.conn.cancel()
            } catch { record("TLS \(port) handshake", false, error.localizedDescription) }
        }
    }

    func runTV(_ tv: TV, _ disc: Discovery) async {
        running = true; defer { running = false }
        results = []; rlog("TEST", "=== TV \(tv.name) \(tv.host) \(tv.brand.rawValue) ===")
        let ports: [(UInt16, String)] = [(80, "HTTP"), (8060, "Roku ECP"), (8001, "Samsung WS"), (8002, "Samsung WSS"), (3000, "LG WS"),
            (3001, "LG WSS"), (1925, "Philips JointSpace"), (1926, "Philips HTTPS"), (6466, "AndroidTV control"), (6467, "AndroidTV pairing")]
        for (p, n) in ports { let ok = await disc.portOpen(tv.host, p); record("Puerto \(p) (\(n))", ok ? true : nil, ok ? "abierto" : "cerrado o sin respuesta") }
        switch tv.brand {
        case .roku: await probe("Roku device-info", "GET", "http://\(tv.host):8060/query/device-info")
        case .samsung:
            await probe("Samsung /api/v2", "GET", "http://\(tv.host):8001/api/v2/")
            let w = await wsPing("wss://\(tv.host):8002/api/v2/channels/samsung.remote.control?name=\(Data("RemoteHub".utf8).base64EncodedString())")
            record("Samsung WSS 8002 handshake", w.0, w.1)
        case .lg:
            let a = await wsPing("wss://\(tv.host):3001"); record("LG WSS 3001 handshake", a.0, a.1)
            let b = await wsPing("ws://\(tv.host):3000"); record("LG WS 3000 handshake", b.0, b.1)
        case .sony:
            let psk = UserDefaults.standard.string(forKey: "sony.psk") ?? "0000"
            await probe("Sony getSystemInformation", "POST", "http://\(tv.host)/sony/system",
                        body: #"{"method":"getSystemInformation","id":1,"params":[],"version":"1.0"}"#,
                        headers: ["X-Auth-PSK": psk, "Content-Type": "application/json"])
        case .philips:
            await probe("Philips JointSpace /6/system", "GET", "http://\(tv.host):1925/6/system")
            await probe("Philips JointSpace /1/system", "GET", "http://\(tv.host):1925/1/system")
            await atvChecks(tv)
        case .androidTV: await atvChecks(tv)
        case .ir: await probe("Tasmota Status", "GET", "http://\(tv.host)/cm?cmnd=Status")
        }
        record("Fin de pruebas de la TV", nil, "Comparte el log desde esta pantalla")
    }

    // MARK: Tecla (Mute dos veces: queda como estaba)
    func runKey(_ tv: TV, _ store: Store) async {
        running = true; defer { running = false }
        rlog("TEST", "=== TECLA Mute x2 \(tv.brand.rawValue) \(tv.host) ===")
        let r = store.remote(for: tv)
        do {
            try await r.send(.mute); record("Tecla Mute (1/2)", true, "enviada")
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try await r.send(.mute); record("Tecla Mute (2/2)", true, "enviada (restaura el estado)")
        } catch ATVError.notPaired {
            record("Enviar tecla", nil, "falta emparejar: abre el control y pulsa Emparejar con la TV")
        } catch { record("Enviar tecla Mute", false, error.localizedDescription) }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var disc: Discovery
    @StateObject private var tester = Tester()
    @ObservedObject private var log = Log.shared
    @State private var selected: UUID?
    @State private var share: ShareItem?

    var tv: TV? { store.tvs.first { $0.id == selected } }

    var body: some View {
        List {
            Section("1. Red del iPhone") {
                Button("Ejecutar pruebas de red (≈30 s)") { Task { await tester.runNetwork(disc) } }.disabled(tester.running)
            }
            Section("2. Una TV") {
                Picker("TV", selection: $selected) {
                    Text("Elegir…").tag(UUID?.none)
                    ForEach(store.tvs) { Text("\($0.name) · \($0.brand.rawValue)").tag(Optional($0.id)) }
                }
                Button("Probar conexión y protocolo") { if let t = tv { Task { await tester.runTV(t, disc) } } }.disabled(tester.running || tv == nil)
                Button("Enviar tecla de prueba (Mute x2)") { if let t = tv { Task { await tester.runKey(t, store) } } }.disabled(tester.running || tv == nil)
                Text("Si la TV muestra un aviso para aceptar la conexión, acéptalo.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Resultados") {
                if tester.running { ProgressView() }
                ForEach(tester.results) { r in
                    HStack(alignment: .top) {
                        Text(r.ok == nil ? "ℹ️" : (r.ok! ? "✅" : "❌"))
                        VStack(alignment: .leading) { Text(r.name).font(.subheadline); Text(r.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Log (\(log.lines.count) líneas)") {
                Button { share = ShareItem(url: log.exportURL()) } label: { Label("Compartir / guardar log", systemImage: "square.and.arrow.up") }
                Button("Copiar log al portapapeles") { UIPasteboard.general.string = log.fullText() }
                Button("Borrar log", role: .destructive) { log.clear() }
                Text(log.lines.suffix(25).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle("Diagnóstico")
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }
}
