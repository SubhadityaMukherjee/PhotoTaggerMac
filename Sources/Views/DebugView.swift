import SwiftUI

/// Developer log pane: every error/warning the app records, newest first.
/// Reached from the sidebar's Debug Log entry, which only appears when
/// View ▸ Show Debug Panel (⇧⌘D) is enabled.
struct DebugView: View {

    private let log = DebugLog.shared

    @State private var errorsOnly = false

    var body: some View {
        List(filtered) { entry in
            DebugLogRow(entry: entry)
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
