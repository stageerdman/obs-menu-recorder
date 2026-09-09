import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A tiny drag-handle view bridging AppKit's `NSFilePromiseProvider` into SwiftUI — this is
/// the only way to get a real move-to-Finder drag. Plain SwiftUI `.onDrag`/`.draggable`
/// backed by a file `URL` produces a Finder *copy*, not a move, which isn't what dragging a
/// recording out of the Library window is supposed to do. Only this small glyph is AppKit;
/// the rest of the row stays pure SwiftUI.
///
/// This dev environment has no way to visually exercise drag-and-drop (no GUI automation for
/// native macOS apps — see CLAUDE.md's "Testing notes"), so `LibraryViewModel.moveToFolder`
/// exists as a guaranteed-reliable fallback via a plain `NSOpenPanel` — don't remove it even
/// if this starts working perfectly in real use.
struct FilePromiseDragHandle: NSViewRepresentable {
    let localPath: String
    let onMoved: () -> Void

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.localPath = localPath
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {
        nsView.localPath = localPath
        nsView.onMoved = onMoved
    }
}

final class DragHandleView: NSView {
    var localPath: String = ""
    var onMoved: (() -> Void)?
    private var promiseDelegate: PromiseDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func mouseDown(with event: NSEvent) {
        guard FileManager.default.fileExists(atPath: localPath) else { return }
        let delegate = PromiseDelegate(localPath: localPath, onMoved: { [weak self] in self?.onMoved?() })
        promiseDelegate = delegate // retained for the duration of the drag

        let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: delegate)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        image.unlockFocus()
        return image
    }
}

extension DragHandleView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

/// Writes the promised file by moving (not copying) the real local file to the destination
/// Finder chose — `FileManager.moveItem` is same-volume-instant and correctly falls back to
/// copy+delete cross-volume, satisfying "real move" either way with one call.
private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let localPath: String
    let onMoved: () -> Void

    init(localPath: String, onMoved: @escaping () -> Void) {
        self.localPath = localPath
        self.onMoved = onMoved
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (localPath as NSString).lastPathComponent
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                              completionHandler: @escaping (Error?) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(atPath: localPath, toPath: url.path)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
        DispatchQueue.main.async { [onMoved] in onMoved() }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.sharedQueue
    }

    private static let sharedQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.recbar.app.filepromise"
        return queue
    }()
}
