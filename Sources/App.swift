import SwiftUI

@main
struct RemoteHubApp: App {
    @StateObject var store = Store()
    @StateObject var disc = Discovery()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store).environmentObject(disc) }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var disc: Discovery
    @State private var adding = false
    @State private var online: [UUID: Bool] = [:]
    @State private var renamingID: UUID?
    @State private var newName = ""

    private var nearby: [TV] { disc.found.filter { f in !store.tvs.contains { $0.host == f.host } } }

    func startRename(_ tv: TV) { newName = tv.name; renamingID = tv.id }

    func refreshOnline() async {
        for tv in store.tvs { online[tv.id] = await quickOnline(tv) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Mis dispositivos") {
                    if store.tvs.isEmpty { Text("Aún no agregas ninguna TV").foregroundStyle(.secondary) }
                    ForEach(store.tvs) { tv in
                        NavigationLink(value: tv) {
                            HStack(spacing: 12) {
                                Circle().fill(online[tv.id] == true ? Color.green : Color.gray.opacity(0.45)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tv.name)
                                    Text("\(tv.brand.rawValue) · \(tv.host) · \(online[tv.id] == true ? "En línea" : "Sin conexión")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) { Button { startRename(tv) } label: { Label("Renombrar", systemImage: "pencil") }.tint(.blue) }
                        .contextMenu { Button { startRename(tv) } label: { Label("Renombrar", systemImage: "pencil") } }
                    }.onDelete { store.tvs.remove(atOffsets: $0) }
                }
                Section("Cerca de ti") {
                    ForEach(nearby) { tv in
                        Button { store.tvs.append(tv) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tv.name).foregroundStyle(.primary)
                                    Text("\(tv.brand.rawValue) · \(tv.host)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if disc.scanning { HStack { ProgressView(); Text("Buscando en tu red…").foregroundStyle(.secondary) } }
                    else if nearby.isEmpty { Text("No hay dispositivos nuevos").foregroundStyle(.secondary) }
                    Button("Buscar de nuevo") { disc.start() }
                }
                Section {
                    Button("Agregar por IP") { adding = true }
                    NavigationLink("Diagnóstico y log") { DiagnosticsView() }
                }
            }
            .navigationTitle("RemoteHub")
            .navigationDestination(for: TV.self) { RemoteView(tv: $0) }
            .sheet(isPresented: $adding) { AddView() }
            .alert("Renombrar", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
                TextField("Nombre", text: $newName)
                Button("Guardar") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    if let id = renamingID, !n.isEmpty, let i = store.tvs.firstIndex(where: { $0.id == id }) { store.tvs[i].name = n }
                    renamingID = nil
                }
                Button("Cancelar", role: .cancel) { renamingID = nil }
            }
            .onAppear { Log.shared.logHeader(); disc.start() }
            .task { while !Task.isCancelled { await refreshOnline(); try? await Task.sleep(nanoseconds: 6_000_000_000) } }
        }
    }
}

struct AddView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var host = ""; @State private var brand = Brand.androidTV
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $name)
                TextField("IP (ej. 192.168.1.50)", text: $host).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                Picker("Marca", selection: $brand) { ForEach(Brand.allCases) { Text($0.rawValue).tag($0) } }
            }
            .navigationTitle("Agregar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { store.tvs.append(TV(name: name.isEmpty ? brand.rawValue : name, host: host, brand: brand)); dismiss() }.disabled(host.isEmpty)
                }
            }
        }
    }
}
