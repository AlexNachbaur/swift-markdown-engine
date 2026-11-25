//
//  SourceTextDiff.swift
//  MarkdownEngine
//
//  Edits between two ranges of text: lines first, then the words of a changed line,
//  then what a changed word starts and ends with. Not the fewest characters
//  possible; what matters is that text nobody touched is left alone, and that the
//  cost stays bounded for texts that share little.
//

import Foundation

struct SourceTextDiff {
    /// Last first, in the old text's coordinates.
    static func edits(
        from old: [UInt16], _ oldRange: NSRange, to new: [UInt16], _ newRange: NSRange
    ) -> [MarkdownSourceEdit] {
        var diff = SourceTextDiff(old: old, new: new)
        diff.addLines(
            oldRange.location..<NSMaxRange(oldRange), newRange.location..<NSMaxRange(newRange))
        return diff.out.reversed()
    }

    private let old: [UInt16]
    private let new: [UInt16]
    /// First first, while it is being built.
    private var out: [MarkdownSourceEdit] = []
    /// Word comparisons still allowed, for the whole diff.
    private var budget = 1_000_000

    private init(old: [UInt16], new: [UInt16]) {
        self.old = old
        self.new = new
    }

    // MARK: - Lines

    private mutating func addLines(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        guard !oldRange.isEmpty, !newRange.isEmpty else {
            replace(oldRange, newRange)
            return
        }
        var numbers = Numbers()
        let oldLines = Self.lines(old, oldRange).map { Piece(range: $0, number: numbers.of(old[$0])) }
        let newLines = Self.lines(new, newRange).map { Piece(range: $0, number: numbers.of(new[$0])) }
        for gap in Self.gaps(oldLines, newLines) {
            if gap.old.count == gap.new.count {
                // A change to each line: a list, a quote, Replace All.
                for (oldLine, newLine) in zip(oldLines[gap.old], newLines[gap.new]) {
                    addWords(oldLine.range, newLine.range)
                }
            } else {
                addWords(
                    Self.span(gap.old, of: oldLines, end: oldRange.upperBound),
                    Self.span(gap.new, of: newLines, end: newRange.upperBound))
            }
        }
    }

    /// Each line with its line feed, and what follows the last one, even if empty:
    /// as many lines as line feeds, and one.
    private static func lines(_ text: [UInt16], _ range: Range<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = range.lowerBound
        for index in range where text[index] == 0x0A {
            out.append(start..<(index + 1))
            start = index + 1
        }
        out.append(start..<range.upperBound)
        return out
    }

    // MARK: - Words

    private mutating func addWords(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        let (oldRange, newRange) = trimmed(oldRange, newRange)
        // Text wrapped in markers, or unwrapped, is left alone.
        if let kept = Self.firstOccurrence(of: old[oldRange], in: new[newRange]) {
            replace(oldRange.lowerBound..<oldRange.lowerBound, newRange.lowerBound..<kept.lowerBound)
            replace(oldRange.upperBound..<oldRange.upperBound, kept.upperBound..<newRange.upperBound)
            return
        }
        if let kept = Self.firstOccurrence(of: new[newRange], in: old[oldRange]) {
            replace(oldRange.lowerBound..<kept.lowerBound, newRange.lowerBound..<newRange.lowerBound)
            replace(kept.upperBound..<oldRange.upperBound, newRange.upperBound..<newRange.upperBound)
            return
        }
        guard !oldRange.isEmpty, !newRange.isEmpty else {
            replace(oldRange, newRange)
            return
        }
        // Several changes (Replace All) are told apart by the words between them.
        var numbers = Numbers()
        let oldWords = Self.words(old, oldRange).map { Piece(range: $0, number: numbers.of(old[$0])) }
        let newWords = Self.words(new, newRange).map { Piece(range: $0, number: numbers.of(new[$0])) }
        guard shareMuch(oldWords, newWords) else {
            replace(oldRange, newRange)
            return
        }
        for gap in Self.gaps(oldWords, newWords) {
            for part in parts(of: gap, oldWords, newWords) {
                replace(
                    Self.span(part.old, of: oldWords, end: oldRange.upperBound),
                    Self.span(part.new, of: newWords, end: newRange.upperBound))
            }
        }
    }

