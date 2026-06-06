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

    /// Build the display string. The transcript body is lightweight markdown
    /// (see MarkdownExporter): document-level `#`/`##`/`###` headings, `>`
    /// block-quotes, and inline `**bold**` around the `[time · speaker]`
    /// labels. We render headings as larger bold text, block-quotes in a
    /// secondary colour, and the inline `**…**` as real bold — DROPPING every
    /// marker so the in-app transcript reads like a formatted document
    /// instead of showing literal `#`, `>` and `*` characters. The on-disk
    /// .md and the Copy button keep the raw markdown form.
    ///
    /// Done line-by-line: the heading/quote prefix is matched per line, and
    /// `**` parity is evaluated WITHIN each line (the exporter emits balanced
    /// pairs per line, so the odd-index pieces are the bold ones). Fonts are
    /// computed once up front, not per line.
    private func attributedText() -> NSAttributedString {
        let bodyBold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        func sized(_ scale: CGFloat) -> NSFont {
            NSFont(descriptor: bodyBold.fontDescriptor, size: font.pointSize * scale) ?? bodyBold
        }
        let h1 = sized(1.5), h2 = sized(1.28), h3 = sized(1.13)

        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (idx, rawLine) in lines.enumerated() {
            var content = rawLine
            var lineFont = font
            var lineBoldFont = bodyBold
            var wholeLineBold = false
            var color = NSColor.labelColor

            // Line-level markdown: strip the marker, style the whole line.
            // Longer prefixes are tested first so `##` doesn't match as `#`.
            if content.hasPrefix("### ") {
                content = String(content.dropFirst(4)); lineFont = h3; lineBoldFont = h3; wholeLineBold = true
            } else if content.hasPrefix("## ") {
                content = String(content.dropFirst(3)); lineFont = h2; lineBoldFont = h2; wholeLineBold = true
            } else if content.hasPrefix("# ") {
                content = String(content.dropFirst(2)); lineFont = h1; lineBoldFont = h1; wholeLineBold = true
            } else if content.hasPrefix("> ") {
                content = String(content.dropFirst(2)); color = .secondaryLabelColor
            } else if content == ">" {
                content = ""; color = .secondaryLabelColor
            } else {
                // Bullets / checkboxes / images (present when the body
                // carries an AI summary or screenshots). Transcript lines
                // start with "[time · speaker]" and pass through untouched.
                content = Self.renderListMarkers(content)
            }

            let normalAttrs: [NSAttributedString.Key: Any] = [.font: lineFont, .foregroundColor: color]
            let boldAttrs: [NSAttributedString.Key: Any] = [.font: lineBoldFont, .foregroundColor: color]
            for (i, seg) in content.components(separatedBy: "**").enumerated() where !seg.isEmpty {
                let useBold = wholeLineBold || !i.isMultiple(of: 2)
                result.append(NSAttributedString(string: seg, attributes: useBold ? boldAttrs : normalAttrs))
            }
            // Re-insert the newline between lines (base font keeps inter-line
            // spacing uniform even after a large heading).
            if idx < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        return result
    }

    /// Convert markdown list/image markers to glyphs, preserving indentation:
    /// `- [ ] x`→`☐ x`, `- [x] x`→`☑ x`, `- x`→`• x`, `![alt](url)`→`🖼 alt`.
    /// Any other line is returned unchanged. Inline `**bold**` is applied by
    /// the caller afterwards. (The on-disk .md keeps the raw markers.)
    private static func renderListMarkers(_ line: String) -> String {
        let spaceCount = line.prefix(while: { $0 == " " }).count
        let indent = String(repeating: " ", count: spaceCount)
        let rest = String(line.dropFirst(spaceCount))
        if rest.hasPrefix("- ") {
            let item = String(rest.dropFirst(2))
            if item.hasPrefix("[ ] ") { return indent + "☐ " + String(item.dropFirst(4)) }
            if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { return indent + "☑ " + String(item.dropFirst(4)) }
            return indent + "• " + item
        }
        if rest.hasPrefix("!["), let bracket = rest.firstIndex(of: "]") {
            let alt = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<bracket])
            return indent + (alt.isEmpty ? "🖼" : "🖼 " + alt)
        }
        return line
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Remembers the last source text + font actually rendered, so
    /// `updateNSView` rebuilds only on a real change. We deliberately do NOT
    /// gate on `nsView.string`/`nsView.font`: once the text storage holds
    /// mixed fonts (headings + body), AppKit's `NSTextView.font` getter
    /// returns nil, which would never equal the base `font` and force a full
    /// attributed rebuild on every layout pass of a long transcript.
    final class Coordinator {
        var lastText: String?
        var lastFont: NSFont?
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
        // Render markdown (headings/quotes/bold, markers stripped) — see
        // attributedText(). Record what we rendered for the update gate.
        tv.textStorage?.setAttributedString(attributedText())
        context.coordinator.lastText = text
        context.coordinator.lastFont = font
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        // Rebuild only when the SOURCE text or font actually changed — see
        // Coordinator for why we don't compare nsView.string/font.
        guard context.coordinator.lastText != text
            || context.coordinator.lastFont != font else { return }
        context.coordinator.lastText = text
        context.coordinator.lastFont = font
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
