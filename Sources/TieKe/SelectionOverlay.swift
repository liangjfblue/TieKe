import AppKit

enum CaptureAction {
    case pin
    case copy
    case save
    case recognize
}

/// 选区覆盖层上的标注工具。select 是默认的框选模式。
enum SelectionTool: Int {
    case select
    case arrow
    case text
    case mosaic
    case spotlight
    case magnifier
    case shape
}

/// 把覆盖层（顶部原点视图坐标）的标注换算到裁剪图像素坐标（底部原点）。
enum CaptureAnnotator {
    static func convert(marks: [AnnotationMark], selection: CGRect,
                        pixelSize: CGSize) -> [AnnotationMark] {
        guard selection.width >= 2, selection.height >= 2,
              pixelSize.width > 0, pixelSize.height > 0 else { return [] }
        let sx = pixelSize.width / selection.width
        let sy = pixelSize.height / selection.height
        func map(point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - selection.minX) * sx,
                    y: (selection.maxY - point.y) * sy)
        }
        func map(rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - selection.minX) * sx,
                   y: (selection.maxY - rect.maxY) * sy,
                   width: rect.width * sx,
                   height: rect.height * sy)
        }
        var result: [AnnotationMark] = []
        for mark in marks {
            switch mark {
            case .arrow(let start, let end): result.append(.arrow(map(point: start), map(point: end)))
            case .text(let value, let origin, let style): result.append(.text(value, map(point: origin), style))
            case .mosaic(let region): result.append(.mosaic(map(rect: region)))
            case .spotlight(let region, let style): result.append(.spotlight(map(rect: region), style))
            case .magnifier(let region, let style): result.append(.magnifier(map(rect: region), style))
            case .shape(let region, let style): result.append(.shape(map(rect: region), style))
            }
        }
        return result
    }
}

enum SelectionToolbarLayout {
    static func frame(selection: CGRect, bounds: CGRect, size: CGSize) -> CGRect? {
        guard selection.width >= 2, selection.height >= 2 else { return nil }
        let gap: CGFloat = 8
        let margin: CGFloat = 8
        let x = min(max(selection.maxX - size.width, bounds.minX + margin),
                    bounds.maxX - size.width - margin)
        let below = selection.maxY + gap
        if below + size.height <= bounds.maxY - margin {
            return CGRect(origin: CGPoint(x: x, y: below), size: size)
        }
        let above = selection.minY - gap - size.height
        if above >= bounds.minY + margin {
            return CGRect(origin: CGPoint(x: x, y: above), size: size)
        }
        let sideY = min(max(selection.minY, bounds.minY + margin),
                        bounds.maxY - size.height - margin)
        let right = selection.maxX + gap
        if right + size.width <= bounds.maxX - margin {
            return CGRect(origin: CGPoint(x: right, y: sideY), size: size)
        }
        let left = selection.minX - gap - size.width
        if left >= bounds.minX + margin {
            return CGRect(origin: CGPoint(x: left, y: sideY), size: size)
        }
        return CGRect(origin: CGPoint(x: x, y: max(bounds.minY + margin,
                                                    min(below, bounds.maxY - size.height - margin))),
                      size: size)
    }
}

final class SelectionOverlay: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    let captured: CapturedDisplay
    var onConfirm: ((CapturedDisplay, CGRect, CGSize, [AnnotationMark], CaptureAction) -> Void)?
    var onCancel: (() -> Void)?

    init(captured: CapturedDisplay, defaultAction: CaptureAction = .pin) {
        self.captured = captured
        super.init(contentRect: captured.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        let view = SelectionView(image: captured.image)
        view.defaultAction = defaultAction
        contentView = view
        view.onConfirm = { [weak self] rect, action in
            guard let self else { return }
            self.onConfirm?(self.captured, rect, view.bounds.size, view.marks, action)
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
    }

    func activate() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(contentView)
    }
}

