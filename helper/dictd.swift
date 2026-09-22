// dictd — offline dictionary + spelling helper for the Tinycast Dictionary extension.
// Usage:
//   dictd dictionaries                         → JSON [{ name, shortName }]
//   dictd lookup [--dictionary <name>] <text>  → JSON { query, correct, results: [...] }
//   dictd define [--dictionary <name>] <word>  → JSON { word, definition, html?, source? }
import Foundation
import AppKit
import CoreServices

// MARK: - Private DictionaryServices (same surface Raycast / Dictionary.app use)

typealias DictRef = OpaquePointer

@_silgen_name("DCSCopyAvailableDictionaries")
func DCSCopyAvailableDictionaries() -> Unmanaged<CFArray>?

@_silgen_name("DCSDictionaryGetName")
func DCSDictionaryGetName(_ dictionary: DictRef) -> Unmanaged<CFString>?

@_silgen_name("DCSDictionaryGetShortName")
func DCSDictionaryGetShortName(_ dictionary: DictRef) -> Unmanaged<CFString>?

@_silgen_name("DCSCopyRecordsForSearchString")
func DCSCopyRecordsForSearchString(
    _ dictionary: DictRef?,
    _ string: CFString,
    _ a: UnsafeRawPointer?,
    _ b: UnsafeRawPointer?
) -> Unmanaged<CFArray>?

@_silgen_name("DCSRecordGetHeadword")
func DCSRecordGetHeadword(_ record: CFTypeRef) -> Unmanaged<CFString>?

@_silgen_name("DCSRecordCopyData")
func DCSRecordCopyData(_ record: CFTypeRef, _ version: Int) -> Unmanaged<CFString>?

private let kRecordHTML = 2 // HTML with popover CSS
private let kRecordText = 3

// MARK: - Models

struct DictInfo: Codable { let name: String; let shortName: String }
struct Entry: Codable {
    let word: String
    let definition: String?
    let html: String?
    let source: String?
}
struct Lookup: Codable {
    let query: String
    let correct: Bool
    let results: [Entry]
    /// Bumped when search behaviour changes; UI can detect a stale assets/dictd binary.
    let engine: String
}

// MARK: - Dictionary resolution

struct ActiveDict {
    let ref: DictRef
    let name: String
    let shortName: String
}

func availableDictionaries() -> [ActiveDict] {
    guard let unmanaged = DCSCopyAvailableDictionaries() else { return [] }
    let cfArray = unmanaged.takeRetainedValue()
    let count = CFArrayGetCount(cfArray)
    var out: [ActiveDict] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        guard let ptr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
        let ref = DictRef(ptr)
        let name = DCSDictionaryGetName(ref)?.takeUnretainedValue() as String? ?? "Dictionary"
        let short = DCSDictionaryGetShortName(ref)?.takeUnretainedValue() as String? ?? name
        out.append(ActiveDict(ref: ref, name: name, shortName: short))
    }
    out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return out
}

