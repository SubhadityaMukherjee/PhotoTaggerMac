import Photos
import SwiftUI

/// Album overview + the "Tag All" action, including the first-run model
/// download confirmation.
struct AlbumDetailView: View {

    @Environment(AppModel.self) private var model

    let assets: AlbumAssets

    @State private var includeAlreadyTagged = false
    @State private var confirmHugeRun = false

    private var pending: Int {
        includeAlreadyTagged ? assets.images.count : model.pendingCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryGrid
                    howItWorks
                    if let failure = model.lastFailureMessage {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Tag \(pending) photos?",
            isPresented: $confirmHugeRun,
            titleVisibility: .visible
        ) {
            Button("Tag All \(pending) Photos") { model.startTagging(includeAlreadyTagged: includeAlreadyTagged) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs the AI over every photo and can take a while. You can stop at any point; already-tagged photos are remembered.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(assets.summary.title)
                    .font(.title.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if pending > 300 {
                    confirmHugeRun = true
                } else {
                    model.startTagging(includeAlreadyTagged: includeAlreadyTagged)
                }
            } label: {
                Text("Tag All (\(pending))")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pending == 0 || model.runIsActive)
        }
        .padding(24)
    }

    private var subtitle: String {
        var parts = ["\(assets.images.count) photos"]
        if model.taggedCount > 0 { parts.append("\(model.taggedCount) already tagged") }
        if assets.videoCount > 0 { parts.append("\(assets.videoCount) videos (skipped)") }
        return parts.joined(separator: " · ")
    }

    private var summaryGrid: some View {
        HStack(spacing: 32) {
            Stat(number: assets.images.count, label: "Photos")
            Stat(number: model.taggedCount, label: "Tagged")
            Stat(number: pending, label: "To Do")
            if assets.videoCount > 0 {
                Stat(number: assets.videoCount, label: "Videos skipped")
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $includeAlreadyTagged) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Re-tag already-tagged photos")
                    Text("Every photo in the album, even ones with AI tags. New tags are merged — nothing is ever removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.runIsActive)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Model")
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Picker("Model", selection: Binding(
                        get: { model.modelStore.choice },
                        set: { model.modelStore.switchModel(to: $0) }
                    )) {
                        ForEach(ModelChoice.allCases) { choice in
                            Text(choice.shortName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .disabled(model.runIsActive || model.modelStore.phase.isBusy)
                    Text("Smaller models are 2–4× faster; downloads on first use. Quality differs little for tags.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Text("Parallel")
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Picker("Parallel", selection: Binding(
                        get: { model.parallelTagging },
                        set: { model.parallelTagging = $0 }
                    )) {
                        ForEach(1...4, id: \.self) { n in
                            Text("\(n)×").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(model.runIsActive)
                    Text("Photos in flight at once — image loading and keyword writes overlap AI analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Text("Detail")
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Picker("Detail", selection: Binding(
                        get: { model.visionDetail },
                        set: { model.visionDetail = $0 }
                    )) {
                        Text("640 · fastest").tag(640)
                        Text("768").tag(768)
                        Text("1024 · best").tag(1024)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .disabled(model.runIsActive)
                    Text("Image size the AI sees — smaller is faster, with a little less fine detail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabelRow(icon: "sparkles.rectangle.stack", text: "Each photo is analyzed on-device by the selected Qwen3-VL model and gets 8–12 search keywords (1–2 words each): subject, pose, clothing & colors, setting, occasion, framing.")
                    LabelRow(icon: "magnifyingglass", text: "Keywords are instantly searchable in the Photos app — try typing “yellow shirt” or “lake” in its search bar.")
                    LabelRow(icon: "checkmark.shield", text: "Photos are never edited, re-encoded, or deleted. The only change is adding keywords, merged with any you set yourself.")
                    LabelRow(icon: "internaldrive", text: "PhotoTagger has tagged \(model.store.ids.count) photos so far — this index is stored on this Mac and persists across restarts and app updates.")
                }
                .padding(4)
            }
        }
    }
}

struct Stat: View {
    let number: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(number)")
                .font(.title2.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LabelRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
