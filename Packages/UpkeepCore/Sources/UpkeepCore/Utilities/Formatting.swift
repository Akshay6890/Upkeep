import Foundation

public enum Formatting {
    /// Decimal byte formatting matching Finder ("842 MB", "12.8 GB").
    public static func bytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        if value < 1_000 { return count == 1 ? "1 byte" : "\(Int(value)) bytes" }
        let units: [(String, Double)] = [("KB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12), ("PB", 1e15)]
        var chosen = units[0]
        for unit in units where value >= unit.1 { chosen = unit }
        let scaled = value / chosen.1
        let decimals: Int
        switch chosen.0 {
        case "KB": decimals = 0
        case "MB": decimals = scaled < 10 ? 1 : 0
        default: decimals = 1
        }
        let rounded = String(format: "%.\(decimals)f", scaled)
        return "\(rounded) \(chosen.0)"
    }

    /// "1,284" style grouping, locale independent for stable output.
    public static func count(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }

    public static func plural(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count(value)) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }
}
