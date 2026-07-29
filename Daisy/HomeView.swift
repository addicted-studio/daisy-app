//
//  HomeView.swift
//  Daisy
//
//  Primary "landing" view that opens when the user clicks the Dock
//  icon. A calm hub: a serif greeting, today's agenda (DayCard), usage
//  stats, and the last few recordings. Recording itself is driven by the
//  persistent RecordCapsule / hotkey, not a button here.
//

import AppKit
import EventKit
import SwiftUI

struct HomeView: View {
    @Bindable var session: RecordingSession
    @Bindable var store = SessionStore.shared
    @Bindable var usage = UsageStats.shared
    /// Token spend per connected API — see TokenLedger. Observable so the
    /// card updates the moment a summary comes back.
    @Bindable var tokens = TokenLedger.shared
    /// Which provider is selected right now; the tokens card leads with
    /// its number when it has spend this month.
    @Bindable var summarizer = Summarizer.shared
    @Bindable var nav = AppNavigation.shared
    @Bindable var calendar = CalendarService.shared
    /// Observe Google OAuth state so the upcoming-events section
    /// re-renders when the user connects/disconnects Google in
    /// Settings. Without this binding the switch below stays
    /// on the Apple-Calendar-only path and visibly hides events
    /// even though `calendar.upcomingEvents` was just populated
    /// by the Google fetch.
    @Bindable var folders = FolderStore.shared
    @Bindable var integrationStore = MCPIntegrationStore.shared
    @Bindable private var permissions = SystemPermissions.shared
    /// Read-through to the session's settings — the destinations
    /// hint uses `hasNotionCredentials`. Done as a computed
    /// passthrough rather than a separate @Bindable property so
    /// we don't accept two settings sources of truth.
    private var settings: AppSettings { session.settings }

    /// Persisted "Don't show again" for the onboarding checklist — set from
    /// the dismiss button, which only appears once the required permissions
    /// are granted. Hides the block for good on Home.
    @AppStorage("daisy.onboardingDismissed") private var onboardingDismissed = false

