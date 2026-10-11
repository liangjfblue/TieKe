import AppKit

enum AnnotationTool: Int {
    case arrow
    case text
    case mosaic
    case spotlight
    case magnifier
    case shape
}

private enum AnnotationShortcut {
    case arrow, text, mosaic, spotlight, magnifier, shape, undo, redo, save, cancel
}

private final class AnnotationEditorWindow: NSWindow {
    var onShortcut: ((AnnotationShortcut) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if firstResponder is NSTextView { return false } // 文字输入中，不拦截按键
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let letter = event.charactersIgnoringModifiers?.lowercased()
        let shortcut: AnnotationShortcut?
        if modifiers.isEmpty {
            switch letter {
            case "a": shortcut = .arrow
            case "t": shortcut = .text
            case "m": shortcut = .mosaic
            case "s": shortcut = .spotlight
            case "z": shortcut = .magnifier
            case "g": shortcut = .shape
            default: shortcut = event.keyCode == 53 ? .cancel : nil
            }
        } else if modifiers == [.command] {
            if letter == "z" { shortcut = .undo }
            else if event.keyCode == 36 || event.keyCode == 76 { shortcut = .save }
            else { shortcut = nil }
        } else if modifiers == [.command, .shift] {
            if letter == "z" { shortcut = .redo }
            else { shortcut = nil }
        } else {
            shortcut = nil
        }
        guard let shortcut else { return false }
        onShortcut?(shortcut)
        return true
    }
}

struct TextStyle: Equatable {
    var fontSize: CGFloat = 24
    var color: NSColor = .systemRed
    var bold = true
    var background = true
}

enum SpotlightShape: Int {
    case rectangle
    case ellipse
}

struct SpotlightStyle: Equatable {
    var shape: SpotlightShape = .rectangle
    var darkness: Double = 0.45
}

/// 放大镜标注：区域内内容按倍数放大，红圈可关。
struct MagnifierStyle: Equatable {
    var shape: SpotlightShape = .ellipse
    var zoom: Double = 2.0
    var showRing = true
}

/// 方框标注：矩形或椭圆轮廓。
enum ShapeKind: Int {
    case rectangle
    case ellipse
}

struct ShapeStyle: Equatable {
    var kind: ShapeKind = .rectangle
    var strokeWidth: CGFloat = 4
}

enum AnnotationMark: Equatable {
    case arrow(CGPoint, CGPoint)
    case text(String, CGPoint, TextStyle)
    case mosaic(CGRect)
    case spotlight(CGRect, SpotlightStyle)
    case magnifier(CGRect, MagnifierStyle)
    case shape(CGRect, ShapeStyle)
}

/// 标注历史：支持撤销与重做；追加新标注会清空重做分支。
struct MarkHistory {
    private(set) var marks: [AnnotationMark] = []
    private var redoStack: [AnnotationMark] = []

    mutating func append(_ mark: AnnotationMark) {
        marks.append(mark)
        redoStack.removeAll()
    }

    mutating func undo() -> AnnotationMark? {
        guard let last = marks.popLast() else { return nil }
        redoStack.append(last)
        return last
    }

    mutating func redo() -> AnnotationMark? {
        guard let last = redoStack.popLast() else { return nil }
        marks.append(last)
        return last
    }

