import Foundation

// Minimal forgiving JSON navigation for parsing varied agent event streams.
enum JSON {
    static func parse(_ line: String) -> [String: Any]? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let data = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func int(_ k: String) -> Int? {
        if let i = self[k] as? Int { return i }
        if let d = self[k] as? Double { return Int(d) }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func dbl(_ k: String) -> Double? {
        if let d = self[k] as? Double { return d }
        if let i = self[k] as? Int { return Double(i) }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
    // dig two levels for a string: dig("a","b") == self["a"]["b"] as String
    func dig(_ a: String, _ b: String) -> String? { dict(a)?.str(b) }
    // dig two levels for a dict
    func dig2(_ a: String, _ b: String) -> [String: Any]? { dict(a)?.dict(b) }
}
