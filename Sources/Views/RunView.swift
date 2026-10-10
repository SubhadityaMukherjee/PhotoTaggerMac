import SwiftUI

/// Live view of a "Tag All" run: current photo, progress, pace, and the
/// stream of tags as they are written. Also covers the model download /
/// load phase that precedes the first photo.
struct RunView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    currentSection
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        progressSection
                    }
                    recentSection
                }
                .padding(24)
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tagging “\(model.runAlbumTitle)”")
                    .font(.title2.bold())
                Text(phaseSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.stopTagging()
            } label: {
                Label(model.stopRequested ? "Stopping…" : "Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
            .disabled(model.stopRequested)
        }
        .padding(24)
    }

    private var phaseSubtitle: String {
        if model.stopRequested {
            return "Stopping — the current photo will finish first…"
        }
        switch model.modelStore.phase {
        case .downloading(let total, let received):
            let pct = total > 0 ? Double(received) / Double(total) * 100 : 0
            return "Downloading AI model (\(Int(pct))%) — one time only"
        case .loading:
            return "Loading AI model into memory…"
        default:
            let stats = model.runStats
            return "\(stats.done + stats.failed) of \(stats.total) processed · \(stats.failed) failed"
        }
    }

    private var currentSection: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 240, height: 240)
                if let cg = model.currentThumbnail {
                    Image(nsImage: NSImage(cgImage: cg, size: .zero))
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ProgressView()
                }
            }
            .shadow(radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 10) {
                Text(model.currentFileName ?? "Preparing…")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if model.currentTags.isEmpty {
                    Label(model.modelStore.phase.isBusy ? "Getting the model ready…" : "Analyzing photo…",
                          systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                } else {
                    FlowLayout {
                        ForEach(model.currentTags, id: \.self) { tag in
                            TagChip(tag: tag)
                        }
                    }
                }

                if let failure = model.lastFailureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            .frame(maxHeight: 240, alignment: .center)
            Spacer()
        }
    }

    private var progressSection: some View {
        let stats = model.runStats
        let processed = stats.done + stats.failed
        return VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(processed), total: Double(max(stats.total, 1)))
            HStack(spacing: 24) {
                Stat(number: stats.done, label: "tagged")
                if stats.failed > 0 { Stat(number: stats.failed, label: "failed") }
                if stats.skippedAlreadyTagged > 0 {
                    Stat(number: stats.skippedAlreadyTagged, label: "already tagged")
                }
                if stats.skippedVideos > 0 {
                    Stat(number: stats.skippedVideos, label: "videos skipped")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(elapsedText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if model.runPace > 0 {
                        Text(String(format: "%.1f photos/min", model.runPace))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var recentSection: some View {
        Group {
            if !model.recentEvents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recently tagged")
                        .font(.headline)
                    ForEach(model.recentEvents.prefix(12)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "photo")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.fileName ?? event.assetLocalID)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(event.tags.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var elapsedText: String {
        let t = Int(model.runElapsed)
        return String(format: "%02d:%02d elapsed", t / 60, t % 60)
    }
}

/// Wrapping row of tag chips.
private struct FlowLayout: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .foregroundStyle(.primary)
    }
}