    /// 整体平移全部标注（选区移动时保持标注跟随）。
    mutating func translate(_ delta: CGPoint) {
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.x, y: p.y + delta.y) }
        marks = marks.map { mark in
            switch mark {
            case .arrow(let a, let b): return .arrow(shift(a), shift(b))
            case .text(let v, let p, let s): return .text(v, shift(p), s)
            case .mosaic(let r): return .mosaic(r.offsetBy(dx: delta.x, dy: delta.y))
            case .spotlight(let r, let s): return .spotlight(r.offsetBy(dx: delta.x, dy: delta.y), s)
            case .magnifier(let r, let s): return .magnifier(r.offsetBy(dx: delta.x, dy: delta.y), s)
            case .shape(let r, let s): return .shape(r.offsetBy(dx: delta.x, dy: delta.y), s)
            }
        }
    }

    mutating func replace(marks newMarks: [AnnotationMark]) {
        marks = newMarks
    }

    mutating func moveMark(at index: Int, by delta: CGPoint) {
        guard marks.indices.contains(index) else { return }
        switch marks[index] {
        case .magnifier(let r, let s): marks[index] = .magnifier(r.offsetBy(dx: delta.x, dy: delta.y), s)
        case .shape(let r, let s): marks[index] = .shape(r.offsetBy(dx: delta.x, dy: delta.y), s)
        default: break
        }
    }

    /// 样式调整实时作用于已有文字标注。
    mutating func applyTextStyle(_ style: TextStyle) {
        marks = marks.map { mark in
            if case .text(let value, let origin, _) = mark {
                return .text(value, origin, style)
            }
            return mark
        }
    }

    /// 样式调整实时作用于已有聚光灯标注。
    mutating func applySpotlightStyle(_ style: SpotlightStyle) {
        marks = marks.map { mark in
            if case .spotlight(let region, _) = mark {
                return .spotlight(region, style)
            }
            return mark
        }
    }

    /// 样式调整实时作用于已有放大镜标注。
    mutating func applyMagnifierStyle(_ style: MagnifierStyle) {
        marks = marks.map { mark in
            if case .magnifier(let region, _) = mark {
                return .magnifier(region, style)
            }
            return mark
        }
    }

    /// 样式调整实时作用于已有方框标注。
    mutating func applyShapeStyle(_ style: ShapeStyle) {
        marks = marks.map { mark in
            if case .shape(let region, _) = mark {
                return .shape(region, style)
            }
            return mark
        }
    }
}

