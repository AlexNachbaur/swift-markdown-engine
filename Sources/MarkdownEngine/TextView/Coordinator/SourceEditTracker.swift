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
    typealias LinkMetadata = [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata]

    /// The source text as of the last reported change.
    private(set) var source: String?
    private(set) var documentId: String?
    private var metadata: LinkMetadata = [:]
    private var cachedLinkMap: WikiLinkOffsetMap?

    /// The display region changed since the last report.
    private var changed: DisplayEditRegion?

    var hasUnreportedEdits: Bool { changed != nil }

    /// Where the display text changed since the last report, as it is now, and by
    /// how much its length changed.
    var unreportedDisplayEdit: (range: NSRange, delta: Int)? {
        changed.map { (NSRange(location: $0.start, length: $0.newLength), $0.delta) }
    }

    /// The map of the last reported text. Built when something asks for it.
    var linkMap: WikiLinkOffsetMap {
        if let cachedLinkMap { return cachedLinkMap }
        let map = WikiLinkOffsetMap(metadata)
        cachedLinkMap = map
        return map
    }

    /// Notes one round of `NSTextStorage` editing.
    func noteStorageEdit(editedRange: NSRange, changeInLength delta: Int) {
        changed = .adding(editedRange: editedRange, changeInLength: delta, to: changed)
    }

    /// Takes a text as the last reported one, without saying how it came about.
    func reset(source: String, metadata: LinkMetadata, documentId: String?) {
        self.source = source
        self.metadata = metadata
        self.documentId = documentId
        cachedLinkMap = nil
        changed = nil
    }

    /// The next report starts over.
    func forget() { source = nil }

    /// The edits from the last reported source text to `newSource`, which becomes
    /// the last reported one.
    func takeEdits(to newSource: String, metadata newMetadata: LinkMetadata) -> [MarkdownSourceEdit] {
        let oldSource = source ?? ""
        let region = changed
        let sameText = oldSource.hasSameUTF16(as: newSource)
        let oldMap = sameText || region == nil ? nil : linkMap
        reset(source: newSource, metadata: newMetadata, documentId: documentId)
        guard !sameText else { return [] }

        let old = oldSource.utf16Units
        let new = newSource.utf16Units
        if let region, let oldMap {
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
    private static func agree(
        _ old: [UInt16], _ new: [UInt16], outside oldRange: NSRange, _ newRange: NSRange
    ) -> Bool {
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
