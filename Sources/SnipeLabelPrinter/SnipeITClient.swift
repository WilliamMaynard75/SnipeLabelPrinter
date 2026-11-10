import Foundation
import Security

enum SnipeITError: LocalizedError {
    case noAPIKey
    case badServerURL
    case unauthorized
    case notFound(String)
    case ambiguous(String, Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No Snipe-IT API key yet. Add one in Settings (⌘,)."
        case .badServerURL: "The Snipe-IT address in Settings isn't a valid URL."
        case .unauthorized: "Snipe-IT rejected the API key. Check it in Settings (⌘,)."
        case let .notFound(entry): "\(entry): asset not found in Snipe-IT."
        case let .ambiguous(entry, count): "\(entry): \(count) assets match. Search for it on its own and pick one."
        case let .server(message): "Snipe-IT: \(message)"
        }
    }
}

/// One row from an asset search.
struct AssetSummary: Identifiable, Equatable {
    let id: Int
    let tag: String
    let name: String
    let model: String?
    let assignedTo: String?
}

/// Fetches label PDFs from Snipe-IT's label API, using the label template configured in Snipe-IT.
struct SnipeITClient {
    static let defaultServer = "https://buckeyerec.snipe-it.io"
    static let serverKey = "serverURL"

    let server: URL
    let token: String

    /// Builds a client from the server saved in Settings and the API key in the Keychain.
    static func fromSettings() throws -> SnipeITClient {
        let address = UserDefaults.standard.string(forKey: serverKey) ?? defaultServer
        guard let server = URL(string: address), let host = server.host else { throw SnipeITError.badServerURL }
        guard let token = Keychain.read(account: host), !token.isEmpty else { throw SnipeITError.noAPIKey }
        return SnipeITClient(server: server, token: token)
    }

    /// Returns the asset tag and its label PDF. `entry` is an asset tag, an asset name, or a scanned
    /// Snipe-IT QR link like https://…/hardware/1432. Tags are tried first since that's one request.
    func label(for entry: String) async throws -> (tag: String, pdf: Data) {
        let tag = try await assetTag(for: entry)
        do {
            return (tag, try await labelPDF(tag: tag))
        } catch SnipeITError.notFound where tag == entry {
            let matches = try await search(entry)
            guard let match = Self.pick(entry, from: matches) else {
                throw matches.isEmpty ? SnipeITError.notFound(entry) : SnipeITError.ambiguous(entry, matches.count)
            }
            return (match.tag, try await labelPDF(tag: match.tag))
        }
    }

    /// The search result `text` clearly refers to: an exact tag or name match, or the only result.
    static func pick(_ text: String, from results: [AssetSummary]) -> AssetSummary? {
        results.first { $0.tag.caseInsensitiveCompare(text) == .orderedSame || $0.name.caseInsensitiveCompare(text) == .orderedSame }
            ?? (results.count == 1 ? results[0] : nil)
    }

    private func labelPDF(tag: String) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["asset_tags": [tag]])
        let (data, response) = try await send("api/v1/hardware/labels", method: "POST", body: body)
        if response.statusCode == 404 { throw SnipeITError.notFound(tag) }
        try check(data, response)

        // Some Snipe-IT versions answer with the PDF itself, newer ones wrap it in JSON as base64.
        if data.starts(with: Data("%PDF".utf8)) { return data }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any],
           let base64 = payload["pdf"] as? String,
           let pdf = Data(base64Encoded: base64) {
            return pdf
        }
        throw SnipeITError.server(errorMessage(in: data) ?? "no label PDF in the response")
    }

    /// Asks for one asset to confirm the address and key work. Returns how many assets the key can see.
    func testConnection() async throws -> Int {
        let (data, response) = try await send("api/v1/hardware?limit=1", method: "GET")
        try check(data, response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["total"] as? Int ?? 0
    }

    /// Snipe-IT's asset search: partial, case-insensitive matches on name, tag, serial and more.
    func search(_ text: String, limit: Int = 20) async throws -> [AssetSummary] {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "search", value: text), URLQueryItem(name: "limit", value: "\(limit)")]
        // URLComponents leaves "+" alone, which servers read as a space.
        let encoded = (query.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let (data, response) = try await send("api/v1/hardware?\(encoded)", method: "GET")
        try check(data, response)
        let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let tag = row["asset_tag"] as? String else { return nil }
            return AssetSummary(id: id, tag: tag,
                                name: row["name"] as? String ?? "",
                                model: (row["model"] as? [String: Any])?["name"] as? String,
                                assignedTo: (row["assigned_to"] as? [String: Any])?["name"] as? String)
        }
    }

    private func assetTag(for entry: String) async throws -> String {
        guard let url = URL(string: entry), url.scheme != nil,
              let index = url.pathComponents.firstIndex(of: "hardware"), index + 1 < url.pathComponents.count,
              let id = Int(url.pathComponents[index + 1])
        else { return entry }
        let (data, response) = try await send("api/v1/hardware/\(id)", method: "GET")
        try check(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["asset_tag"] as? String
        else { throw SnipeITError.notFound(entry) }
        return tag
    }

    private func send(_ path: String, method: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: server.appendingPathComponent("/")) else { throw SnipeITError.badServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SnipeITError.server("no HTTP response") }
        return (data, http)
    }

    /// Throws for HTTP errors and for Snipe-IT's `{"status":"error"}` replies, which can come with HTTP 200.
    private func check(_ data: Data, _ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw SnipeITError.unauthorized }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if !(200..<300).contains(response.statusCode) || json?["status"] as? String == "error" {
            throw SnipeITError.server(errorMessage(in: data) ?? "HTTP \(response.statusCode)")
        }
    }

    private func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch json["messages"] ?? json["error"] {
        case let text as String: return text
        case let fields as [String: Any]: return fields.values.map { "\($0)" }.joined(separator: " ")
        default: return nil
        }
    }
}

/// The API key lives in the login Keychain as a generic password: service "SnipeLabelPrinter", account = server host.
enum Keychain {
    private static let service = "SnipeLabelPrinter"

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SnipeITError.server(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }
}
