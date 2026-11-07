import SwiftUI

/// Settings → iCloud sync: on/off, account and sync status, what syncs.
struct CloudSyncView: View {
    @State private var wantsSync = CloudSync.userWantsSync
    private let monitor = CloudSyncMonitor.shared

    /// One-word state for the Settings row.
    static var summary: String {
        guard CloudSync.isInBuild else { return "Not in this build" }
        if CloudSync.activeContainerID != nil { return "On" }
        return CloudSync.userWantsSync ? "Restart to turn on" : "Off"
    }

    var body: some View {
        Form {
            if CloudSync.isInBuild {
                Section {
                    Toggle("Sync with iCloud", isOn: $wantsSync)
                        .onChange(of: wantsSync) { CloudSync.userWantsSync = wantsSync }
                    if restartNeeded {
                        Label("Close and reopen Spaar to \(wantsSync ? "turn sync on" : "turn sync off").",
                              systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Your budgets, payments, belongings and month ends sync to every iPhone signed in to your Apple Account. They're stored in your private iCloud, which only you can read. Turning sync off keeps everything on this iPhone.")
                }

                if CloudSync.activeContainerID != nil {
                    Section("Status") {
                        LabeledContent("iCloud account", value: accountText)
                        if monitor.inProgress {
                            LabeledContent("Sync") { ProgressView() }
                        } else if let last = monitor.lastSuccess {
                            LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened))
                        }
                        if let error = monitor.lastError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .task { await monitor.refreshAccount() }
                } else if let error = CloudSync.launchError, wantsSync {
                    Section("Status") {
                        Text("Sync couldn't start, so your data stayed on this iPhone: \(error)")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Good to know") {
                    Text("On a new iPhone: install Spaar, sign in with the same Apple Account, and your data appears within a minute or two.")
                    Text("Not synced, set up on each iPhone: the Apple Pay automation in Shortcuts, AI settings and API key, and reminders.")
                    Text("If two iPhones change the same thing while offline, the latest change wins. Duplicates (like the same month closed on both) are merged automatically.")
                }
                .font(.footnote)
            } else {
                Section {
                    Text("This copy of Spaar was installed without iCloud (for example sideloaded), so it can't sync. The App Store version syncs through iCloud.")
                }
            }
        }
        .navigationTitle("iCloud sync")
    }

    private var restartNeeded: Bool {
        (CloudSync.activeContainerID != nil) != wantsSync
    }

    private var accountText: String {
        switch monitor.account {
        case .available: "Signed in"
        case .noAccount: "Not signed in. Sign in under Settings → your name."
        case .restricted: "Restricted on this iPhone"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .couldNotDetermine: "Couldn't check"
        case .unknown: "Checking…"
        }
    }
}
