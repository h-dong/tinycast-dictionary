// dictd — offline dictionary + spelling helper for the Tinycast Dictionary extension.
// Usage: dictd lookup <text>   → JSON { query, correct, results: [{ word, definition }] }
//        dictd define <word>   → JSON { word, definition }
import Foundation
import AppKit
import CoreServices

struct Entry: Codable { let word: String; let definition: String? }
struct Lookup: Codable { let query: String; let correct: Bool; let results: [Entry] }

func define(_ word: String) -> String? {
    let ns = word as NSString
    let range = CFRangeMake(0, ns.length)
    guard let def = DCSCopyTextDefinition(nil, ns as CFString, range) else { return nil }
    return def.takeRetainedValue() as String
}

// DCSCopyTextDefinition is prefix-fuzzy: "uninstal" returns the "uninstall" entry.
// The line always starts with the real headword before the first " | ".
func definitionHeadword(_ definition: String) -> String? {
    let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sep = trimmed.range(of: " | ") else { return nil }
    var head = String(trimmed[..<sep.lowerBound])
    // Homographs are recorded as "cat 1", "bass 2".
    if let numbered = head.range(of: #" \d+$"#, options: .regularExpression) {
        head.removeSubrange(numbered)
    }
    return head
}

func isExactHeadword(_ word: String, definition: String) -> Bool {
    guard let head = definitionHeadword(definition) else { return false }
    return head.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
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
let isCorrect = misspelled.location == NSNotFound

var candidates: [String] = []
var seen = Set<String>()
func add(_ w: String) {
    let key = w.lowercased()
    if !seen.contains(key) { seen.insert(key); candidates.append(w) }
}

// Exact query first only when it is the dictionary headword, then spelling guesses, then completions.
if let def = define(text), isExactHeadword(text, definition: def) { add(text) }
if !isCorrect {
    for g in checker.guesses(forWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] { add(g) }
}
for c in checker.completions(forPartialWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] { add(c) }

let limited = Array(candidates.prefix(12))
let results = limited.map { Entry(word: $0, definition: define($0)) }
emit(Lookup(query: text, correct: isCorrect, results: results))