enum AnnotationRenderer {
    static func render(base: CGImage, marks: [AnnotationMark], styleScale: CGFloat = 1) throws -> CGImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.width,
                                            pixelsHigh: base.height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ImageExchangeError.invalidImage
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(base: base, marks: marks, in: CGRect(x: 0, y: 0, width: base.width, height: base.height),
             styleScale: styleScale)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let result = bitmap.cgImage else { throw ImageExchangeError.invalidImage }
        return result
    }

    static func draw(base: CGImage, marks: [AnnotationMark], in rect: CGRect,
                     styleScale: CGFloat = 1, pendingSpotlight: (CGRect, SpotlightStyle)? = nil) {
        NSImage(cgImage: base, size: rect.size).draw(in: rect)
        var spotlights: [(CGRect, SpotlightStyle)] = []
        var magnifierHoles: [(CGRect, SpotlightShape)] = []
        for mark in marks {
            switch mark {
            case .arrow(let start, let end): drawArrow(start: start, end: end, scale: styleScale)
            case .text(let value, let origin, let style): drawText(value, at: origin, style: style, scale: styleScale)
            case .mosaic(let region): drawMosaic(base: base, region: region, in: rect, flipped: false)
            case .magnifier(let region, let style):
                drawMagnifier(base: base, region: region, in: rect, imageRect: rect, style: style)
                magnifierHoles.append((region.standardized.intersection(rect), style.shape))
            case .shape(let region, let style): drawShape(region, style: style, scale: styleScale)
            case .spotlight(let region, let style): spotlights.append((region, style))
            }
        }
        if let pending = pendingSpotlight { spotlights.append(pending) }
        dimOutside(spotlights: spotlights, exemptions: magnifierHoles, in: rect)
    }

    /// 聚光灯压暗全局只画一次：所有亮区（含放大镜）之外统一一层暗度，不叠加。
    static func dimOutside(spotlights: [(CGRect, SpotlightStyle)],
                           exemptions: [(CGRect, SpotlightShape)], in canvas: CGRect) {
        guard !spotlights.isEmpty else { return }
        var maxDarkness = 0.0
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        path.append(NSBezierPath(rect: canvas))
        for (region, style) in spotlights {
            let hole = region.standardized.intersection(canvas)
            guard hole.width >= 2, hole.height >= 2 else { continue }
            switch style.shape {
            case .rectangle: path.append(NSBezierPath(rect: hole))
            case .ellipse: path.append(NSBezierPath(ovalIn: hole))
            }
            maxDarkness = max(maxDarkness, style.darkness)
        }
        for (region, shape) in exemptions {
            let hole = region.standardized.intersection(canvas)
            guard hole.width >= 2, hole.height >= 2 else { continue }
            switch shape {
            case .rectangle: path.append(NSBezierPath(rect: hole))
            case .ellipse: path.append(NSBezierPath(ovalIn: hole))
            }
        }
        NSColor.black.withAlphaComponent(CGFloat(maxDarkness)).setFill()
        path.fill()
    }

    /// 方框标注：矩形或椭圆轮廓。
    static func drawShape(_ region: CGRect, style: ShapeStyle, scale: CGFloat = 1) {
        let rect = region.standardized
        guard rect.width >= 2, rect.height >= 2 else { return }
        let path: NSBezierPath
        switch style.kind {
        case .rectangle: path = NSBezierPath(rect: rect)
        case .ellipse: path = NSBezierPath(ovalIn: rect)
        }
        path.lineWidth = max(1, style.strokeWidth * scale)
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    /// 放大镜：圆区域内的内容按倍数放大，红色圆环边界（可关）。
    /// 用纯 CG 绘制：AppKit 图像绘制在翻转视图里会丢失 CTM 变换。
    static func drawMagnifier(base: CGImage, region: CGRect, in canvas: CGRect,
                              imageRect: CGRect, style: MagnifierStyle) {
        let hole = region.standardized.intersection(canvas)
        guard hole.width >= 2, hole.height >= 2,
              let context = NSGraphicsContext.current,
              let ctx = context.cgContext as CGContext? else { return }
        let center = CGPoint(x: hole.midX, y: hole.midY)
        let flipped = context.isFlipped
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        Self.pathFor(hole, shape: style.shape).addClip()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: CGFloat(style.zoom), y: CGFloat(style.zoom))
        ctx.translateBy(x: -center.x, y: -center.y)
        if flipped {
            // 翻转围绕图像中线，图像按其真实范围绘制
            ctx.translateBy(x: 0, y: imageRect.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -imageRect.midY)
        }
        ctx.draw(base, in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
        guard style.showRing else { return }
        let ring = Self.pathFor(hole.insetBy(dx: 1, dy: 1), shape: style.shape)
        ring.lineWidth = 2
        NSColor.systemRed.setStroke()
        ring.stroke()
    }

    private static func pathFor(_ rect: CGRect, shape: SpotlightShape) -> NSBezierPath {
        switch shape {
        case .rectangle: return NSBezierPath(rect: rect)
        case .ellipse: return NSBezierPath(ovalIn: rect)
        }
    }

    static func drawArrow(start: CGPoint, end: CGPoint, scale: CGFloat = 1) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 4 * scale else { return }
        let ux = dx / length
        let uy = dy / length
        let wing: CGFloat = 14 * scale
        let left = CGPoint(x: end.x - ux * wing - uy * wing * 0.55,
                           y: end.y - uy * wing + ux * wing * 0.55)
        let right = CGPoint(x: end.x - ux * wing + uy * wing * 0.55,
                            y: end.y - uy * wing - ux * wing * 0.55)
        let path = NSBezierPath()
        path.lineWidth = 4 * scale
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

    /// 文字以顶部锚点绘制。flipped 标记当前上下文是否顶部原点（覆盖层）。
    static func drawText(_ value: String, at point: CGPoint, style: TextStyle,
                         scale: CGFloat = 1, flipped: Bool = false) {
        let font = style.bold ? NSFont.boldSystemFont(ofSize: style.fontSize * scale)
                              : NSFont.systemFont(ofSize: style.fontSize * scale)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
        if style.background {
            attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.75)
        }
        let size = (value as NSString).size(withAttributes: attributes)
        let origin = flipped ? point : CGPoint(x: point.x, y: point.y - size.height)
        value.draw(at: origin, withAttributes: attributes)
    }

    /// 马赛克：实时可用。base 按其实际分辨率映射到 canvas，flipped 标记画布坐标方向。
    static func drawMosaic(base: CGImage, region: CGRect, in canvas: CGRect, flipped: Bool) {
        let rect = region.standardized.intersection(canvas).integral
        guard rect.width >= 2, rect.height >= 2 else { return }
        let scaleX = Double(base.width) / Double(canvas.width)
        let scaleY = Double(base.height) / Double(canvas.height)
        let sampleX = (rect.minX - canvas.minX) * scaleX
        let sampleYTop = (rect.minY - canvas.minY) * scaleY
        let sampleH = rect.height * scaleY
        let pixelRect = CGRect(x: sampleX,
                               y: flipped ? Double(base.height) - sampleYTop - sampleH : sampleYTop,
                               width: rect.width * scaleX, height: sampleH).integral
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let source = base.cropping(to: pixelRect) else { return }
        let smallWidth = max(1, Int(rect.width / 12))
        let smallHeight = max(1, Int(rect.height / 12))
        guard let context = CGContext(data: nil, width: smallWidth, height: smallHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let pixels = context.makeImage() else { return }
        let previous = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: pixels, size: rect.size).draw(in: rect)
        if let previous { NSGraphicsContext.current?.imageInterpolation = previous }
    }
}

