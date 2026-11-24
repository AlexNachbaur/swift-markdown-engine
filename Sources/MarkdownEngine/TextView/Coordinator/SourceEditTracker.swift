//
//  SourceEditTracker.swift
//  MarkdownEngine
//
//  Turns what happened to the text storage into edits of the source text.
//
//  The storage says where characters changed, so a run of equal characters is
//  edited where the user edited it. What changed is read from the source texts
//  before and after, so the edits always lead from one to the other: a region the
//  storage reported is used only if the texts agree outside it.
//

import Foundation

final class SourceEditTracker {
    /// The source text as of the last reported change.
    private(set) var source: String?
    private(set) var linkMap = WikiLinkOffsetMap([:])
    private var documentId: String?

    /// The display region changed since the last report: where it was before, and
    /// where it is now. Both start at the same offset.
    private var changed: (start: Int, oldLength: Int, newLength: Int)?

    var hasUnreportedEdits: Bool { changed != nil }

    /// Where the display text changed since the last report, as it is now.
    var unreportedDisplayRange: NSRange? {
        changed.map { NSRange(location: $0.start, length: $0.newLength) }
    }

    /// Notes one round of `NSTextStorage` editing.
    func noteStorageEdit(editedRange: NSRange, changeInLength delta: Int) {
        let location = editedRange.location
        let priorLength = editedRange.length - delta
        guard location != NSNotFound, priorLength >= 0 else { return }
        guard let current = changed else {
            changed = (location, priorLength, editedRange.length)
            return
        }
        let start = min(current.start, location)
        let priorEnd = max(current.start + current.newLength, location + priorLength)
        let priorUnion = priorEnd - start
        changed = (start, current.oldLength + priorUnion - current.newLength, priorUnion + delta)
    }

    /// Takes a text as the starting point without reporting how it came about.
    func reset(source: String, metadata: LinkMetadata, documentId: String?) {
        self.source = source
        self.documentId = documentId
        linkMap = WikiLinkOffsetMap(metadata)
        changed = nil
    }

    typealias LinkMetadata = [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata]

    /// The edits from the last reported source text to `newSource`, which becomes
    /// the last reported one. Empty for the first text of a document.
    func takeEdits(to newSource: String, metadata: LinkMetadata, documentId: String?) -> [MarkdownSourceEdit] {
        let oldSource = source
        let oldMap = linkMap
        let region = changed
        let sameDocument = self.documentId == documentId
        reset(source: newSource, metadata: metadata, documentId: documentId)
        guard let oldSource, sameDocument, !oldSource.hasSameUTF16(as: newSource) else { return [] }

        let old = oldSource.utf16Units
        let new = newSource.utf16Units
        if let region {
            let oldRange = oldMap.sourceRange(
                forDisplayRange: NSRange(location: region.start, length: region.oldLength))
            let newRange = linkMap.sourceRange(
                forDisplayRange: NSRange(location: region.start, length: region.newLength))
            if Self.agree(old, new, outside: oldRange, newRange) {
                return SourceTextDiff.edits(from: old, oldRange, to: new, newRange)
            }
        }
        return SourceTextDiff.edits(
            from: old, NSRange(location: 0, length: old.count),
            to: new, NSRange(location: 0, length: new.count))
    }

    /// Whether the texts are the same before and after the two ranges.
    private static func agree(_ old: [UInt16], _ new: [UInt16], outside oldRange: NSRange, _ newRange: NSRange) -> Bool {
        guard oldRange.location == newRange.location,
              NSMaxRange(oldRange) <= old.count, NSMaxRange(newRange) <= new.count,
              old.count - NSMaxRange(oldRange) == new.count - NSMaxRange(newRange) else { return false }
        return old.withUnsafeBufferPointer { old in
            new.withUnsafeBufferPointer { new in
                func same(_ oldStart: Int, _ newStart: Int, _ count: Int) -> Bool {
                    guard count > 0, let oldBase = old.baseAddress, let newBase = new.baseAddress else { return true }
                    return memcmp(oldBase + oldStart, newBase + newStart, count * MemoryLayout<UInt16>.stride) == 0
                }
                return same(0, 0, oldRange.location)
                    && same(NSMaxRange(oldRange), NSMaxRange(newRange), old.count - NSMaxRange(oldRange))
            }
        }
    }
}

/// Small, predictable edits between two ranges of text: not the fewest characters
/// possible, but one edit for each place that changed.
enum SourceTextDiff {
    /// Last first, in the old text's coordinates.
    static func edits(
        from old: [UInt16], _ oldRange: NSRange, to new: [UInt16], _ newRange: NSRange
    ) -> [MarkdownSourceEdit] {
        var out: [MarkdownSourceEdit] = []
        append(old[oldRange.location..<NSMaxRange(oldRange)], new[newRange.location..<NSMaxRange(newRange)], to: &out)
        return out.reversed()
    }

