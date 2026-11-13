import Cocoa
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests a short name, a colour and an emoji for a space from what is open on it. Uses
/// Apple's on-device model where there is one (macOS 26 with Apple Intelligence on).
enum AutoNamer {
    struct Suggestion {
        var name: String
        var color: Int?       // index into Palette.colors; nil leaves the choice to the store
        var emoji: String?    // one of Palette.emoji[color]
    }

    static func suggest(apps: [String], titles: [String]) async -> Suggestion? {
        guard !apps.isEmpty else { return nil }
        // Finder has windows everywhere and says little; a lone app is its own best name.
        // The model still picks the colour and emoji for those.
        let relevant = apps.filter { $0 != "Finder" }
        let fixed = relevant.isEmpty ? "Files" : relevant.count == 1 ? relevant[0] : nil
        let reply = await askModel(apps: relevant.isEmpty ? apps : relevant, titles: titles)
        return Suggestion(name: fixed ?? reply?.name ?? relevant.prefix(2).joined(separator: " + "),
                          color: reply?.color, emoji: reply?.emoji)
    }

    private static func askModel(apps: [String], titles: [String]) async -> Suggestion? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let rows = zip(Palette.colorNames, Palette.emoji).map { "\($0): \($1.joined(separator: " "))" }
            let session = LanguageModelSession(instructions: """
                You name macOS desktop workspaces. Given the apps open on one workspace, reply with a \
                one or two word name for what the person is doing there, such as Coding, Chat, Browsing, \
                Email, Music, Writing or Design. Do not just repeat an app name. Then pick the color and \
                the emoji that suit it best from this list; the emoji must be one from the chosen color's row:
                \(rows.joined(separator: "\n"))
                Reply with one line only, in the form: name, color, emoji
                """)
            var prompt = "Apps: " + apps.joined(separator: ", ")
            if !titles.isEmpty { prompt += "\nWindow titles: " + titles.joined(separator: "; ") }
            guard let reply = try? await session.respond(to: prompt).content else { return nil }
            return parse(reply)
        }
        #endif
        return nil
    }

    /// Reads "name, color, emoji". The model sometimes adds quotes, punctuation or a sentence, so
    /// keep the first two words of the name and only a colour and emoji that are in the palette.
    static func parse(_ reply: String) -> Suggestion? {
        let line = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
        let words = (parts.first ?? "").split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        let name = String(words.prefix(2).joined(separator: " ").prefix(24))
        guard !name.isEmpty else { return nil }

        let rest = parts.count > 1 ? parts[1] : ""
        var color = rest.lowercased().split { !$0.isLetter }
            .lazy.compactMap { Palette.colorNames.firstIndex(of: String($0)) }.first
        // The model may drop the variation selector some palette emoji carry.
        func bare(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F })) }
        let said = bare(rest)
        func pick(in row: Int) -> String? { Palette.emoji[row].first { said.contains(bare($0)) } }
        var emoji = color.flatMap(pick)
        // An emoji from another row wins over the colour named: the two must match to be shown.
        if emoji == nil, let row = Palette.emoji.indices.first(where: { pick(in: $0) != nil }) {
            color = row
            emoji = pick(in: row)
        }
        return Suggestion(name: name, color: color, emoji: emoji)
    }
}