private final class SelectionView: NSView {
    let image: CGImage
    var onConfirm: ((CGRect, CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    var defaultAction: CaptureAction = .pin
    var marks: [AnnotationMark] { history.marks }
    var tool: SelectionTool = .select
    private(set) var history = MarkHistory()
    private var anchor: CGPoint?
    private var selection: CGRect = .zero
    private var draggedEdges: EdgeMask = []
    private var dragStart: CGPoint = .zero
    private var originalSelection: CGRect = .zero
    private var drawAnchor: CGPoint?
    private var drawCurrent: CGPoint?
    private var movingSelection = false
    private var moveOriginalMarks: [AnnotationMark] = []
    private var movingMarkIndex: Int?
    private var markDragStart: CGPoint = .zero
    private var markOriginalMarks: [AnnotationMark] = []
    private var toolButtons: [SelectionTool: NSButton] = [:]
    private let inlineText = InlineTextEditor()
    private let textStyleBar = AnnotationStyleBar(mode: .text)
    private let spotlightStyleBar = AnnotationStyleBar(mode: .spotlight)
    private let magnifierStyleBar = AnnotationStyleBar(mode: .magnifier)
    private let shapeStyleBar = AnnotationStyleBar(mode: .shape)
    private let toolbar = NSView(frame: .zero)

    private struct EdgeMask: OptionSet {
        let rawValue: Int
        static let left = EdgeMask(rawValue: 1)
        static let right = EdgeMask(rawValue: 2)
        static let top = EdgeMask(rawValue: 4)
        static let bottom = EdgeMask(rawValue: 8)
    }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        inlineText.onCommit = { [weak self] value, origin, style in
            self?.history.append(.text(value, origin, style))
            self?.needsDisplay = true
        }
        setupToolbar()
        addSubview(textStyleBar)
        addSubview(spotlightStyleBar)
        addSubview(magnifierStyleBar)
        addSubview(shapeStyleBar)
        textStyleBar.isHidden = true
        spotlightStyleBar.isHidden = true
        magnifierStyleBar.isHidden = true
        shapeStyleBar.isHidden = true
        textStyleBar.onChange = { [weak self] in
            guard let self else { return }
            self.inlineText.apply(style: self.textStyleBar.textStyle)
            self.history.applyTextStyle(self.textStyleBar.textStyle)
            self.needsDisplay = true
        }
        spotlightStyleBar.onChange = { [weak self] in
            guard let self else { return }
            self.history.applySpotlightStyle(self.spotlightStyleBar.spotlightStyle)
            self.needsDisplay = true
        }
        magnifierStyleBar.onChange = { [weak self] in
            guard let self else { return }
            self.history.applyMagnifierStyle(self.magnifierStyleBar.magnifierStyle)
            self.needsDisplay = true
        }
        shapeStyleBar.onChange = { [weak self] in
            guard let self else { return }
            self.history.applyShapeStyle(self.shapeStyleBar.shapeStyle)
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func setupToolbar() {
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        toolbar.shadow = shadow
        toolbar.isHidden = true

        var x: CGFloat = 8
        let tools: [(SelectionTool, String, String)] = [
            (.arrow, "箭头 A", "arrow.up.right"),
            (.text, "文字 T", "textformat"),
            (.mosaic, "马赛克 M", "square.grid.3x3"),
            (.spotlight, "聚光灯 S", "flashlight.on.fill"),
            (.magnifier, "放大镜 Z", "plus.magnifyingglass"),
            (.shape, "方框 G", "rectangle")
        ]
        for (tool, tip, symbol) in tools {
            let button = makeButton(symbol: symbol, tip: tip, tag: 100 + tool.rawValue)
            button.frame = CGRect(x: x, y: 5, width: 34, height: 34)
            toolbar.addSubview(button)
            toolButtons[tool] = button
            x += 38
        }
        let undo = makeButton(symbol: "arrow.uturn.backward", tip: "撤销标注 ⌘Z", tag: 200)
        undo.frame = CGRect(x: x, y: 5, width: 34, height: 34)
        toolbar.addSubview(undo)
        x += 38
        let redo = makeButton(symbol: "arrow.uturn.forward", tip: "重做标注 ⌘⇧Z", tag: 201)
        redo.frame = CGRect(x: x, y: 5, width: 34, height: 34)
        toolbar.addSubview(redo)
        x += 38
        let separator = NSView(frame: CGRect(x: x, y: 8, width: 1, height: 28))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        toolbar.addSubview(separator)
        x += 9
        // 动作组靠右：复制固定在最右
        let actions: [(Int, String, String)] = [
            (0, "贴图", "pin.fill"),
            (2, "保存", "square.and.arrow.down"),
            (3, "识字复制", "text.viewfinder"),
            (4, "取消", "xmark"),
            (1, "复制", "doc.on.doc")
        ]
        for (tag, tip, symbol) in actions {
            let button = makeButton(symbol: symbol, tip: tip, tag: tag)
            button.contentTintColor = tag == 0 ? .systemBlue : .darkGray
            button.layer?.backgroundColor = (tag == 0 ? NSColor.systemBlue.withAlphaComponent(0.10)
                                                      : NSColor.clear).cgColor
            button.frame = CGRect(x: x, y: 5, width: 34, height: 34)
            toolbar.addSubview(button)
            x += 38
        }
        toolbar.frame.size = CGSize(width: x + 4, height: 44)
        addSubview(toolbar)
        restyleToolButtons()
    }

    /// 样式栏贴在工具条上方，仅文字/聚光灯工具时显示。
    private func updateStyleBars(above toolbarFrame: CGRect?) {
        guard let toolbarFrame, !toolbar.isHidden,
              tool == .text || tool == .spotlight || tool == .magnifier || tool == .shape else {
            textStyleBar.isHidden = true
            spotlightStyleBar.isHidden = true
            magnifierStyleBar.isHidden = true
            shapeStyleBar.isHidden = true
            return
        }
        let bar: AnnotationStyleBar
        switch tool {
        case .text: bar = textStyleBar
        case .spotlight: bar = spotlightStyleBar
        case .magnifier: bar = magnifierStyleBar
        default: bar = shapeStyleBar
        }
        let otherBars: [AnnotationStyleBar] = [textStyleBar, spotlightStyleBar, magnifierStyleBar, shapeStyleBar].filter { $0 !== bar }
        otherBars.forEach { $0.isHidden = true }
        let size = bar.preferredSize
        var origin = CGPoint(x: toolbarFrame.minX, y: toolbarFrame.maxY + 6)
        if origin.y + size.height > bounds.maxY - 8 {
            origin.y = toolbarFrame.minY - 6 - size.height
        }
        origin.x = max(bounds.minX + 8, min(origin.x, bounds.maxX - size.width - 8))
        bar.frame = CGRect(origin: origin, size: size)
        bar.isHidden = false
    }

    private func makeButton(symbol: String, tip: String, tag: Int) -> NSButton {
        let button = NSButton(frame: .zero)
        button.target = self
        button.action = #selector(performToolbarAction(_:))
        button.tag = tag
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        return button
    }

    private func restyleToolButtons() {
        for (tool, button) in toolButtons {
            let selected = tool == self.tool
            button.layer?.backgroundColor = (selected ? NSColor.systemBlue.withAlphaComponent(0.15)
                                                      : NSColor.clear).cgColor
            button.contentTintColor = selected ? .systemBlue : .darkGray
        }
    }

    private func updateToolbar() {
        guard let frame = SelectionToolbarLayout.frame(selection: selection,
                                                       bounds: bounds, size: toolbar.frame.size) else {
            toolbar.isHidden = true
            updateStyleBars(above: nil)
            return
        }
        toolbar.frame = frame
        toolbar.isHidden = false
        updateStyleBars(above: frame)
    }

    @objc private func performToolbarAction(_ sender: NSButton) {
        switch sender.tag {
        case 0: confirm(.pin)
        case 1: confirm(.copy)
        case 2: confirm(.save)
        case 3: confirm(.recognize)
        case 4: onCancel?()
        case 200: undoLastMark()
        case 201: redoLastMark()
        default:
            guard let tool = SelectionTool(rawValue: sender.tag - 100) else { return }
            selectTool(tool)
        }
    }

    private func confirm(_ action: CaptureAction) {
        inlineText.end(commit: true)
        guard selection.width >= 2, selection.height >= 2 else { return }
        onConfirm?(selection, action)
    }

    private func selectTool(_ tool: SelectionTool) {
        inlineText.end(commit: true)
        self.tool = tool
        restyleToolButtons()
        window?.invalidateCursorRects(for: self)
        updateStyleBars(above: toolbar.isHidden ? nil : toolbar.frame)
    }

    private func undoLastMark() {
        guard history.undo() != nil else { return }
        needsDisplay = true
    }

    private func redoLastMark() {
        guard history.redo() != nil else { return }
        needsDisplay = true
    }

    private func clampToSelection(_ point: CGPoint) -> CGPoint {
        guard selection.width >= 2, selection.height >= 2 else { return point }
        return CGPoint(x: min(max(point.x, selection.minX), selection.maxX),
                       y: min(max(point.y, selection.minY), selection.maxY))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        if selection.width > 1, selection.height > 1 {
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.clip(to: selection)
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
            NSGraphicsContext.current?.cgContext.restoreGState()
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()
            NSColor.white.setFill()
            for point in handlePoints {
                NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
            drawSizeLabel()
        }

        for mark in marks { drawPreview(mark) }
        if let drawAnchor, let drawCurrent {
            switch tool {
            case .arrow:
                drawArrowPreview(drawAnchor, drawCurrent)
            case .mosaic:
                let rect = CGRect(x: min(drawAnchor.x, drawCurrent.x),
                                  y: min(drawAnchor.y, drawCurrent.y),
                                  width: abs(drawCurrent.x - drawAnchor.x),
                                  height: abs(drawCurrent.y - drawAnchor.y))
                AnnotationRenderer.drawMosaic(base: image, region: rect, in: bounds, flipped: true)
            case .spotlight, .magnifier, .shape, .text, .select: break
            }
        }
        // 聚光灯压暗全局只画一次（含进行中的），放大镜区域保持明亮
        var spotlights: [(CGRect, SpotlightStyle)] = []
        for mark in history.marks {
            if case .spotlight(let r, let s) = mark { spotlights.append((r, s)) }
        }
        var exemptions: [(CGRect, SpotlightShape)] = []
        for mark in history.marks {
            if case .magnifier(let r, let s) = mark { exemptions.append((r, s.shape)) }
        }
        if tool == .spotlight, let drawAnchor, let drawCurrent {
            spotlights.append((CGRect(x: min(drawAnchor.x, drawCurrent.x),
                                      y: min(drawAnchor.y, drawCurrent.y),
                                      width: abs(drawCurrent.x - drawAnchor.x),
                                      height: abs(drawCurrent.y - drawAnchor.y)),
                               spotlightStyleBar.spotlightStyle))
        }
        if tool == .magnifier, let drawAnchor, let drawCurrent {
            exemptions.append((CGRect(x: min(drawAnchor.x, drawCurrent.x),
                                      y: min(drawAnchor.y, drawCurrent.y),
                                      width: abs(drawCurrent.x - drawAnchor.x),
                                      height: abs(drawCurrent.y - drawAnchor.y)),
                               magnifierStyleBar.magnifierStyle.shape))
        }
        AnnotationRenderer.dimOutside(spotlights: spotlights, exemptions: exemptions, in: selection)
        if tool == .magnifier, let drawAnchor, let drawCurrent {
            let rect = CGRect(x: min(drawAnchor.x, drawCurrent.x), y: min(drawAnchor.y, drawCurrent.y),
                              width: abs(drawCurrent.x - drawAnchor.x), height: abs(drawCurrent.y - drawAnchor.y))
            AnnotationRenderer.drawMagnifier(base: image, region: rect, in: selection,
                                             imageRect: bounds,
                                             style: magnifierStyleBar.magnifierStyle)
        }
        if tool == .shape, let drawAnchor, let drawCurrent {
            let rect = CGRect(x: min(drawAnchor.x, drawCurrent.x), y: min(drawAnchor.y, drawCurrent.y),
                              width: abs(drawCurrent.x - drawAnchor.x), height: abs(drawCurrent.y - drawAnchor.y))
            AnnotationRenderer.drawShape(rect, style: shapeStyleBar.shapeStyle)
        }
        drawHint()
    }

    /// 固定在截图区域内的放大镜：圆圈不动，内容取光标处放大约 2.5 倍。
    private func drawMagnifier(anchor: CGPoint, source: CGPoint) {
        let radius: CGFloat = 80
        let zoom: CGFloat = 2.5
        let circle = CGRect(x: anchor.x - radius, y: anchor.y - radius,
                            width: radius * 2, height: radius * 2)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -source.x, y: -source.y)
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 2, dy: 2))
        ring.lineWidth = 4
        NSColor.systemRed.setStroke()
        ring.stroke()
    }

    /// 操作提示固定在左下角，多行纵向排列。
    private func drawHint() {
        let lines = [
            "拖动框选 · 在选区内拖动可整体移动",
            "A 箭头 · T 文字 · M 马赛克 · S 聚光灯",
            "Z 放大镜 · G 方框 · ⌘Z 撤销 · ⌘⇧Z 重做",
            "回车执行 · ⌘C 复制 · ⌘S 保存",
            "Esc 取消截图"
        ]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ]
        let lineHeight: CGFloat = 26
        let margin: CGFloat = 20
        let total = CGFloat(lines.count) * lineHeight
        var y = bounds.maxY - margin - total
        for line in lines {
            line.draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
            y += lineHeight
        }
    }

