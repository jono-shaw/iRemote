import Foundation

/// Streams a large `.bin` model file from Hugging Face to a target path
/// in `~/.cache/whisper/`, reporting progress and completion on the
/// main thread.
///
/// Implementation notes:
/// - Uses `URLSessionDownloadTask`, which streams to a temp file
///   without holding the full payload in memory (multi-GB models would
///   blow up Data-based loaders).
/// - Reports progress via the standard delegate. The callbacks already
///   come on the delegate queue we pass in (`.main`), so handlers run
///   on the main thread and can update UI directly.
/// - On completion, atomically moves the temp file into the cache
///   directory. If the destination already exists it's overwritten so
///   that "re-download" works without leaving zero-byte stragglers.
@MainActor
final class ModelDownloader: NSObject {

    enum DownloadError: Error {
        case noLocation
        case fileSystem(Error)
        case cancelled
        case httpStatus(Int)
    }

    /// Called on every progress tick. Both values are in bytes;
    /// `total` is 0 if the server didn't send a Content-Length header.
    var onProgress: ((_ bytesWritten: Int64, _ total: Int64) -> Void)?
    var onComplete: ((Result<URL, Error>) -> Void)?

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var destinationPath: String?
    private var didReportCompletion = false

    var isRunning: Bool { task != nil && !didReportCompletion }

    func start(from url: URL, savingTo destinationPath: String) {
        cancel()
        didReportCompletion = false
        self.destinationPath = destinationPath
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if !didReportCompletion {
            didReportCompletion = true
            onComplete?(.failure(DownloadError.cancelled))
        }
        session?.invalidateAndCancel()
        session = nil
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !didReportCompletion else { return }
        didReportCompletion = true
        onComplete?(result)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // We must move the file synchronously inside this delegate
        // callback — the temp `location` is deleted as soon as the
        // method returns.
        let fm = FileManager.default
        let destination = MainActor.assumeIsolated { self.destinationPath }
        guard let destination else {
            try? fm.removeItem(at: location)
            MainActor.assumeIsolated {
                self.finish(.failure(DownloadError.noLocation))
            }
            return
        }

        let destURL = URL(fileURLWithPath: destination)
        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: location, to: destURL)
            MainActor.assumeIsolated {
                self.finish(.success(destURL))
            }
        } catch {
            try? fm.removeItem(at: location)
            MainActor.assumeIsolated {
                self.finish(.failure(DownloadError.fileSystem(error)))
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        // Cancellation already reported by `cancel()`.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        MainActor.assumeIsolated {
            self.finish(.failure(error))
        }
    }
}
