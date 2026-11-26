//
//  DisplayEditRegion.swift
//  MarkdownEngine
//
//  Where the display text changed: one region that covers every change, given
//  as where it was before and where it is now.
//

import Foundation

/// Where the display text changed over rounds of `NSTextStorage` editing: where it
/// was before, and where it is now. Both start at the same offset.
struct DisplayEditRegion {
    let start: Int
    let oldLength: Int
    let newLength: Int

    var delta: Int { newLength - oldLength }

    /// `region` with one more round of editing in it.
    static func adding(editedRange: NSRange, changeInLength delta: Int, to region: Self?) -> Self? {
        let location = editedRange.location
        let priorLength = editedRange.length - delta
        guard location != NSNotFound, priorLength >= 0 else { return region }
        guard let current = region else {
            return Self(start: location, oldLength: priorLength, newLength: editedRange.length)
        }
        let start = min(current.start, location)
        let priorEnd = max(current.start + current.newLength, location + priorLength)
        let priorUnion = priorEnd - start
        return Self(start: start, oldLength: current.oldLength + priorUnion - current.newLength, newLength: priorUnion + delta)
    }

    /// What differs between two texts: everything but what they start and end with.
    static func between(_ old: String, _ new: String) -> Self {
        let old = old as NSString
        let new = new as NSString
        let shorter = min(old.length, new.length)
        let prefix = sharedLength(old, new, upTo: shorter, fromEnd: false)
        let suffix = sharedLength(old, new, upTo: shorter - prefix, fromEnd: true)
        return Self(start: prefix, oldLength: old.length - prefix - suffix, newLength: new.length - prefix - suffix)
    }

    /// How many UTF-16 units two texts share at their start or end, at most `limit`,
    /// compared a block at a time instead of copying both whole.
    private static func sharedLength(_ a: NSString, _ b: NSString, upTo limit: Int, fromEnd: Bool) -> Int {
        let block = 4096
        var left = [unichar](repeating: 0, count: block)
        var right = [unichar](repeating: 0, count: block)
        var shared = 0
        while shared < limit {
            let count = min(block, limit - shared)
            a.getCharacters(&left, range: NSRange(location: fromEnd ? a.length - shared - count : shared, length: count))
            b.getCharacters(&right, range: NSRange(location: fromEnd ? b.length - shared - count : shared, length: count))
            if memcmp(left, right, count * MemoryLayout<unichar>.stride) == 0 {
                shared += count
                continue
            }
            for i in 0..<count {
                let index = fromEnd ? count - 1 - i : i
                if left[index] != right[index] { break }
                shared += 1
            }
            return shared
        }
        return shared
    }

    /// Where a range of the text before is now, unless the edits reached it.
    func moved(_ range: NSRange) -> NSRange? {
        if NSMaxRange(range) <= start { return range }
        guard range.location >= start + oldLength else { return nil }
        return NSRange(location: range.location + delta, length: range.length)
    }
}
