import AppKit

private enum PinShortcut {
    case annotate, copyImage, copyOCR, close
}

private final class PinPanel: NSPanel {
    var onShortcut: ((PinShortcut) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let letter = event.charactersIgnoringModifiers?.lowercased()
        let shortcut: PinShortcut?
        if modifiers.isEmpty && event.keyCode == 49 { shortcut = .annotate }
        else if modifiers.isEmpty && event.keyCode == 53 { shortcut = .close }
        else if modifiers == [.command] && letter == "c" { shortcut = .copyImage }
        else if modifiers == [.shift] && letter == "c" { shortcut = .copyOCR }
        else { shortcut = nil }
        guard let shortcut else { return false }
        onShortcut?(shortcut)
        return true
    }
}

/// NSImageView 默认吞掉鼠标事件，导致 isMovableByWindowBackground 失效。
/// 放开 mouseDownCanMoveWindow，贴图才能按住拖动。
private final class PinImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        super.mouseDown(with: event)
    }
}

final class PinWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    let id: UUID
    var onClose: ((UUID) -> Void)?
    var onFrameChange: ((UUID, CGRect) -> Void)?
    var onAnnotatedImage: ((UUID, CGImage) -> Bool)?
    private var ocrText: String?
    private var ocrFailed = false
    private var image: CGImage
    private let imageView: PinImageView
    private var annotationEditor: AnnotationEditorController?

    init(record: PinRecord, image: CGImage) {
        id = record.id
        self.image = image
        ocrText = record.ocrText?.isEmpty == true ? nil : record.ocrText
        let window = PinPanel(contentRect: record.frame,
                             styleMask: [.borderless, .resizable],
                             backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSPanel 默认在应用失活时隐藏，会导致点击外部后贴图"消失"
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.minSize = CGSize(width: 100, height: 80)
        window.isReleasedWhenClosed = false

        imageView = PinImageView(frame: window.contentView?.bounds ?? .zero)
        imageView.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(imageView)
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        imageView.onDoubleClick = { [weak self] in self?.annotateImage() }
        window.delegate = self
        window.onShortcut = { [weak self] shortcut in
            switch shortcut {
            case .annotate: self?.annotateImage()
            case .copyImage: self?.copyImage()
            case .copyOCR: self?.copyOCR()
            case .close: self?.closePin()
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        imageView.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() { window?.makeKeyAndOrderFront(nil) }
    func updateOCR(_ text: String) { ocrText = text }
    func updateOCRError() { ocrFailed = true }

    private func updateImage(_ updated: CGImage) {
        image = updated
        imageView.image = NSImage(cgImage: updated, size: CGSize(width: updated.width, height: updated.height))
        ocrText = nil
        ocrFailed = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if ocrText == nil {
            let status = NSMenuItem(title: ocrFailed ? "识字失败" : "识字中…", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        let copy = NSMenuItem(title: "复制识字结果  ⇧C", action: #selector(copyOCR), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = !(ocrText ?? "").isEmpty
        menu.addItem(copy)
        let copyImage = NSMenuItem(title: "复制图片  ⌘C", action: #selector(copyImage), keyEquivalent: "")
        copyImage.target = self
        menu.addItem(copyImage)
        let annotate = NSMenuItem(title: "标注…  空格", action: #selector(annotateImage), keyEquivalent: "")
        annotate.target = self
        menu.addItem(annotate)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭贴图", action: #selector(closePin), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
    }

    @objc private func copyOCR() {
        guard let text = ocrText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyImage() {
        _ = ImageExchange.copy(image)
    }

    @objc private func annotateImage() {
        if let annotationEditor { annotationEditor.show(); return }
        let editor = AnnotationEditorController(image: image)
        editor.onSave = { [weak self] updated in
            guard let self, self.onAnnotatedImage?(self.id, updated) == true else { return false }
            self.updateImage(updated)
            return true
        }
        editor.onFinish = { [weak self] in self?.annotationEditor = nil }
        annotationEditor = editor
        editor.show()
    }

    @objc private func closePin() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        annotationEditor?.close()
        onClose?(id)
    }
    func windowDidMove(_ notification: Notification) { reportFrame() }
    func windowDidResize(_ notification: Notification) { reportFrame() }

    private func reportFrame() {
        guard let frame = window?.frame else { return }
        onFrameChange?(id, frame)
    }
}
