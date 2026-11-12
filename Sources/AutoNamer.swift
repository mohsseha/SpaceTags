import Cocoa
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests a short name for a space from what is open on it. Uses Apple's
/// on-device model where there is one (macOS 26 with Apple Intelligence on).
enum AutoNamer {
    static func suggest(apps: [String], titles: [String]) async -> String? {
        guard !apps.isEmpty else { return nil }
        // Finder has windows everywhere and says little; a lone app is its own best name.
        let relevant = apps.filter { $0 != "Finder" }
        guard let first = relevant.first else { return "Files" }
        if relevant.count == 1 { return first }
        if let name = await askModel(apps: relevant, titles: titles) { return name }
        return relevant.prefix(2).joined(separator: " + ")
    }

    private static func askModel(apps: [String], titles: [String]) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You name macOS desktop workspaces. Given the apps open on one workspace, reply with a \
                one or two word name for what the person is doing there, such as Coding, Chat, Browsing, \
                Email, Music, Writing or Design. Do not just repeat an app name. Reply with the name only.
                """)
            var prompt = "Apps: " + apps.joined(separator: ", ")
            if !titles.isEmpty { prompt += "\nWindow titles: " + titles.joined(separator: "; ") }
            guard let reply = try? await session.respond(to: prompt).content else { return nil }
            return clean(reply)
        }
        #endif
        return nil
    }

    /// The model sometimes adds quotes, punctuation or a sentence; keep the first two words.
    private static func clean(_ reply: String) -> String? {
        let line = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        let name = String(words.prefix(2).joined(separator: " ").prefix(24))
        return name.isEmpty ? nil : name
    }
}
