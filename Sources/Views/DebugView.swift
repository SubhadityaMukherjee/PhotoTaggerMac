import SwiftUI

/// Developer log pane: every error/warning the app records, newest first.
/// Reached from the sidebar's Debug Log entry, which only appears when
/// View ▸ Show Debug Panel (⇧⌘D) is enabled.
struct DebugView: View {

    private let log = DebugLog.shared

    @Environment(AppModel.self) private var model
    @State private var splitter = KeywordSplitService()
    @State private var errorsOnly = false

    var body: some View {
        List {
            Section("Keyword Maintenance") {
                KeywordSplitSection(service: splitter, ids: model.store.ids)
            }
            Section("Events") {
                ForEach(filtered) { entry in
                    DebugLogRow(entry: entry)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Debug Log")
        .overlay {
            if log.entries.isEmpty {
                ContentUnavailableView(
                    "No Events Yet",
                    systemImage: "ladybug",
                    description: Text(
                        "Errors, warnings, and lifecycle events are recorded here as the app runs."
                    )
                )
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No Errors Recorded",
                    systemImage: "checkmark.circle",
                    description: Text("Everything so far has been warnings or informational.")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $errorsOnly) {
                    Label("Errors Only", systemImage: "exclamationmark.triangle")
                }
                .toggleStyle(.button)
                .help("Show only error-level events")

                Button {
                    copyAll()
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(log.entries.isEmpty)
                .help("Copy the whole log to the clipboard")

                Button {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(log.entries.isEmpty)
                .help("Clear all recorded events")
            }
        }
    }

    private var filtered: [DebugLog.Entry] {
        errorsOnly ? log.entries.filter { $0.level == .error } : log.entries
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.transcript(), forType: .string)
    }
}

// MARK: - Keyword split section

/// Runs the one-shot "split multi-word keywords" maintenance job over the
/// photos tagged so far. Hidden in the debug pane because it exists to
/// migrate keywords written by older prompt versions.
private struct KeywordSplitSection: View {

    @Environment(AppModel.self) private var model
    let service: KeywordSplitService
    let ids: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Older runs wrote multi-word keywords. This rewrites the keywords of the \(ids.count) tagged photos, splitting any 3+ word keyword into 1-2 word pieces (\"woman in yellow shirt\" → \"woman\", \"yellow shirt\"). Keywords that look hand-made are left alone."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if service.progress.isRunning {
                HStack {
                    ProgressView(value: Double(service.progress.scanned), total: Double(max(service.progress.total, 1)))
                        .frame(width: 220)
                    Text(service.progress.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        service.cancel()
                    }
                }
            } else {
                HStack {
                    Button {
                        Task { await service.run(ids: Array(ids)) }
                    } label: {
                        Text("Split Multi-Word Keywords")
                    }
                    .disabled(ids.isEmpty || model.runIsActive)
                    if ids.isEmpty {
                        Text("No tagged photos yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if service.progress.isDone {
                        Text(service.progress.summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("macOS will ask once for permission to control Photos — this is required because PhotoKit can only add keywords, not read or replace them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Row

private struct DebugLogRow: View {

    let entry: DebugLog.Entry

    private static let timeFormatter: Date.FormatStyle = .dateTime
        .hour().minute().second().secondFraction(.fractional(3))

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.date.formatted(Self.timeFormatter))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.category)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }

                Text(entry.message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.level {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch entry.level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
