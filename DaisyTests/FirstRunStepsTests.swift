//
//  FirstRunStepsTests.swift
//  DaisyTests
//
//  Regression locks for the onboarding step order — the one pure piece
//  of FirstRunView. The UI itself (rail clicks, the narrow-window
//  fallback, permission prompts) is device-QA territory; what CAN be
//  pinned down is which steps appear, for which setup path, and where
//  the layout-fixer step lands relative to the hotkeys step.
//

import Testing
@testable import Daisy

@Suite("First-run step order")
struct FirstRunStepsTests {

    typealias Step = FirstRunView.Step

    // MARK: - Exact orders (also proves folder/vocab are gone and the
    // rest of the order didn't move)

    @Test("Full path with one layout: no folder, no vocab, no layout step")
    func fullPathSingleLayout() {
        #expect(FirstRunView.steps(for: .full, installedLayoutCount: 1) == [
            .welcome, .language, .purpose, .name,
            .microphone, .screenRecording, .accessibility,
            .hotkeys, .calendar, .model, .done,
        ])
    }

    @Test("Dictation-only path with one layout")
    func dictationPathSingleLayout() {
        #expect(FirstRunView.steps(for: .dictationOnly, installedLayoutCount: 1) == [
            .welcome, .language, .purpose,
            .microphone, .accessibility, .hotkeys, .done,
        ])
    }

    // MARK: - The layout step

    @Test("Layout step appears with 2+ installed layouts, right after hotkeys",
          arguments: [2, 3, 5])
    func layoutStepPresentWithManyLayouts(count: Int) {
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let steps = FirstRunView.steps(for: path, installedLayoutCount: count)
            let hotkeysIndex = steps.firstIndex(of: .hotkeys)
            #expect(hotkeysIndex != nil)
            if let hotkeysIndex {
                #expect(steps[hotkeysIndex + 1] == .layout)
            }
            // Exactly once, never duplicated.
            #expect(steps.filter { $0 == .layout }.count == 1)
        }
    }

    @Test("Layout step absent with a single installed layout")
    func layoutStepAbsentWithOneLayout() {
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let steps = FirstRunView.steps(for: path, installedLayoutCount: 1)
            #expect(!steps.contains(.layout))
        }
    }

    @Test("Adding the layout step changes nothing else about the order")
    func layoutStepIsPureInsertion() {
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            let without = FirstRunView.steps(for: path, installedLayoutCount: 1)
            let with = FirstRunView.steps(for: path, installedLayoutCount: 2)
            #expect(with.filter { $0 != .layout } == without)
        }
    }
}