func resolveDictionary(named wanted: String?) -> ActiveDict? {
    guard let wanted, !wanted.isEmpty else { return nil }
    let all = availableDictionaries()
    if let exact = all.first(where: { $0.name == wanted }) { return exact }
    return all.first {
        $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || $0.shortName.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// Scoped when `dict` is set; otherwise the system default amalgam of active dictionaries.
func define(_ word: String, dict: ActiveDict? = nil) -> String? {
    let ns = word as NSString
    let range = CFRangeMake(0, ns.length)
    let cfDict: DCSDictionary? = dict.map { unsafeBitCast($0.ref, to: DCSDictionary.self) }
    guard let def = DCSCopyTextDefinition(cfDict, ns as CFString, range) else { return nil }
    return def.takeRetainedValue() as String
}

func richEntry(for word: String, dict: ActiveDict?) -> Entry {
    let plain = define(word, dict: dict)
    var html: String?
    var source = dict?.name

    // Prefer HTML from a concrete dictionary's records (nicer formatting in the UI).
    let targets: [ActiveDict]
    if let dict {
        targets = [dict]
    } else {
        targets = availableDictionaries()
    }
    for d in targets {
        guard let recordsRef = DCSCopyRecordsForSearchString(d.ref, word as CFString, nil, nil) else { continue }
        let records = recordsRef.takeRetainedValue()
        let count = CFArrayGetCount(records)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(records, i) else { continue }
            let record = unsafeBitCast(ptr, to: CFTypeRef.self)
            let head = DCSRecordGetHeadword(record)?.takeUnretainedValue() as String?
            let headOK = head == nil
                || head!.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            guard headOK else { continue }
            if let htmlRef = DCSRecordCopyData(record, kRecordHTML) {
                html = htmlRef.takeRetainedValue() as String
                source = d.name
                break
            }
        }
        if html != nil { break }
    }

    return Entry(word: word, definition: plain, html: html, source: source)
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

// MARK: - Fuzzy / phonetic

/// Banded Damerau–Levenshtein (optimal string alignment).
func editDistance(_ s: String, _ t: String, limit: Int) -> Int {
    let a = Array(s), b = Array(t)
    let n = a.count, m = b.count
    if abs(n - m) > limit { return limit + 1 }
    if n == 0 { return m }
    if m == 0 { return n }

    var prevPrev = [Int](repeating: 0, count: m + 1)
    var prev = Array(0...m)
    var cur = [Int](repeating: 0, count: m + 1)
    for i in 1...n {
        cur[0] = i
        var rowMin = cur[0]
        for j in 1...m {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            var best = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                best = min(best, prevPrev[j - 2] + 1)
            }
            cur[j] = best
            if best < rowMin { rowMin = best }
        }
        if rowMin > limit { return limit + 1 }
        prevPrev = prev
        prev = cur
        cur = [Int](repeating: 0, count: m + 1)
    }
    return prev[m]
}

func metaphone(_ input: String) -> String {
    let vowels = Set("AEIOU")
    var s = input.uppercased().filter { $0.isLetter }
    guard !s.isEmpty else { return "" }

    let silentPrefixes = ["KN", "GN", "PN", "AE", "WR"]
    for p in silentPrefixes where s.hasPrefix(p) {
        s = String(s.dropFirst())
        break
    }
    if s.hasPrefix("X") { s = "S" + s.dropFirst() }
    if s.hasPrefix("WH") { s = "W" + s.dropFirst(2) }

    let chars = Array(s)
    var out = ""
    var i = 0
    let maxLen = 6

    func at(_ idx: Int) -> Character? {
        (idx >= 0 && idx < chars.count) ? chars[idx] : nil
    }
    func isVowel(_ idx: Int) -> Bool {
        guard let c = at(idx) else { return false }
        return vowels.contains(c)
    }

    while i < chars.count, out.count < maxLen {
        let c = chars[i]
        let next = at(i + 1)
        let prev = at(i - 1)

        if c != "C", prev == c {
            i += 1
            continue
        }

        switch c {
        case "A", "E", "I", "O", "U":
            if i == 0 { out.append(c) }
        case "B":
            if !(prev == "M" && next == nil) { out.append("B") }
        case "C":
            if next == "H" {
                out.append("X"); i += 1
            } else if next == "I" || next == "E" || next == "Y" {
                out.append("S")
            } else {
                out.append("K")
            }
        case "D":
            if next == "G", let n2 = at(i + 2), "IEY".contains(n2) {
                out.append("J"); i += 1
            } else {
                out.append("T")
            }
        case "F", "J", "L", "M", "N", "R":
            out.append(c)
        case "G":
            if next == "H", !isVowel(i + 2) {
                i += 1
            } else if next == "N", at(i + 2) == nil {
                break
            } else if next == "I" || next == "E" || next == "Y" {
                out.append("J")
            } else {
                out.append("K")
            }
        case "H":
            if isVowel(i + 1), prev == nil || isVowel(i - 1) {
                out.append("H")
            }
        case "K":
            if prev != "C" { out.append("K") }
        case "P":
            out.append(next == "H" ? "F" : "P")
            if next == "H" { i += 1 }
        case "Q":
            out.append("K")
        case "S":
            if next == "H" {
                out.append("X"); i += 1
            } else if next == "I", let n2 = at(i + 2), n2 == "O" || n2 == "A" {
                out.append("X")
            } else {
                out.append("S")
            }
        case "T":
            if next == "I", let n2 = at(i + 2), n2 == "O" || n2 == "A" {
                out.append("X")
            } else if next == "H" {
                out.append("0"); i += 1
            } else if !(next == "C" && at(i + 2) == "H") {
                out.append("T")
            }
        case "V":
            out.append("F")
        case "W", "Y":
            if isVowel(i + 1) { out.append(c) }
        case "X":
            out.append("K"); out.append("S")
        case "Z":
            out.append("S")
        default:
            break
        }
        i += 1
    }
    return out
}

func soundsLike(_ a: String, _ b: String) -> Bool {
    let ma = metaphone(a), mb = metaphone(b)
    return !ma.isEmpty && ma == mb
}

func phoneticVariants(_ word: String) -> [String] {
    let lower = word.lowercased()
    guard lower.count >= 3, lower.count <= 24 else { return [] }
    let pairs: [(String, String)] = [
        ("ph", "f"), ("f", "ph"),
        ("ck", "k"), ("k", "ck"), ("c", "k"), ("k", "c"),
        ("qu", "kw"), ("kw", "qu"),
        ("x", "ks"), ("ks", "x"),
        ("z", "s"), ("s", "z"),
        ("tion", "sion"), ("sion", "tion"),
        ("ight", "ite"), ("ite", "ight"), ("yte", "ight"),
        ("ough", "uff"), ("ough", "ow"), ("uff", "ough"),
        ("kn", "n"), ("n", "kn"),
        ("wr", "r"),
        ("wh", "w"), ("w", "wh"),
        ("ee", "ea"), ("ea", "ee"), ("ee", "i"),
        ("ie", "ei"), ("ei", "ie"), ("ie", "y"), ("y", "ie"),
        ("ou", "ow"), ("ow", "ou"), ("oo", "u"), ("u", "oo"),
        ("er", "re"), ("re", "er"),
        ("ance", "ence"), ("ence", "ance"),
        ("ense", "ence"), ("ence", "ense"),
    ]
    var out = Set<String>()
    for (from, to) in pairs {
        var search = lower.startIndex
        while let r = lower.range(of: from, range: search..<lower.endIndex) {
            var v = lower
            v.replaceSubrange(r, with: to)
            if v != lower, v.contains(where: { $0.isLetter }) {
                out.insert(v)
            }
            search = r.lowerBound < lower.endIndex ? lower.index(after: r.lowerBound) : lower.endIndex
        }
    }
    let chars = Array(lower)
    for i in 0..<(chars.count - 1) where chars[i] == chars[i + 1] && chars[i].isLetter {
        var c = chars
        c.remove(at: i)
        out.insert(String(c))
    }
    for i in chars.indices where chars[i].isLetter {
        var c = chars
        c.insert(chars[i], at: i)
        out.insert(String(c))
    }
    out.remove(lower)
    return Array(out)
}

/// One-edit variants plus non-adjacent letter swaps (characters in the wrong place).
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
            for j in (i + 1)..<chars.count where chars[i] != chars[j] {
                var c = chars
                c.swapAt(i, j)
                out.insert(String(c))
            }
        }
    }
    out.remove(word.lowercased())
    return Array(out)
}

