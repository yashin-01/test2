import SwiftUI

struct RemoteView: View {
    @EnvironmentObject var store: Store
    @State var tv: TV
    @State private var error = ""
    @State private var askCode = false
    @State private var code = ""
    @State private var connectedOK = false
    @State private var linking = false
    @State private var linkTask: Task<Void, Never>?
    @State private var mode = 0
    @State private var showKeyboard = false
    @State private var showApps = false
    @State private var favorites: [AppItem] = []
    @State private var last = CGSize.zero
    @State private var acc = CGSize.zero
    @State private var moved = false
    @State private var lastSend = Date.distantPast

    private var remote: TVRemote { store.remote(for: tv) }
    private var pairable: Pairable? { remote as? Pairable }
    private var linked: Bool { connectedOK || (pairable?.isLinked ?? false) }
    private var favKey: String { "fav.\(tv.id.uuidString)" }

    // MARK: acciones
    func press(_ k: RemoteKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do { try await remote.send(k); error = ""; connectedOK = true; rlog("UI", "\(tv.brand.rawValue) \(tv.host) \(k.rawValue) OK") }
            catch ATVError.notPaired { startPairing() }
            catch { rlog("UI", "\(tv.brand.rawValue) \(tv.host) \(k.rawValue) FALLO: \(error)"); self.error = "Error: \(error.localizedDescription)" }
        }
    }
    func launch(_ app: AppItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            guard let l = remote as? AppLaunchable else { error = "Esta marca no permite abrir apps"; return }
            do { try await l.launch(app); error = ""; connectedOK = true; rlog("UI", "abrir \(app.name) OK") }
            catch ATVError.notPaired { startPairing() }
            catch { rlog("UI", "abrir \(app.name) FALLO: \(error)"); self.error = "Error: \(error.localizedDescription)" }
        }
    }
    func startPairing() {
        guard let p = pairable, !linking else { return }
        linking = true; error = ""
        linkTask = Task {
            do {
                try await p.beginPairing()
                if p.needsCode { code = ""; askCode = true } else { connectedOK = true; rlog("UI", "vinculado \(tv.host)") }
            } catch { if !Task.isCancelled { self.error = "Emparejado: \(error.localizedDescription)" } }
            linking = false
        }
    }
    func cancelPairing() {
        linkTask?.cancel(); pairable?.cancelPairing()
        linking = false; askCode = false; code = ""; error = ""
    }
    func finish() {
        Task {
            do { try await pairable?.finishPairing(code: code); connectedOK = true; error = ""; rlog("UI", "emparejado OK \(tv.host)") }
            catch { self.error = "Error: \(error.localizedDescription)" }
        }
    }
    func saveFav() { UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: favKey) }

    // MARK: touchpad
    private func padChanged(_ v: DragGesture.Value) {
        let d = CGSize(width: v.translation.width - last.width, height: v.translation.height - last.height)
        last = v.translation
        if hypot(v.translation.width, v.translation.height) > 6 { moved = true }
        acc.width += d.width; acc.height += d.height
        if let p = remote as? PointerCapable {
            if Date().timeIntervalSince(lastSend) > 0.03 {
                let dx = Int(acc.width * 2), dy = Int(acc.height * 2)
                acc = .zero; lastSend = Date()
                if dx != 0 || dy != 0 { Task { try? await p.moveCursor(dx: dx, dy: dy) } }
            }
        } else {
            let step: CGFloat = 38
            if abs(acc.width) >= step, abs(acc.width) >= abs(acc.height) { press(acc.width > 0 ? .right : .left); acc = .zero }
            else if abs(acc.height) >= step, abs(acc.height) > abs(acc.width) { press(acc.height > 0 ? .down : .up); acc = .zero }
        }
    }
    private func padEnded() {
        if !moved {
            if let p = remote as? PointerCapable { Task { try? await p.click() } } else { press(.ok) }
        }
        last = .zero; acc = .zero; moved = false
    }

    // MARK: piezas de UI
    func round(_ icon: String, _ k: RemoteKey, tint: Color? = nil) -> some View {
        Button { press(k) } label: {
            Image(systemName: icon).font(.title3).frame(width: 62, height: 62)
                .background(.thinMaterial, in: Circle()).foregroundStyle(tint ?? .primary)
        }
    }
    func arrow(_ icon: String, _ k: RemoteKey) -> some View {
        Button { press(k) } label: { Image(systemName: icon).font(.title2.bold()).frame(width: 64, height: 64).contentShape(Rectangle()) }
    }
    var dpad: some View {
        ZStack {
            Circle().fill(.thinMaterial).frame(width: 232, height: 232)
            VStack { arrow("chevron.up", .up); Spacer(); arrow("chevron.down", .down) }.frame(height: 224)
            HStack { arrow("chevron.left", .left); Spacer(); arrow("chevron.right", .right) }.frame(width: 224)
            Button { press(.ok) } label: { Text("OK").font(.headline).frame(width: 88, height: 88).background(.tint.opacity(0.25), in: Circle()) }
        }
    }
    var touchpad: some View {
        let real = remote is PointerCapable
        return ZStack {
            RoundedRectangle(cornerRadius: 28).fill(.thinMaterial)
            VStack(spacing: 6) {
                Image(systemName: "hand.point.up.left").font(.largeTitle)
                Text(real ? "Cursor real: desliza para mover, toca para hacer clic" : "Desliza = flechas (sigue deslizando para recorrer listas) · Toca = OK")
                    .font(.caption).multilineTextAlignment(.center).padding(.horizontal)
            }.foregroundStyle(.secondary)
        }
        .frame(height: 280)
        .gesture(DragGesture(minimumDistance: 0).onChanged { padChanged($0) }.onEnded { _ in padEnded() })
    }
    var statusBar: some View {
        HStack {
            if linked {
                Label("Conectado", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline.bold())
            } else if linking {
                ProgressView(); Text("Esperando a la TV…").font(.subheadline)
                Button("Cancelar", role: .cancel) { cancelPairing() }.buttonStyle(.bordered)
            } else if pairable != nil {
                Button("Emparejar con la TV") { startPairing() }.buttonStyle(.borderedProminent)
            }
            Spacer()
            Menu {
                Picker("Marca", selection: $tv.brand) { ForEach(Brand.allCases) { Text($0.rawValue).tag($0) } }
            } label: { Label(tv.brand.rawValue, systemImage: "gearshape") .font(.footnote) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusBar
                HStack { round("power", .power, tint: .red); Spacer(); round("speaker.slash.fill", .mute); Spacer(); round("house.fill", .home) }
                Picker("", selection: $mode) { Text("Botones").tag(0); Text("Touchpad").tag(1) }.pickerStyle(.segmented)
                if mode == 0 { dpad } else { touchpad }
                HStack(spacing: 22) {
                    round("arrow.uturn.backward", .back)
                    VStack(spacing: 10) { round("speaker.plus.fill", .volUp); round("speaker.minus.fill", .volDown) }
                    VStack(spacing: 10) {
                        Button { showKeyboard = true } label: { Label("Teclado", systemImage: "keyboard").frame(maxWidth: .infinity) }
                        Button { showApps = true } label: { Label("Atajos", systemImage: "plus.app").frame(maxWidth: .infinity) }
                    }.buttonStyle(.bordered).frame(maxWidth: 140)
                }
                if !favorites.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(favorites) { app in
                                Button(app.name) { launch(app) }.buttonStyle(.borderedProminent).tint(.indigo)
                                    .contextMenu { Button("Quitar atajo", role: .destructive) { favorites.removeAll { $0 == app }; saveFav() } }
                            }
                        }
                    }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding()
        }
        .navigationTitle(tv.name).navigationBarTitleDisplayMode(.inline)
        .onChange(of: tv.brand) { _ in
            if let i = store.tvs.firstIndex(where: { $0.id == tv.id }) { store.tvs[i] = tv }
            connectedOK = false
        }
        .onAppear {
            if let d = UserDefaults.standard.data(forKey: favKey), let v = try? JSONDecoder().decode([AppItem].self, from: d) { favorites = v }
            if let s = remote as? TextRequestSource { s.onTextRequest = { showKeyboard = true } }
        }
        .task { await (remote as? Warmable)?.warmUp() }
        .sheet(isPresented: $showKeyboard) { KeyboardSheet(tv: tv) }
        .sheet(isPresented: $showApps) {
            AppPicker(tv: tv) { app in if !favorites.contains(app) { favorites.append(app); saveFav() } }
        }
        .alert("Código de la TV", isPresented: $askCode) {
            TextField("6 caracteres", text: $code).textInputAutocapitalization(.never)
            Button("Emparejar") { finish() }
            Button("Cancelar", role: .cancel) { cancelPairing() }
        } message: { Text("Escribe el código que aparece en la pantalla de la TV.") }
    }
}