/// 工具样式栏：文字样式与聚光灯样式，选中对应工具时显示。
final class AnnotationStyleBar: NSView {
    enum Mode {
        case text
        case spotlight
        case magnifier
        case shape
    }

    private let mode: Mode
    private(set) var textStyle = TextStyle()
    private(set) var spotlightStyle = SpotlightStyle()
    private(set) var magnifierStyle = MagnifierStyle()
    private(set) var shapeStyle = ShapeStyle()
    var onChange: (() -> Void)?

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredSize: CGSize {
        mode == .text ? CGSize(width: 356, height: 32)
                      : CGSize(width: 320, height: 32)
    }

    private func build() {
        var x: CGFloat = 8
        switch mode {
        case .text:
            let sizeLabel = NSTextField(labelWithString: "24")
            sizeLabel.frame = CGRect(x: x, y: 7, width: 28, height: 18)
            sizeLabel.alignment = .right
            sizeLabel.tag = 900
            addSubview(sizeLabel)
            x += 32
            let stepper = NSStepper(frame: .zero)
            stepper.minValue = 10
            stepper.maxValue = 96
            stepper.increment = 2
            stepper.doubleValue = 24
            stepper.valueWraps = false
            stepper.autorepeat = true
            stepper.frame = CGRect(x: x, y: 4, width: 60, height: 24)
            stepper.target = self
            stepper.action = #selector(changeSize(_:))
            addSubview(stepper)
            x += 68
            let colors = [NSColor.systemRed, .systemOrange, .systemYellow,
                          .systemGreen, .systemBlue, .black]
            for (index, color) in colors.enumerated() {
                let swatch = NSButton(frame: CGRect(x: x, y: 7, width: 18, height: 18))
                swatch.title = ""
                swatch.isBordered = false
                swatch.wantsLayer = true
                swatch.layer?.backgroundColor = color.cgColor
                swatch.layer?.cornerRadius = 9
                swatch.layer?.borderWidth = 1
                swatch.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
                swatch.tag = index
                swatch.target = self
                swatch.action = #selector(changeColor(_:))
                addSubview(swatch)
                x += 24
            }
            let bold = makeIconButton(symbol: "bold", tip: "加粗", action: #selector(toggleBold(_:)))
            bold.frame = CGRect(x: x, y: 4, width: 26, height: 24)
            bold.state = .on
            styleToggleButton(bold)
            addSubview(bold)
            x += 30
            let background = NSButton(title: "底色", target: self, action: #selector(toggleBackground(_:)))
            background.frame = CGRect(x: x, y: 4, width: 46, height: 24)
            background.setButtonType(.toggle)
            background.state = .on
            styleToggleButton(background)
            addSubview(background)
        case .spotlight:
            let shape = NSSegmentedControl(labels: ["矩形", "圆圈"],
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(changeShape(_:)))
            shape.frame = CGRect(x: x, y: 4, width: 100, height: 24)
            shape.selectedSegment = 0
            addSubview(shape)
            x += 108
            let label = NSTextField(labelWithString: "暗度")
            label.frame = CGRect(x: x, y: 7, width: 30, height: 18)
            addSubview(label)
            x += 34
            let slider = NSSlider(value: 45, minValue: 20, maxValue: 80,
                                  target: self, action: #selector(changeDarkness(_:)))
            slider.frame = CGRect(x: x, y: 4, width: 150, height: 24)
            addSubview(slider)
        case .magnifier:
            let shape = NSSegmentedControl(labels: ["圆圈", "方框"],
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(changeMagnifierShape(_:)))
            shape.frame = CGRect(x: x, y: 4, width: 100, height: 24)
            shape.selectedSegment = 0
            addSubview(shape)
            x += 108
            let label = NSTextField(labelWithString: "倍数")
            label.frame = CGRect(x: x, y: 7, width: 30, height: 18)
            addSubview(label)
            x += 34
            let slider = NSSlider(value: 2, minValue: 1.5, maxValue: 4,
                                  target: self, action: #selector(changeZoom(_:)))
            slider.frame = CGRect(x: x, y: 4, width: 120, height: 24)
            addSubview(slider)
            x += 128
            let ring = NSButton(title: "红圈", target: self, action: #selector(toggleRing(_:)))
            ring.frame = CGRect(x: x, y: 4, width: 46, height: 24)
            ring.setButtonType(.toggle)
            ring.state = .on
            styleToggleButton(ring)
            addSubview(ring)
        case .shape:
            let shape = NSSegmentedControl(labels: ["方框", "圆圈"],
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(changeShapeKind(_:)))
            shape.frame = CGRect(x: x, y: 4, width: 100, height: 24)
            addSubview(shape)
            x += 108
            let label = NSTextField(labelWithString: "粗细")
            label.frame = CGRect(x: x, y: 7, width: 30, height: 18)
            addSubview(label)
            x += 34
            let stepper = NSStepper(frame: .zero)
            stepper.minValue = 1
            stepper.maxValue = 20
            stepper.increment = 1
            stepper.doubleValue = 4
            stepper.valueWraps = false
            stepper.autorepeat = true
            stepper.frame = CGRect(x: x, y: 4, width: 60, height: 24)
            stepper.target = self
            stepper.action = #selector(changeStrokeWidth(_:))
            addSubview(stepper)
        }
    }

    /// 开关按钮统一样式：边框 + 选中着色，状态一眼可辨。
    private func styleToggleButton(_ button: NSButton) {
        button.wantsLayer = true
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 5
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        applyToggleTint(button)
    }

    private func makeIconButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.setButtonType(.toggle)
        button.target = self
        button.action = action
        button.toolTip = tip
        return button
    }

    private func applyToggleTint(_ button: NSButton) {
        let on = button.state == .on
        button.layer?.backgroundColor = (on ? NSColor.systemBlue.withAlphaComponent(0.15)
                                            : NSColor.clear).cgColor
        button.contentTintColor = on ? .systemBlue : .darkGray
    }

    @objc private func changeSize(_ sender: NSStepper) {
        textStyle.fontSize = sender.doubleValue
        if let label = subviews.first(where: { $0.tag == 900 }) as? NSTextField {
            label.stringValue = "\(Int(sender.doubleValue))"
        }
        onChange?()
    }

    @objc private func changeColor(_ sender: NSButton) {
        let colors = [NSColor.systemRed, .systemOrange, .systemYellow,
                      .systemGreen, .systemBlue, .black]
        textStyle.color = colors[sender.tag]
        onChange?()
    }

    @objc private func toggleBold(_ sender: NSButton) {
        textStyle.bold = sender.state == .on
        applyToggleTint(sender)
        onChange?()
    }

    @objc private func toggleBackground(_ sender: NSButton) {
        textStyle.background = sender.state == .on
        applyToggleTint(sender)
        onChange?()
    }

    @objc private func changeShape(_ sender: NSSegmentedControl) {
        spotlightStyle.shape = sender.selectedSegment == 0 ? .rectangle : .ellipse
        onChange?()
    }

    @objc private func changeDarkness(_ sender: NSSlider) {
        spotlightStyle.darkness = sender.doubleValue / 100
        onChange?()
    }

    @objc private func changeZoom(_ sender: NSSlider) {
        magnifierStyle.zoom = sender.doubleValue
        onChange?()
    }

    @objc private func toggleRing(_ sender: NSButton) {
        magnifierStyle.showRing = sender.state == .on
        applyToggleTint(sender)
        onChange?()
    }

    @objc private func changeMagnifierShape(_ sender: NSSegmentedControl) {
        magnifierStyle.shape = sender.selectedSegment == 0 ? .ellipse : .rectangle
        onChange?()
    }

    @objc private func changeShapeKind(_ sender: NSSegmentedControl) {
        shapeStyle.kind = sender.selectedSegment == 0 ? .rectangle : .ellipse
        onChange?()
    }

    @objc private func changeStrokeWidth(_ sender: NSStepper) {
        shapeStyle.strokeWidth = CGFloat(sender.doubleValue)
        onChange?()
    }
}

/// 就地文字输入：回车提交，Esc 取消，点击别处自动提交。
final class InlineTextEditor: NSObject, NSTextFieldDelegate {
    var onCommit: ((String, CGPoint, TextStyle) -> Void)?
    private let field = NSTextField(frame: .zero)
    private weak var container: NSView?
    private var style = TextStyle()
    private var active = false

    func begin(in container: NSView, at point: CGPoint, style: TextStyle) {
        end(commit: true)
        active = true
        self.container = container
        self.style = style
        let width: CGFloat = 280
        let font = style.bold ? NSFont.boldSystemFont(ofSize: style.fontSize)
                              : NSFont.systemFont(ofSize: style.fontSize)
        let textHeight = ("测" as NSString).size(withAttributes: [.font: font]).height
        let height: CGFloat = max(style.fontSize + 10, textHeight + 6)
        var x = point.x
        var y = container.isFlipped ? point.y : point.y - height
        x = max(container.bounds.minX, min(x, container.bounds.maxX - width))
        y = max(container.bounds.minY, min(y, container.bounds.maxY - height))
        field.frame = CGRect(x: x, y: y, width: width, height: height)
        field.stringValue = ""
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = style.background
        field.backgroundColor = NSColor.white.withAlphaComponent(0.75)
        field.textColor = style.color
        field.font = style.bold ? NSFont.boldSystemFont(ofSize: style.fontSize)
                                : NSFont.systemFont(ofSize: style.fontSize)
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        container.addSubview(field)
        container.window?.makeFirstResponder(field)
    }

    func end(commit: Bool) {
        guard active else { return }
        active = false
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let committedStyle = style
        // 用输入框真实文本矩形定位，抵消内边距和行高差异
        var point = field.frame.origin
        if let cell = field.cell, let container {
            let title = cell.titleRect(forBounds: field.bounds)
            if container.isFlipped {
                point = CGPoint(x: field.frame.minX + title.minX,
                                y: field.frame.origin.y + field.frame.height - title.maxY)
            } else {
                point = CGPoint(x: field.frame.minX + title.minX,
                                y: field.frame.minY + title.maxY)
            }
        }
        field.delegate = nil
        if let container { container.window?.makeFirstResponder(container) }
        field.removeFromSuperview()
        if commit, !value.isEmpty { onCommit?(value, point, committedStyle) }
    }

    /// 输入中实时应用样式变化。
    func apply(style: TextStyle) {
        self.style = style
        guard active else { return }
        field.textColor = style.color
        field.font = style.bold ? NSFont.boldSystemFont(ofSize: style.fontSize)
                                : NSFont.systemFont(ofSize: style.fontSize)
        field.drawsBackground = style.background
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            end(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            end(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        end(commit: true)
    }
}

private final class AnnotationCanvas: NSView {
    let image: CGImage
    var tool: AnnotationTool = .arrow
    private(set) var history = MarkHistory()
    var marks: [AnnotationMark] { history.marks }
    var textStyleProvider: (() -> TextStyle)?
    var spotlightStyleProvider: (() -> SpotlightStyle)?
    var magnifierStyleProvider: (() -> MagnifierStyle)?
    var shapeStyleProvider: (() -> ShapeStyle)?
    private let inlineText = InlineTextEditor()
    private var anchor: CGPoint?
    private var currentPoint: CGPoint?

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        inlineText.onCommit = { [weak self] value, origin, style in
            self?.history.append(.text(value, origin, style))
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    func commitPendingText() {
        inlineText.end(commit: true)
    }

    /// 输入中实时应用文字样式，并同步已有文字标注。
    func applyTextStyle(_ style: TextStyle) {
        inlineText.apply(style: style)
        history.applyTextStyle(style)
        needsDisplay = true
    }

    /// 实时应用聚光灯样式到已有标注。
    func applySpotlightStyle(_ style: SpotlightStyle) {
        history.applySpotlightStyle(style)
        needsDisplay = true
    }

    /// 实时应用放大镜样式到已有标注。
    func applyMagnifierStyle(_ style: MagnifierStyle) {
        history.applyMagnifierStyle(style)
        needsDisplay = true
    }

    /// 实时应用方框样式到已有标注。
    func applyShapeStyle(_ style: ShapeStyle) {
        history.applyShapeStyle(style)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var pending: (CGRect, SpotlightStyle)? = nil
        if tool == .spotlight, let anchor, let currentPoint {
            pending = (CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                              width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y)),
                       spotlightStyleProvider?() ?? SpotlightStyle())
        }
        AnnotationRenderer.draw(base: image, marks: marks, in: bounds, pendingSpotlight: pending)
        if let anchor, let currentPoint {
            switch tool {
            case .arrow:
                AnnotationRenderer.drawArrow(start: anchor, end: currentPoint)
            case .mosaic:
                let rect = CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                  width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y))
                AnnotationRenderer.drawMosaic(base: image, region: rect, in: bounds, flipped: false)
            case .magnifier:
                let rect = CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                  width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y))
                AnnotationRenderer.drawMagnifier(base: image, region: rect, in: bounds,
                                                 imageRect: bounds,
                                                 style: magnifierStyleProvider?() ?? MagnifierStyle())
            case .shape:
                let rect = CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                  width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y))
                AnnotationRenderer.drawShape(rect, style: shapeStyleProvider?() ?? ShapeStyle())
            case .spotlight, .text: break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        inlineText.end(commit: true)
        if tool == .text {
            inlineText.begin(in: self, at: point, style: textStyleProvider?() ?? TextStyle())
        } else {
            anchor = point
            currentPoint = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentPoint = CGPoint(x: min(max(point.x, 0), bounds.maxX),
                               y: min(max(point.y, 0), bounds.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        defer { anchor = nil; currentPoint = nil; needsDisplay = true }
        guard let anchor, let currentPoint, hypot(anchor.x - currentPoint.x, anchor.y - currentPoint.y) >= 4 else { return }
        switch tool {
        case .arrow: history.append(.arrow(anchor, currentPoint))
        case .mosaic:
            history.append(.mosaic(CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                          width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y))))
        case .spotlight:
            history.append(.spotlight(CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                             width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y)),
                                      spotlightStyleProvider?() ?? SpotlightStyle()))
        case .magnifier:
            history.append(.magnifier(CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                             width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y)),
                                      magnifierStyleProvider?() ?? MagnifierStyle()))
        case .shape:
            history.append(.shape(CGRect(x: min(anchor.x, currentPoint.x), y: min(anchor.y, currentPoint.y),
                                         width: abs(anchor.x - currentPoint.x), height: abs(anchor.y - currentPoint.y)),
                                  shapeStyleProvider?() ?? ShapeStyle()))
        case .text: break
        }
    }

    func undoLastMark() {
        guard history.undo() != nil else { return }
        needsDisplay = true
    }

    func redoLastMark() {
        guard history.redo() != nil else { return }
        needsDisplay = true
    }
}

