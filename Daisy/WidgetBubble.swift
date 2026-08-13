//
//  WidgetBubble.swift
//  Daisy
//
//  A small callout anchored to the floating daisy widget — the one UI
//  surface that floats over every other app, so it can carry a prompt
//  the user needs to see while working somewhere else.
//
//  WHY THIS EXISTS AGAIN. A custom widget callout lived here once (the
//  "Are we done?" silence prompt) and was retired 2026-05-18 for a
//  native notification, because Apple handles positioning, dismissal,
//  reduced-motion and Focus for free. That trade was right for the
//  silence prompt — it isn't time-critical and reads fine as a banner.
//  It is WRONG for the screenshot-note and dictation-landed-nowhere
//  prompts: those are contextual and live for ~12 s ("hold your key
//  NOW"), and a banner that auto-dismisses into Notification Center is
//  easy to miss in exactly that window. The widget is always on screen,
//  over every app — a callout from it is immediate and unmissable.
//
//  Positioning is kept deliberately dumb (the maths is what got the last
//  one retired): the bubble is a plain rounded card, no tail, placed
//  above the widget with right edges aligned, then clamped whole into
//  the widget's screen. No arrow that has to know which side it's on.
//
//  ROUTING. `WidgetBubbleCenter.present` shows the bubble when the widget
//  is visible; when the widget is off or hidden there's nothing to anchor
//  to, so it falls back to a notification. Callers don't choose — they
//  state the prompt and the center picks the surface.
//

import SwiftUI
import UserNotifications

/// One callout: a line of text and, optionally, one action button.
struct WidgetBubbleContent: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    /// Closure isn't Equatable — identity is the `id`, and a given
    /// content value is never mutated, so comparing ids is sufficient
    /// for SwiftUI's diffing.
    var action: (@MainActor () -> Void)?

    static func == (lhs: WidgetBubbleContent, rhs: WidgetBubbleContent) -> Bool {
        lhs.id == rhs.id
    }
}

/// Routes a prompt to the widget bubble when the widget is on screen,
/// else to a notification. A tiny shared holder so singletons
/// (`ScreenshotNoteCapture`, `DictationPaste`) can reach the panel
/// without owning a reference to it — `FloatingPanelController` registers
/// itself here on init.
@MainActor
final class WidgetBubbleCenter {
    static let shared = WidgetBubbleCenter()
    private init() {}

    /// Set by `FloatingPanelController.init`. Weak so the center never
    /// keeps a torn-down panel alive.
    weak var host: (any WidgetBubbleHosting)?

    /// Show `content` on the best available surface. On the notification
    /// fallback the bubble's action button can't come along, so a caller
    /// whose bubble HAS an action must pass a `notificationBody` that
    /// still makes sense without a button — otherwise a banner would ask
    /// "Keep it?" with no way to answer. When the bubble has no action,
    /// `notificationBody` defaults to the bubble text.
    func present(
        _ content: WidgetBubbleContent,
        notificationTitle: String,
        notificationBody: String? = nil
    ) {
        if let host, host.isWidgetVisible {
            host.showBubble(content)
        } else {
            postNotification(title: notificationTitle, body: notificationBody ?? content.text)
        }
    }

    private func postNotification(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            Task { @MainActor in Self.addRequest(title: title, body: body) }
        }
    }

    /// Synchronous so the fire-and-forget `add` doesn't sit in an async
    /// context (which draws a "use the async alternative" warning) —
    /// matches the other notification posters.
    private static func addRequest(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Unique per post: these are distinct transient prompts (a
        // screenshot save, a dictation that landed nowhere) and one must
        // not replace another still sitting unread.
        let request = UNNotificationRequest(
            identifier: "app.essazanov.Daisy.widgetBubble." + UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// What the bubble center needs from the panel controller. A protocol so
/// `WidgetBubbleCenter` doesn't import the AppKit panel machinery and the
/// two can be reasoned about (and tested) apart.
@MainActor
protocol WidgetBubbleHosting: AnyObject {
    var isWidgetVisible: Bool { get }
    func showBubble(_ content: WidgetBubbleContent)
    func hideBubble()
}

/// The bubble's content view. Mirrors `ToastView`'s look (elevated card,
/// hairline border, soft shadow) so the two feel like one design, but as
/// a rounded rect rather than a capsule since it wraps to two lines.
struct WidgetBubbleView: View {
    let content: WidgetBubbleContent
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.daisyAccent)
            Text(content.text)
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            if let title = content.actionTitle {
                Button(action: onAction) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.daisyBgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // A tap anywhere that isn't the action button dismisses — same
        // affordance as the toast.
        .onTapGesture(perform: onDismiss)
    }
}