    private static func append(
        _ old: ArraySlice<UInt16>, _ new: ArraySlice<UInt16>, to out: inout [MarkdownSourceEdit]
    ) {
        let (old, new) = trimmed(old, new)
        guard !old.isEmpty || !new.isEmpty else { return }

        // A change to several lines (a list, a quote, Replace All) is a change to each.
        let oldLines = lines(old)
        if oldLines.count > 1 {
            let newLines = lines(new)
            if oldLines.count == newLines.count {
                for (oldLine, newLine) in zip(oldLines, newLines) { append(oldLine, newLine, to: &out) }
                return
            }
        }

        // Text wrapped in markers, or unwrapped, keeps its identity.
        if let kept = firstOccurrence(of: old, in: new) {
            insert(new[new.startIndex..<kept.lowerBound], at: old.startIndex, to: &out)
            insert(new[kept.upperBound..<new.endIndex], at: old.endIndex, to: &out)
        } else if let kept = firstOccurrence(of: new, in: old) {
            delete(old.startIndex..<kept.lowerBound, to: &out)
            delete(kept.upperBound..<old.endIndex, to: &out)
        } else {
            appendByWord(old, new, to: &out)
        }
    }

    /// Several changes in a line (Replace All) are told apart by the words between them.
    private static func appendByWord(
        _ old: ArraySlice<UInt16>, _ new: ArraySlice<UInt16>, to out: inout [MarkdownSourceEdit]
    ) {
        let oldWords = words(old)
        let newWords = words(new)
        guard oldWords.count <= wordLimit, newWords.count <= wordLimit else {
            replace(old, with: new, to: &out)
            return
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newWords.difference(from: oldWords) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldWords.count || newIndex < newWords.count {
            let oldStart = oldIndex
            let newStart = newIndex
            while removed.contains(oldIndex) { oldIndex += 1 }
            while inserted.contains(newIndex) { newIndex += 1 }
            if oldIndex > oldStart || newIndex > newStart {
                let oldFrom = oldStart < oldWords.count ? oldWords[oldStart].startIndex : old.endIndex
                let oldTo = oldIndex < oldWords.count ? oldWords[oldIndex].startIndex : old.endIndex
                let newFrom = newStart < newWords.count ? newWords[newStart].startIndex : new.endIndex
                let newTo = newIndex < newWords.count ? newWords[newIndex].startIndex : new.endIndex
                replace(old[oldFrom..<oldTo], with: new[newFrom..<newTo], to: &out)
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
    }

    private static let wordLimit = 256

    /// Runs of letters and digits, and every other unit on its own (a surrogate
    /// counts as a letter, so a pair stays together).
    private static func words(_ text: ArraySlice<UInt16>) -> [ArraySlice<UInt16>] {
        var out: [ArraySlice<UInt16>] = []
        var start = text.startIndex
        for index in text.indices where !isWordUnit(text[index]) {
            if start < index { out.append(text[start..<index]) }
            out.append(text[index...index])
            start = index + 1
        }
        if start < text.endIndex { out.append(text[start..<text.endIndex]) }
        return out
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        guard unit < 0x80 else { return true }
        return (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func replace(
        _ old: ArraySlice<UInt16>, with new: ArraySlice<UInt16>, to out: inout [MarkdownSourceEdit]
    ) {
        out.append(MarkdownSourceEdit(
            range: NSRange(location: old.startIndex, length: old.count),
            replacement: String(decoding: new, as: UTF16.self)))
    }

    private static func insert(_ units: ArraySlice<UInt16>, at location: Int, to out: inout [MarkdownSourceEdit]) {
        guard !units.isEmpty else { return }
        out.append(MarkdownSourceEdit(
            range: NSRange(location: location, length: 0),
            replacement: String(decoding: units, as: UTF16.self)))
    }

    private static func delete(_ range: Range<Int>, to out: inout [MarkdownSourceEdit]) {
        guard !range.isEmpty else { return }
        out.append(MarkdownSourceEdit(
            range: NSRange(location: range.lowerBound, length: range.count), replacement: ""))
    }

    /// Without what both start and end with, never splitting a surrogate pair.
    private static func trimmed(
        _ old: ArraySlice<UInt16>, _ new: ArraySlice<UInt16>
    ) -> (ArraySlice<UInt16>, ArraySlice<UInt16>) {
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit, old[old.startIndex + prefix] == new[new.startIndex + prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old[old.startIndex + prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, old[old.endIndex - 1 - suffix] == new[new.endIndex - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old[old.endIndex - suffix]) { suffix -= 1 }
        return (old[(old.startIndex + prefix)..<(old.endIndex - suffix)],
                new[(new.startIndex + prefix)..<(new.endIndex - suffix)])
    }

    /// Each line with its line feed.
    private static func lines(_ text: ArraySlice<UInt16>) -> [ArraySlice<UInt16>] {
        var out: [ArraySlice<UInt16>] = []
        var start = text.startIndex
        for index in text.indices where text[index] == 0x0A {
            out.append(text[start...index])
            start = index + 1
        }
        if start < text.endIndex || out.isEmpty { out.append(text[start..<text.endIndex]) }
        return out
    }

    /// Bounded, so a large unrelated replacement isn't searched for itself.
    private static let searchLimit = 4096

    private static func firstOccurrence(of needle: ArraySlice<UInt16>, in text: ArraySlice<UInt16>) -> Range<Int>? {
        guard !needle.isEmpty, needle.count < text.count, text.count <= searchLimit else { return nil }
        for start in text.startIndex...(text.endIndex - needle.count)
        where text[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }
}

extension String {
    /// Compares UTF-16 units. Swift's `==` treats precomposed and decomposed accents
    /// as equal, so it misses an edit from one to the other.
    func hasSameUTF16(as other: String) -> Bool {
        (self as NSString).isEqual(to: other)
    }

    /// In one bulk copy: a bridged string hands its `utf16` view out one by one.
    var utf16Units: [UInt16] {
        let text = self as NSString
        var units = [UInt16](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: units.count))
        return units
    }
}