/// Cached system word list + metaphone index for Datamuse-style recall.
final class WordIndex {
    static let shared = WordIndex()
    let words: [String]
    let bySound: [String: [String]]

    private init() {
        let paths = ["/usr/share/dict/words", "/usr/share/dict/web2"]
        var loaded: [String] = []
        for path in paths {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            loaded = raw.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let w = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard w.count >= 3, w.count <= 30, w.allSatisfy({ $0.isLetter }) else { return nil }
                return w
            }
            break
        }
        words = loaded
        var index: [String: [String]] = [:]
        for w in loaded {
            let code = metaphone(w)
            guard !code.isEmpty else { continue }
            index[code, default: []].append(w)
        }
        bySound = index
    }
}

func wordListMatches(for query: String, limit: Int = 20) -> [(String, Int, Bool)] {
    let q = query.lowercased()
    guard q.count >= 3, q.count <= 24 else { return [] }
    let index = WordIndex.shared
    guard !index.words.isEmpty else { return [] }
    let qSound = metaphone(q)
    let minLen = max(3, q.count - 2)
    let maxLen = q.count + 2
    var seen = Set<String>()
    var hits: [(String, Int, Bool)] = []

    func consider(_ w: String, preferSound: Bool) {
        let n = w.count
        guard n >= minLen, n <= maxLen, !seen.contains(w) else { return }
        let sound = preferSound || (!qSound.isEmpty && metaphone(w) == qSound)
        let d = editDistance(q, w, limit: sound ? 3 : 2)
        guard sound || d <= 2 else { return }
        seen.insert(w)
        hits.append((w, min(d, 4), sound))
    }

    // Sound bucket first (jirraf → giraffe), then nearby spellings in the length band.
    if !qSound.isEmpty {
        for w in index.bySound[qSound] ?? [] {
            consider(w, preferSound: true)
        }
    }
    if hits.count < limit {
        for w in index.words {
            let n = w.count
            guard n >= minLen, n <= maxLen else { continue }
            consider(w, preferSound: false)
        }
    }

    hits.sort {
        let s0 = ($0.2 && $0.1 > 0) ? max(1, $0.1 - 1) : $0.1
        let s1 = ($1.2 && $1.1 > 0) ? max(1, $1.1 - 1) : $1.1
        if s0 != s1 { return s0 < s1 }
        if $0.2 != $1.2 { return $0.2 && !$1.2 }
        return $0.0 < $1.0
    }
    return Array(hits.prefix(limit))
}

