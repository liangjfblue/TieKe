import AppKit
import Carbon
import UniformTypeIdentifiers

final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let captureService = ScreenCaptureService()
    private let recognition = TextRecognitionService()
    private var store: PinStore?
    private var overlays: [SelectionOverlay] = []
    private var pins: [UUID: PinWindowController] = [:]
    private var recognitionGeneration: [UUID: UUID] = [:]
    private var recognitionTasks: [UUID: RecognitionTask] = [:]
    private var hotkeys: GlobalHotkeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            store = try PinStore()
        } catch {
            showError(error)
            NSApp.terminate(nil)
            return
        }

        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "贴图")
        statusItem.button?.toolTip = "贴刻 · ⌘⇧2 截图"
        let menu = NSMenu()
        for (title, action) in [
            ("截图并贴图  ⌘⇧2", #selector(startCapturePin)),
            ("截图并复制  ⌃⌥3", #selector(startCaptureCopy)),
            ("截图并保存…  ⌃⌥4", #selector(startCaptureSave)),
            ("从剪贴板贴图  ⌃⌥2", #selector(pinClipboard)),
            ("从文件贴图…  ⌃⌥O", #selector(pinFile))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let permission = NSMenuItem(title: "打开录屏权限设置", action: #selector(openScreenCaptureSettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        let folder = NSMenuItem(title: "打开数据目录", action: #selector(openDataFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        let hotkeys = GlobalHotkeys()
        var failed: [String] = []
        let bindings: [(UInt32, UInt32, UInt32, String, () -> Void)] = [
            (1, 19, UInt32(cmdKey | shiftKey), "⌘⇧2", { [weak self] in self?.startCapturePin() }),
            (2, 19, UInt32(controlKey | optionKey), "⌃⌥2", { [weak self] in self?.pinClipboard() }),
            (3, 20, UInt32(controlKey | optionKey), "⌃⌥3", { [weak self] in self?.startCaptureCopy() }),
            (4, 21, UInt32(controlKey | optionKey), "⌃⌥4", { [weak self] in self?.startCaptureSave() }),
            (5, 31, UInt32(controlKey | optionKey), "⌃⌥O", { [weak self] in self?.pinFile() })
        ]
        for (id, code, modifiers, label, action) in bindings {
            if !hotkeys.register(id: id, keyCode: code, modifiers: modifiers, action: action) {
                failed.append(label)
            }
        }
        self.hotkeys = hotkeys
        if !failed.isEmpty { statusItem.button?.toolTip = "快捷键注册失败：\(failed.joined(separator: "、"))" }
        restorePins()
    }

    @objc private func startCapturePin() { startCapture(defaultAction: .pin) }
    @objc private func startCaptureCopy() { startCapture(defaultAction: .copy) }
    @objc private func startCaptureSave() { startCapture(defaultAction: .save) }

    private func startCapture(defaultAction: CaptureAction) {
        guard overlays.isEmpty else { return }
        Task { @MainActor in
            do {
                let captures = try await captureService.captureDisplays()
                for captured in captures {
                    let overlay = SelectionOverlay(captured: captured, defaultAction: defaultAction)
                    overlay.onConfirm = { [weak self] display, rect, size, marks, action in
                        self?.finishCapture(display: display, rect: rect, viewSize: size,
                                            marks: marks, action: action)
                    }
                    overlay.onCancel = { [weak self] in self?.dismissOverlays() }
                    overlays.append(overlay)
                }
                overlays.forEach { $0.activate() }
            } catch {
                showError(error)
            }
        }
    }

    private func finishCapture(display: CapturedDisplay, rect: CGRect, viewSize: CGSize,
                               marks: [AnnotationMark], action: CaptureAction) {
        guard let cropped = ImageCropper.crop(display.image, selection: rect, viewSize: viewSize) else { return }
        var output = cropped
        if !marks.isEmpty {
            let converted = CaptureAnnotator.convert(
                marks: marks, selection: rect,
                pixelSize: CGSize(width: cropped.width, height: cropped.height))
            if !converted.isEmpty {
                do {
                    output = try AnnotationRenderer.render(
                        base: cropped, marks: converted,
                        styleScale: CGFloat(cropped.width) / rect.width)
                } catch {
                    showError(error)
                }
            }
        }
        dismissOverlays()
        switch action {
        case .copy:
            if !ImageExchange.copy(output) { showError(ImageExchangeError.invalidImage) }
            return
        case .save:
            saveImageWithPanel(output)
            return
        case .recognize:
            recognition.recognize(output) { [weak self] result in
                switch result {
                case .success(let text) where !text.isEmpty:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self?.statusItem.button?.toolTip = "识字结果已复制"
                case .success:
                    self?.showError(RecognitionError.noText)
                case .failure(let error):
                    self?.showError(error)
                }
            }
            return
        case .pin:
            break
        }
        // 最小窗口尺寸按比例放大，不破坏图片宽高比
        let scale = max(1, 100 / max(rect.width, 1), 80 / max(rect.height, 1))
        let width = rect.width * scale
        let height = rect.height * scale
        let centerX = display.screen.frame.minX + rect.midX
        let centerY = display.screen.frame.maxY - rect.midY
        let frame = CGRect(x: centerX - width / 2, y: centerY - height / 2,
                           width: width, height: height)
        createPin(image: output, frame: frame)
    }

    @objc private func pinClipboard() {
        do {
            let image = try ImageExchange.loadClipboard()
            createPin(image: image, frame: centeredFrame(for: image))
        } catch { showError(error) }
    }

    @objc private func pinFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let image = try ImageExchange.load(url: url)
                createPin(image: image, frame: centeredFrame(for: image))
            } catch { showError(error) }
        }
    }

    private func centeredFrame(for image: CGImage) -> CGRect {
        let area = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = min(1, min(area.width * 0.75 / CGFloat(image.width), area.height * 0.75 / CGFloat(image.height)))
        let width = max(100, CGFloat(image.width) * scale)
        let height = max(80, CGFloat(image.height) * scale)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private func createPin(image: CGImage, frame: CGRect) {
        guard let store else { return }
        do {
            let record = try store.save(image: image, frame: frame)
            openPin(record: record, image: image)
            recognize(image, id: record.id)
        } catch { showError(error) }
    }

    private func saveImageWithPanel(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "截图-\(formatter.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ImageExchange.savePNG(image, to: url) }
        catch { showError(error) }
    }

    private func recognize(_ image: CGImage, id: UUID) {
        let generation = UUID()
        recognitionGeneration[id] = generation
        recognitionTasks[id]?.cancel()
        let task = recognition.recognize(image) { [weak self] result in
            guard let self, self.recognitionGeneration[id] == generation else { return }
            switch result {
            case .success(let text):
                self.pins[id]?.updateOCR(text)
                try? self.store?.saveOCR(text, id: id)
            case .failure(let error):
                self.pins[id]?.updateOCRError()
                self.statusItem.button?.toolTip = "识字失败：\(error.localizedDescription)"
            }
        }
        recognitionTasks[id] = task
    }

    private func dismissOverlays() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    private func openPin(record: PinRecord, image: CGImage) {
        let controller = PinWindowController(record: record, image: image)
        controller.onClose = { [weak self] id in
            try? self?.store?.close(id: id)
            self?.pins.removeValue(forKey: id)
            self?.recognitionGeneration.removeValue(forKey: id)
            self?.recognitionTasks[id]?.cancel()
            self?.recognitionTasks.removeValue(forKey: id)
        }
        controller.onFrameChange = { [weak self] id, frame in
            try? self?.store?.updateFrame(frame, id: id)
        }
        controller.onAnnotatedImage = { [weak self] id, updated in
            guard let self, let store = self.store else { return false }
            do {
                try store.replaceImage(updated, for: record)
                try store.saveOCR("", id: id)
                self.recognize(updated, id: id)
                return true
            } catch {
                self.showError(error)
                return false
            }
        }
        pins[record.id] = controller
        controller.show()
    }

    private func restorePins() {
        guard let store else { return }
        do {
            for record in try store.openRecords() {
                do {
                    let image = try store.image(for: record)
                    openPin(record: record, image: image)
                    if record.ocrText == nil || record.ocrText?.isEmpty == true {
                        recognize(image, id: record.id)
                    }
                } catch {
                    try? store.close(id: record.id)
                    showError(error)
                }
            }
        } catch {
            showError(error)
        }
    }

    @objc private func openDataFolder() {
        if let store { NSWorkspace.shared.open(store.root) }
    }

    @objc private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
