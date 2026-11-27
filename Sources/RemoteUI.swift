import SwiftUI

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1).scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RemoteView: View {
    @EnvironmentObject var store: Store
    @State var tv: TV
    @AppStorage("autoKeyboard") private var autoKeyboard = true
    @State private var error = ""
    @State private var askCode = false
    @State private var code = ""
    @State private var connectedOK = false
    @State private var online: Bool? = nil
    @State private var linking = false
    @State private var linkTask: Task<Void, Never>?
    @State private var mode = 0
    @State private var showKeyboard = false
    @State private var kbClosedAt = Date.distantPast
    @State private var showApps = false
    @State private var editing: AppItem?
    @State private var editName = ""
    @State private var editID = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var favorites: [AppItem] = []
    @State private var last = CGSize.zero
    @State private var acc = CGSize.zero
    @State private var moved = false
    @State private var lastSend = Date.distantPast
    @State private var lastLaunch = Date.distantPast
    @State private var askMac = false
    @State private var macText = ""

    private var remote: TVRemote { store.remote(for: tv) }
    private var pairable: Pairable? { remote as? Pairable }
    private var linked: Bool { connectedOK || (pairable?.isLinked ?? false) }
    private var favKey: String { "fav.\(tv.id.uuidString)" }
    private var macKey: String { "mac.\(tv.host)" }

    // MARK: acciones
    func press(_ k: RemoteKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Encender: con la TV apagada no existe conexión de control (cierra a los pocos segundos), solo sirve Wake-on-LAN.
        if k == .power, online != true {
            let macs = wolMACs(tv.host)
            if !macs.isEmpty { wake(macs); return }
            error = "La TV no responde y no tengo su MAC. Ponla en ⋯ → Encender (MAC) (la de Ethernet si usa cable)."
        }
        Task {
            do { try await remote.send(k); error = ""; connectedOK = true; rlog("UI", "\(tv.brand.rawValue) \(tv.host) \(k.rawValue) OK") }
            catch ATVError.notPaired { startPairing() }
            catch {
                rlog("UI", "\(tv.brand.rawValue) \(tv.host) \(k.rawValue) FALLO: \(error)")
                let macs = wolMACs(tv.host)
                if k == .power, !macs.isEmpty { wake(macs) }      // la TV acababa de apagarse: el estado "en línea" estaba atrasado
                else { self.error = "Error: \(error.localizedDescription)" }
            }
        }
    }
    func wake(_ macs: [String]) {
        error = "Enviando señal de encendido…"
        Task {
            await sendWoL(macs: macs, ip: tv.host)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if error.hasPrefix("Enviando") { error = "" }
        }
    }
    func launch(_ app: AppItem) {
        guard Date().timeIntervalSince(lastLaunch) > 1.2 else { return }   // evita ráfagas al tocar muchas veces
        lastLaunch = Date()
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
    /// La TV avisa cuando hay un campo de texto enfocado ("usa tu dispositivo para escribir"): se abre el teclado solo.
    /// Se usan Bindings (referencias al estado) en vez de capturar la vista, para que siempre lean el valor actual.
    func bindKeyboardRequest() {
        let show = $showKeyboard, closed = $kbClosedAt
        (remote as? TextRequestSource)?.onTextRequest = {
            let auto = UserDefaults.standard.object(forKey: "autoKeyboard") as? Bool ?? true
            if auto && !show.wrappedValue && Date().timeIntervalSince(closed.wrappedValue) > 2 { show.wrappedValue = true }
        }
    }
    /// La TV solo entra en "Mis dispositivos" cuando ya está vinculada (o respondió a una tecla).
    func saveIfNew() {
        guard !store.tvs.contains(where: { $0.host == tv.host }) else { return }
        store.tvs.append(tv); rlog("UI", "TV guardada tras vincular: \(tv.host)")
    }
    func saveFav() { UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: favKey) }
    func persistTV() { if let i = store.tvs.firstIndex(where: { $0.id == tv.id }) { store.tvs[i] = tv } }

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
        if !moved { if let p = remote as? PointerCapable { Task { try? await p.click() } } else { press(.ok) } }
        last = .zero; acc = .zero; moved = false
    }

    // MARK: piezas de UI
    private let fill = Color(.tertiarySystemFill)

    func circleIcon(_ icon: String, tint: Color = .primary) -> some View {
        Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 60, height: 60).background(Circle().fill(fill))
    }
    func keyButton(_ icon: String, _ k: RemoteKey, tint: Color = .primary) -> some View {
        Button { press(k) } label: { circleIcon(icon, tint: tint) }.buttonStyle(PressStyle())
    }
    func zone(_ icon: String, _ k: RemoteKey) -> some View {
        Button { press(k) } label: {
            Image(systemName: icon).font(.system(size: 24, weight: .bold)).foregroundStyle(.primary)
                .frame(width: 80, height: 60).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).padding(8)
    }
    var dpad: some View {
        ZStack {
            Circle().fill(fill)
            VStack { zone("chevron.up", .up); Spacer(); zone("chevron.down", .down) }
            HStack { zone("chevron.left", .left); Spacer(); zone("chevron.right", .right) }
            Button { press(.ok) } label: {
                Text("OK").font(.headline).foregroundStyle(.white).frame(width: 96, height: 96).background(Circle().fill(Color.accentColor))
            }.buttonStyle(PressStyle())
        }.frame(width: 262, height: 262)
    }
    func touchpad(_ h: CGFloat) -> some View {
        let real = remote is PointerCapable
        return ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous).fill(fill)
            VStack(spacing: 8) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 34))
                Text(real ? "Cursor real: desliza para mover, toca para hacer clic" : "Desliza = flechas (sigue deslizando para recorrer listas)\nToca = OK")
                    .font(.caption).multilineTextAlignment(.center).padding(.horizontal, 24)
            }.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: h)
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .gesture(DragGesture(minimumDistance: 0).onChanged { padChanged($0) }.onEnded { _ in padEnded() })
    }
    var volume: some View {
        VStack(spacing: 0) {
            Button { press(.volUp) } label: { Image(systemName: "plus").font(.title2.bold()).foregroundStyle(.primary).frame(width: 64, height: 62).contentShape(Rectangle()) }
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 30, height: 1.5)
            Button { press(.volDown) } label: { Image(systemName: "minus").font(.title2.bold()).foregroundStyle(.primary).frame(width: 64, height: 62).contentShape(Rectangle()) }
        }
        .buttonStyle(PressStyle()).background(Capsule().fill(fill)).frame(width: 64)
    }
    var statusBar: some View {
        HStack(spacing: 10) {
            if linking {
                ProgressView(); Text("Esperando a la TV…").foregroundStyle(.secondary)
                Button("Cancelar") { cancelPairing() }.buttonStyle(.bordered)
            } else if online == nil {
                ProgressView(); Text("Comprobando…").foregroundStyle(.secondary)
            } else if online == false {
                Label("Sin conexión", systemImage: "wifi.slash").foregroundStyle(.orange)
            } else if linked || pairable == nil {
                Label("Conectado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Emparejar con la TV") { startPairing() }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.font(.subheadline.bold()).frame(minHeight: 34)
    }

    // Atajos: cuadrícula fija de 3 columnas. No se desliza ni se mueve; el "+" queda siempre al final.
    private let maxShortcuts = 9
    private var shortcutSlots: Int { favorites.count + (favorites.count < maxShortcuts ? 1 : 0) }
    private var shortcutRows: Int { max(1, (shortcutSlots + 2) / 3) }
    private var shortcutsHeight: CGFloat { CGFloat(shortcutRows) * 44 + CGFloat(shortcutRows - 1) * 10 }

    var shortcuts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(favorites) { app in
                Button { launch(app) } label: {
                    Text(app.name).font(.subheadline.bold()).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                }.buttonStyle(PressStyle())
                .contextMenu {
                    Button { editing = app; editName = app.name; editID = app.id } label: { Label("Editar", systemImage: "pencil") }
                    Button(role: .destructive) { favorites.removeAll { $0 == app }; saveFav() } label: { Label("Quitar atajo", systemImage: "trash") }
                }
            }
            if favorites.count < maxShortcuts {
                Button { showApps = true } label: {
                    Image(systemName: "plus").font(.headline).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Capsule().fill(fill))
                }.buttonStyle(PressStyle())
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let P = min(262, max(150, geo.size.height - 360 - shortcutsHeight))
            VStack(spacing: 14) {
                statusBar
                    .alert("Editar atajo", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                        TextField("Nombre", text: $editName)
                        TextField("Paquete o enlace", text: $editID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Guardar") {
                            let id = editID.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let e = editing, !id.isEmpty, let i = favorites.firstIndex(of: e) {
                                favorites[i] = AppItem(id: id, name: editName.isEmpty ? id : editName); saveFav()
                            }
                            editing = nil
                        }
                        Button("Cancelar", role: .cancel) { editing = nil }
                    } message: { Text("En Android TV: un paquete (com.xxx.yyy) o un enlace completo.") }
                HStack { keyButton("power", .power, tint: .red); Spacer(); keyButton("speaker.slash.fill", .mute); Spacer(); keyButton("house.fill", .home) }
                Picker("", selection: $mode) { Text("Botones").tag(0); Text("Touchpad").tag(1) }.pickerStyle(.segmented)
                ZStack { if mode == 0 { dpad.scaleEffect(P / 262) } else { touchpad(P) } }.frame(maxWidth: .infinity).frame(height: P)
                HStack(alignment: .center) {
                    keyButton("arrow.uturn.backward", .back)
                    Spacer(); volume; Spacer()
                    Button { showKeyboard = true } label: { circleIcon("keyboard") }.buttonStyle(PressStyle())
                }
                shortcuts
                if favorites.isEmpty { Text("Toca + para crear atajos a tus apps").font(.caption).foregroundStyle(.secondary) }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert("Renombrar", isPresented: $renaming) {
                TextField("Nombre", text: $newName)
                Button("Guardar") { if !newName.isEmpty { tv.name = newName; persistTV() } }
                Button("Cancelar", role: .cancel) {}
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { newName = tv.name; renaming = true } label: {
                    HStack(spacing: 5) { Text(tv.name).font(.headline); Image(systemName: "pencil").font(.caption) }.foregroundStyle(.primary)
                }.buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Teclado automático", isOn: $autoKeyboard)
                    Button { macText = UserDefaults.standard.string(forKey: macKey) ?? ""; askMac = true } label: { Label("Encender (MAC)" + (wolMACs(tv.host).isEmpty ? "" : ": \(wolMACs(tv.host).count) guardada(s)"), systemImage: "power.circle") }
                    Section("Marca (solo si se detectó mal)") {
                        Picker("Marca", selection: $tv.brand) { ForEach(Brand.allCases) { Text($0.rawValue).tag($0) } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onChange(of: tv.brand) { _ in persistTV(); connectedOK = false; bindKeyboardRequest() }
        .onChange(of: connectedOK) { if $0 { saveIfNew() } }
        .onAppear {
            if let d = UserDefaults.standard.data(forKey: favKey), let v = try? JSONDecoder().decode([AppItem].self, from: d) { favorites = v }
            bindKeyboardRequest()
        }
        .onDisappear { (remote as? TextRequestSource)?.onTextRequest = nil }
        .task(id: tv.brand) {
            online = nil
            while !Task.isCancelled {
                let ok = await quickOnline(tv)
                online = ok
                if ok, linked { saveIfNew() }
                if ok { await learnMAC(tv); await (remote as? Warmable)?.warmUp() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(isPresented: $showKeyboard, onDismiss: { kbClosedAt = Date() }) { KeyboardSheet(tv: tv) }
        .sheet(isPresented: $showApps) {
            AppPicker(tv: tv) { app in if !favorites.contains(app) { favorites.append(app); saveFav() } }
        }
        .alert("MAC de la TV (la de Ethernet si usa cable)", isPresented: $askMac) {
            TextField("AA:BB:CC:DD:EE:FF", text: $macText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Guardar") { UserDefaults.standard.set(macText.trimmingCharacters(in: .whitespaces), forKey: macKey) }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Si la TV usa cable, la MAC de Ethernet es distinta a la de Wi-Fi: mírala en la lista de dispositivos de tu router. Puedes poner varias separadas por coma.") }
        .alert("Código de la TV", isPresented: $askCode) {
            TextField("6 caracteres", text: $code).textInputAutocapitalization(.never)
            Button("Emparejar") { finish() }
            Button("Cancelar", role: .cancel) { cancelPairing() }
        } message: { Text("Escribe el código que aparece en la pantalla de la TV.") }
    }
}

// MARK: Teclado: se abre solo con el teclado del iPhone y envía en vivo a la TV
struct KeyboardSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let tv: TV
    @State private var text = ""
    @State private var prev = ""
    @State private var tvText = ""
    @State private var status = ""
    @State private var chain: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var remote: TVRemote { store.remote(for: tv) }
    private var cap: TextCapable? { remote as? TextCapable }

    func sync(_ new: String) {
        let old = prev
        guard new != old else { return }
        prev = new
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

    func submit() {
        Task {
            await chain?.value
            do { try await cap?.enter(); rlog("KEYBOARD", "enter enviado") }
            catch { status = "Error: \(error.localizedDescription)"; rlog("KEYBOARD", "\(error)"); return }
            dismiss()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Escribir en la TV", systemImage: "keyboard").font(.subheadline.bold())
                Spacer()
                Button("Cerrar") { dismiss() }
            }
            HStack {
                TextField("Escribe aquí…", text: $text)
                    .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.search).onSubmit { submit() }
                    .onChange(of: text) { sync($0) }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
            if remote is TextMirror { Text("En la TV: \(tvText.isEmpty ? "(vacío)" : tvText)").font(.caption).foregroundStyle(.secondary) }
            Text("Primero selecciona un campo de texto en la TV. La tecla de buscar del teclado envía Enter.")
                .font(.caption2).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .presentationDetents([.height(230)])
        .onAppear {
            if let m = remote as? TextMirror {
                let initial = m.tvText ?? ""
                prev = initial; text = initial; tvText = initial
                m.onTVText = { v in tvText = v }
            }
        }
        .onDisappear { (remote as? TextMirror)?.onTVText = nil }
        .task { try? await Task.sleep(nanoseconds: 400_000_000); focused = true }
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
                    if tv.brand == .androidTV || tv.brand == .philips {
                        Text("Dónde ver el paquete: en la TV, Ajustes → Apps → Ver todas → elige la app. Suele aparecer bajo la versión. Mantén pulsado un atajo para editarlo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
