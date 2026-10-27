/// Removes isolated horizontal spaces introduced between Chinese characters by
/// speech recognition. Callers choose whether the writing preference is Chinese;
/// this function neither translates nor changes character forms.
public enum ChineseSpacingNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var line: [Character] = []
        var fence: Fence?
        var inlineTicks = 0

        func appendLine() {
            defer { line.removeAll(keepingCapacity: true) }
            if let activeFence = fence {
                result.append(contentsOf: line)
                if isClosingFence(line, matching: activeFence) { fence = nil }
                return
            }
            if inlineTicks == 0, let opening = openingFence(line) {
                fence = opening
                result.append(contentsOf: line)
                return
            }
            let indented = isIndentedCode(line)
            if inlineTicks == 0, indented {
                // Conservatively protect Markdown's indented code, even when
                // surrounding block context could make this an indented paragraph.
                // Backticks in such code must not open spans on following lines.
                result.append(contentsOf: line)
                return
            }
            let mayNormalize = !indented && !line.contains(where: containsKanaOrHangul)
            var index = 0
            while index < line.count {
                let character = line[index]
                if character == "`" {
                    if inlineTicks == 0, isEscaped(at: index, in: line) {
                        result.append(character)
                        index += 1
                        continue
                    }
                    var end = index + 1
                    while end < line.count, line[end] == "`" { end += 1 }
                    let count = end - index
                    if inlineTicks == count { inlineTicks = 0 }
                    else if inlineTicks == 0 { inlineTicks = count }
                    result.append(contentsOf: line[index..<end])
                    index = end
                    continue
                }
                if mayNormalize, inlineTicks == 0, isHorizontalSpace(character),
                   index > 0, index + 1 < line.count,
                   shouldJoin(line[index - 1], line[index + 1]) {
                    // Looking at original neighbours also protects runs of two
                    // or more spaces, including mixed Unicode space separators.
                    index += 1
                    continue
                }
                result.append(character)
                index += 1
            }
        }

        for character in text {
            line.append(character)
            // Character preserves CRLF as one grapheme, as well as other Unicode
            // line separators. No split/join step can rewrite the line endings.
            if character.isNewline { appendLine() }
        }
        if !line.isEmpty { appendLine() }
        return result
    }

    private struct Fence {
        let marker: Character
        let count: Int
    }

    private static func openingFence(_ line: [Character]) -> Fence? {
        let start = line.prefix(while: { $0 == " " }).count
        guard start <= 3, start < line.count,
              line[start] == "`" || line[start] == "~" else { return nil }
        let marker = line[start]
        let count = line[start...].prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        // CommonMark forbids backticks in the info string of a backtick fence.
        if marker == "`", line[(start + count)...].contains("`") { return nil }
        return Fence(marker: marker, count: count)
    }

    private static func isClosingFence(_ line: [Character], matching fence: Fence) -> Bool {
        let start = line.prefix(while: { $0 == " " }).count
        guard start <= 3, start < line.count else { return false }
        let count = line[start...].prefix(while: { $0 == fence.marker }).count
        guard count >= fence.count else { return false }
        return line[(start + count)...].allSatisfy { $0 == " " || $0 == "\t" || $0.isNewline }
    }

    private static func isEscaped(at index: Int, in line: [Character]) -> Bool {
        var previous = index
        while previous > 0, line[previous - 1] == "\\" { previous -= 1 }
        return (index - previous) % 2 == 1
    }

    private static func isIndentedCode(_ line: [Character]) -> Bool {
        let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
        return indentation.count >= 4 || indentation.contains("\t")
    }

    private static func isHorizontalSpace(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.generalCategory == .spaceSeparator
    }

    private static func shouldJoin(_ left: Character, _ right: Character) -> Bool {
        (isHan(left) && (isHan(right) || chinesePunctuation.contains(right)))
            || (chinesePunctuation.contains(left) && isHan(right))
    }

    // Explicit Chinese punctuation only: shared ASCII punctuation, dashes and
    // ellipses retain their original spacing. Punctuation-to-punctuation spaces
    // are also left alone.
    private static let chinesePunctuation: Set<Character> = Set("，。！？；：、「」『』（）《》〈〉【】〔〕［］｛｝")

    private static func isHan(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, isHanScalar(first.value) else { return false }
        // An ideographic variation sequence is one character. Do not strip its
        // selector, or classify emoji/ZWJ sequences merely by a constituent.
        return scalars.dropFirst().allSatisfy {
            (0xFE00...0xFE0F).contains($0.value) || (0xE0100...0xE01EF).contains($0.value)
        }
    }

    private static func isHanScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x3005, 0x3007, // Ideographic iteration mark and zero.
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
             0x2B820...0x2CEAF, 0x2CEB0...0x2EBEF, 0x2EBF0...0x2EE5F,
             0x2F800...0x2FA1F, 0x30000...0x3134F, 0x31350...0x323AF:
            return true
        default: return false
        }
    }

    private static func containsKanaOrHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF65...0xFF9F,
                 0x1AFF0...0x1AFFF, 0x1B000...0x1B16F,
                 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
                 0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC:
                return true
            default: return false
            }
        }
    }
}
