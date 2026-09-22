// dictd — offline dictionary + spelling helper for the Tinycast Dictionary extension.
// Usage: dictd lookup <text>   → JSON { query, correct, results: [{ word, definition }] }
//        dictd define <word>   → JSON { word, definition }
//        dictd correct <text>  → JSON { original, corrected, changes: [{ from, to }] }
import Foundation
import AppKit
import CoreServices

struct Entry: Codable { let word: String; let definition: String? }
struct Lookup: Codable { let query: String; let correct: Bool; let results: [Entry] }
struct Change: Codable { let from: String; let to: String }
struct Correction: Codable { let original: String; let corrected: String; let changes: [Change] }

/// Match the casing pattern of `source` onto `replacement` (ALL CAPS, Capitalised, or lower).
func matchCase(_ source: String, _ replacement: String) -> String {
    if source == source.uppercased() && source != source.lowercased() { return replacement.uppercased() }
    if let f = source.first, f.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
    return replacement
}

func correct(_ text: String) -> Correction {
    let checker = NSSpellChecker.shared
    let lang = checker.language()
    var result = text
    var offset = 0
    var changes: [Change] = []
    while true {
        let ns = result as NSString
        if offset >= ns.length { break }
        let r = checker.checkSpelling(of: result, startingAt: offset, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        if r.location == NSNotFound { break }
        let word = ns.substring(with: r)
        let guesses = checker.guesses(forWordRange: r, in: result, language: lang, inSpellDocumentWithTag: 0) ?? []
        if let g = guesses.first {
            let fixed = matchCase(word, g)
            result = ns.replacingCharacters(in: r, with: fixed)
            changes.append(Change(from: word, to: fixed))
            offset = r.location + (fixed as NSString).length
        } else {
            offset = r.location + r.length
        }
    }
    return Correction(original: text, corrected: result, changes: changes)
}

func define(_ word: String) -> String? {
    let ns = word as NSString
    let range = CFRangeMake(0, ns.length)
    guard let def = DCSCopyTextDefinition(nil, ns as CFString, range) else { return nil }
    return def.takeRetainedValue() as String
}

func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{}")
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: dictd lookup|define <text>\n".data(using: .utf8)!)
    exit(2)
}
let cmd = args[1]
let text = args[2...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

if cmd == "correct" {
    emit(correct(args[2...].joined(separator: " ")))
    exit(0)
}

if cmd == "define" {
    emit(Entry(word: text, definition: define(text)))
    exit(0)
}

guard !text.isEmpty else { emit(Lookup(query: text, correct: true, results: [])); exit(0) }

let checker = NSSpellChecker.shared
let ns = text as NSString
let fullRange = NSRange(location: 0, length: ns.length)
let lang = checker.language()

let misspelled = checker.checkSpelling(of: text, startingAt: 0)
let correct = misspelled.location == NSNotFound

var candidates: [String] = []
var seen = Set<String>()
func add(_ w: String) {
    let key = w.lowercased()
    if !seen.contains(key) { seen.insert(key); candidates.append(w) }
}

// Exact query first (if the dictionary knows it), then spelling guesses, then completions.
if define(text) != nil { add(text) }
if !correct {
    for g in checker.guesses(forWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] { add(g) }
}
for c in checker.completions(forPartialWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] { add(c) }

let limited = Array(candidates.prefix(12))
let results = limited.map { Entry(word: $0, definition: define($0)) }
emit(Lookup(query: text, correct: correct, results: results))