    /// Runs of letters and digits, and every other unit on its own. Outside ASCII
    /// everything counts as a letter, so a surrogate pair stays together.
    private static func words(_ text: [UInt16], _ range: Range<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = range.lowerBound
        for index in range where !isWordUnit(text[index]) {
            if start < index { out.append(start..<index) }
            out.append(index..<(index + 1))
            start = index + 1
        }
        if start < range.upperBound { out.append(start..<range.upperBound) }
        return out
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        guard unit < 0x80 else { return true }
        return (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    /// Whether a third of the words on the side with more are on the other side too.
    /// Long texts that share less are better replaced than picked apart.
    private func shareMuch(_ oldWords: [Piece], _ newWords: [Piece]) -> Bool {
        guard max(oldWords.count, newWords.count) > 64 else { return true }
        var counts: [Int: Int] = [:]
        var oldCount = 0
        for word in oldWords where Self.isWordUnit(old[word.range.lowerBound]) {
            counts[word.number, default: 0] += 1
            oldCount += 1
        }
        var newCount = 0
        var shared = 0
        for word in newWords where Self.isWordUnit(new[word.range.lowerBound]) {
            newCount += 1
            if let left = counts[word.number], left > 0 {
                counts[word.number] = left - 1
                shared += 1
            }
        }
        return shared > 0 && shared * 3 >= max(oldCount, newCount)
    }

    /// The differing parts of a gap between words, by longest common subsequence
    /// while the budget lasts.
    private mutating func parts(of gap: Gap, _ oldWords: [Piece], _ newWords: [Piece]) -> [Gap] {
        let cells = gap.old.count * gap.new.count
        guard cells > 0, cells <= 65_536, cells <= budget else { return [gap] }
        budget -= cells
        let (rows, columns) = (gap.old.count, gap.new.count)
        func same(_ row: Int, _ column: Int) -> Bool {
            oldWords[gap.old.lowerBound + row].number == newWords[gap.new.lowerBound + column].number
        }
        // Length of the longest common subsequence from each cell on.
        var length = [Int32](repeating: 0, count: (rows + 1) * (columns + 1))
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                length[row * (columns + 1) + column] = same(row, column)
                    ? length[(row + 1) * (columns + 1) + column + 1] + 1
                    : max(length[(row + 1) * (columns + 1) + column], length[row * (columns + 1) + column + 1])
            }
        }
        var parts: [Gap] = []
        var (row, column) = (0, 0)
        while row < rows || column < columns {
            let start = (row, column)
            while row < rows || column < columns {
                if row < rows, column < columns, same(row, column) { break }
                if column == columns
                    || (row < rows
                        && length[(row + 1) * (columns + 1) + column] >= length[row * (columns + 1) + column + 1]) {
                    row += 1
                } else {
                    column += 1
                }
            }
            if start != (row, column) {
                parts.append(Gap(
                    old: (gap.old.lowerBound + start.0)..<(gap.old.lowerBound + row),
                    new: (gap.new.lowerBound + start.1)..<(gap.new.lowerBound + column)))
            }
            row += 1
            column += 1
            if row > rows || column > columns { break }
        }
        return parts
    }

    // MARK: - Pieces

    /// A line or a word. Equal ones have equal numbers.
    private struct Piece {
        let range: Range<Int>
        let number: Int
    }

    private struct Numbers {
        private var known: [ArraySlice<UInt16>: Int] = [:]
        mutating func of(_ text: ArraySlice<UInt16>) -> Int {
            if let number = known[text] { return number }
            known[text] = known.count
            return known.count - 1
        }
    }

