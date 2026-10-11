import AppKit
import CoreGraphics
import ScreenCaptureKit

struct CapturedDisplay {
    let screen: NSScreen
    let image: CGImage
}

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "未找到可截图的屏幕。"
        case .permissionDenied: return "请在系统设置中允许录制屏幕。"
        }
    }
}

final class ScreenCaptureService {
    static func configuration(displayWidth: Int, displayHeight: Int,
                              backingScaleFactor: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(displayWidth) * backingScaleFactor).rounded())
        config.height = Int((CGFloat(displayHeight) * backingScaleFactor).rounded())
        config.showsCursor = false
        return config
    }

    func captureDisplays() async throws -> [CapturedDisplay] {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundle = Bundle.main.bundleIdentifier
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ownBundle }
        var result: [CapturedDisplay] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let config = Self.configuration(displayWidth: display.width,
                                            displayHeight: display.height,
                                            backingScaleFactor: screen.backingScaleFactor)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(CapturedDisplay(screen: screen, image: image))
        }
        guard !result.isEmpty else { throw CaptureError.noDisplay }
        return result
    }
}

enum ImageCropper {
    static func crop(_ image: CGImage, selection: CGRect, viewSize: CGSize) -> CGImage? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let rect = selection.standardized.intersection(CGRect(origin: .zero, size: viewSize))
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        let scaleX = CGFloat(image.width) / viewSize.width
        let scaleY = CGFloat(image.height) / viewSize.height
        let pixels = CGRect(x: floor(rect.minX * scaleX), y: floor(rect.minY * scaleY),
                            width: ceil(rect.width * scaleX), height: ceil(rect.height * scaleY))
        return image.cropping(to: pixels)
    }
}
