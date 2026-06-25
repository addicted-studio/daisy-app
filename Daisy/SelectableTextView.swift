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
//  2026-06-12 — second mode: `init(attributed:)` renders a pre-built
//  NSAttributedString verbatim. Used by the summary card, which had the
//  same class of bug as the transcript (a stack of separate SwiftUI
//  `Text` views — lede / headers / each bullet — so selection couldn't
//  cross view boundaries; Egor flagged it as a release blocker). The
//  card builds one fully-styled string via
//  `summaryAttributedString(_:compact:)` (bottom of this file) and both
//  modes share the same makeNSView / updateNSView / sizeThatFits.
//

import AppKit
import SwiftUI

struct SelectableTextView: NSViewRepresentable {

    let text: String
    let font: NSFont
    /// Non-nil ⇒ attributed mode: render this exact string (summary
    /// card). nil ⇒ markdown mode: render `text` through
    /// `attributedText()` below (transcript). See `displayString()`.
    let attributed: NSAttributedString?

    init(_ text: String, font: NSFont = NSFont.preferredFont(forTextStyle: .body)) {
        self.text = text
        self.font = font
        self.attributed = nil
    }

    /// Attributed mode — the caller owns ALL styling (fonts, colours,
    /// paragraph styles). `text` mirrors the plain characters so any
    /// string-based introspection keeps working; `font` stays the body
    /// default and is only used for the one-line measurement slack in
    /// `sizeThatFits` (the storage's real fonts come from the
    /// attributed string itself).
    init(attributed: NSAttributedString) {
        self.text = attributed.string
        self.font = NSFont.preferredFont(forTextStyle: .body)
        self.attributed = attributed
    }