    private func drawPreview(_ mark: AnnotationMark) {
        switch mark {
        case .arrow(let start, let end):
            drawArrowPreview(start, end)
        case .text(let value, let origin, let style):
            AnnotationRenderer.drawText(value, at: origin, style: style, flipped: true)
        case .mosaic(let region):
            AnnotationRenderer.drawMosaic(base: image, region: region, in: bounds, flipped: true)
        case .spotlight:
            break // 压暗由 dimOutside 统一处理，避免多层叠加
        case .magnifier(let region, let style):
            AnnotationRenderer.drawMagnifier(base: image, region: region, in: selection,
                                             imageRect: bounds, style: style)
        case .shape(let region, let style):
            AnnotationRenderer.drawShape(region, style: style)
        }
    }

    private func drawArrowPreview(_ start: CGPoint, _ end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 4 else { return }
        let ux = dx / length
        let uy = dy / length
        let wing: CGFloat = 14
        let left = CGPoint(x: end.x - ux * wing - uy * wing * 0.55,
                           y: end.y - uy * wing + ux * wing * 0.55)
        let right = CGPoint(x: end.x - ux * wing + uy * wing * 0.55,
                            y: end.y - uy * wing - ux * wing * 0.55)
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.move(to: left)
        path.line(to: end)
        path.line(to: right)
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 命中已有放大镜 / 方框：进入拖动模式，可移到截图内任意位置
        if let index = hitMovableMark(at: point) {
            movingMarkIndex = index
            markDragStart = point
            markOriginalMarks = history.marks
            return
        }
        if tool != .select {
            if tool == .text {
                guard selection.contains(point) else { return }
                inlineText.end(commit: true)
                inlineText.begin(in: self, at: clampToSelection(point),
                                 style: textStyleBar.textStyle)
            } else {
                inlineText.end(commit: true)
                drawAnchor = clampToSelection(point)
                drawCurrent = drawAnchor
                needsDisplay = true
            }
            return
        }
        inlineText.end(commit: true)
        toolbar.isHidden = true
        updateStyleBars(above: nil)
        draggedEdges = hitEdges(at: point)
        movingSelection = false
        if !draggedEdges.isEmpty {
            anchor = nil
            dragStart = point
            originalSelection = selection
        } else if selection.width >= 2, selection.height >= 2, selection.contains(point) {
            // 选区内按下：整体移动选区，标注跟随
            movingSelection = true
            dragStart = point
            originalSelection = selection
            moveOriginalMarks = history.marks
        } else {
            // 智能探测命中且未拖动时，点击即选中该区域
            anchor = point
            selection = .zero
            history = MarkHistory()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = movingMarkIndex {
            history.replace(marks: markOriginalMarks)
            history.moveMark(at: index, by: CGPoint(x: point.x - markDragStart.x,
                                                    y: point.y - markDragStart.y))
            needsDisplay = true
            return
        }
        if movingSelection {
            let dx = max(bounds.minX - originalSelection.minX,
                         min(point.x - dragStart.x, bounds.maxX - originalSelection.maxX))
            let dy = max(bounds.minY - originalSelection.minY,
                         min(point.y - dragStart.y, bounds.maxY - originalSelection.maxY))
            selection = originalSelection.offsetBy(dx: dx, dy: dy)
            history.replace(marks: moveOriginalMarks)
            history.translate(CGPoint(x: dx, y: dy))
            needsDisplay = true
            return
        }
        if drawAnchor != nil {
            drawCurrent = clampToSelection(point)
            needsDisplay = true
            return
        }
        if !draggedEdges.isEmpty {
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            var left = originalSelection.minX
            var right = originalSelection.maxX
            var top = originalSelection.minY
            var bottom = originalSelection.maxY
            if draggedEdges.contains(.left) { left = min(right - 2, max(bounds.minX, left + dx)) }
            if draggedEdges.contains(.right) { right = max(left + 2, min(bounds.maxX, right + dx)) }
            if draggedEdges.contains(.top) { top = min(bottom - 2, max(bounds.minY, top + dy)) }
            if draggedEdges.contains(.bottom) { bottom = max(top + 2, min(bounds.maxY, bottom + dy)) }
            selection = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            needsDisplay = true
            return
        }
        guard let anchor else { return }
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if drawAnchor != nil {
            defer { drawAnchor = nil; drawCurrent = nil; needsDisplay = true }
            guard let drawAnchor, let drawCurrent else { return }
            guard hypot(drawCurrent.x - drawAnchor.x, drawCurrent.y - drawAnchor.y) >= 4 else { return }
            let rect = CGRect(x: min(drawAnchor.x, drawCurrent.x), y: min(drawAnchor.y, drawCurrent.y),
                              width: abs(drawCurrent.x - drawAnchor.x),
                              height: abs(drawCurrent.y - drawAnchor.y))
            switch tool {
            case .arrow: history.append(.arrow(drawAnchor, drawCurrent))
            case .mosaic: history.append(.mosaic(rect))
            case .spotlight: history.append(.spotlight(rect, spotlightStyleBar.spotlightStyle))
            case .magnifier: history.append(.magnifier(rect, magnifierStyleBar.magnifierStyle))
            case .shape: history.append(.shape(rect, shapeStyleBar.shapeStyle))
            case .text, .select: break
            }
            return
        }
        mouseDragged(with: event)
        anchor = nil
        draggedEdges = []
        movingSelection = false
        movingMarkIndex = nil
        window?.invalidateCursorRects(for: self)
        updateToolbar()
    }

    /// 命中最上层可拖动的标注（放大镜 / 方框），形状感知。
    private func hitMovableMark(at point: CGPoint) -> Int? {
        for (index, mark) in history.marks.enumerated().reversed() {
            let hit: Bool
            switch mark {
            case .magnifier(let rect, let style):
                hit = shapeHit(rect: rect.standardized, shape: style.shape, point: point)
            case .shape(let rect, let style):
                hit = shapeHit(rect: rect.standardized, shape: style.kind == .rectangle ? .rectangle : .ellipse,
                               point: point)
            default:
                hit = false
            }
            if hit { return index }
        }
        return nil
    }

    private func shapeHit(rect: CGRect, shape: SpotlightShape, point: CGPoint) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        switch shape {
        case .rectangle:
            return rect.contains(point)
        case .ellipse:
            let dx = (point.x - rect.midX) / (rect.width / 2)
            let dy = (point.y - rect.midY) / (rect.height / 2)
            return dx * dx + dy * dy <= 1
        }
    }

