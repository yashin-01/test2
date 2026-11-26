import Foundation

enum RemoteKey: String, CaseIterable { case power, up, down, left, right, ok, back, home, volUp, volDown, mute }

enum Brand: String, CaseIterable, Identifiable, Codable {
    case roku = "Roku", samsung = "Samsung", lg = "LG", sony = "Sony", philips = "Philips", androidTV = "Android TV / Google TV", ir = "Blaster IR (Tasmota)"
    var id: String { rawValue }
}

struct TV: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var brand: Brand
}

protocol TVRemote { func send(_ key: RemoteKey) async throws }

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: t)) }
        else { completionHandler(.performDefaultHandling, nil) }
    }
}
let lanSession = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)

@discardableResult
func httpFull(_ method: String, _ url: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, String) {
    guard let u = URL(string: url) else { throw URLError(.badURL) }
    var r = URLRequest(url: u, timeoutInterval: 4)
    r.httpMethod = method; r.httpBody = body
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    let t0 = Date()
    do {
        let (d, resp) = try await lanSession.data(for: r)
        let sc = (resp as? HTTPURLResponse)?.statusCode ?? 0
        rlog("HTTP", "\(method) \(url) -> \(sc) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        return (sc, String(data: d, encoding: .utf8) ?? "")
    } catch {
        let e = error as NSError
        rlog("HTTP", "\(method) \(url) FALLO \(e.domain) \(e.code) \(e.localizedDescription)")
        throw error
    }
}

@discardableResult
func http(_ method: String, _ url: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> Int {
    try await httpFull(method, url, body: body, headers: headers).0
}

final class Store: ObservableObject {
    @Published var tvs: [TV] = [] { didSet { save() } }
    private var cache: [String: TVRemote] = [:]
    init() {
        if let d = UserDefaults.standard.data(forKey: "tvs"), let v = try? JSONDecoder().decode([TV].self, from: d) { tvs = v }
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(tvs), forKey: "tvs") }
    func remote(for tv: TV) -> TVRemote {
        let k = "\(tv.id)\(tv.brand.rawValue)\(tv.host)"
        if let r = cache[k] { return r }
        let r: TVRemote
        switch tv.brand {
        case .roku: r = RokuRemote(host: tv.host)
        case .samsung: r = SamsungRemote(host: tv.host)
        case .lg: r = LGRemote(host: tv.host)
        case .sony: r = SonyRemote(host: tv.host)
        case .philips: r = PhilipsRemote(host: tv.host)
        case .androidTV: r = AndroidTVRemote(host: tv.host)
        case .ir: r = TasmotaIRRemote(host: tv.host)
        }
        cache[k] = r; return r
    }
}
