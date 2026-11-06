import AppKit

/// Windows 8 search: with Start focused, just type. There's no search box; keystrokes
/// go straight into the query and the results replace the tiles.
enum TypeToSearch {
    enum Action: Equatable {
        case append(String)
        case deleteBackward
        case deleteWord
        case clear
        case submit
        case ignore          // not ours: let the event continue
    }

    static func action(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, query: String) -> Action {
        let mods = flags.intersection([.command, .control, .option, .shift])

        switch keyCode {
        case 51:   // Delete (backspace): ⌘ clears, ⌥ or ⌃ deletes a word
            if query.isEmpty { return .ignore }
            if mods.contains(.command) { return .clear }
            if mods.contains(.option) || mods.contains(.control) { return .deleteWord }
            return .deleteBackward
        case 36, 76:   // Return, keypad Enter
            return query.isEmpty || !mods.subtracting(.shift).isEmpty ? .ignore : .submit
        case 48, 53:   // Tab, Escape (Escape is handled by the launcher)
            return .ignore
        default:
            break
        }

        // Shortcuts (⌘, ⌃) are never typing. ⌥ is allowed: it types accented letters and symbols.
        if mods.contains(.command) || mods.contains(.control) { return .ignore }

        guard let chars = characters, !chars.isEmpty else { return .ignore }
        // Drop control characters and the function-key range (arrows, F-keys, Home/End…).
        let typed = chars.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        guard !typed.isEmpty else { return .ignore }
        let text = String(String.UnicodeScalarView(typed))
        // A leading space would just look empty; ignore it until there's something to search.
        if query.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty { return .ignore }
        return .append(text)
    }

    /// Applies an action to the query.
    static func apply(_ action: Action, to query: String) -> String {
        switch action {
        case .append(let s):
            return query + s
        case .deleteBackward:
            return String(query.dropLast())
        case .deleteWord:
            var q = query
            while q.last == " " { q.removeLast() }
            while let c = q.last, c != " " { q.removeLast() }
            return q
        case .clear:
            return ""
        case .submit, .ignore:
            return query
        }
    }
}
