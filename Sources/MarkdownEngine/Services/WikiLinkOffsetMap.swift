//
//  WikiLinkOffsetMap.swift
//  MarkdownEngine
//
//  Offsets between the display text and the source (storage) text. They agree
//  everywhere except inside and after links whose `|<id>` the display hides, or
//  whose name it shows as the target's current one.
//

import Foundation

struct WikiLinkOffsetMap {
    private struct Link {
        let display: NSRange
        let source: NSRange
        /// Lengths of `[[Name` or `![[Name`, which the two forms can spell differently.
        let displayPrefix: Int
        let sourcePrefix: Int
    }

    private let links: [Link]

    init(_ metadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata]) {
        links = metadata.map { key, value in
            let hidden = value.id.map { $0.isEmpty ? 0 : $0.utf16.count + 1 } ?? 0
            return Link(
                display: NSRange(location: key.location, length: key.length),
                source: value.storageRange,
                displayPrefix: key.length - 2,
                sourcePrefix: value.storageRange.length - 2 - hidden
            )
        }
        .sorted { $0.display.location < $1.display.location }
    }

    func sourceRange(forDisplayRange range: NSRange) -> NSRange {
        let start = sourceOffset(forDisplayOffset: range.location)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = sourceOffset(forDisplayOffset: NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }

    func displayRange(forSourceRange range: NSRange) -> NSRange {
        let start = displayOffset(forSourceOffset: range.location)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = displayOffset(forSourceOffset: NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }

    func sourceOffset(forDisplayOffset offset: Int) -> Int {
        // The last link starting before the offset holds it or precedes it.
        guard let link = lastLink(where: { $0.display.location < offset }) else { return offset }
        let fromEnd = NSMaxRange(link.display) - offset
        // After the link (zero or less), or between its closing brackets.
        if fromEnd < 2 { return NSMaxRange(link.source) - fromEnd }
        let inLink = offset - link.display.location
        // The end of the name is the end of the name, however long it is.
        return link.source.location
            + (inLink >= link.displayPrefix ? link.sourcePrefix : min(inLink, link.sourcePrefix))
    }

    func displayOffset(forSourceOffset offset: Int) -> Int {
        guard let link = lastLink(where: { $0.source.location < offset }) else { return offset }
        let fromEnd = NSMaxRange(link.source) - offset
        if fromEnd < 2 { return NSMaxRange(link.display) - fromEnd }
        let inLink = offset - link.source.location
        return link.display.location
            + (inLink >= link.sourcePrefix ? link.displayPrefix : min(inLink, link.displayPrefix))
    }

    private func lastLink(where precedes: (Link) -> Bool) -> Link? {
        var low = 0
        var high = links.count
        while low < high {
            let middle = (low + high) / 2
            if precedes(links[middle]) { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? links[low - 1] : nil
    }
}
