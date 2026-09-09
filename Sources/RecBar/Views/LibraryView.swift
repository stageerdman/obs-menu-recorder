import SwiftUI
import AppKit

/// The Library window's root view — opened from a button in the popover header (see
/// `PopoverContent` in RecBarApp.swift), lists every tracked recording across the three save
/// folders with its category tag, a cloud-upload control, rename, and move-out actions.
///
/// Since RecBar is `LSUIElement` (no Dock icon), this window toggles the app's activation
/// policy itself while open so it can come to the foreground/Cmd-Tab despite the app
/// otherwise having no Dock presence — see CLAUDE.md's warning about never doing this from
/// `init()` (NSApp isn't populated yet then); doing it here, well after launch, is safe.
struct LibraryView: View {
    let appState: AppState
    @StateObject private var viewModel: LibraryViewModel

    init(appState: AppState) {
        self.appState = appState
        _viewModel = StateObject(wrappedValue: LibraryViewModel(config: appState.config))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.items.isEmpty {
                emptyState
            } else {
                // Deliberately a ScrollView/LazyVStack, not a List: on macOS, List is backed
                // by NSTableView, which intercepts mouseDown for its own row-selection
                // tracking before it ever reaches FilePromiseDragHandle's custom NSView —
                // confirmed by real-usage report (2026-09-09) that dragging did nothing at
                // all while everything else (buttons, rename) worked fine. A plain
                // ScrollView has no competing event handling to fight with.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            RecordingRow(item: item, viewModel: viewModel)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            viewModel.start()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            viewModel.stop()
        }
        .sheet(item: $viewModel.signInPrompt) { device in
            OneDriveSignInView(device: device)
        }
        .alert("OneDrive", isPresented: Binding(
            get: { viewModel.signInError != nil },
            set: { if !$0 { viewModel.signInError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.signInError ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Library").font(.headline)
            Spacer()
            Button {
                viewModel.reconcile()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecordingRow: View {
    let item: RecordingMetadata
    @ObservedObject var viewModel: LibraryViewModel
    @State private var isEditingName = false
    @State private var editedName: String = ""

    var body: some View {
        HStack(spacing: 10) {
            // The NSView itself draws nothing (see FilePromiseDragHandle) — this SF Symbol is
            // purely a visible affordance sitting underneath it so there's something to grab;
            // the invisible NSView on top is what actually intercepts the mouseDown/drag.
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                FilePromiseDragHandle(localPath: item.lastKnownLocalPath ?? "") {
                    viewModel.fileMovedOut()
                }
            }
            .frame(width: 20, height: 20)
            .opacity(item.lastKnownLocalPath == nil ? 0.2 : 1)
            .help(item.lastKnownLocalPath == nil ? "" : "Drag to move to another folder")

            Image(systemName: item.category.symbolName)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                if isEditingName {
                    TextField("Name", text: $editedName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .medium))
                } else {
                    Text((item.fileName as NSString).deletingPathExtension)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginEditing() }
                }
                HStack(spacing: 6) {
                    Text(item.category.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if item.lastKnownLocalPath == nil {
                        Label("Cloud only", systemImage: "icloud")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            cloudControl

            Menu {
                Button("Rename") { beginEditing() }
                Button("Reveal in Finder") { viewModel.revealInFinder(item) }
                    .disabled(item.lastKnownLocalPath == nil)
                Button("Move to Folder…") { viewModel.moveToFolder(item) }
                    .disabled(item.lastKnownLocalPath == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }

    private func beginEditing() {
        editedName = (item.fileName as NSString).deletingPathExtension
        isEditingName = true
    }

    private func commitRename() {
        isEditingName = false
        guard !editedName.isEmpty else { return }
        viewModel.rename(item, to: editedName)
    }

    @ViewBuilder
    private var cloudControl: some View {
        switch item.cloudUploadState {
        case .none:
            Button {
                viewModel.startCloudUpload(for: item)
            } label: {
                Image(systemName: "icloud.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(item.lastKnownLocalPath == nil)
            .help("Upload to OneDrive")
        case .creatingLink:
            ProgressView().controlSize(.small)
        case .uploading:
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: uploadFraction).frame(width: 60)
                if let webUrl = item.cloudWebUrl {
                    Button("Copy Link") { copyLink(webUrl) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                }
            }
        case .uploaded:
            Button {
                if let webUrl = item.cloudWebUrl { copyLink(webUrl) }
            } label: {
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(RecBarColor.green)
            }
            .buttonStyle(.plain)
            .help("Copy share link")
        case .failed:
            Button {
                viewModel.startCloudUpload(for: item)
            } label: {
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(RecBarColor.red)
            }
            .buttonStyle(.plain)
            .help(item.cloudErrorMessage ?? "Upload failed — click to retry")
        }
    }

    private var uploadFraction: Double {
        guard let total = item.sizeBytes, total > 0 else { return 0 }
        return Double(item.cloudBytesSent) / Double(total)
    }

    private func copyLink(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}

private struct OneDriveSignInView: View {
    let device: DeviceCodeResponse

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to OneDrive")
                .font(.headline)
            Text("Enter this code at the link below:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(device.userCode)
                .font(.system(.title, design: .monospaced))
                .textSelection(.enabled)
            Button("Open Microsoft Sign-In…") {
                if let url = URL(string: device.verificationUri) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            ProgressView("Waiting for confirmation…")
                .controlSize(.small)
        }
        .padding(24)
        .frame(width: 320)
    }
}
