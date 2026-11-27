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

    var body: some View {
        NavigationStack {
            List {
                Section("Mis dispositivos") {
                    ForEach(store.tvs) { tv in
                        NavigationLink(value: tv) { VStack(alignment: .leading) { Text(tv.name); Text("\(tv.brand.rawValue) · \(tv.host)").font(.caption).foregroundStyle(.secondary) } }
                    }.onDelete { store.tvs.remove(atOffsets: $0) }
                }
                Section("Encontrados en la red (Bonjour)") {
                    ForEach(disc.found) { tv in
                        Button { store.tvs.append(tv) } label: { Label("\(tv.name) · \(tv.host)", systemImage: "plus.circle") }
                    }
                    Button("Buscar de nuevo") { disc.found = []; disc.start() }
                }
                Section { Button("Agregar por IP") { adding = true }; NavigationLink("Diagnóstico y log") { DiagnosticsView() } }
            }
            .navigationTitle("RemoteHub")
            .navigationDestination(for: TV.self) { RemoteView(tv: $0) }
            .sheet(isPresented: $adding) { AddView() }
            .onAppear { Log.shared.logHeader(); disc.start() }
        }
    }
}

struct AddView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var host = ""; @State private var brand = Brand.roku
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

