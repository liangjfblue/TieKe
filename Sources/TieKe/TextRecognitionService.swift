import AppKit
import Vision

enum RecognitionError: LocalizedError {
    case noText

    var errorDescription: String? { "选区内没有识别到文字。" }
}

/// 一次识字任务的取消句柄。
/// Vision 的 perform 无法中断；取消保证丢弃尚未开始的任务与已产生的结果。
final class RecognitionTask {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class TextRecognitionService {
    @discardableResult
    func recognize(_ image: CGImage,
                   completion: @escaping (Result<String, Error>) -> Void) -> RecognitionTask {
        let task = RecognitionTask()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !task.isCancelled else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                guard !task.isCancelled else { return }
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                DispatchQueue.main.async {
                    guard !task.isCancelled else { return }
                    completion(.success(text))
                }
            } catch {
                guard !task.isCancelled else { return }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        return task
    }
}