final class AnnotationEditorController: NSWindowController, NSWindowDelegate {
    var onSave: ((CGImage) -> Bool)?
    var onFinish: (() -> Void)?
    private let canvas: AnnotationCanvas
    private let tools = NSPopUpButton()
    private let textStyleBar = AnnotationStyleBar(mode: .text)
    private let spotlightStyleBar = AnnotationStyleBar(mode: .spotlight)
    private let magnifierStyleBar = AnnotationStyleBar(mode: .magnifier)
    private let shapeStyleBar = AnnotationStyleBar(mode: .shape)

    init(image: CGImage) {
        canvas = AnnotationCanvas(image: image)
        let width = min(1000, max(500, image.width))
        let height = min(760, max(350, image.height + 48))
        let window = AnnotationEditorWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "标注贴图"
        window.minSize = CGSize(width: 500, height: 350)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onShortcut = { [weak self] shortcut in self?.perform(shortcut) }

        guard let content = window.contentView else { return }
        let toolbar = NSView(frame: CGRect(x: 0, y: height - 48, width: width, height: 48))
        toolbar.autoresizingMask = [.width, .minYMargin]
        tools.frame = CGRect(x: 12, y: 9, width: 150, height: 30)
        tools.addItems(withTitles: ["箭头 A", "文字 T", "马赛克 M", "聚光灯 S", "放大镜 Z", "方框 G"])
        tools.target = self
        tools.action = #selector(changeTool)
        toolbar.addSubview(tools)
        let undo = NSButton(title: "撤销 ⌘Z", target: self, action: #selector(undoAnnotation))
        undo.frame = CGRect(x: 170, y: 9, width: 70, height: 30)
        toolbar.addSubview(undo)
        let redo = NSButton(title: "重做 ⌘⇧Z", target: self, action: #selector(redoAnnotation))
        redo.frame = CGRect(x: 244, y: 9, width: 84, height: 30)
        toolbar.addSubview(redo)

        let save = NSButton(title: "完成 ⌘↵", target: self, action: #selector(saveAnnotations))
        save.frame = CGRect(x: width - 92, y: 9, width: 80, height: 30)
        save.autoresizingMask = [.minXMargin]
        toolbar.addSubview(save)
        let cancel = NSButton(title: "取消 Esc", target: self, action: #selector(cancel))
        cancel.frame = CGRect(x: width - 180, y: 9, width: 80, height: 30)
        cancel.autoresizingMask = [.minXMargin]
        toolbar.addSubview(cancel)
        content.addSubview(toolbar)

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height - 48))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        content.addSubview(scroll)
        for bar in [textStyleBar, spotlightStyleBar, magnifierStyleBar, shapeStyleBar] {
            bar.frame = CGRect(x: 12, y: CGFloat(height) - 48 - 38,
                               width: bar.preferredSize.width, height: bar.preferredSize.height)
            bar.autoresizingMask = [.minYMargin]
            bar.isHidden = true
            content.addSubview(bar)
        }
        canvas.textStyleProvider = { [weak self] in self?.textStyleBar.textStyle ?? TextStyle() }
        canvas.spotlightStyleProvider = { [weak self] in self?.spotlightStyleBar.spotlightStyle ?? SpotlightStyle() }
        canvas.magnifierStyleProvider = { [weak self] in self?.magnifierStyleBar.magnifierStyle ?? MagnifierStyle() }
        canvas.shapeStyleProvider = { [weak self] in self?.shapeStyleBar.shapeStyle ?? ShapeStyle() }
        textStyleBar.onChange = { [weak self] in
            self?.canvas.applyTextStyle(self?.textStyleBar.textStyle ?? TextStyle())
        }
        spotlightStyleBar.onChange = { [weak self] in
            self?.canvas.applySpotlightStyle(self?.spotlightStyleBar.spotlightStyle ?? SpotlightStyle())
        }
        magnifierStyleBar.onChange = { [weak self] in
            self?.canvas.applyMagnifierStyle(self?.magnifierStyleBar.magnifierStyle ?? MagnifierStyle())
        }
        shapeStyleBar.onChange = { [weak self] in
            self?.canvas.applyShapeStyle(self?.shapeStyleBar.shapeStyle ?? ShapeStyle())
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changeTool() {
        canvas.commitPendingText()
        canvas.tool = AnnotationTool(rawValue: tools.indexOfSelectedItem) ?? .arrow
        updateStyleBars()
        window?.makeFirstResponder(canvas)
    }
    @objc private func undoAnnotation() { canvas.undoLastMark() }
    @objc private func redoAnnotation() { canvas.redoLastMark() }

    private func updateStyleBars() {
        textStyleBar.isHidden = canvas.tool != .text
        spotlightStyleBar.isHidden = canvas.tool != .spotlight
        magnifierStyleBar.isHidden = canvas.tool != .magnifier
        shapeStyleBar.isHidden = canvas.tool != .shape
    }

    private func perform(_ shortcut: AnnotationShortcut) {
        switch shortcut {
        case .arrow: selectTool(.arrow)
        case .text: selectTool(.text)
        case .mosaic: selectTool(.mosaic)
        case .spotlight: selectTool(.spotlight)
        case .magnifier: selectTool(.magnifier)
        case .shape: selectTool(.shape)
        case .undo: undoAnnotation()
        case .redo: redoAnnotation()
        case .save: saveAnnotations()
        case .cancel: cancel()
        }
    }

    private func selectTool(_ tool: AnnotationTool) {
        canvas.commitPendingText()
        tools.selectItem(at: tool.rawValue)
        canvas.tool = tool
        updateStyleBars()
        window?.makeFirstResponder(canvas)
    }

    @objc private func saveAnnotations() {
        canvas.commitPendingText()
        do {
            let image = try AnnotationRenderer.render(base: canvas.image, marks: canvas.marks)
            if onSave?(image) == true { window?.close() }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func cancel() { window?.close() }

    func windowWillClose(_ notification: Notification) { onFinish?() }
}