// MARK: Teclado: lo que escribes se envía en vivo a la TV
struct KeyboardSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let tv: TV
    @State private var text = ""
    @State private var prev = ""
    @State private var status = ""
    @State private var chain: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var cap: TextCapable? { store.remote(for: tv) as? TextCapable }

    func sync(_ new: String) {
        let old = prev; prev = new
        guard let c = cap else { status = "Esta marca no permite escribir desde el iPhone."; return }
        let before = chain
        chain = Task {
            await before?.value
            do {
                if c.replacesText { try await c.typeText(new) }
                else {
                    let common = zip(old, new).prefix(while: { $0.0 == $0.1 }).count
                    let del = old.count - common
                    if del > 0 { try await c.backspace(del) }
                    let add = String(new.dropFirst(common))
                    if !add.isEmpty { try await c.typeText(add) }
                }
                status = ""
            } catch { status = "Error: \(error.localizedDescription)"; rlog("KEYBOARD", "\(error)") }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField("Escribe aquí y se envía a la TV", text: $text)
                    .textFieldStyle(.roundedBorder).focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: text) { sync($0) }
                    .onSubmit { Task { try? await cap?.enter() } }
                HStack {
                    Button("Borrar todo") { text = "" }.buttonStyle(.bordered)
                    Button("Enter / Buscar") { Task { try? await cap?.enter() } }.buttonStyle(.borderedProminent)
                }
                Text("Primero selecciona el campo de texto en la TV. En Android TV solo se envían letras minúsculas, números y algunos signos.")
                    .font(.caption).foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
                Spacer()
            }
            .padding().navigationTitle("Teclado")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Atajos a apps
