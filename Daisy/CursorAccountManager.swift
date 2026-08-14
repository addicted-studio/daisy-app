//
//  CursorAccountManager.swift
//  Daisy
//
//  Observable browser-login state for Cursor's separate Agent CLI.
//  Credentials remain owned by Cursor; Daisy only invokes documented
//  login/status/logout commands.
//

import Foundation
import Observation

@Observable
@MainActor
final class CursorAccountManager: SummaryAccountManaging {
    static let shared = CursorAccountManager()

    private(set) var accountState: SummaryAccountState = .signedOut
    private(set) var availableModels: [SummaryAccountModel] = [
        SummaryAccountModel(id: CursorAgentService.defaultModelID, displayName: "Auto", isDefault: true)
    ]
    private(set) var account: SummaryAccount?

    @ObservationIgnored
    private let service: any CursorAgentServing
    @ObservationIgnored
    private let executableAvailable: @Sendable (String) -> Bool

    init(
        service: any CursorAgentServing = CursorAgentService.shared,
        executableAvailable: @escaping @Sendable (String) -> Bool = {
            CursorAgentService.resolveExecutable(override: $0) != nil
        }
    ) {
        self.service = service
        self.executableAvailable = executableAvailable
    }

    var isConnected: Bool {
        if case .connected = accountState { return true }
        return false
    }

    func connect() async {
        guard executableAvailable(executableOverride) else {
            account = nil
            accountState = .notInstalled
            return
        }
        accountState = .connecting
        do {
            try await service.login(executableOverride: executableOverride)
            await refreshStatus()
        } catch is CancellationError {
            accountState = .signedOut
        } catch {
            apply(error)
        }
    }

    func disconnect() async {
        do {
            try await service.logout(executableOverride: executableOverride)
            account = nil
            accountState = .signedOut
        } catch {
            apply(error)
        }
    }

    func refreshStatus() async {
        guard executableAvailable(executableOverride) else {
            accountState = .notInstalled
            return
        }
        do {
            guard let status = try await service.status(executableOverride: executableOverride) else {
                account = nil
                accountState = .signedOut
                return
            }
            account = status.account
            accountState = .connected(status.account)
        } catch {
            apply(error)
        }
    }

    private var executableOverride: String {
        UserDefaults.standard.string(forKey: "daisy.cursorAgentPath") ?? ""
    }

    private func apply(_ error: Error) {
        switch error as? CursorAgentError {
        case .notInstalled: accountState = .notInstalled
        case .signedOut: accountState = .sessionExpired
        case .limitReached: accountState = .limitReached(resetAt: nil)
        case .some(let error): accountState = .failed(message: error.localizedDescription)
        case nil: accountState = .failed(message: String(localized: "Couldn't refresh the Cursor account. Try again."))
        }
    }
}
