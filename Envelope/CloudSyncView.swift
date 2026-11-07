import SwiftUI

/// Settings → iCloud sync: on/off, account and sync status, what syncs.
struct CloudSyncView: View {
    @State private var wantsSync = CloudSync.userWantsSync
    @State private var confirmingRestore = false
    @State private var restoreRequested = UserDefaults.standard.string(forKey: CloudSync.pendingRestoreKey) != nil
    @State private var schemaMessage: String?
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
                    Text("Your budgets, payments, belongings and month ends sync to every iPhone signed in to your Apple Account. They're stored in your private iCloud, which only you can read. Turning sync off keeps everything on this iPhone. Before the first sync, Spaar keeps a backup copy of what's on this iPhone.")
                }

                if CloudSync.restoredFromBackup {
                    Section {
                        Label("Restored the backup from before iCloud sync. Sync is off.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
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

                if let backup = CloudSync.backupFolder() {
                    Section {
                        if restoreRequested {
                            Label("Close and reopen Spaar to restore the backup.", systemImage: "arrow.clockwise")
                                .foregroundStyle(.orange)
                        } else {
                            Button("Restore backup from before iCloud…", role: .destructive) { confirmingRestore = true }
                        }
                    } footer: {
                        Text("Made \(backupDate(backup)). Only needed if your data went missing, for example after signing out of iCloud while syncing wasn't working.")
                    }
                    .confirmationDialog("Restore the backup?", isPresented: $confirmingRestore, titleVisibility: .visible) {
                        Button("Restore and turn sync off", role: .destructive) {
                            UserDefaults.standard.set(backup.path, forKey: CloudSync.pendingRestoreKey)
                            restoreRequested = true
                        }
                    } message: {
                        Text("Everything on this iPhone is replaced with the copy from \(backupDate(backup)), and iCloud sync is turned off so it isn't mixed with what's in iCloud. Changes made since then on this iPhone are lost.")
                    }
                }

                #if DEBUG
                if let id = CloudSync.containerID {
                    Section {
                        Button("Create CloudKit schema (Development)") {
                            do {
                                try CloudKitSchemaInitializer.run(containerID: id)
                                schemaMessage = "Done. Deploy it to Production in CloudKit Console."
                            } catch {
                                schemaMessage = error.localizedDescription
                            }
                        }
                        if let schemaMessage { Text(schemaMessage).font(.footnote) }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Debug builds only. Run once after changing the models, then deploy the schema to Production in CloudKit Console.")
                    }
                }
                #endif

                Section("Good to know") {
                    Text("On a new iPhone: install Spaar, sign in with the same Apple Account, and your data appears within a minute or two.")
                    Text("The first upload can take a while. Keep Spaar open on Wi-Fi, and don't sign out of iCloud until \"Last synced\" shows a time: signing out removes the synced data from this iPhone.")
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

    private func backupDate(_ folder: URL) -> String {
        let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
        return date?.formatted(date: .abbreviated, time: .shortened) ?? folder.lastPathComponent
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
