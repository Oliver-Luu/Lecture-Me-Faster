import Foundation
import Observation
import Security

@Observable final class AppSettings {
    struct Stored: Codable {
        var provider = AIProvider.ollama
        var claudeModel = FileToAI.claudeModels[0]
        var ollamaURL = "http://localhost:11434"
        var ollamaModel = ""
        var openAIURL = "http://localhost:1234/v1"
        var openAIModel = ""
        var includeFrames = true
        var maxFrames = 30
    }

    enum Problem: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let what): "Open Settings and \(what)."
            }
        }
    }

    var stored: Stored {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: "settings") }
    }
    var claudeKey: String {
        didSet { Keychain.set(claudeKey, for: "claude") }
    }
    var openAIKey: String {
        didSet { Keychain.set(openAIKey, for: "openai-compatible") }
    }

    init() {
        let saved = UserDefaults.standard.data(forKey: "settings")
        stored = saved.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        claudeKey = Keychain.get("claude")
        openAIKey = Keychain.get("openai-compatible")
    }

    func configuration() throws -> AIConfiguration {
        switch stored.provider {
        case .claude:
            let key = claudeKey.isEmpty ? DevKeys.anthropic : claudeKey
            guard !key.isEmpty else { throw Problem.missing("add your Anthropic API key") }
            return AIConfiguration(
                provider: .claude, baseURL: URL(string: "https://api.anthropic.com")!,
                model: stored.claudeModel, apiKey: key
            )
        case .ollama:
            guard let url = URL(string: stored.ollamaURL), url.host() != nil else {
                throw Problem.missing("enter a valid Ollama server address")
            }
            guard !stored.ollamaModel.isEmpty else { throw Problem.missing("choose an Ollama model") }
            return AIConfiguration(provider: .ollama, baseURL: url, model: stored.ollamaModel, apiKey: "")
        case .openAICompatible:
            guard let url = URL(string: stored.openAIURL), url.host() != nil else {
                throw Problem.missing("enter a valid server address")
            }
            guard !stored.openAIModel.isEmpty else { throw Problem.missing("enter a model name") }
            let key = openAIKey.isEmpty ? DevKeys.openAICompatible : openAIKey
            return AIConfiguration(provider: .openAICompatible, baseURL: url, model: stored.openAIModel, apiKey: key)
        }
    }
}

/// Developer keys from the git-ignored Secrets.env, which is bundled into Debug builds only.
nonisolated enum DevKeys {
    static var anthropic: String { values["ANTHROPIC_API_KEY"] ?? "" }
    static var openAICompatible: String { values["OPENAI_COMPATIBLE_API_KEY"] ?? "" }

    private static let values: [String: String] = {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "env"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
        #else
        return [:]
        #endif
    }()

    /// Parses `KEY=value` lines, skipping blanks, `#` comments, and keys with no value.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, !value.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

nonisolated enum Keychain {
    private static func query(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "LectureMeFaster",
            kSecAttrAccount: account,
        ]
    }

    static func get(_ account: String) -> String {
        var item: CFTypeRef?
        let lookup = query(account).merging([kSecReturnData: true]) { $1 }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        SecItemAdd(query(account).merging([kSecValueData: Data(value.utf8)]) { $1 } as CFDictionary, nil)
    }
}
