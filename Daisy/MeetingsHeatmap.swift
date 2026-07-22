//
//  MeetingsHeatmap.swift
//  Daisy
//
//  GitHub-style activity heatmap of recording days, built entirely from
//  the local session corpus (each `StoredSession.startedAt`). Columns are
//  weeks (oldest → newest, Sunday-started), rows are weekdays. Cell
//  intensity encodes how many recordings happened that day. Purely local,
//  purely derived — no new data, no network.
//

import SwiftUI

struct MeetingsHeatmap: View {
    /// Activity count per local start-of-day (dictations + recordings).
    let dayCounts: [Date: Int]
    /// How many week-columns to show. 26 ≈ half a year, fits the 720pt
    /// content column comfortably.
    var weeks: Int = 26

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        let model = Self.build(dayCounts: dayCounts, weeks: weeks, now: Date())
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(model.columns) { column in
                    VStack(spacing: gap) {
                        ForEach(column.days) { day in
                            cellView(day)
                        }
                    }
                }
            }
            legend(max: model.maxCount)
        }
    }

    @ViewBuilder
    private func cellView(_ day: DayCell) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color(for: day))
            .frame(width: cell, height: cell)
            .help(day.inFuture ? "" : "\(Self.tooltip(day))")
    }

    private func color(for day: DayCell) -> Color {
        if day.inFuture { return .clear }
        switch day.count {
        case 0:      return Color.gray.opacity(0.12)
        case 1:      return Color.daisyHomeAccent.opacity(0.30)
        case 2:      return Color.daisyHomeAccent.opacity(0.50)
        case 3:      return Color.daisyHomeAccent.opacity(0.72)
        default:     return Color.daisyHomeAccent
        }
    }

    private func legend(max: Int) -> some View {
        HStack(spacing: 6) {
            Text("Less")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(legendColor(level))
                    .frame(width: cell, height: cell)
            }
            Text("More")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(summaryLabel(max: max))
                .daisyStatLabel()
        }
    }

    private func legendColor(_ level: Int) -> Color {
        switch level {
        case 0: return Color.gray.opacity(0.12)
        case 1: return Color.daisyHomeAccent.opacity(0.30)
        case 2: return Color.daisyHomeAccent.opacity(0.50)
        case 3: return Color.daisyHomeAccent.opacity(0.72)
        default: return Color.daisyHomeAccent
        }
    }

    private func summaryLabel(max: Int) -> String {
        let total = dayCounts.values.reduce(0, +)
        if total == 1 { return String(localized: "1 session") }
        return String(localized: "\(total) sessions")
    }

    // MARK: - Tooltip

    private static func tooltip(_ day: DayCell) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        let date = df.string(from: day.date)
        switch day.count {
        case 0: return String(localized: "No recordings · \(date)")
        case 1: return String(localized: "1 recording · \(date)")
        default: return String(localized: "\(day.count) recordings · \(date)")
        }
    }

    // MARK: - Model (pure, nonisolated)

    struct DayCell: Identifiable {
        var id: Date { date }
        let date: Date
        let count: Int
        let inFuture: Bool
    }

    struct Column: Identifiable {
        let id: Int
        let days: [DayCell]
    }

    struct Model {
        let columns: [Column]
        let maxCount: Int
    }

    /// Build the week-columns grid. Each column is a Sunday-started week;
    /// the last column contains today. Future cells in the last column are
    /// flagged so they render blank.
    nonisolated static func build(dayCounts: [Date: Int], weeks: Int, now: Date) -> Model {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1  // Sunday

        let todayStart = cal.startOfDay(for: now)
        // Sunday of the current week.
        let weekdayIndex = (cal.component(.weekday, from: todayStart) - cal.firstWeekday + 7) % 7
        guard let thisWeekStart = cal.date(byAdding: .day, value: -weekdayIndex, to: todayStart),
              let gridStart = cal.date(byAdding: .day, value: -(weeks - 1) * 7, to: thisWeekStart) else {
            return Model(columns: [], maxCount: 0)
        }

        var columns: [Column] = []
        var maxCount = 0
        for col in 0..<weeks {
            var days: [DayCell] = []
            for row in 0..<7 {
                let offset = col * 7 + row
                guard let date = cal.date(byAdding: .day, value: offset, to: gridStart) else { continue }
                let inFuture = date > todayStart
                // `date` is midnight; dayCounts is keyed by start-of-day.
                let count = dayCounts[date] ?? 0
                maxCount = Swift.max(maxCount, count)
                days.append(DayCell(date: date, count: count, inFuture: inFuture))
            }
            columns.append(Column(id: col, days: days))
        }
        return Model(columns: columns, maxCount: maxCount)
    }
}
