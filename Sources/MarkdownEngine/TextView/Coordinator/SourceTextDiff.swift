//
//  SourceTextDiff.swift
//  MarkdownEngine
//
//  Edits between two ranges of text: lines first, then the words of a changed line,
//  then what a changed word starts and ends with. Not the fewest characters
//  possible; what matters is that text nobody touched is left alone, and that the
//  cost stays bounded for texts that share nothing.
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

    private init(old: [UInt16], new: [UInt16]) {
        self.old = old
        self.new = new
    }

    // MARK: - Lines

    private mutating func addLines(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        let (oldRange, newRange) = trimmed(oldRange, newRange)
        // Equal lines get equal numbers, so comparing lines is comparing numbers.
        var numbers: [ArraySlice<UInt16>: Int] = [:]
        func numbered(_ text: [UInt16], _ range: Range<Int>) -> [(range: Range<Int>, number: Int)] {
            Self.lines(text, range).map { line in
                let number = numbers[text[line], default: numbers.count]
                numbers[text[line]] = number
                return (line, number)
            }
        }
        let oldLines = numbered(old, oldRange)
        let newLines = numbered(new, newRange)
        addLines(oldLines[...], newLines[...], oldEnd: oldRange.upperBound, newEnd: newRange.upperBound)
    }

    private typealias Lines = ArraySlice<(range: Range<Int>, number: Int)>

    /// Splits at the lines both sides have exactly once, in the longest run of them
    /// that is in the same order on both.
    private mutating func addLines(_ old: Lines, _ new: Lines, oldEnd: Int, newEnd: Int) {
        var (old, new, oldEnd, newEnd) = (old, new, oldEnd, newEnd)
        while let oldLine = old.first, let newLine = new.first, oldLine.number == newLine.number {
            old.removeFirst()
            new.removeFirst()
        }
        while let oldLine = old.last, let newLine = new.last, oldLine.number == newLine.number {
            oldEnd = oldLine.range.lowerBound
            newEnd = newLine.range.lowerBound
            old.removeLast()
            new.removeLast()
        }
        let anchors = Self.commonUniqueLines(old, new)
        guard !anchors.isEmpty else {
            if old.count == new.count {
                // A change to each line: a list, a quote, Replace All.
                for (oldLine, newLine) in zip(old, new) { addText(oldLine.range, newLine.range) }
            } else {
                addText(
                    (old.first?.range.lowerBound ?? oldEnd)..<oldEnd,
                    (new.first?.range.lowerBound ?? newEnd)..<newEnd)
            }
            return
        }
        var oldFrom = old.startIndex
        var newFrom = new.startIndex
        for (oldIndex, newIndex) in anchors {
            addLines(
                old[oldFrom..<oldIndex], new[newFrom..<newIndex],
                oldEnd: old[oldIndex].range.lowerBound, newEnd: new[newIndex].range.lowerBound)
            oldFrom = oldIndex + 1
            newFrom = newIndex + 1
        }
        addLines(old[oldFrom...], new[newFrom...], oldEnd: oldEnd, newEnd: newEnd)
    }

    private static func commonUniqueLines(_ old: Lines, _ new: Lines) -> [(Int, Int)] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        func uniqueIndices(_ lines: Lines) -> [Int: Int] {
            var seen: [Int: Int] = [:]
            for index in lines.indices { seen[lines[index].number] = seen[lines[index].number] == nil ? index : -1 }
            return seen.filter { $0.value >= 0 }
        }
        let inNew = uniqueIndices(new)
        let pairs = uniqueIndices(old)
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

    /// Each line with its line feed.
    private static func lines(_ text: [UInt16], _ range: Range<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = range.lowerBound
        for index in range where text[index] == 0x0A {
            out.append(start..<(index + 1))
            start = index + 1
        }
        if start < range.upperBound { out.append(start..<range.upperBound) }
        return out
    }

    // MARK: - Within lines

    private mutating func addText(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        let (oldRange, newRange) = trimmed(oldRange, newRange)
        // Text wrapped in markers, or unwrapped, is left alone.
        if let kept = Self.firstOccurrence(of: old[oldRange], in: new[newRange]) {
            replace(oldRange.lowerBound..<oldRange.lowerBound, newRange.lowerBound..<kept.lowerBound)
            replace(oldRange.upperBound..<oldRange.upperBound, kept.upperBound..<newRange.upperBound)
        } else if let kept = Self.firstOccurrence(of: new[newRange], in: old[oldRange]) {
            replace(oldRange.lowerBound..<kept.lowerBound, newRange.lowerBound..<newRange.lowerBound)
            replace(kept.upperBound..<oldRange.upperBound, newRange.upperBound..<newRange.upperBound)
        } else {
            addWords(oldRange, newRange)
        }
    }

    /// Several changes in a line (Replace All) are told apart by the words between them.
    private mutating func addWords(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        let oldWords = Self.words(old, oldRange)
        let newWords = Self.words(new, newRange)
        guard oldWords.count <= Self.wordLimit, newWords.count <= Self.wordLimit else {
            replace(oldRange, newRange)
            return
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newWords.map({ new[$0] }).difference(from: oldWords.map { old[$0] }) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldWords.count || newIndex < newWords.count {
            let oldStart = oldIndex < oldWords.count ? oldWords[oldIndex].lowerBound : oldRange.upperBound
            let newStart = newIndex < newWords.count ? newWords[newIndex].lowerBound : newRange.upperBound
            let before = (oldIndex, newIndex)
            while removed.contains(oldIndex) { oldIndex += 1 }
            while inserted.contains(newIndex) { newIndex += 1 }
            if before == (oldIndex, newIndex) {
                oldIndex += 1
                newIndex += 1
            } else {
                let oldEnd = oldIndex < oldWords.count ? oldWords[oldIndex].lowerBound : oldRange.upperBound
                let newEnd = newIndex < newWords.count ? newWords[newIndex].lowerBound : newRange.upperBound
                replace(oldStart..<oldEnd, newStart..<newEnd)
            }
        }
    }

    /// The word comparison costs the square of the words that differ.
    private static let wordLimit = 256

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
