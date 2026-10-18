import Foundation

public struct SessionNames {
    public static func slugify(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let lower = text.lowercased()
        var result = ""
        var inDash = false

        for scalar in lower.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                inDash = false
            } else if !inDash {
                result.append("-")
                inDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "session" : trimmed
    }

    public static func makeStem(title: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let datePart = formatter.string(from: date)
        let slugPart = slugify(title)
        return "local-transcript-\(datePart)-\(slugPart)"
    }
}