    /// What actually lands in the text storage: the caller-supplied
    /// attributed string, or the markdown-rendered transcript. The
    /// markdown path (`attributedText()`) is untouched by the
    /// attributed mode — both converge here only.
    private func displayString() -> NSAttributedString {
        attributed ?? Self.renderMarkdown(text, font: font)
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
    static func renderMarkdown(_ text: String, font: NSFont) -> NSAttributedString {
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
        /// Attributed-mode gate — the summary card rebuilds its
        /// NSAttributedString on every SwiftUI body pass, so we keep the
        /// last rendered one and compare by equality (characters AND
        /// attributes) before touching the text storage.
        var lastAttributed: NSAttributedString?
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
        // Markdown mode renders headings/quotes/bold with markers
        // stripped (see attributedText()); attributed mode takes the
        // caller's string verbatim. Record what we rendered for the
        // update gate.
        tv.textStorage?.setAttributedString(displayString())
        context.coordinator.lastText = text
        context.coordinator.lastFont = font
        context.coordinator.lastAttributed = attributed
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        // Rebuild only on a REAL change. Markdown mode compares the
        // source text + font (see Coordinator for why we don't compare
        // nsView.string/font). Attributed mode compares the attributed
        // strings themselves by equality — the caller re-derives the
        // value each body pass, so identity is useless but equality
        // (characters + attributes) is exact.
        if let attributed {
            guard context.coordinator.lastAttributed != attributed else { return }
        } else {
            guard context.coordinator.lastText != text
                || context.coordinator.lastFont != font else { return }
        }
        context.coordinator.lastText = text
        context.coordinator.lastFont = font
        context.coordinator.lastAttributed = attributed
        nsView.font = font
        nsView.textStorage?.setAttributedString(displayString())
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

// MARK: - Scrollable transcript view (long transcripts)

/// Scrollable variant for LONG transcripts. `SelectableTextView` sizes a
/// bare NSTextView to its FULL intrinsic height so the outer SwiftUI
/// ScrollView owns scrolling — but on a 50-min, ~900-segment transcript
/// the laid-out height runs to tens of thousands of points and hits
/// AppKit's max view/layer height (~16k pt): the bottom is clipped with
/// no way to scroll to it (Egor, 2026-06-16). Here the NSTextView lives
/// inside its OWN NSScrollView and scrolls internally — TextKit lays the
/// text out lazily, so any length renders. The caller bounds the pane
/// height via `.frame`. Selection + ⌘F still span the whole transcript
/// (one text storage). Reuses `SelectableTextView.renderMarkdown`.
struct ScrollableTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    /// Non-nil ⇒ attributed mode (summary card): render this exact string.
    /// nil ⇒ markdown mode (transcript / follow-up): render `text` through
    /// `SelectableTextView.renderMarkdown`. Mirrors `SelectableTextView`.
    let attributed: NSAttributedString?
    /// Self-sizing cap (2026-06-25). `nil` = no intrinsic size: the caller
    /// bounds the pane with `.frame` (the Transcript block does this with a
    /// fixed 600pt). Non-nil = the pane sizes to its CONTENT up to this many
    /// points, then scrolls internally past it. Used by the Summary + Follow-
    /// up cards so short content sits flush (no empty pane) while long content
    /// stops clipping. Robust where `SelectableTextView` is not: even if the
    /// macOS-26 `usedRect` measurement under-reports, the inner NSTextView is
    /// `isVerticallyResizable` and lays out to the TRUE content height, so the
    /// internal scroller always reaches the real bottom — no unscrollable clip.
    var maxHeight: CGFloat?

    init(
        _ text: String,
        font: NSFont = NSFont.preferredFont(forTextStyle: .body),
        maxHeight: CGFloat? = nil
    ) {
        self.text = text
        self.font = font
        self.attributed = nil
        self.maxHeight = maxHeight
    }

    init(attributed: NSAttributedString, maxHeight: CGFloat? = nil) {
        self.text = attributed.string
        self.font = NSFont.preferredFont(forTextStyle: .body)
        self.attributed = attributed
        self.maxHeight = maxHeight
    }

    private func displayString() -> NSAttributedString {
        attributed ?? SelectableTextView.renderMarkdown(text, font: font)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var lastText: String?
        var lastFont: NSFont?
        var lastAttributed: NSAttributedString?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textColor = .labelColor
        tv.font = font
        tv.textContainerInset = .zero
        // Standard scrollable-NSTextView setup: the view grows vertically
        // to fit content inside the scroll view's clip view, width tracks
        // the visible content width so text wraps to the pane.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // ⌘F Find Bar inside long transcripts, same as SelectableTextView.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textStorage?.setAttributedString(displayString())

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        context.coordinator.lastText = text
        context.coordinator.lastFont = font
        context.coordinator.lastAttributed = attributed
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Rebuild only on a real change. Attributed mode (summary) re-derives
        // the string each body pass, so compare by equality; markdown mode
        // (transcript / follow-up) compares source text + font.
        if let attributed {
            guard context.coordinator.lastAttributed != attributed else { return }
        } else {
            guard context.coordinator.lastText != text
                || context.coordinator.lastFont != font else { return }
        }
        context.coordinator.lastText = text
        context.coordinator.lastFont = font
        context.coordinator.lastAttributed = attributed
        tv.font = font
        tv.textStorage?.setAttributedString(displayString())
    }

    /// Self-sizing for the capped (Summary / Follow-up) case. Returns `nil`
    /// when `maxHeight` is unset so the unbounded caller (Transcript) keeps
    /// owning the pane height via its own `.frame`. Otherwise measures the
    /// laid-out content at the proposed width and returns `min(content, cap)`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let maxHeight else { return nil }
        guard let width = proposal.width, width > 0,
              let tv = nsView.documentView as? NSTextView,
              let container = tv.textContainer,
              let layoutManager = tv.layoutManager else { return nil }
        // widthTracksTextView == true → the container's wrap width follows the
        // text view's frame width, so set the frame to the proposed width
        // before measuring (otherwise we'd measure against a stale wrap).
        if abs(tv.frame.width - width) > 0.5 {
            tv.frame.size.width = width
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        // One line of slack — macOS-26 TK1 can under-report the trailing
        // fragment (same note as SelectableTextView.sizeThatFits).
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let content = ceil(used.height) + ceil(lineHeight)
        return CGSize(width: width, height: min(content, maxHeight))
    }
}

// MARK: - Summary → attributed string

/// Render a `MeetingSummary` into ONE attributed string for
/// `SelectableTextView(attributed:)`. The summary card used to be a stack
/// of independent SwiftUI `Text` views (lede, each section header, every
/// bullet and action item its own view) and macOS text selection cannot
/// cross view boundaries — drag-select / ⌘A topped out at a single line
/// (Egor, 2026-06-12, release blocker). One NSTextView over one attributed
/// string gives whole-card selection — the same fix the transcript got on
/// 2026-05-25 (see file header).
///
/// Mirrors the old SwiftUI card 1:1 in content, order and hierarchy:
/// Meeting lede → topical sections (hierarchical bullets) → Next actions
/// (☐ rows, mirroring the old `square` SF-symbol checkboxes) → Follow-up
/// draft. Structural headers come from `SummaryLabels`, localised to the
/// summary's own language via the same content sniffing the card used.
/// Legacy summaries (`sections == []`) keep the pre-1.0.2 paragraph
/// fallback. Empty `actionItems` / `clientFollowUp` blocks are skipped,
/// exactly like the old conditional sections.
///
/// `compact: false` = History detail document (`.body` text, `.title3`
/// headers, 22pt per nesting level — the old `bulletTree` constants).
/// `compact: true` = menu-bar popover (`.callout` text, `.subheadline`
/// headers, 18pt per level — the old `homeBulletTree` constants).
///
/// Block gaps are expressed through paragraphSpacing(Before), NOT blank
/// lines, so copying the whole card yields clean text with no stray empty
/// paragraphs. Bullet rows are "•\t<text>" with a hanging indent — wrapped
/// lines align under the text, not under the marker. Only semantic colours
/// (label / secondaryLabel / tertiaryLabel) so the forced-darkAqua
/// appearance renders them correctly.
@MainActor
func summaryAttributedString(_ summary: MeetingSummary, compact: Bool) -> NSAttributedString {
    // Typography — NSFont equivalents of the SwiftUI styles the card used.
    let bodyFont = NSFont.preferredFont(forTextStyle: compact ? .callout : .body)
    let headerBase = NSFont.preferredFont(forTextStyle: compact ? .subheadline : .title3)
    let headerFont = NSFont.systemFont(ofSize: headerBase.pointSize, weight: .semibold)
    // Top-level bullet markers were semibold in the SwiftUI tree.
    let topMarkerFont = NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold)

    // Layout constants — same numbers the old SwiftUI stacks used
    // (rowSpacing / bulletSpacing / childIndent / inter-section VStack
    // spacing in SessionDetailView resp. ContentView).
    let indentStep: CGFloat = compact ? 18 : 22   // per bullet nesting level
    let markerGap: CGFloat = compact ? 8 : 10     // marker glyph → text gap
    let rowGap: CGFloat = compact ? 4 : 6         // between rows in a block
    let blockGap: CGFloat = compact ? 16 : 18     // between blocks
    let headerGap: CGFloat = compact ? 8 : 10     // header → its content

    // Structural-header language — same trick as the old
    // `SessionDetailView.summaryLabels(for:)`: sniff the lede, padded
    // with the first bullet when the lede alone is too short for
    // NLLanguageRecognizer. Unknown / low confidence → English labels.
    var sample = summary.summary
    if sample.count < 60, let firstBullet = summary.sections.first?.bullets.first?.text {
        sample += " " + firstBullet
    }
    let labels = SummaryLabels.for(language: LanguageDetector.detect(sample))

    let result = NSMutableAttributedString()

    func paragraphStyle(
        spacingBefore: CGFloat,
        spacing: CGFloat,
        level: Int = 0,
        hangingIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = CGFloat(level) * indentStep
        ps.headIndent = ps.firstLineHeadIndent + hangingIndent
        if hangingIndent > 0 {
            // Marker rows are "•\t<text>" — this tab stop lands the text
            // exactly on headIndent, so wrapped lines align under the
            // TEXT, not under the marker.
            ps.tabStops = [NSTextTab(textAlignment: .left, location: ps.headIndent, options: [:])]
        }
        ps.paragraphSpacingBefore = spacingBefore
        ps.paragraphSpacing = spacing
        return ps
    }

    /// Append one paragraph built from styled runs. The separating "\n"
    /// goes in BEFORE the new paragraph, carrying the PREVIOUS
    /// paragraph's attributes (a newline belongs to the paragraph it
    /// terminates) — so the result never ends in a trailing newline,
    /// which NSTextView would lay out as a phantom empty last line and
    /// inflate the measured height.
    func appendParagraph(_ runs: [(String, [NSAttributedString.Key: Any])]) {
        if result.length > 0 {
            let prev = result.attributes(at: result.length - 1, effectiveRange: nil)
            result.append(NSAttributedString(string: "\n", attributes: prev))
        }
        for (string, attrs) in runs where !string.isEmpty {
            result.append(NSAttributedString(string: string, attributes: attrs))
        }
    }

    func appendHeader(_ title: String) {
        // blockGap minus the preceding row's own paragraphSpacing, so the
        // VISIBLE gap between blocks matches the old VStack spacing
        // exactly (spacing between paragraphs = prev.paragraphSpacing +
        // next.paragraphSpacingBefore). First block starts flush.
        let before = result.length == 0 ? 0 : max(0, blockGap - rowGap)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(spacingBefore: before, spacing: headerGap),
        ]
        appendParagraph([(title, attrs)])
    }

