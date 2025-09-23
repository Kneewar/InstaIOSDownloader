import Foundation
import Photos
import UIKit

final class Downloader: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloader()

    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    // Used to avoid racing with URLSession's temp cleanup; we move files in the delegate.

    // Foreground session is fine for MVP; switch to background later if you want.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func downloadAndSave(from url: URL, onProgress: @escaping (Double) -> Void) async throws {
        self.progressHandler = onProgress
        // Photos authorization check
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw NSError(domain: "PhotosAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photos permission not granted. Enable access in Settings → Privacy → Photos."])
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            guard status == .authorized else {
                throw NSError(domain: "PhotosAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photos permission not granted. Enable access in Settings → Privacy → Photos."])
            }
        }
        let localURL = try await download(url: url)
        try await saveToPhotos(fileURL: localURL, originalURL: url)
    }

    private func download(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.continuation = cont
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        do {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            // Derive extension from the original request URL if possible, or from MIME type.
            let orig = downloadTask.originalRequest?.url
            let lowerPath = orig?.path.lowercased() ?? ""
            let pathExt = (orig?.pathExtension.lowercased() ?? "")
            // Prefer URL extension; if missing, infer from MIME type.
            var ext = pathExt
            if ext.isEmpty {
                let mime = downloadTask.response?.mimeType?.lowercased() ?? ""
                switch mime {
                case "video/mp4": ext = "mp4"
                case "video/quicktime": ext = "mov"
                case "video/x-m4v": ext = "m4v"
                case "image/jpeg": ext = "jpg"
                case "image/png": ext = "png"
                case "image/heic": ext = "heic"
                default:
                    // Heuristic fallback based on path hints
                    if lowerPath.contains(".mp4") { ext = "mp4" }
                    else if lowerPath.contains(".mov") { ext = "mov" }
                    else if lowerPath.contains(".m4v") { ext = "m4v" }
                    else if lowerPath.contains(".jpg") || lowerPath.contains(".jpeg") { ext = "jpg" }
                    else if lowerPath.contains(".png") { ext = "png" }
                    else { ext = "dat" }
                }
            }
            let dest = caches.appendingPathComponent("igsaver-\(UUID().uuidString).\(ext)")
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let prog = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler?(max(0.0, min(1.0, prog)))
        } else {
            // Unknown content length; signal indeterminate progress
            progressHandler?(-1.0)
        }
    }

    // MARK: Save

    private func saveToPhotos(fileURL: URL, originalURL: URL) async throws {
        let lower = fileURL.path.lowercased()
        let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v")

        try await withCheckedThrowingContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    // Load image data to avoid temp-file lifetime issues
                    if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                       let img = UIImage(data: data) {
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }
                }
            }, completionHandler: { success, error in
                if success {
                    cont.resume(returning: ())
                } else {
                    let err = error ?? NSError(domain: "SaveError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to save to Photos."])
                    cont.resume(throwing: err)
                }
            })
        }
    }
}
