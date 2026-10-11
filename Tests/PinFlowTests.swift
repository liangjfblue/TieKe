import AppKit
import XCTest
@testable import TieKe

final class PinFlowTests: XCTestCase {
    func testPinnedImageWindowHasNoTitleBar() throws {
        let image = try makeImage(width: 200, height: 100)
        let record = PinRecord(id: UUID(), imageName: "test.png",
                               frame: CGRect(x: 20, y: 30, width: 100, height: 50),
                               createdAt: Date(), isOpen: true, ocrText: nil)
        let controller = PinWindowController(record: record, image: image)
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, window.frame.size)
    }

    func testPinnedImageAllowsWindowDragging() throws {
        let image = try makeImage(width: 20, height: 20)
        let record = PinRecord(id: UUID(), imageName: "test.png",
                               frame: CGRect(x: 0, y: 0, width: 60, height: 40),
                               createdAt: Date(), isOpen: true, ocrText: nil)
        let controller = PinWindowController(record: record, image: image)
        let imageView = try XCTUnwrap(controller.window?.contentView?.subviews.first as? NSImageView)
        XCTAssertTrue(imageView.mouseDownCanMoveWindow)
    }

    func testSelectionToolbarUsesFreeSpaceOutsideSelection() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let size = CGSize(width: 202, height: 44)
        for selection in [CGRect(x: 100, y: 100, width: 100, height: 100),
                          CGRect(x: 100, y: 350, width: 100, height: 30),
                          CGRect(x: 20, y: 0, width: 100, height: 400)] {
            let frame = try XCTUnwrap(SelectionToolbarLayout.frame(selection: selection,
                                                                   bounds: bounds, size: size))
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertFalse(frame.intersects(selection))
        }
    }

    func testCaptureConfigurationUsesRetinaPixels() {
        let config = ScreenCaptureService.configuration(displayWidth: 1440, displayHeight: 900,
                                                        backingScaleFactor: 2)
        XCTAssertEqual(config.width, 2880)
        XCTAssertEqual(config.height, 1800)
    }

    func testSavedPinRestoresItsImageAndGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeImage(width: 12, height: 8)
        let frame = CGRect(x: 41, y: 52, width: 120, height: 80)

        do {
            let store = try PinStore(root: root)
            let record = try store.save(image: image, frame: frame)
            XCTAssertEqual(try store.image(for: record).width, 12)
        }

        let reopened = try PinStore(root: root)
        let records = try reopened.openRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].frame, frame)
        XCTAssertEqual(try reopened.image(for: records[0]).height, 8)
        try reopened.close(id: records[0].id)
        XCTAssertTrue(try reopened.openRecords().isEmpty)
    }

    func testCropUsesImagePixelsAndClampsSelection() throws {
        let image = try makeImage(width: 400, height: 200)
        let crop = ImageCropper.crop(image, selection: CGRect(x: 20, y: 10, width: 50, height: 30),
                                     viewSize: CGSize(width: 100, height: 50))
        XCTAssertEqual(crop?.width, 200)
        XCTAssertEqual(crop?.height, 120)

        let clipped = ImageCropper.crop(image, selection: CGRect(x: 90, y: 40, width: 40, height: 30),
                                        viewSize: CGSize(width: 100, height: 50))
        XCTAssertEqual(clipped?.width, 40)
        XCTAssertEqual(clipped?.height, 40)
    }

    func testImageCanBePinnedFromClipboardAndFile() throws {
        let image = try makeImage(width: 72, height: 48)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ImageExchange.copy(image, to: pasteboard))
        XCTAssertEqual(try ImageExchange.loadClipboard(pasteboard).width, 72)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try ImageExchange.savePNG(image, to: file)
        XCTAssertEqual(try ImageExchange.load(url: file).height, 48)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL]))
        XCTAssertEqual(try ImageExchange.loadClipboard(pasteboard).width, 72)
    }

    func testAnnotatedImageIsSavedForRestoration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeImage(width: 120, height: 80)
        let annotated = try AnnotationRenderer.render(base: original, marks: [
            .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 60)),
            .text("说明", CGPoint(x: 12, y: 40), TextStyle()),
            .mosaic(CGRect(x: 30, y: 12, width: 35, height: 25)),
            .spotlight(CGRect(x: 30, y: 12, width: 35, height: 25), SpotlightStyle())
        ])
        XCTAssertNotEqual(try rgbaBytes(original), try rgbaBytes(annotated))

        let store = try PinStore(root: root)
        let record = try store.save(image: original, frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        try store.replaceImage(annotated, for: record)
        let restored = try store.image(for: record)
        XCTAssertEqual(try rgbaBytes(restored), try rgbaBytes(annotated))
    }

    func testSpotlightDarkensOnlyOutsideRegion() throws {
        let base = try makeImage(width: 100, height: 60)
        let marked = try AnnotationRenderer.render(base: base, marks: [
            .spotlight(CGRect(x: 30, y: 20, width: 40, height: 20), SpotlightStyle())
        ])
        // 绘制坐标原点在左下，位图像素坐标原点在左上。
        let rep = NSBitmapImageRep(cgImage: marked)
        let inside = try XCTUnwrap(rep.colorAt(x: 50, y: 29)?.usingColorSpace(.deviceRGB))
        let outside = try XCTUnwrap(rep.colorAt(x: 10, y: 49)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(inside.blueComponent, 0.9)
        XCTAssertLessThan(outside.blueComponent, 0.8)
        XCTAssertGreaterThan(outside.blueComponent, 0.3)
    }

    func testEllipseSpotlightKeepsOvalBright() throws {
        let base = try makeImage(width: 100, height: 60)
        let style = SpotlightStyle(shape: .ellipse, darkness: 0.45)
        let marked = try AnnotationRenderer.render(base: base, marks: [
            .spotlight(CGRect(x: 25, y: 15, width: 50, height: 30), style)
        ])
        let rep = NSBitmapImageRep(cgImage: marked)
        // 椭圆中心保持原亮度；矩形内部、椭圆外被压暗
        let center = try XCTUnwrap(rep.colorAt(x: 50, y: 29)?.usingColorSpace(.deviceRGB))
        let outsideOval = try XCTUnwrap(rep.colorAt(x: 30, y: 17)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.blueComponent, 0.9)
        XCTAssertLessThan(outsideOval.blueComponent, 0.8)
    }

    func testCaptureMarksConvertToPixelCoordinates() {
        let selection = CGRect(x: 100, y: 200, width: 300, height: 200)
        let converted = CaptureAnnotator.convert(
            marks: [.arrow(CGPoint(x: 110, y: 210), CGPoint(x: 210, y: 310)),
                    .text("hi", CGPoint(x: 130, y: 220), TextStyle()),
                    .spotlight(CGRect(x: 100, y: 200, width: 150, height: 100), SpotlightStyle())],
            selection: selection,
            pixelSize: CGSize(width: 600, height: 400))
        XCTAssertEqual(converted.count, 3)
        // 视图坐标顶部原点 → 像素坐标底部原点，2 倍缩放
        if case .arrow(let start, let end) = converted[0] {
            XCTAssertEqual(start, CGPoint(x: 20, y: 380))
            XCTAssertEqual(end, CGPoint(x: 220, y: 180))
        } else {
            XCTFail("expected arrow mark")
        }
        if case .text(_, let origin, let style) = converted[1] {
            XCTAssertEqual(origin, CGPoint(x: 60, y: 360))
            XCTAssertEqual(style, TextStyle())
        } else {
            XCTFail("expected text mark")
        }
        if case .spotlight(let rect, let style) = converted[2] {
            XCTAssertEqual(rect, CGRect(x: 0, y: 200, width: 300, height: 200))
            XCTAssertEqual(style, SpotlightStyle())
        } else {
            XCTFail("expected spotlight mark")
        }
    }

    func testPinWindowDoesNotHideOnDeactivate() throws {
        let image = try makeImage(width: 20, height: 20)
        let record = PinRecord(id: UUID(), imageName: "test.png",
                               frame: CGRect(x: 0, y: 0, width: 60, height: 40),
                               createdAt: Date(), isOpen: true, ocrText: nil)
        let controller = PinWindowController(record: record, image: image)
        XCTAssertFalse(try XCTUnwrap(controller.window).hidesOnDeactivate)
    }

    func testMarkHistoryUndoRedo() {
        var history = MarkHistory()
        let spotlight = AnnotationMark.spotlight(CGRect(x: 0, y: 0, width: 10, height: 10), SpotlightStyle())
        let mosaic = AnnotationMark.mosaic(CGRect(x: 1, y: 1, width: 5, height: 5))
        history.append(spotlight)
        history.append(mosaic)
        XCTAssertEqual(history.marks, [spotlight, mosaic])
        XCTAssertEqual(history.undo(), mosaic)
        XCTAssertEqual(history.marks, [spotlight])
        XCTAssertEqual(history.redo(), mosaic)
        XCTAssertEqual(history.marks, [spotlight, mosaic])
        history.undo()
        history.append(.text("新", CGPoint(x: 0, y: 0), TextStyle()))
        XCTAssertNil(history.redo())
        XCTAssertEqual(history.marks, [spotlight, .text("新", CGPoint(x: 0, y: 0), TextStyle())])
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                                  CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
