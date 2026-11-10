import SwiftUI

/// Snipe-IT connection settings. The API key is written to the Keychain, never to UserDefaults.
struct SettingsView: View {
    @AppStorage(SnipeITClient.serverKey) private var server = SnipeITClient.defaultServer
    @State private var newKey = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var isTesting = false

    private var host: String? { URL(string: server)?.host }

    var body: some View {
        Form {
            TextField("Snipe-IT address", text: $server)
                .onChange(of: server) { refreshKeyState() }
            LabeledContent("API key") {
                Text(hasKey ? "Saved in Keychain" : "Not set").foregroundStyle(hasKey ? .green : .secondary)
            }
            SecureField(hasKey ? "Paste a new key to replace it" : "Paste API key", text: $newKey)
            HStack {
                Button("Save Key", action: saveKey).disabled(newKey.isEmpty || host == nil)
                Button("Test Connection", action: test).disabled(!hasKey || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Create a key in Snipe-IT under your name (top right) → Manage API Keys. Fetching labels needs permission to view assets.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: refreshKeyState)
    }

    private func refreshKeyState() {
        hasKey = host.flatMap { Keychain.read(account: $0) }?.isEmpty == false
    }

    private func saveKey() {
        guard let host else { return }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.save(key, account: host)
            newKey = ""
            message = "Saved (\(key.count) characters)."
            refreshKeyState()
        } catch {
            message = error.localizedDescription
        }
    }

    private func test() {
        isTesting = true
        message = nil
        Task {
            do {
                let total = try await SnipeITClient.fromSettings().testConnection()
                message = "Connected. This key can see \(total) assets."
            } catch {
                message = error.localizedDescription
            }
            isTesting = false
        }
    }
}
