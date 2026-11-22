import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Lock-protected, cancellation-safe concurrency gate capping simultaneous thumbnail/metadata jobs.
/// Uses per-call `WaiterSlot` state under an `NSLock` so early cancellation can never race with
/// `withCheckedContinuation` registration, double-resume a continuation, or leak permits.
nonisolated final class ThumbnailConcurrencyLimiter: @unchecked Sendable {
    static let shared = ThumbnailConcurrencyLimiter(limit: 4)

    private final class WaiterSlot: @unchecked Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var isCancelled = false
        var isResolved = false
    }

    private let lock = NSLock()
    private var available: Int
    private var waiters: [WaiterSlot] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire() async -> Bool {
        if Task.isCancelled { return false }

        let acquiredFast: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if available > 0 {
                available -= 1
                return true
            }
            return false
        }()
        if acquiredFast { return true }

        let slot = WaiterSlot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enum Decision {
                    case acquired
                    case cancelled
                    case queued
                }
                let decision: Decision = {
                    lock.lock()
                    defer { lock.unlock() }
                    if slot.isCancelled || Task.isCancelled {
                        slot.isResolved = true
                        return .cancelled
                    }
                    if available > 0 {
                        available -= 1
                        slot.isResolved = true
                        return .acquired
                    }
                    slot.continuation = continuation
                    waiters.append(slot)
                    return .queued
                }()
                switch decision {
                case .acquired:
                    continuation.resume(returning: true)
                case .cancelled:
                    continuation.resume(returning: false)
                case .queued:
                    break
                }
            }
        } onCancel: {
            let continuationToCancel: CheckedContinuation<Bool, Never>? = {
                lock.lock()
                defer { lock.unlock() }
                slot.isCancelled = true
                guard !slot.isResolved, let continuation = slot.continuation else {
                    return nil
                }
                slot.continuation = nil
                slot.isResolved = true
                if let idx = waiters.firstIndex(where: { $0 === slot }) {
                    waiters.remove(at: idx)
                }
                return continuation
            }()
            continuationToCancel?.resume(returning: false)
        }
    }

    func release() {
        let nextContinuation: CheckedContinuation<Bool, Never>? = {
            lock.lock()
            defer { lock.unlock() }
            while !waiters.isEmpty {
                let slot = waiters.removeFirst()
                if slot.isResolved { continue }
                let continuation = slot.continuation
                slot.continuation = nil
                slot.isResolved = true
                return continuation
            }
            available += 1
            return nil
        }()
        nextContinuation?.resume(returning: true)
    }
}

/// Thread-safe single-resume guard for `QLThumbnailGenerator` continuations so cancellation
/// and completion callbacks can never double-resume or leak a `CheckedContinuation`.
nonisolated final class ThumbnailContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var isCancelled = false

    init() {}

    func install(_ continuation: CheckedContinuation<NSImage?, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            return false
        }
        self.continuation = continuation
        return true
    }

    func resume(returning value: NSImage?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: nil)
    }
}

enum ThumbnailGenerator {
    private nonisolated static let size = Constants.Thumbnail.size

    nonisolated static func generate(for kind: ShelfItemKind) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        switch kind {
        case .file(let url, _):
            return await generateForFile(url: url)
        case .folder(let url, _):
            guard !Task.isCancelled else { return nil }
            return await MainActor.run {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 96, height: 96)
                return icon
            }
        case .image(let data, _, _):
            guard !Task.isCancelled else { return nil }
            return Self.downsampledImage(from: data, maxPixelSize: 560)
        case .webURL, .text:
            return nil
        }
    }

    nonisolated static func generateForFile(url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        guard !Task.isCancelled else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        let gate = ThumbnailContinuationGate()

        let generated: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gate.install(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                    gate.resume(returning: thumbnail?.nsImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
            gate.cancel()
        }

        if let generated {
            return generated
        }
        guard !Task.isCancelled else { return nil }

        return await MainActor.run {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 96, height: 96)
            return icon
        }
    }

    /// Downsamples encoded image bytes directly via ImageIO without decoding a full-resolution
    /// bitmap or using `NSImage.lockFocus`.
    nonisolated static func downsampledImage(from data: Data, maxPixelSize: CGFloat = 560) -> NSImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded())),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    /// Reads image pixel dimensions from the header only via ImageIO (zero pixel decoding).
    nonisolated static func imagePixelDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = props[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0 else {
            return nil
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5..8 rotate 90°/270°, swapping width and height.
        if (5...8).contains(orientation) {
            return (rawHeight, rawWidth)
        }
        return (rawWidth, rawHeight)
    }

    /// Transcodes encoded image bytes to a target UTType (e.g. `.png` or `.tiff`) via ImageIO,
    /// safe to execute on any background queue without AppKit graphics contexts.
    nonisolated static func transcodeImageData(_ data: Data, to targetType: UTType) -> Data? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            targetType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            CGImageDestinationAddImage(destination, cgImage, nil)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        }

        guard CGImageDestinationFinalize(destination), mutableData.length > 0 else {
            return nil
        }
        return mutableData as Data
    }
}
