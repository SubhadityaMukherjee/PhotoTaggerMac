import SwiftUI

/// Main window: album sidebar + detail, with a permanent model status footer.
struct ContentView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.accessPhase {
            case .checking:
                ProgressView("Checking photo library access…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .needsPermission, .denied:
                AccessView()

            case .granted:
                mainContent
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.store.flush() }
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            AlbumSidebar()
        } detail: {
            DetailPane()
        }
        .safeAreaInset(edge: .bottom) {
            ModelStatusFooter()
        }
    }
}

// MARK: - Sidebar

private struct AlbumSidebar: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.albums, selection: Binding(
            get: { model.selectedAlbumID },
            set: { id in
                if let id, let album = model.albums.first(where: { $0.id == id }) {
                    model.select(album)
                }
            }
        )) { album in
            HStack {
                Label(album.title, systemImage: album.isSmartAlbum ? "sparkles" : "rectangle.stack")
                    .lineLimit(1)
                Spacer()
                Text("\(album.assetCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(album.id)
        }
        .navigationTitle("Albums")
        .overlay {
            if model.albums.isEmpty {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "rectangle.stack",
                    description: Text("Albums from your Photos library appear here.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshAlbums()
                    if let id = model.selectedAlbumID,
                        let album = model.albums.first(where: { $0.id == id })
                    {
                        model.select(album)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.runIsActive)
            }
        }
    }
}

// MARK: - Detail pane

private struct DetailPane: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.runIsActive {
                RunView()
            } else if let assets = model.selectedAssets {
                AlbumDetailView(assets: assets)
            } else {
                ContentUnavailableView(
                    "Pick an Album",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        "Choose an album on the left, then click Tag All to let the AI describe and keyword every photo in it."
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Access view

private struct AccessView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Photo Library Access")
                .font(.title2.bold())

            Text(
                model.accessPhase == .denied
                    ? "PhotoTagger was denied access to Photos. Enable it in System Settings → Privacy & Security → Photos, then click Retry."
                    : "PhotoTagger reads photos to describe them with keywords, and adds those keywords back into Photos. It never edits or deletes photos."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)

            if model.accessPhase == .denied {
                Button("Open Photos Privacy Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }

            Button("Retry") {
                Task { await model.bootstrap() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model status footer

struct ModelStatusFooter: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Photos are never modified — tags are added as keywords")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: Color {
        switch model.modelStore.phase {
        case .ready: return .green
        case .downloading, .loading: return .orange
        case .failed: return .red
        case .notLoaded: return .gray
        }
    }

    private var statusText: String {
        switch model.modelStore.phase {
        case .notLoaded:
            return "AI model: \(ModelStore.modelDisplayName) — downloads on first use (\(AppModel.formatByteCount(ModelStore.approximateBytes)))"
        case .downloading(let total, let received):
            let pct = total > 0 ? Double(received) / Double(total) * 100 : 0
            return "Downloading \(ModelStore.modelDisplayName) — \(AppModel.formatByteCount(received)) of \(AppModel.formatByteCount(total)) (\(Int(pct))%)"
        case .loading:
            return "Loading model into memory…"
        case .ready:
            return "AI model ready — \(ModelStore.modelDisplayName), on-device"
        case .failed(let message):
            return "Model error: \(message)"
        }
    }
}
