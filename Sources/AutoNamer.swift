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
        var emoji: String?    // one of Palette.emoji[color]; nil leaves the choice to the store
    }

    /// `taken` are the palette colours other spaces already use; the model chooses among the rest.
    static func suggest(apps: [String], titles: [String], taken: Set<Int> = []) async -> Suggestion? {
        guard !apps.isEmpty else { return nil }
        // Finder has windows everywhere and says little; a lone app is its own best name.
        // The model still picks the colour and emoji for those.
        let relevant = apps.filter { $0 != "Finder" }
        let fixed = relevant.isEmpty ? "Files" : relevant.count == 1 ? relevant[0] : nil
        let reply = await askModel(apps: relevant.isEmpty ? apps : relevant, titles: titles, taken: taken)
        return Suggestion(name: fixed ?? reply?.name ?? relevant.prefix(2).joined(separator: " + "),
                          color: reply?.color, emoji: reply?.emoji)
    }

    private static func askModel(apps: [String], titles: [String], taken: Set<Int>) async -> Suggestion? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            // Left to itself the model paints everything green, teal or blue. Offering only the
            // colours still free, in no fixed order, keeps the spaces apart.
            let free = Palette.colors.indices.filter { !taken.contains($0) }
            let offered = (free.isEmpty ? Array(Palette.colors.indices) : free).shuffled()
            let colors = offered.map { Palette.colorNames[$0] }.joined(separator: ", ")
            let session = LanguageModelSession(instructions: """
                You name macOS desktop workspaces. Given the apps open on one workspace, reply with a \
                one or two word name for what the person is doing there, such as Coding, Chat, Browsing, \
                Email, Music, Writing or Design. Do not just repeat an app name. Then pick the color \
                that suits it best from: \(colors).
                Reply with one line only, in the form: name, color
                """)
            var prompt = "Apps: " + apps.joined(separator: ", ")
            if !titles.isEmpty { prompt += "\nWindow titles: " + titles.joined(separator: "; ") }
            guard let reply = try? await session.respond(to: prompt).content, let name = name(in: reply) else { return nil }
            let line = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            var color = color(in: line.split(separator: ",", maxSplits: 1).dropFirst().first.map(String.init) ?? "", among: offered)
            if color == nil, let again = try? await session.respond(to: "That color is not on the list. Reply with one of these only: \(colors)").content {
                color = self.color(in: again, among: offered)
            }
            let row = color ?? offered[0]
            // It keeps to the palette far better when the emoji is a question of its own.
            let pick = try? await session.respond(to: """
                Now pick the one emoji from this list that suits it best: \(Palette.emoji[row].shuffled().joined(separator: " "))
                Reply with that emoji only.
                """).content
            return Suggestion(name: name, color: row, emoji: pick.flatMap { emoji(in: $0, row: row) })
        }
        #endif
        return nil
    }

    /// The model sometimes adds quotes, punctuation or a sentence; keep the first two words
    /// of what comes before the comma.
    static func name(in reply: String) -> String? {
        let line = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = (line.split(separator: ",").first ?? "").split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        let name = String(words.prefix(2).joined(separator: " ").prefix(24))
        return name.isEmpty ? nil : name
    }

    /// The first of the offered colours that the reply names.
    static func color(in reply: String, among offered: [Int]) -> Int? {
        reply.lowercased().split { !$0.isLetter }
            .lazy.compactMap { word in offered.first { Palette.colorNames[$0] == word } }.first
    }

    /// The emoji of the colour's row that the reply contains, as the palette spells it.
    static func emoji(in reply: String, row: Int) -> String? {
        // The model may drop the variation selector some palette emoji carry.
        func bare(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F })) }
        let said = bare(reply)
        return Palette.emoji[row].first { said.contains(bare($0)) }
    }
}
