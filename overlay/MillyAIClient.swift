import Foundation
import Security

/// AI backends for the Ask Milly assistant. `codex` is the built-in local Codex
/// server (no key); the rest are bring-your-own-key cloud providers reached over
/// plain HTTPS. Mirrors the iOS `AIProvider`, plus the desktop-only `.codex`.
enum AIProvider: String, CaseIterable, Identifiable, Hashable {
    case codex, anthropic, openai, gemini
    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex:     return "Local Codex (built-in)"
        case .anthropic: return "Anthropic (Claude)"
        case .openai:    return "OpenAI (GPT)"
        case .gemini:    return "Google (Gemini)"
        }
    }

    /// Short status-line label shown in the assistant panel header.
    var shortLabel: String {
        switch self {
        case .codex:     return "Local Codex"
        case .anthropic: return "Claude"
        case .openai:    return "GPT"
        case .gemini:    return "Gemini"
        }
    }

    /// Whether this provider needs a user-supplied API key.
    var needsKey: Bool { self != .codex }

    var defaultModel: String {
        switch self {
        case .codex:     return ""
        case .anthropic: return "claude-sonnet-4-6"
        case .openai:    return "gpt-4o"
        case .gemini:    return "gemini-2.5-flash"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .codex:     return ""
        case .anthropic: return "sk-ant-…"
        case .openai:    return "sk-…"
        case .gemini:    return "AIza…"
        }
    }

    var keyAccount: String { "millie.key.\(rawValue)" }
}

/// "Ask Milly" cloud client — calls the user's chosen provider (BYO key,
/// Keychain-stored) with the current page as context. The `.codex` provider is
/// handled separately by `CodexBrowserAssistant` and never reaches this client.
@MainActor
final class MillyAIClient {
    static let shared = MillyAIClient()
    private init() {}

    struct Turn { let role: String; let text: String }   // role: "user" | "assistant"

    enum ClientError: LocalizedError {
        case noKey(AIProvider), http(String)
        var errorDescription: String? {
            switch self {
            case .noKey(let p): return "Add your \(p.label) API key in Settings → AI."
            case .http(let m):  return m
            }
        }
    }

    // MARK: Keys (per provider)

    func key(for p: AIProvider) -> String { Keychain.get(p.keyAccount) ?? "" }
    func setKey(_ value: String, for p: AIProvider) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        v.isEmpty ? Keychain.delete(p.keyAccount) : Keychain.set(v, for: p.keyAccount)
    }
    func hasKey(for p: AIProvider) -> Bool { !key(for: p).isEmpty }

    private let systemPrompt = """
    You are Milly, a warm, concise browsing assistant inside the Milly web browser. \
    Answer the user's questions, using the current web page as context when relevant. \
    Be brief and helpful — short paragraphs or bullet points. If the page content is \
    truncated or missing, answer from general knowledge and say so.
    """

    // MARK: Ask

    func ask(question: String, pageTitle: String, pageText: String, history: [Turn]) async throws -> String {
        let provider = BrowserSettings.shared.assistantProvider
        let apiKey = key(for: provider)
        guard !apiKey.isEmpty else { throw ClientError.noKey(provider) }
        let model = BrowserSettings.shared.model(for: provider)
        let context = "Current page: \(pageTitle)\n\nPage content (may be truncated):\n\(String(pageText.prefix(8000)))"
        let userMessage = "\(question)\n\n———\n\(context)"

        switch provider {
        case .anthropic: return try await callAnthropic(apiKey, model, history, userMessage)
        case .openai:    return try await callOpenAI(apiKey, model, history, userMessage)
        case .gemini:    return try await callGemini(apiKey, model, history, userMessage)
        case .codex:     return "(Local Codex is handled by the built-in assistant.)"
        }
    }

    // MARK: Providers

    private func callAnthropic(_ key: String, _ model: String, _ history: [Turn], _ user: String) async throws -> String {
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
        messages.append(["role": "user", "content": user])
        let body: [String: Any] = ["model": model, "max_tokens": 1024, "system": systemPrompt, "messages": messages]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await sendJSON(req)
        let content = json["content"] as? [[String: Any]]
        return content?.compactMap { $0["text"] as? String }.joined() ?? "(no response)"
    }

    private func callOpenAI(_ key: String, _ model: String, _ history: [Turn], _ user: String) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages += history.map { ["role": $0.role, "content": $0.text] }
        messages.append(["role": "user", "content": user])
        let body: [String: Any] = ["model": model, "messages": messages]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await sendJSON(req)
        let choices = json["choices"] as? [[String: Any]]
        let msg = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        return msg ?? "(no response)"
    }

    private func callGemini(_ key: String, _ model: String, _ history: [Turn], _ user: String) async throws -> String {
        var contents: [[String: Any]] = history.map {
            ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.text]]]
        }
        contents.append(["role": "user", "parts": [["text": user]]])
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
        ]
        // Key goes in a header, not the query string — URLs end up in
        // logs and proxies; headers don't.
        let url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let endpoint = URL(string: url) else { throw ClientError.http("Invalid Gemini model name: \(model)") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await sendJSON(req)
        let candidates = json["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined() ?? "(no response)"
    }

    // MARK: HTTP

    private func sendJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.http("No response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let m = (json?["error"] as? [String: Any])?["message"] as? String
                ?? (json?["error"] as? String)
                ?? "API error \(http.statusCode)"
            throw ClientError.http(m)
        }
        return json ?? [:]
    }
}

/// Minimal Keychain wrapper for API keys (macOS generic password items).
/// New items carry a service attribute so they can't collide with other
/// apps' account names; `get`/`delete` query by account only so keys
/// saved by pre-service builds keep working.
enum Keychain {
    private static let service = "app.millie.byok"

    static func set(_ value: String, for account: String) {
        // Account-only delete also clears any legacy (service-less) item.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecAttrService as String] = service
        add[kSecValueData as String] = Data(value.utf8)
        // ThisDeviceOnly: an API key shouldn't ride along in backups or
        // device transfers — worst case the user re-pastes it.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account] as CFDictionary)
    }
}