    /// 选区内光标为十字架，提示可整体移动。
    override func resetCursorRects() {
        if tool == .select, selection.width >= 2, selection.height >= 2 {
            addCursorRect(selection, cursor: NSCursor.crosshair)
        }
    }

    private func drawSizeLabel() {
        let label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ]
        let labelSize = label.size(withAttributes: attrs)
        var origin = CGPoint(x: selection.maxX - labelSize.width - 10,
                             y: selection.maxY + 6)
        if origin.y + labelSize.height > bounds.maxY - 2 {
            origin.y = selection.minY - labelSize.height - 6
        }
        label.draw(at: origin, withAttributes: attrs)
    }

    private var handlePoints: [CGPoint] {
        let x = [selection.minX, selection.midX, selection.maxX]
        let y = [selection.minY, selection.midY, selection.maxY]
        return [CGPoint(x: x[0], y: y[0]), CGPoint(x: x[1], y: y[0]), CGPoint(x: x[2], y: y[0]),
                CGPoint(x: x[0], y: y[1]), CGPoint(x: x[2], y: y[1]),
                CGPoint(x: x[0], y: y[2]), CGPoint(x: x[1], y: y[2]), CGPoint(x: x[2], y: y[2])]
    }

    private func hitEdges(at point: CGPoint) -> EdgeMask {
        guard selection.width >= 2, selection.height >= 2 else { return [] }
        let tolerance: CGFloat = 8
        let nearX = point.x >= selection.minX - tolerance && point.x <= selection.maxX + tolerance
        let nearY = point.y >= selection.minY - tolerance && point.y <= selection.maxY + tolerance
        var result: EdgeMask = []
        if nearY && abs(point.x - selection.minX) <= tolerance { result.insert(.left) }
        if nearY && abs(point.x - selection.maxX) <= tolerance { result.insert(.right) }
        if nearX && abs(point.y - selection.minY) <= tolerance { result.insert(.top) }
        if nearX && abs(point.y - selection.maxY) <= tolerance { result.insert(.bottom) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 8 where selection.width >= 2: onConfirm?(selection, .copy); return
            case 1 where selection.width >= 2: onConfirm?(selection, .save); return
            case 6 where event.modifierFlags.contains(.shift): redoLastMark(); return
            case 6: undoLastMark(); return
            default: break
            }
        }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": selectTool(.arrow); return
            case "t": selectTool(.text); return
            case "m": selectTool(.mosaic); return
            case "s": selectTool(.spotlight); return
            case "z": selectTool(.magnifier); return
            case "g": selectTool(.shape); return
            default: break
            }
        }
        switch event.keyCode {
        case 36, 76:
            if selection.width >= 2, selection.height >= 2 { onConfirm?(selection, defaultAction) }
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}
