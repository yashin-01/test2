import Foundation

/// Valor protegido con candado: acceso seguro desde varios hilos.
final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    /// Pone un valor nuevo y devuelve el anterior.
    @discardableResult
    func swap(_ v: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
    @discardableResult
    func modify<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// Una sola conexión compartida. Si varias pulsaciones piden conectar a la vez, todas esperan
/// la misma conexión (antes cada una abría la suya y se pisaban, causando el crash).
/// Nunca devuelve nil: o hay conexión viva o lanza error (adiós a los `x!`).
actor ConnectionGate<C: AnyObject> {
    private var conn: C?
    private var pending: Task<C, Error>?
    private var gen = 0

    var current: C? { conn }

    func get(_ make: @escaping () async throws -> C) async throws -> C {
        if let c = conn { return c }
        if let p = pending { return try await p.value }
        let myGen = gen
        let p = Task { try await make() }
        pending = p
        do {
            let c = try await p.value
            guard gen == myGen else { throw URLError(.cancelled) }
            conn = c; pending = nil
            return c
        } catch {
            if gen == myGen { pending = nil }
            throw error
        }
    }

    /// Marca la conexión como caída (solo si sigue siendo la actual).
    func drop(_ c: C) { if conn === c { conn = nil } }

    /// Olvida la conexión actual y la devuelve para que el llamador la cierre.
    func reset() -> C? { gen += 1; let c = conn; conn = nil; pending = nil; return c }
}
