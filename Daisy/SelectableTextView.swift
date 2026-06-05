//
//  SelectableTextView.swift
//  Daisy
//
//  Read-only NSTextView wrapped for SwiftUI. Reason this exists:
//  SwiftUI `Text(...).textSelection(.enabled)` inside a ScrollView on
//  macOS 26 only lets the user drag-select content within the current
//  viewport — anything that has scrolled out of view can't be reached
//  by a drag-extending selection, and ⌘A is similarly clipped.
//  Reported by Egor on 2026-05-25 on a 44-min transcript view:
//  "выделение работает только на то, что в первый экран попадает".
//
//  The workaround is to put the long text into the AppKit text system
//  via NSTextView, which has had proper full-content selection,
//  ⌘A / ⌘C / Find behaviour since the System 7 era. We size the
//  NSTextView intrinsically based on its content so it embeds cleanly
//  inside a SwiftUI ScrollView — outer scrolling is owned by SwiftUI,
//  the NSTextView itself doesn't scroll, it just lays out tall.
//
//  Read-only: `isEditable = false` blocks the user from typing into
//  the transcript by accident. `isSelectable = true` keeps selection
//  + copy + Find Bar working. Background draw is off so the view
//  inherits whatever SwiftUI background sits behind it.
//

import AppKit
import SwiftUI

struct SelectableTextView: NSViewRepresentable {

    let text: String
    let font: NSFont

    init(_ text: String, font: NSFont = NSFont.preferredFont(forTextStyle: .body)) {
        self.text = text
        self.font = font
    }

    /// Build the display string. The transcript body is markdown whose only
    /// inline markup is `**bold**` around the `[time · speaker]` labels
    /// (see MarkdownExporter). We render those as real bold and DROP the
    /// `**` markers, preserving every newline — so the in-app transcript
    /// reads cleanly instead of showing literal asterisks, while the on-disk
    /// .md and the Copy button keep the markdown form. Implementation: split
    /// on `**` and bold the odd-index pieces (the exporter always emits
    /// balanced pairs, so the marker count is even and parity is stable).
    /// `enumerated()` indices come before the empty-skip, so parity holds.
    private func attributedText() -> NSAttributedString {
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: boldFont, .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString()
        for (i, part) in text.components(separatedBy: "**").enumerated() where !part.isEmpty {
            result.append(NSAttributedString(string: part, attributes: i.isMultiple(of: 2) ? normal : bold))
        }
        return result
    }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.font = font
        tv.textColor = .labelColor
        // Strict SwiftUI-driven sizing: NSTextView never tries to
        // grow itself, the height is exactly what `sizeThatFits`
        // returns. With `isVerticallyResizable = true` AppKit
        // could lay out tall content that didn't fit the SwiftUI
        // frame, which made the transcript visually overflow the
        // outer CollapsibleBlock's rounded background (last few
        // lines drawn past the bottom border, no parent clip).
        // false + a precise sizeThatFits gives the parent block a
        // height that always matches what we actually draw.
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        // Zero out the lineFragmentPadding so left edge aligns with
        // whatever container the view sits in (matches SwiftUI Text
        // baseline, no surprise indent).
        tv.textContainer?.lineFragmentPadding = 0
        // CRITICAL — horizontal-spill fix (2026-06-05). AppKit defaults
        // `widthTracksTextView` to TRUE, which forces the text container's
        // width to equal the NSTextView's *frame* width and SILENTLY
        // ignores the `containerSize.width` we compute in `sizeThatFits`.
        // On macOS 26 the frame width lags the SwiftUI-proposed width by a
        // layout pass, so the text wrapped to a stale/too-wide frame and
        // each line's tail drew past the card's right edge in the Library
        // transcript (the long-standing "text spills out of the container"
        // bug). FALSE makes our manual `containerSize.width` authoritative,
        // so the text wraps to exactly the width we derive from the SwiftUI
        // proposal — never wider than the card. (Past fixes only touched
        // the height path, which is why this kept coming back.)
        tv.textContainer?.widthTracksTextView = false
        // Tall vertical container — sized for real on layout pass via
        // sizeThatFits below. Width gets pinned by the SwiftUI layout.
        tv.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        // 1.0.7.1 — enable Find Bar so ⌘F works inside long transcripts.
        // Mac users expect this on any sufficiently text-heavy surface;
        // SwiftUI Text has no equivalent.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // Bold the `**…**` labels (markers stripped) — see attributedText().
        tv.textStorage?.setAttributedString(attributedText())
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        // Compare against the rendered (marker-stripped) plain text so we
        // only rebuild when content or font actually changed.
        let renderedPlain = text.replacingOccurrences(of: "**", with: "")
        if nsView.string != renderedPlain || nsView.font != font {
            nsView.font = font
            nsView.textStorage?.setAttributedString(attributedText())
            // Force layout-manager flush so the next sizeThatFits call reads
            // a fresh usedRect (otherwise a transcript that grew mid-session
            // — e.g. live append — could measure against stale glyph ranges
            // and underflow).
            if let lm = nsView.layoutManager, let tc = nsView.textContainer {
                lm.ensureLayout(for: tc)
            }
            nsView.invalidateIntrinsicContentSize()
        }
    }

    /// Intrinsic sizing — tell SwiftUI how tall to make us for a given
    /// proposed width. Without this the NSTextView gets a default
    /// height and scrolls internally (bad — we want the outer ScrollView
    /// to scroll). Computes the actual laid-out glyph rect for the
    /// proposed width, returns that height. Runs on each layout pass
    /// the parent makes; cost is one glyph layout per resize event.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        guard let container = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }
        container.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        // `ensureLayout` forces the layout manager to *complete*
        // layout for the entire container (not just generate glyph
        // ranges). `glyphRange` alone left the trailing paragraph
        // un-laid-out on long transcripts, so usedRect reported a
        // height shorter than what NSTextView actually drew — the
        // last few lines fell outside the SwiftUI frame and
        // visually spilled below the outer CollapsibleBlock's
        // rounded background.
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        // Pad by a FULL line height (was +2). On macOS 26 the TK1
        // `usedRect` can under-report the trailing line fragment by ~one
        // row, so NSTextView draws one line past the height SwiftUI gives
        // the parent CollapsibleBlock → the last transcript line spilled
        // below the card's rounded background (Egor, 2026-06-04). A full
        // line of slack guarantees the card always covers the drawn text;
        // worst case it's one row of bottom breathing room — harmless in a
        // reader. (Proper long-term fix: measure via TextKit 2
        // `usageBoundsForTextContainer`; deferred — needs on-device check.)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        return CGSize(width: width, height: ceil(used.height) + ceil(lineHeight))
    }
}