struct AppPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let tv: TV
    let onAdd: (AppItem) -> Void
    @State private var apps: [AppItem] = []
    @State private var loading = true
    @State private var note = ""
    @State private var cname = ""
    @State private var cid = ""

    private var hint: String {
        switch tv.brand {
        case .androidTV, .philips: return "Paquete (com.xxx.yyy) o enlace https://…"
        case .samsung: return "App ID de Tizen"
        case .lg: return "ID de app (ej. netflix)"
        case .roku: return "ID de canal"
        case .sony: return "URI de la app"
        case .ir: return "No disponible"
        }
    }

    func load() async {
        guard let l = store.remote(for: tv) as? AppLaunchable else { note = "Esta marca no permite abrir apps."; loading = false; return }
        var list = (try? await l.installedApps()) ?? []
        if list.isEmpty { list = l.presets; note = "No pude leer la lista de apps de la TV. Muestro apps comunes; si no está instalada, la TV no la abrirá." }
        apps = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        loading = false
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Apps de la TV") {
                    if loading { ProgressView() }
                    ForEach(apps) { a in Button(a.name) { onAdd(a); dismiss() } }
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Personalizada (ej. MagisTV, TizenTV…)") {
                    TextField("Nombre", text: $cname)
                    TextField(hint, text: $cid).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Agregar atajo") { onAdd(AppItem(id: cid.trimmingCharacters(in: .whitespaces), name: cname.isEmpty ? cid : cname)); dismiss() }
                        .disabled(cid.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Agregar atajo")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .task { await load() }
        }
    }
}