    /// Plain paragraph block (lede / follow-up draft). Inner "\n"s in the
    /// source text keep this one style per paragraph — the model's
    /// multi-paragraph follow-ups get rowGap spacing between paragraphs.
    func appendBody(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(spacingBefore: 0, spacing: rowGap),
        ]
        appendParagraph([(text, attrs)])
    }

    /// "<marker>\t<text>" row with a hanging indent.
    func appendMarkerRow(
        marker: String,
        markerFont: NSFont,
        markerColor: NSColor,
        text: String,
        level: Int
    ) {
        // Measure the actual marker glyph so the tab stop clears it at
        // any text size, then add the same marker→text gap the HStacks
        // used (`bulletSpacing`).
        let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: markerFont]).width)
        let ps = paragraphStyle(
            spacingBefore: 0,
            spacing: rowGap,
            level: level,
            hangingIndent: markerWidth + markerGap
        )
        appendParagraph([
            (marker + "\t", [.font: markerFont, .foregroundColor: markerColor, .paragraphStyle: ps]),
            (text, [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: ps]),
        ])
    }

    /// Recursive bullets — same depth styling the SwiftUI tree had: the
    /// top level gets a darker semibold mid-dot, deeper levels lighter
    /// tertiary dots, so the eye reads indentation as semantic depth.
    func appendBullets(_ bullets: [SummaryBullet], level: Int) {
        for bullet in bullets {
            appendMarkerRow(
                marker: "•",
                markerFont: level == 0 ? topMarkerFont : bodyFont,
                markerColor: level == 0 ? .secondaryLabelColor : .tertiaryLabelColor,
                text: bullet.text,
                level: level
            )
            if !bullet.children.isEmpty {
                appendBullets(bullet.children, level: level + 1)
            }
        }
    }

    // Assembly — mirrors the old card's order and conditionals.

    if summary.sections.isEmpty {
        // Legacy pre-1.0.2 summary: full paragraph under "Meeting",
        // shown even when other blocks are empty (old behaviour).
        appendHeader(labels.meeting)
        appendBody(summary.summary)
    } else {
        if !summary.summary.isEmpty {
            appendHeader(labels.meeting)
            appendBody(summary.summary)
        }
        for section in summary.sections {
            appendHeader(section.title)
            appendBullets(section.bullets, level: 0)
        }
    }
    if !summary.actionItems.isEmpty {
        appendHeader(labels.nextActions)
        for item in summary.actionItems {
            // ☐ mirrors the old `square` SF-symbol checkbox rows; owner
            // prefixes (if any) are part of the item text itself.
            appendMarkerRow(
                marker: "☐",
                markerFont: bodyFont,
                markerColor: .tertiaryLabelColor,
                text: item,
                level: 0
            )
        }
    }
    if !summary.clientFollowUp.isEmpty {
        appendHeader(labels.followUp)
        appendBody(summary.clientFollowUp)
    }
    return result
}
