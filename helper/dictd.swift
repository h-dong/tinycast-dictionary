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

/// Banded Levenshtein; returns limit+1 when distance exceeds `limit`.
func editDistance(_ s: String, _ t: String, limit: Int) -> Int {
    let a = Array(s), b = Array(t)
    let n = a.count, m = b.count
    if abs(n - m) > limit { return limit + 1 }
    if n == 0 { return m }
    if m == 0 { return n }

    var prev = Array(0...m)
    var cur = [Int](repeating: 0, count: m + 1)
    for i in 1...n {
        cur[0] = i
        var rowMin = cur[0]
        for j in 1...m {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if cur[j] < rowMin { rowMin = cur[j] }
        }
        if rowMin > limit { return limit + 1 }
        swap(&prev, &cur)
    }
    return prev[m]
}

/// All strings one edit away (insert / delete / substitute / transpose). ASCII letters only.
func distance1Variants(_ word: String) -> [String] {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    let chars = Array(word.lowercased())
    var out = Set<String>()

    for i in chars.indices {
        var c = chars
        c.remove(at: i)
        out.insert(String(c))
    }
    for i in 0...chars.count {
        for ch in alphabet {
            var c = chars
            c.insert(ch, at: i)
            out.insert(String(c))
        }
    }
    for i in chars.indices {
        for ch in alphabet where ch != chars[i] {
            var c = chars
            c[i] = ch
            out.insert(String(c))
        }
    }
    if chars.count > 1 {
        for i in 0..<(chars.count - 1) {
            var c = chars
            c.swapAt(i, i + 1)
            out.insert(String(c))
        }
    }
    out.remove(word.lowercased())
    return Array(out)
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
let queryLower = text.lowercased()

let misspelled = checker.checkSpelling(of: text, startingAt: 0)
let isCorrect = misspelled.location == NSNotFound

struct Candidate {
    let word: String
    var distance: Int
}
var candidates: [Candidate] = []
var seen = Set<String>()

func add(_ w: String, distance: Int) {
    let key = w.lowercased()
    if let idx = candidates.firstIndex(where: { $0.word.lowercased() == key }) {
        if distance < candidates[idx].distance {
            candidates[idx].distance = distance
        }
        return
    }
    if seen.contains(key) { return }
    seen.insert(key)
    candidates.append(Candidate(word: w, distance: distance))
}

func distance(to word: String) -> Int {
    editDistance(queryLower, word.lowercased(), limit: 4)
}

// Exact headword first.
if let def = define(text), isExactHeadword(text, definition: def) {
    add(text, distance: 0)
}

// DCS prefix/fuzzy hit: surface the real headword when it is close to what was typed
// ("uninstal" → "uninstall"), without listing the typo as a definition.
if let def = define(text), let head = definitionHeadword(def) {
    let d = editDistance(queryLower, head.lowercased(), limit: 2)
    if d <= 2 {
        add(head, distance: d)
    }
}

// Spelling guesses for flagged misspellings, then prefix completions.
if !isCorrect {
    for g in checker.guesses(forWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] {
        add(g, distance: distance(to: g))
    }
}
for c in checker.completions(forPartialWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] {
    add(c, distance: distance(to: c))
}

// One-edit dictionary probe for typos the spellchecker misses ("unstall" → "uninstall").
// Skip when we already have an exact or one-edit hit; concurrent lookups keep this interactive.
let hasExact = candidates.contains { $0.distance == 0 }
let hasClose = candidates.contains { $0.distance <= 1 }
let shouldProbe = !hasClose && text.count >= 4 && text.count <= 24
if shouldProbe {
    let variants = distance1Variants(text)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: variants.count) { i in
        let variant = variants[i]
        guard let def = define(variant) else { return }
        if isExactHeadword(variant, definition: def) {
            lock.lock()
            add(variant, distance: 1)
            lock.unlock()
            return
        }
        // Variant may itself be a DCS prefix of a nearby headword.
        if let head = definitionHeadword(def) {
            let d = editDistance(queryLower, head.lowercased(), limit: 2)
            if d <= 2 {
                lock.lock()
                add(head, distance: d)
                lock.unlock()
            }
        }
    }
}

candidates.sort {
    if $0.distance != $1.distance { return $0.distance < $1.distance }
    return $0.word.lowercased() < $1.word.lowercased()
}

let limited = Array(candidates.prefix(12))
let results = limited.map { Entry(word: $0.word, definition: define($0.word)) }
emit(Lookup(query: text, correct: hasExact, results: results))
