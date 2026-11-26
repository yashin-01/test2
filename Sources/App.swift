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

struct RemoteView: View {
    @EnvironmentObject var store: Store
    @State var tv: TV
    @State private var error = ""
    @State private var askCode = false
    @State private var code = ""

    func press(_ k: RemoteKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do { try await store.remote(for: tv).send(k); error = ""; rlog("UI", "\(tv.brand.rawValue) \(tv.host) \(k.rawValue) OK") }
            catch ATVError.notPaired { await pair() }
            catch { rlog("UI", "\(tv.brand.rawValue) \(tv.host) \(k.rawValue) FALLO: \(error)"); self.error = "Error: \(error.localizedDescription)" }
        }
    }
    func pair() async {
        do { try await (store.remote(for: tv) as? Pairable)?.beginPairing(); code = ""; askCode = true; error = "" }
        catch { self.error = "Emparejado: \(error.localizedDescription)" }
    }
    func finish() {
        Task {
            do { try await (store.remote(for: tv) as? Pairable)?.finishPairing(code: code); error = "Emparejado ✓"; rlog("UI", "emparejado OK \(tv.host)") }
            catch { self.error = "Error: \(error.localizedDescription)" }
        }
    }
    func btn(_ icon: String, _ k: RemoteKey) -> some View {
        Button { press(k) } label: { Image(systemName: icon).font(.title2).frame(width: 70, height: 70).background(.thinMaterial, in: Circle()) }
    }
    var body: some View {
        VStack(spacing: 18) {
            Picker("Marca", selection: $tv.brand) { ForEach(Brand.allCases) { Text($0.rawValue).tag($0) } }
                .onChange(of: tv.brand) { _ in if let i = store.tvs.firstIndex(where: { $0.id == tv.id }) { store.tvs[i] = tv } }
            if tv.brand == .androidTV || tv.brand == .philips {
                Button("Emparejar con la TV") { Task { await pair() } }.buttonStyle(.bordered)
            }
            HStack { btn("power", .power); Spacer(); btn("house", .home); Spacer(); btn("speaker.slash", .mute) }
            btn("chevron.up", .up)
            HStack(spacing: 14) { btn("chevron.left", .left); Button("OK") { press(.ok) }.frame(width: 70, height: 70).background(.tint.opacity(0.25), in: Circle()); btn("chevron.right", .right) }
            btn("chevron.down", .down)
            HStack { btn("arrow.uturn.backward", .back); Spacer(); btn("speaker.minus", .volDown); btn("speaker.plus", .volUp) }
            Text(error).font(.caption).foregroundStyle(.red)
            Spacer()
        }
        .padding().navigationTitle(tv.name)
        .alert("Código de la TV", isPresented: $askCode) {
            TextField("6 caracteres", text: $code).textInputAutocapitalization(.never)
            Button("Emparejar") { finish() }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Escribe el código que aparece en la pantalla de la TV.") }
    }
}