// MARK: - CLI

func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{}")
    }
}

func parseArgs(_ args: [String]) -> (cmd: String, dictionary: String?, text: String) {
    var dictionary: String?
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--dictionary" || a == "-d" {
            i += 1
            if i < args.count { dictionary = args[i] }
        } else if a.hasPrefix("--dictionary=") {
            dictionary = String(a.dropFirst("--dictionary=".count))
        } else if positional.isEmpty {
            positional.append(a) // command
        } else {
            positional.append(a)
        }
        i += 1
    }
    let cmd = positional.first ?? ""
    let text = positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return (cmd, dictionary, text)
}

let parsed = parseArgs(CommandLine.arguments)
let cmd = parsed.cmd
let text = parsed.text
let activeDict = resolveDictionary(named: parsed.dictionary)

if cmd == "dictionaries" {
    emit(availableDictionaries().map { DictInfo(name: $0.name, shortName: $0.shortName) })
    exit(0)
}

guard !cmd.isEmpty else {
    FileHandle.standardError.write(
        "usage: dictd dictionaries|lookup|define [--dictionary <name>] <text>\n".data(using: .utf8)!
    )
    exit(2)
}

if cmd == "define" {
    guard !text.isEmpty else { emit(Entry(word: "", definition: nil, html: nil, source: nil)); exit(0) }
    emit(richEntry(for: text, dict: activeDict))
    exit(0)
}

if cmd != "lookup" {
    FileHandle.standardError.write(
        "usage: dictd dictionaries|lookup|define [--dictionary <name>] <text>\n".data(using: .utf8)!
    )
    exit(2)
}

guard !text.isEmpty else { emit(Lookup(query: text, correct: true, results: [], engine: "sounds-1")); exit(0) }

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
    var soundsLike: Bool
}
var candidates: [Candidate] = []
var seen = Set<String>()
let querySound = metaphone(queryLower)