    /// Pieces of the old text, by index, with the pieces of the new one in their place.
    private struct Gap {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// What differs, split at the pieces both sides have exactly once, in the longest
    /// run of them that is in the same order on both; and between those, again.
    private static func gaps(_ old: [Piece], _ new: [Piece]) -> [Gap] {
        var out: [Gap] = []
        // First on top. A list rather than recursion: nesting can be as deep as the text is long.
        var pending = [Gap(old: old.startIndex..<old.endIndex, new: new.startIndex..<new.endIndex)]
        // Splitting can, for texts made to do so, find one piece at a time.
        var budget = 32 * (old.count + new.count)
        while var gap = pending.popLast() {
            budget -= gap.old.count + gap.new.count
            while let oldIndex = gap.old.first, let newIndex = gap.new.first,
                  old[oldIndex].number == new[newIndex].number {
                gap.old.removeFirst()
                gap.new.removeFirst()
            }
            while let oldIndex = gap.old.last, let newIndex = gap.new.last,
                  old[oldIndex].number == new[newIndex].number {
                gap.old.removeLast()
                gap.new.removeLast()
            }
            guard !gap.old.isEmpty || !gap.new.isEmpty else { continue }
            let anchors = budget > 0 ? commonUnique(old, new, gap) : []
            guard !anchors.isEmpty else {
                out.append(gap)
                continue
            }
            var between: [Gap] = []
            var (oldFrom, newFrom) = (gap.old.lowerBound, gap.new.lowerBound)
            for (oldIndex, newIndex) in anchors {
                between.append(Gap(old: oldFrom..<oldIndex, new: newFrom..<newIndex))
                (oldFrom, newFrom) = (oldIndex + 1, newIndex + 1)
            }
            between.append(Gap(old: oldFrom..<gap.old.upperBound, new: newFrom..<gap.new.upperBound))
            pending.append(contentsOf: between.reversed())
        }
        return out
    }

    private static func commonUnique(_ old: [Piece], _ new: [Piece], _ gap: Gap) -> [(Int, Int)] {
        guard !gap.old.isEmpty, !gap.new.isEmpty else { return [] }
        func uniqueIndices(_ pieces: [Piece], _ range: Range<Int>) -> [Int: Int] {
            var seen: [Int: Int] = [:]
            for index in range { seen[pieces[index].number] = seen[pieces[index].number] == nil ? index : -1 }
            return seen.filter { $0.value >= 0 }
        }
        let inNew = uniqueIndices(new, gap.new)
        let pairs = uniqueIndices(old, gap.old)
            .compactMap { number, oldIndex in inNew[number].map { (oldIndex, $0) } }
            .sorted { $0.0 < $1.0 }
        return longestIncreasing(pairs)
    }

    /// The longest subsequence whose second members increase.
    private static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].1 < pairs[index].1 { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var out: [(Int, Int)] = []
        var index = tails.last ?? -1
        while index >= 0 {
            out.append(pairs[index])
            index = previous[index]
        }
        return out.reversed()
    }

    /// The text of a run of pieces; where it would be, if there are none.
    private static func span(_ indices: Range<Int>, of pieces: [Piece], end: Int) -> Range<Int> {
        let start = indices.lowerBound < pieces.count ? pieces[indices.lowerBound].range.lowerBound : end
        let stop = indices.upperBound < pieces.count ? pieces[indices.upperBound].range.lowerBound : end
        return start..<stop
    }

    // MARK: - Characters

    /// Bounded, so a large unrelated replacement isn't searched for itself.
    private static let searchLimit = 4096

    private static func firstOccurrence(
        of needle: ArraySlice<UInt16>, in text: ArraySlice<UInt16>
    ) -> Range<Int>? {
        guard !needle.isEmpty, needle.count < text.count, text.count <= searchLimit else { return nil }
        for start in text.startIndex...(text.endIndex - needle.count)
        where text[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }

    private mutating func replace(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        let (oldRange, newRange) = trimmed(oldRange, newRange)
        guard !oldRange.isEmpty || !newRange.isEmpty else { return }
        out.append(MarkdownSourceEdit(
            range: NSRange(location: oldRange.lowerBound, length: oldRange.count),
            replacement: String(decoding: new[newRange], as: UTF16.self)))
    }

    /// Without what both start and end with, never splitting a surrogate pair.
    private func trimmed(_ oldRange: Range<Int>, _ newRange: Range<Int>) -> (Range<Int>, Range<Int>) {
        let limit = min(oldRange.count, newRange.count)
        var prefix = 0
        while prefix < limit, old[oldRange.lowerBound + prefix] == new[newRange.lowerBound + prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old[oldRange.lowerBound + prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix,
              old[oldRange.upperBound - 1 - suffix] == new[newRange.upperBound - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old[oldRange.upperBound - suffix]) { suffix -= 1 }
        return ((oldRange.lowerBound + prefix)..<(oldRange.upperBound - suffix),
                (newRange.lowerBound + prefix)..<(newRange.upperBound - suffix))
    }
}