    /// Free space on the volume recordings land on, re-read on appear and
    /// on every foreground activation. nil until the first read — treated
    /// as "plenty", so a failed stat never invents a warning.
    @State private var freeDiskBytes: Int64?


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcomeHeader
                // Permissions moved from a full-width top banner into the
                // onboarding checklist that sits above the day card in the
                // right column (2026-07-21) — a calmer "finish setting up"
                // block instead of an alarm bar.
                homeColumns
                if showDestinationsHint { destinationsHint }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            // Cap the content column and centre it, instead of stretching
            // edge-to-edge on wide windows. Was 720 to match the grouped-Form
            // pages; widened to 1040 so the stats row (words/min · total
            // words · activity heatmap) fits on ONE line with the 26-week
            // heatmap taking half the width (Egor, 2026-07-14).
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            await store.refresh()
            // Rebuild the open-items list now that the session corpus is
            // loaded. MorningBriefStore.prepare also rebuilds, but the day
            // card's own `.task` can fire before this refresh finishes on a
            // cold launch — leaving the to-do list empty even though the
            // (cached) lede already names the tasks. Redo it here so the
            // checkable items always appear once sessions are in.
            ActionItemStore.shared.rebuild(from: store.sessions)
            // One-time: seed the usage widgets from the existing Library
            // so long-time users don't see an empty stats block.
            usage.backfillIfNeeded(from: store.sessions)
            // Keep the daily morning-brief notification armed (idempotent).
            MorningBriefStore.rescheduleNotification(settings: settings)
            freeDiskBytes = DiskSpace.recordingsVolumeFreeBytes()
        }
        // Re-read on activation: the user very likely left Daisy to go
        // empty the Trash, and a warning that survives the cleanup reads
        // as broken. Cheap — one volume stat, no I/O.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            freeDiskBytes = DiskSpace.recordingsVolumeFreeBytes()
        }
        .tint(Color.daisyHomeAccent)
    }

    // MARK: - Welcome header

    /// Serif greeting at the very top of Home. Uses Apple's system serif
    /// (New York) via `.serif` fontDesign. Appends the user's display
    /// name when set ("Welcome back, Egor"); bare "Welcome back" otherwise.
    private var welcomeHeader: some View {
        let name = settings.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let greeting = name.isEmpty
            ? String(localized: "Welcome back")
            : String(localized: "Welcome back, \(name)")
        return Text(greeting)
            .font(.system(.largeTitle, design: .serif).weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
    }

    // MARK: - Onboarding checklist
    //
    // Replaces the old full-width permissions alarm bar (2026-07-21).
    // A calm "finish setting up Daisy" checklist that lives above the
    // day card in the right column and disappears once everything is
    // handled. Required rows (Microphone, Accessibility) always show
    // until granted; optional rows (Screen Recording, Calendar) show
    // only while still undecided (notDetermined) — once the user has
    // acted on them, we stop nudging.

    /// Setup rows: any required permission missing, or an optional one
    /// still undecided. Hidden once setup is complete (or dismissed) so
    /// Home is clean for the everyday case.
    private var showsSetupRows: Bool {
        guard !onboardingDismissed else { return false }
        return permissions.microphone != .granted
            || permissions.accessibility != .granted
            || permissions.screenRecording == .notDetermined
            || permissions.calendar == .notDetermined
    }

    /// Free bytes when they're under the floor where Daisy stops
    /// archiving audio — nil means nothing to warn about.
    ///
    /// Deliberately NOT gated on `onboardingDismissed`: this is a live
    /// condition, not a setup step, and it can appear months after the
    /// checklist was dismissed. The 2026-07-27 field report was exactly
    /// that user — every permission granted, checklist long gone, four
    /// meetings recorded with no audio at 0.4 GB free and nothing on
    /// Home saying so.
    ///
    /// Also skipped when the user chose "Don't record audio": there's no
    /// audio to lose, so warning about losing it is noise. Mirrors
    /// `RecordingSession.start()`, which likewise doesn't apply the
    /// low-disk branch in that mode.
    private var lowDiskBytes: Int64? {
        guard settings.audioRetentionDays != AppSettings.audioRetentionDoNotRecord,
              let freeDiskBytes,
              freeDiskBytes < DiskSpace.recordingFloorBytes
        else { return nil }
        return freeDiskBytes
    }

    /// The card shows for either reason.
    private var shouldShowOnboarding: Bool {
        lowDiskBytes != nil || showsSetupRows
    }

    /// Both REQUIRED permissions granted — the point at which we let the
    /// user dismiss the whole checklist (optional rows may still linger,
    /// but nothing is broken, so "Don't show again" is safe to offer).
    private var requiredPermissionsMet: Bool {
        permissions.microphone == .granted && permissions.accessibility == .granted
    }

    private var onboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // "Finish setting up" would be a lie on a card that's
                // showing only a disk warning to a fully-configured user.
                Text(showsSetupRows
                     ? String(localized: "Finish setting up Daisy")
                     : String(localized: "Needs your attention"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                // Low-emphasis escape hatch — only once the essentials are
                // in place, so the user can't skip past a broken setup.
                // Never offered for the disk row: it clears itself the
                // moment space is freed, and hiding it would hide the
                // reason meetings are recording without audio.
                if showsSetupRows, requiredPermissionsMet {
                    Button(String(localized: "Don't show again")) {
                        onboardingDismissed = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // First in the card: it's the only row here describing
            // something being lost right now.
            if let lowDiskBytes { lowDiskRow(freeBytes: lowDiskBytes) }

            if showsSetupRows {
                onboardingRow(
                    title: String(localized: "Microphone"),
                    caption: String(localized: "Captures your voice"),
                    status: permissions.microphone,
                    action: { Task { await permissions.requestMicrophone() } },
                    openSettings: permissions.openMicrophoneSettings
                )
                onboardingRow(
                    title: String(localized: "Accessibility"),
                    caption: String(localized: "Lets dictation paste into any app"),
                    status: permissions.accessibility,
                    action: { permissions.requestAccessibility() },
                    openSettings: permissions.openAccessibilitySettings
                )
                onboardingRow(
                    title: String(localized: "Screen Recording"),
                    caption: String(localized: "Captures the other side of meetings"),
                    status: permissions.screenRecording,
                    action: { permissions.requestScreenRecording() },
                    openSettings: permissions.openScreenRecordingSettings
                )
                onboardingRow(
                    title: String(localized: "Calendar"),
                    caption: String(localized: "Auto-starts recording at meeting times"),
                    status: permissions.calendar,
                    action: { Task { await permissions.requestCalendar() } },
                    openSettings: permissions.openCalendarSettings
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Low-disk line. Same visual language as the permission rows, but a
    /// warning glyph instead of a checkbox — nothing here gets ticked
    /// off, it clears when the disk does.
    ///
    /// Names the consequence, not just the number: "1.9 GB free" reads as
    /// fine to anyone who doesn't know Daisy needs 3 GB to keep audio.
    /// Tapping lands on Settings → General, where the storage location,
    /// the audio-cache purge and bulk delete of old recordings all live —
    /// Daisy's own recordings are usually the biggest thing it can free
    /// (~0.7 GB per recorded hour).
    @ViewBuilder
    private func lowDiskRow(freeBytes: Int64) -> some View {
        Button {
            AppNavigation.shared.openInSettings(.general)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.daisyWarning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Low disk space")
                        .font(.callout.weight(.medium))
                    Text(String(localized: "Only \(freeBytes.formatted(.byteCount(style: .file))) left — recordings are being saved without audio, transcript only. Free up space to get audio back."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OnboardingRowHover(active: true))
    }

    /// One checklist line: a status glyph (filled check when granted) plus
    /// the name + one-line rationale. The WHOLE row is the tap target —
    /// notDetermined requests the permission, denied/restricted opens
    /// System Settings, granted is inert. No buttons (keeps the block
    /// calm); a hover highlight + trailing chevron signal it's clickable.
    @ViewBuilder
    private func onboardingRow(
        title: String,
        caption: String,
        status: SystemPermissions.Status,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        let granted = (status == .granted)
        Button {
            switch status {
            case .granted:       break
            case .notDetermined: action()
            // denied / restricted / insufficient — the system won't prompt
            // again, so send them to System Settings.
            default:             openSettings()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(granted ? Color.daisyHomeAccent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(granted)
        .modifier(OnboardingRowHover(active: !granted))
    }

    // MARK: - Destinations discoverability

    /// Show the destination-setup nudge when:
    ///   • At least one session exists (proves user is past the
    ///     "haven't recorded yet" stage and might want a destination)
    ///   • AND nothing is configured: no Notion creds, no MCP
    ///     integrations enabled.
    /// Without this, Send-to integrations stay invisible — the
    /// feature lives behind Settings, and users we surveyed didn't
    /// know it existed.
    private var showDestinationsHint: Bool {
        guard !store.sessions.isEmpty else { return false }
        let hasNotion = settings.hasNotionCredentials
        let hasMCP = !integrationStore.enabledIntegrations.isEmpty
        return !hasNotion && !hasMCP
    }

    private var destinationsHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.daisyHomeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Send recordings somewhere")
                    .font(.callout.weight(.medium))
                Text("Daisy can push finished recordings to Notion, Linear, Slack, or any MCP server — automatically or via the kebab menu in History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                // Deep-link straight to Connections → Auto-routing —
                // landing on generic Settings left users hunting for
                // where destinations actually live.
                AppNavigation.shared.pendingConnectionsSection = .autoRouting
                AppNavigation.shared.section = .connections
            } label: {
                Text("Set up").frame(minWidth: 120)
                    .foregroundStyle(Color.daisyBannerActionText)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyBannerAction)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.daisyBannerBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyBannerBorder, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Two-column band: calendar ↔ recent recordings

    /// Calendar events (left) and recent recordings (right), half the
    /// content width each (Egor, 2026-07-14). When no calendar source is
    /// connected the recordings take the full width — an empty left
    /// column would just be dead space.
    /// One gutter for every column split on Home (stats row + the
    /// calendar/recordings band) so vertical boundaries align.
    static let columnGap: CGFloat = 16

    /// Home body layout (columns swapped 2026-07-25, per Egor): two
    /// full-height columns. LEFT = the DayCard (morning lede + agenda +
    /// open items). RIGHT = activity heatmap, then the fixes/words
    /// number pair, then recent recordings. (`leftColumn` kept its
    /// historical name to avoid churn — it now renders on the right.)
    ///
    /// The layout is FIXED regardless of calendar state (Egor 2026-07-22):
    /// no calendar just means the day card shows less inside it — it must
    /// NOT restack the whole screen into one column. The old single-column
    /// fallback made a fresh install (or a permissions-reset release build)
    /// look like a different app.
    /// Fixed width for the stats column (right): the 26-week heatmap
    /// grid's natural width + the card's 16pt padding on both sides.
    /// A 50/50 split left ~100pt of dead space inside the activity
    /// card on wide windows (Egor, 2026-07-25) — the heatmap grid has
    /// intrinsic width, so its column should hug it; the day card
    /// takes everything else.
    private static let statsColumnWidth: CGFloat =
        MeetingsHeatmap.defaultGridWidth + 32

    private var homeColumns: some View {
        HStack(alignment: .top, spacing: Self.columnGap) {
            dayColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
            leftColumn
                .frame(width: Self.statsColumnWidth, alignment: .topLeading)
        }
        .padding(.horizontal, 24)
    }

    /// Day column (now LEFT): the onboarding checklist (while setup is
    /// unfinished) stacked above the day card.
    @ViewBuilder
    private var dayColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if shouldShowOnboarding {
                onboardingChecklist
            }
            dayCard
        }
    }

    /// Stats column (now RIGHT; name is historical): heatmap on top, the
    /// fixes/words number pair beneath it, then recent recordings. Stats
    /// hide until there's at least one session so a fresh install isn't
    /// greeted by zeros.
    @ViewBuilder
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if usage.totalCount > 0 {
                heatmapCard
                HStack(alignment: .top, spacing: Self.columnGap) {
                    fixesCard
                    wordsCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // Full-width under the number pair rather than squeezed in
            // beside them: the provider name + per-model line needs the
            // horizontal room, and a third ⅓ card would crush all three.
            if tokens.hasSpendThisMonth { tokensCard }
            recentSessionsSection
        }
    }

    /// The unified "your day" card — lede + agenda (with inline Prep +
    /// per-meeting tasks) + standalone open items. Replaces the old
    /// morning-brief card, Today/Tomorrow column, and standalone brief card.
    private var dayCard: some View {
        DayCard(
            events: displayedEvents,
            isTomorrow: showingTomorrow,
            settings: settings,
            onStartMeeting: { event in
                Task { await session.startFromMeeting(event) }
            }
        )
    }

    // MARK: - Calendar plumbing (consumed by DayCard)

    // (`hasAnyCalendarSource` removed 2026-07-22 — the column layout no
    // longer branches on calendar state; DayCard degrades internally.)

    /// Which day the card shows — delegated to `MorningBriefStore` so
    /// the agenda and the LLM lede above it can never disagree about
    /// what day it is (Egor, 2026-07-26: in the evening the card said
    /// TOMORROW, listed tomorrow's meetings, and narrated this morning).
    private var showingTomorrow: Bool { MorningBriefStore.briefScope().isTomorrow }

    /// The events actually rendered — today's if any remain, else
    /// tomorrow's. Empty only when there's nothing in either day.
    private var displayedEvents: [DaisyMeeting] { MorningBriefStore.briefScope().events }

    // (sectionHeader / eventsBody / UpcomingEventRow removed 2026-07-15 —
    // the DayCard renders the agenda now, with inline Prep + nested tasks.)

    // (connectCalendarCTA / deniedCalendarCTA removed 2026-07-21 — the
    // onboarding checklist's Calendar row is the only calendar nudge on
    // Home now; the standalone banners were dead code.)

    // MARK: - Usage stats (words/min · total words · activity)

    /// Wispr-style "fixes" card: big total + breakdown (dictionary
    /// replacements / voice-polish changes). Counters start at zero on
    /// this build — they can't be backfilled.
    private var fixesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.totalFixes.formatted(.number))
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Fixes made by Daisy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.daisyDivider.opacity(0.5))
                .frame(height: 1)
                .padding(.horizontal, -16)
                .padding(.vertical, 4)
            HStack(spacing: 6) {
                Text(usage.totalDictionaryFixes.formatted(.number))
                Text("Dictionary")
                Spacer()
            }
            .daisyStatLabel()
            HStack(spacing: 6) {
                Text(usage.totalPolishedWords.formatted(.number))
                Text("Voice polish")
                Spacer()
            }
            .daisyStatLabel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Combined words card: total words big, dictation words/min beneath.
    private var wordsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.totalWords.formatted(.number))
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Total words")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.daisyDivider.opacity(0.5))
                .frame(height: 1)
                .padding(.horizontal, -16)
                .padding(.vertical, 4)
            HStack(spacing: 6) {
                // "—" until the first dictation lands: WPM is dictation-
                // only, and a literal 0 reads as broken.
                Text(usage.averageWPM > 0 ? "\(usage.averageWPM)" : "—")
                Text("Words / min")
                Spacer()
            }
            .daisyStatLabel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Tokens spent per connected API
    //
    // Window is the current CALENDAR MONTH, not all-time: providers bill
    // monthly, so that's the only number comparable to their console, and
    // a forever-growing cumulative total stops being actionable after the
    // first week. The ledger keeps 90 days (TokenLedger.retentionDays) so
    // a previous-month comparison can be added without re-collecting.
    //
    // MULTI-PROVIDER: the hero number is ONE provider — the selected one
    // if it spent anything this month, else the biggest spender. Other
    // providers with spend get a small row each. Tokens are deliberately
    // never summed across providers: a Claude token and a GPT token cost
    // different money, so a combined figure would be adding two
    // currencies. The rows exist because two providers in one month is a
    // real case — switching mid-month, and the pre-meeting brief's web
    // research, which always bills the Anthropic key no matter which
    // provider is selected for summaries.

    /// Current month in its standalone (nominative) form.
    private static func standaloneMonthName() -> String {
        let calendar = Calendar.current
        let index = calendar.component(.month, from: Date()) - 1
        let symbols = calendar.standaloneMonthSymbols
        guard symbols.indices.contains(index) else {
            return Date.now.formatted(.dateTime.month(.wide))
        }
        return symbols[index]
    }

    /// Compact token count — "1.2M", "840K", localized.
    private func compactTokens(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }

    /// A model's own cost, for the legend table.
    ///
    /// Blank for local providers, which is the whole point — nothing to
    /// pay, nothing to say. But a cloud model whose tariff Daisy doesn't
    /// know must NOT be blank: blank reads as free, and that one is
    /// billing the user at a rate we simply can't quote. It gets a mark
    /// and a tooltip instead (Egor, 2026-07-29).
    /// - Parameter digits: decimals for the WHOLE column, not for this
    ///   row. Rounding each row to its own comfortable precision made
    ///   the column stop adding up on screen: $0.1365 printed as "$0.14"
    ///   beside $0.0025, under a total of $0.14 — so the total looked
    ///   like it was one model's, not the sum (Egor, 2026-07-29). One
    ///   precision for every row, chosen by the smallest of them, and
    ///   the arithmetic is visible again.
    @ViewBuilder
    private func rowCost(_ estimate: TokenCostEstimate, digits: Int) -> some View {
        if estimate.hasPricedUsage {
            let amount = estimate.usd.formatted(
                .currency(code: "USD").precision(.fractionLength(digits))
            )
            // Both flags can be true at once — the merged "other models"
            // row sums a priced model with an unpriced one. Printing the
            // bare figure there would state a number that is knowingly
            // short, which is the failure the summing operator was
            // written to prevent.
            Text(estimate.hasUnpricedBilledUsage ? String(localized: "At least \(amount)") : amount)
        } else if estimate.hasUnpricedBilledUsage {
            Text(verbatim: "?")
                .help(String(localized: "This model is billed, but Daisy doesn't know its price."))
                .accessibilityLabel(String(localized: "Cost unavailable"))
        } else {
            // Local provider — deliberately empty. The column still
            // exists so the rows stay aligned.
            Text(verbatim: "")
                .accessibilityHidden(true)
        }
    }

    /// API pricing changes and Daisy only sees calls it made itself, so
    /// this is consciously an estimate — never an invoice.
    private func estimatedCostLabel(_ estimate: TokenCostEstimate) -> String? {
        guard estimate.hasPricedUsage else {
            return estimate.hasUnpricedBilledUsage ? String(localized: "Cost unavailable") : nil
        }
        let digits = estimate.usd > 0 && estimate.usd < 0.01 ? 4 : 2
        let amount = estimate.usd.formatted(
            .currency(code: "USD").precision(.fractionLength(digits))
        )
        return estimate.hasUnpricedBilledUsage
            ? String(localized: "At least \(amount)")
            : String(localized: "≈ \(amount)")
    }

    @ViewBuilder
    private var tokensCard: some View {
        let rows = tokens.currentMonthModelSeries()
        if !rows.isEmpty {
            let total = tokens.currentMonthTotalTokens()
            let cost = tokens.currentMonthCostEstimate()
            let searches = tokens.currentMonthWebSearches()
            let cached = tokens.currentMonthCachedInputTokens()
            // Driven by the SMALLEST priced row: two decimals would round
            // a cheap model to $0.00 and make it look free, and a mix of
            // precisions down the column stops it adding up by eye.
            let hasSubCentRow = rows.contains {
                $0.cost.hasPricedUsage && $0.cost.usd > 0 && $0.cost.usd < 0.01
            }
            let costDigits = hasSubCentRow ? 4 : 2
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tokens")
                        .daisyStatLabel()
                    Spacer()
                    // Standalone symbol, not `.dateTime.month(.wide)`:
                    // that one is the FORMAT context, which in Russian
                    // gives the genitive "июля" ("of July") — correct
                    // inside a date, a fragment as a bare label.
                    Text(Self.standaloneMonthName())
                        .daisyStatLabel()
                }
                // One headline for the whole month, not one model's.
                // The card used to lead with a single model chosen as
                // "the active one", which it got wrong: the match was on
                // PROVIDER, so with two Claude models it led with the
                // bigger spender and labelled it as the user's pick.
                // A total needs no such guess (Egor, 2026-07-29).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(compactTokens(total))
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let costLabel = estimatedCostLabel(cost) {
                        Text(costLabel)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                TokenUsageChart(rows: rows)
                    .frame(height: 44)
                    .padding(.top, 4)

                Rectangle()
                    .fill(Color.daisyDivider.opacity(0.5))
                    .frame(height: 1)
                    .padding(.horizontal, -16)
                    .padding(.vertical, 4)

                // Doubles as the chart's legend — which is why the swatch
                // is never the only thing telling two models apart.
                //
                // A Grid, not a stack of HStacks: with the numbers merely
                // pushed right by a Spacer, each row's ↓ and ↑ started
                // wherever that row's digits happened to end, so the
                // columns zig-zagged and two models couldn't be compared
                // down the page. A grid gives every column one width.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(TokenUsageChart.color(at: index))
                                    .frame(width: 7, height: 7)
                                Text(row.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            // Takes the slack so the two number columns
                            // sit together at the right, still aligned to
                            // each other's leading edge.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(row.name)

                            // `verbatim`: an arrow and a formatted number
                            // are not translatable text, and letting them
                            // extract as "↓ %@" would put a glyph in the
                            // catalogue for a translator to puzzle over.
                            Text(verbatim: "↓ \(compactTokens(row.inputTokens))")
                                .help(String(localized: "Input tokens"))
                                .accessibilityLabel(String(localized: "\(row.inputTokens) tokens in"))
                            Text(verbatim: "↑ \(compactTokens(row.outputTokens))")
                                .help(String(localized: "Output tokens"))
                                .accessibilityLabel(String(localized: "\(row.outputTokens) tokens out"))

                            rowCost(row.cost, digits: costDigits)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                // Explicit, so the flexible first cell has a width to
                // take the slack from rather than sizing the grid to its
                // own content.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Monospaced digits so the columns hold still between
                // rows — proportional figures make a column of numbers
                // look ragged even when it is perfectly aligned.
                .daisyStatLabel()
                .monospacedDigit()

                // Billed per search, not per token, so no token figure
                // on this card contains them.
                if searches > 0 || cached > 0 {
                    HStack(spacing: 6) {
                        if cached > 0 {
                            // "of which": cache reads are INSIDE the ↓
                            // figures above, priced at about a tenth.
                            // Web searches next to them are the opposite
                            // — billed per search and in no token count
                            // on this card — so the wording has to carry
                            // the difference, or a reader adds both.
                            Text("of which \(compactTokens(cached)) from cache")
                        }
                        Spacer()
                        if searches > 0 {
                            Text("plus \(searches.formatted(.number)) web searches")
                        }
                    }
                    .daisyStatLabel()
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(usage.currentStreak == 1
                     ? String(localized: "1 day streak")
                     : String(localized: "\(usage.currentStreak) day streak"))
                    .daisyStatLabel()
            }
            MeetingsHeatmap(dayCounts: usage.dayCounts())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recent sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent recordings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button("Open Library") {
                    nav.section = .library
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "tray",
                    description: Text("Click Record to make your first one.")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            } else {
                // One block, no dividers — the per-row hover carries the
                // separation now.
                VStack(spacing: 0) {
                    ForEach(Array(store.sessions.prefix(5))) { session in
                        RecentSessionRow(session: session) {
                            // Deep-link into the Library view with this
                            // session pre-selected, not the default row.
                            nav.openInLibrary(session.id)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
    }


}

// MARK: - Recent session row

/// Shared minimum content height for the Home list rows (see DayCard's
/// agenda rows for the calendar side).
private let homeRowMinHeight: CGFloat = 36

/// A quiet month-to-date usage graph for one model. It deliberately has no axes:
/// the card already gives the exact total, while the bars answer the more
/// useful question of whether usage was steady or happened in one burst.
/// Daily token spend for the current month, stacked by model.
///
/// Stacked rather than one bar per model side by side: the question the
/// card answers is "how much did Daisy spend", and the split is the
/// second question. A grouped chart would make the day's total something
/// the eye has to add up.
///
/// Colour is the only thing distinguishing the segments inside a column,
/// which is why the legend rows below the chart carry the same swatch
/// beside a written model name — identity is never colour alone. The
/// palette is validated for colour-blind separation (see `palette`); the
/// adjacent-pair margin sits in the band that is only legal WITH that
/// secondary encoding, so the legend is load-bearing, not decoration.
private struct TokenUsageChart: View {
    let rows: [ModelSeriesRow]

    /// Fixed categorical order — a model keeps its colour when another
    /// model appears or drops out of the month. Assigned by position in
    /// `rows`, which is ordered by spend, so the biggest is always the
    /// first hue rather than a colour that shifts with rank.
    ///
    /// Validated with the dataviz palette checker against both card
    /// surfaces (light #FBF9F5, dark #151816): lightness band, chroma
    /// floor, normal-vision separation and 3:1 contrast all pass in both
    /// modes; adjacent-pair CVD separation lands at ΔE 8.0, the floor
    /// that requires the written labels the legend already provides.
    private static let palette: [Color] = [
        Color(light: Color(hex: 0xC96A10), dark: Color(hex: 0xC87720)),  // amber — the app's own accent family
        Color(light: Color(hex: 0x2E6EC8), dark: Color(hex: 0x5386DA)),  // blue
        Color(light: Color(hex: 0x1F7A55), dark: Color(hex: 0x279C6B)),  // green
        Color(light: Color(hex: 0xA0468F), dark: Color(hex: 0xB563A3)),  // plum
    ]

    /// Never cycles: past the palette the caller has already merged the
    /// tail into one "Other" row, so this can only be reached by a bug —
    /// and a grey band reads as "the rest" rather than as a fifth model.
    static func color(at index: Int) -> Color {
        palette.indices.contains(index) ? palette[index] : Color.daisyTextTertiary
    }

    /// Total per day across every row — the column heights.
    private var dailyTotals: [Int] {
        let length = rows.map(\.values.count).max() ?? 0
        return (0..<length).map { day in
            rows.reduce(0) { $0 + ($1.values.indices.contains(day) ? $1.values[day] : 0) }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let totals = dailyTotals
            let highest = max(totals.max() ?? 0, 1)
            let gap: CGFloat = 3
            let columns = max(totals.count, 1)
            let width = max(2, (proxy.size.width - gap * CGFloat(max(columns - 1, 0))) / CGFloat(columns))

            HStack(alignment: .bottom, spacing: gap) {
                ForEach(totals.indices, id: \.self) { day in
                    column(day: day, height: proxy.size.height, width: width, highest: highest)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Token usage day by day this month, by model"))
    }

    @ViewBuilder
    private func column(day: Int, height: CGFloat, width: CGFloat, highest: Int) -> some View {
        let total = rows.reduce(0) { $0 + ($1.values.indices.contains(day) ? $1.values[day] : 0) }
        if total == 0 {
            // A quiet day is context, not missing data — but it must not
            // look like a tiny bar either, so it stays a baseline tick.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.daisyDivider.opacity(0.45))
                .frame(width: width, height: 3)
        } else {
            let columnHeight = max(4, height * CGFloat(total) / CGFloat(highest))
            let live = rows.indices.filter { index in
                let row = rows[index]
                return (row.values.indices.contains(day) ? row.values[day] : 0) > 0
            }
            // 2pt of surface between segments so two fills never touch —
            // adjacent hues sharing an edge are much harder to separate
            // than ones with a gap, and this is where the colour-blind
            // margin is thinnest.
            //
            // Taken OUT of the column, not added on top of it. Segment
            // heights already sum to `columnHeight`, so N-1 gaps of
            // spacing made every multi-model column overflow — and the
            // damage scaled inversely with the value, because a quiet
            // day's 4pt column carried the same fixed 6pt of gaps as a
            // full-height one. Quiet days rendered TALLER than busy ones,
            // which is the opposite of what the chart is for.
            let gaps = CGFloat(max(live.count - 1, 0)) * 2
            let fill = max(0, columnHeight - gaps)
            // Below this the split cannot physically fit — four models
            // in a 4pt column need 4pt of bars plus 6pt of gaps. Drawn
            // anyway, the stack lays out at 10pt and the frame clips it
            // to the BOTTOM 4 — and since rows are ordered by spend, the
            // bottom is the SMALLEST models. A light day would show the
            // two colours that mattered least, contradicting the legend
            // in exactly the columns a reader is squinting at. One solid
            // band for the day's dominant model is the honest answer at
            // this size.
            // `Group`, because the frame and clip below apply to the
            // WHOLE column: modifiers can't be chained onto a bare
            // if/else in a ViewBuilder.
            Group {
                if columnHeight < CGFloat(live.count) + gaps {
                    TokenUsageChart.color(at: live[0])
                } else {
                    VStack(spacing: 2) {
                        ForEach(live, id: \.self) { index in
                            let value = rows[index].values.indices.contains(day) ? rows[index].values[day] : 0
                            TokenUsageChart.color(at: index)
                                // 1pt floor, not 2: a hairline keeps a
                                // tiny contributor visible without
                                // inventing height for it. A model at
                                // 0.001% of the day should look like
                                // nothing, not like 4% of the column.
                                .frame(width: width, height: max(1, fill * CGFloat(value) / CGFloat(total)))
                        }
                    }
                }
            }
            // Frame BEFORE the clip so residual rounding is contained by
            // the shape rather than escaping around it.
            .frame(width: width, height: columnHeight, alignment: .bottom)
            // Rounded at the top only, anchored to the baseline — the
            // data end is the top of the column, and rounding the bottom
            // would lift the fill off the axis it's measured from.
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 2,
                    style: .continuous
                )
            )
        }
    }
}

/// Subtle hover highlight for the onboarding checklist rows. `active` is
/// false for a granted (inert) row, so it never lights up. Pads a comfy
/// hit area, draws a faint fill on hover, then negates the padding so the
/// row layout doesn't shift.
private struct OnboardingRowHover: ViewModifier {
    let active: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(active && hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.horizontal, -8)
            .padding(.vertical, -6)
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Shared secondary "stat label" style — the same aligned look as the
    /// uppercase section headers on Home (caption · semibold · secondary ·
    /// uppercase). Used for the number-led breakdown rows in the stat
    /// cards, the streak, the heatmap session count, and the day-card
    /// counts, so every small figure+label reads the same.
    func daisyStatLabel() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct RecentSessionRow: View {
    let session: StoredSession
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(formattedDate)
                        Text("·")
                        Text(formattedDuration)
                        if session.hasSummary {
                            Text("·")
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.daisyHomeAccent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: homeRowMinHeight)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                    // Extend 8pt past the content on each side so the
                    // highlight lines up with the day-card / onboarding rows.
                    .padding(.horizontal, -8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    // One shared formatter instead of allocating per row per render.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var formattedDate: String {
        Self.dateFormatter.string(from: session.startedAt)
    }

    private var formattedDuration: String {
        let total = max(0, session.durationSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