func add(_ w: String, distance: Int) {
    let key = w.lowercased()
    let sound = !querySound.isEmpty && metaphone(key) == querySound
    let ranked = (sound && distance > 0) ? max(1, distance - 1) : distance
    if let idx = candidates.firstIndex(where: { $0.word.lowercased() == key }) {
        if ranked < candidates[idx].distance {
            candidates[idx].distance = ranked
        }
        if sound { candidates[idx].soundsLike = true }
        return
    }
    if seen.contains(key) { return }
    seen.insert(key)
    candidates.append(Candidate(word: w, distance: ranked, soundsLike: sound))
}

func distance(to word: String) -> Int {
    editDistance(queryLower, word.lowercased(), limit: 4)
}

func probeVariant(_ variant: String) -> [(word: String, distance: Int)] {
    guard let def = define(variant, dict: activeDict) else { return [] }
    var hits: [(String, Int)] = []
    if isExactHeadword(variant, definition: def) {
        hits.append((variant, distance(to: variant)))
    }
    if let head = definitionHeadword(def) {
        let d = editDistance(queryLower, head.lowercased(), limit: 3)
        if d <= 3 || soundsLike(queryLower, head) {
            hits.append((head, min(d, 4)))
        }
    }
    return hits
}

func mergeVariants(_ variants: [String]) {
    guard !variants.isEmpty else { return }
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: variants.count) { i in
        let hits = probeVariant(variants[i])
        guard !hits.isEmpty else { return }
        lock.lock()
        for hit in hits {
            add(hit.word, distance: hit.distance)
        }
        lock.unlock()
    }
}

if let def = define(text, dict: activeDict), isExactHeadword(text, definition: def) {
    add(text, distance: 0)
}

if let def = define(text, dict: activeDict), let head = definitionHeadword(def) {
    let d = editDistance(queryLower, head.lowercased(), limit: 2)
    if d <= 2 || soundsLike(queryLower, head) {
        add(head, distance: min(d, 4))
    }
}

if !isCorrect {
    for g in checker.guesses(forWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] {
        add(g, distance: distance(to: g))
    }
}
// Prefix completions are noisy ("fone" → fon/font/fond…). Keep only close ones so
// sound-alikes like "phone" are not crowded out of the top 12.
for c in checker.completions(forPartialWordRange: fullRange, in: text, language: lang, inSpellDocumentWithTag: 0) ?? [] {
    let d = distance(to: c)
    if d <= 2 || soundsLike(queryLower, c) {
        add(c, distance: d)
    }
}

// Phonetic spelling probes ("fone" → "phone", "nite" → "night"). Always run.
mergeVariants(phoneticVariants(text))

// System word-list pass for sound-alikes / wrong-place letters the probes miss
// ("jirraf" → "giraffe", "hipopatamus" → "hippopotamus"), then keep only real dictionary hits.
let hasExactEarly = candidates.contains { $0.distance == 0 }
if !hasExactEarly {
    let lock = NSLock()
    let matches = wordListMatches(for: text)
    DispatchQueue.concurrentPerform(iterations: matches.count) { i in
        let (w, d, _) = matches[i]
        guard let def = define(w, dict: activeDict), isExactHeadword(w, definition: def) else { return }
        lock.lock()
        add(w, distance: d)
        lock.unlock()
    }
}

let hasExact = candidates.contains { $0.distance == 0 }
let hasClose = candidates.contains { $0.distance <= 1 }
let hasSound = candidates.contains { $0.soundsLike && $0.distance <= 2 }
// Still probe edits when we only have weak prefix hits and no sound-alike yet.
let shouldProbe = !hasSound && !hasClose && text.count >= 4 && text.count <= 24
if shouldProbe {
    mergeVariants(distance1Variants(text))
}

// Sound-alikes first (fone→phone), then edit distance, then alpha.
candidates.sort {
    if $0.soundsLike != $1.soundsLike { return $0.soundsLike && !$1.soundsLike }
    if $0.distance != $1.distance { return $0.distance < $1.distance }
    return $0.word.lowercased() < $1.word.lowercased()
}

let limited = Array(candidates.prefix(12))
let results = limited.map { richEntry(for: $0.word, dict: activeDict) }
emit(Lookup(query: text, correct: hasExact, results: results, engine: "sounds-1"))
