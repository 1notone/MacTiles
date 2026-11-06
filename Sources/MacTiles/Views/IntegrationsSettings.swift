import AppKit
import SwiftUI

/// Settings → Integrations: the homelab services MacTiles can show as tiles.
@MainActor
struct IntegrationsSection: View {
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var services: ServiceHub

    /// Owned by SettingsView, so requests from Start work even while this section is scrolled away.
    @Binding var editing: EditorTarget?
    @State private var removing: Integration?

    struct EditorTarget: Identifiable {
        let id = UUID()
        let integration: Integration?
    }

    var body: some View {
        Section {
            if store.settings.integrations.isEmpty {
                Text("Connect Plex, Jellyfin, Sonarr, Pi-hole, Home Assistant, Proxmox, Docker and more. MacTiles talks to each one directly — no Homarr needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.settings.integrations) { integration in
                HStack(spacing: 10) {
                    Image(systemName: integration.kind.symbol)
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color(hex: integration.kind.defaultColor))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(integration.displayName)
                        Text(subtitle(integration)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit…") { editing = EditorTarget(integration: integration) }
                    Button {
                        removing = integration
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            HStack {
                Button("Add Service…") { editing = EditorTarget(integration: nil) }
                if !store.settings.integrations.isEmpty {
                    Button("Add a Tile to Start…") { launcher.addServiceTile() }
                }
            }
        } header: {
            Text("Integrations")
        } footer: {
            Text("Passwords, tokens and API keys are kept in your Keychain. Service tiles only update while Start is on screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing {
                    store.removeIntegration(removing.id)
                    services.integrationChanged(removing.id)
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removeMessage)
        }
    }

    private func subtitle(_ i: Integration) -> String {
        let address = i.url.trimmingCharacters(in: .whitespaces)
        let place = address.isEmpty ? (i.kind == .docker ? "This Mac" : "No address") : address
        return i.kind.title + " · " + place
    }

    private var removeTitle: String { "Remove \(removing?.displayName ?? "service")?" }

    private var removeMessage: String {
        guard let removing else { return "" }
        let count = store.serviceTiles(of: removing.id).count
        let tiles = count == 0 ? "" : count == 1 ? " Its tile will be unpinned from Start." : " Its \(count) tiles will be unpinned from Start."
        return "Its saved key or password will be deleted from your Keychain." + tiles
    }

}

/// Add or edit one service connection.
@MainActor
struct IntegrationEditor: View {
    let original: Integration?
    let done: () -> Void

    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var services: ServiceHub

    @State private var kind: ServiceKind = .plex
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var allowSelfSigned = false
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)?
    @State private var error = ""
    @State private var loaded = false
    @State private var newID = UUID()

    private var isNew: Bool { original == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Connect a Service" : "Edit \(original?.displayName ?? "Service")")
                .font(.title2)
                .padding([.top, .horizontal], 20)
            Form {
                if isNew {
                    Picker("Service", selection: $kind) {
                        ForEach(ServiceKind.Category.allCases) { category in
                            Section(category.rawValue) {
                                ForEach(ServiceKind.inCategory(category)) { k in
                                    Label(k.title, systemImage: k.symbol).tag(k)
                                }
                            }
                        }
                    }
                } else {
                    LabeledContent("Service", value: kind.title)
                }
                TextField("Name", text: $name, prompt: Text(kind.title))
                TextField(kind.addressOptional ? "Address (optional)" : "Address", text: $url, prompt: Text(kind.placeholder))
                if let label = kind.usernameLabel {
                    TextField(label, text: $username, prompt: Text(kind.usernamePrompt))
                }
                if let label = kind.secretLabel {
                    SecureField(kind.secretRequired ? label : "\(label) (optional)", text: $secret)
                }
                if showsCertificateToggle {
                    Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                }
                if kind.secretLabel != nil, draft.sendsSecretInsecurely {
                    Label("This address uses plain HTTP and isn't on your local network, so the \((kind.secretLabel ?? "key").lowercased()) would be sent unencrypted. Use https:// if the service supports it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(kind.help).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Test Connection", action: test)
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? Color.green : Color.red)
                            .font(.caption)
                            .lineLimit(3)
                    }
                }
            }
            .formStyle(.grouped)
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: kind) { _, newKind in
            guard loaded, isNew else { return }
            allowSelfSigned = newKind.usuallySelfSigned
            result = nil
            error = ""
        }
    }

    private var showsCertificateToggle: Bool {
        if kind == .docker { return !url.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    private var draft: Integration {
        var i = original ?? Integration(kind: kind)
        if original == nil { i.id = newID }
        i.kind = kind
        i.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        i.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        i.username = kind.usernameLabel == nil ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines)
        i.allowSelfSigned = allowSelfSigned
        return i
    }

    private func load() {
        if let original {
            kind = original.kind
            name = original.name
            url = original.url
            username = original.username
            allowSelfSigned = original.allowSelfSigned
            secret = IntegrationSecrets.get(original.id)
        } else {
            allowSelfSigned = kind.usuallySelfSigned
        }
        loaded = true
    }

    private func validate() -> String? {
        let address = url.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            if !kind.addressOptional { return "Enter the service's address, like \(kind.placeholder)." }
        } else if Integration.normalize(address) == nil {
            return "That doesn't look like an address. Try something like \(kind.placeholder)."
        }
        if kind.usernameRequired, username.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the \(kind.usernameLabel?.lowercased() ?? "username")."
        }
        if kind.secretRequired, secret.isEmpty { return "Enter the \(kind.secretLabel ?? "key")." }
        return nil
    }

    private func test() {
        if let problem = validate() {
            result = (false, problem)
            return
        }
        testing = true
        result = nil
        let integration = draft
        let secret = self.secret
        Task {
            result = await services.test(integration, secret: secret)
            testing = false
        }
    }

    private func save() {
        if let problem = validate() {
            error = problem
            return
        }
        let integration = draft
        guard IntegrationSecrets.set(kind.secretLabel == nil ? "" : secret, for: integration.id, name: integration.displayName) else {
            error = "Your Keychain didn't accept the \((kind.secretLabel ?? "key").lowercased()). Unlock it in Keychain Access and try again."
            return
        }
        if let index = store.settings.integrations.firstIndex(where: { $0.id == integration.id }) {
            store.settings.integrations[index] = integration
        } else {
            store.settings.integrations.append(integration)
        }
        services.integrationChanged(integration.id)
        done()
    }
}
