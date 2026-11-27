import SwiftUI

func rlog(_ tag: String, _ msg: String) { Log.shared.add(tag, msg) }

/// Log persistente (archivo + memoria). No registra tokens, claves LG ni PSK de Sony.
final class Log: ObservableObject {
    static let shared = Log()
    @Published var lines: [String] = []
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("remotehub.log")
    private let q = DispatchQueue(label: "remotehub.log")
    private let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm:ss.SSS"; return d }()

    init() {
        if let t = try? String(contentsOf: url) { lines = Array(t.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(800)) }
    }

    func add(_ tag: String, _ msg: String) {
        let line = "\(df.string(from: Date())) [\(tag)] \(msg)"
        DispatchQueue.main.async { self.lines.append(line); if self.lines.count > 1500 { self.lines.removeFirst(300) } }
        q.async {
            let d = Data((line + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: self.url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: self.url) }
        }
    }

    func deviceLine() -> String {
        var u = utsname(); uname(&u)
        let model = withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "RemoteHub \(v) · iOS \(UIDevice.current.systemVersion) · \(model)"
    }
    func logHeader() { add("APP", deviceLine()) }

    func fullText() -> String { deviceLine() + "\n" + lines.joined(separator: "\n") }

    func exportURL() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("remotehub-log-\(f.string(from: Date())).txt")
        try? fullText().write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func clear() { lines = []; try? FileManager.default.removeItem(at: url) }
}
