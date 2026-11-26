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
}
