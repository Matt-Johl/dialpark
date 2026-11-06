import Foundation

/// How a name spoken to Siri is matched against the directory (SPEC §6
/// item 17). The Intents extension asks this when Siri hands it a party
/// with a name but no handle ("Call Amara with Dialler"); a party that
/// already has a handle — a Recents row, spoken digits Siri recognised as
/// a number — never gets here.
public enum SiriContactMatch: Equatable, Sendable {
    /// Nothing in the directory answers to the name.
    case none
    /// Spoken digits: not a directory lookup, a number to dial as said.
    case number(String)
    /// Exactly one contact.
    case one(DirectoryContact)
    /// Several could be meant; Siri asks the user which, favourites first.
    case several([DirectoryContact])
}

public enum SiriContactMatcher {
    /// The rules, in order:
    /// 1. digits (with `+`, `*`, `#`), however paused, are a number;
    /// 2. a whole-name match, case and accent insensitive, wins outright —
    ///    "it helpdesk" is IT Helpdesk even though "it" also starts nothing
    ///    else;
    /// 3. otherwise every spoken word must begin a word of the contact's
    ///    name, in any order — "amara" is Amara Nwosu, "okafor" is Daniel
    ///    Okafor, "sales" is Sales Line;
    /// 4. one hit is the party; several are offered favourites first then
    ///    alphabetically; none is none. Deleted contacts are never offered.
    public static func match(_ spoken: String, in contacts: [DirectoryContact]) -> SiriContactMatch {
        let words = Self.words(spoken)
        guard !words.isEmpty else { return .none }
        let run = words.joined()
        if run.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789+*#").contains($0) }) {
            return .number(run)
        }
        let live = contacts.filter { $0.deleted != true }
        let exact = live.filter { Self.words($0.displayName) == words }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .several(Self.ordered(exact)) }
        let partial = live.filter { contact in
            let nameWords = Self.words(contact.displayName)
            return words.allSatisfy { spokenWord in nameWords.contains { $0.hasPrefix(spokenWord) } }
        }
        switch partial.count {
        case 0: return .none
        case 1: return .one(partial[0])
        default: return .several(Self.ordered(partial))
        }
    }

    /// Lowercased, accents folded, split on anything that is not a letter,
    /// digit or one of the dialable signs.
    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+*#"))
        return folded.unicodeScalars
            .map { keep.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    static func ordered(_ contacts: [DirectoryContact]) -> [DirectoryContact] {
        contacts.sorted {
            if $0.isFavourite != $1.isFavourite { return $0.isFavourite }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
