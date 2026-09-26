import Foundation

/// The session's own failures. Previously this threw `AzureBlobError.notHTTPResponse`
/// — a provider-neutral class reaching into one provider's error type, which is how a
/// leak starts.
enum DownloadSessionError: Error, Sendable {
    case notHTTPResponse
}

/// Runs URLSession download tasks with real byte progress.
///
/// The obvious spelling — `URLSession.download(for:delegate:)` with a task delegate —
/// does not work: that API never invokes the caller's `URLSessionDownloadDelegate`
/// methods, so `didWriteData` never fires and progress is invisible. (Verified
/// against a live 11 MB blob: zero callbacks.) Byte progress on a download requires
/// a session we own, with a session-level delegate.
///
/// Owning the session is also what a resumable download will need later — a paused
/// transfer resumes from `cancel(byProducingResumeData:)`, which is only reachable
/// from the task, not from the async convenience API.
///
/// Provider-agnostic on purpose: S3 downloads will use the same machinery.
final class DownloadSession: NSObject, @unchecked Sendable {

    static let shared = DownloadSession()

    /// Guards the two task-indexed tables below. A plain lock rather than an actor:
    /// URLSession calls the delegate from its own queue, and hopping actors mid-
    /// callback would let `didFinishDownloadingTo` return — and the temporary file
    /// be deleted — before we had moved it.
    private let lock = NSLock()
    private var progressHandlers: [Int: @Sendable (Int64, Int64) -> Void] = [:]
    private var continuations: [Int: CheckedContinuation<(URL, HTTPURLResponse), any Error>] = [:]
    /// Where each task's resume data goes if it fails or is stopped.
    private var resumeStates: [Int: DownloadResumeState] = [:]

    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    /// Performs `request` as a download. Returns a file in the temporary directory
    /// that the **caller now owns** and must move or delete, plus the response so the
    /// caller can check the status code before trusting the bytes.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer.
    ///
    /// With `resume`, a download that stopped part-way — a dropped connection, or the
    /// user pressing Stop — leaves URLSession's resume data there, and the next call
    /// with the same state carries on from the byte it reached instead of starting
    /// over. The resume data is used once: if the resumed request is refused, the
    /// caller asks again and gets a fresh download.
    func download(
        _ request: URLRequest,
        resume: DownloadResumeState? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (URL, HTTPURLResponse) {
        let task: URLSessionDownloadTask
        if let data = resume?.resumeData {
            resume?.resumeData = nil
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                continuations[task.taskIdentifier] = continuation
                if let onProgress { progressHandlers[task.taskIdentifier] = onProgress }
                if let resume { resumeStates[task.taskIdentifier] = resume }
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            if let resume {
                task.cancel { data in if let data { resume.resumeData = data } }
            } else {
                task.cancel()
            }
        }
    }

    /// Resumes a task's continuation exactly once. `didFinishDownloadingTo` and
    /// `didCompleteWithError` both fire on a successful download, so this has to be
    /// idempotent — resuming a continuation twice traps.
    private func finish(_ taskIdentifier: Int, with result: Result<(URL, HTTPURLResponse), any Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: taskIdentifier)
        progressHandlers.removeValue(forKey: taskIdentifier)
        resumeStates.removeValue(forKey: taskIdentifier)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension DownloadSession: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let handler = progressHandlers[downloadTask.taskIdentifier]
        lock.unlock()
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes `location` as soon as this method returns, so the move
        // has to happen here and synchronously.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-download-\(UUID().uuidString)")
        let result: Result<(URL, HTTPURLResponse), any Error>
        do {
            try FileManager.default.moveItem(at: location, to: owned)
            guard let http = downloadTask.response as? HTTPURLResponse else {
                throw DownloadSessionError.notHTTPResponse
            }
            result = .success((owned, http))
        } catch {
            result = .failure(error)
        }
        finish(downloadTask.taskIdentifier, with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else {
            // Success already resumed the continuation above; this is a no-op.
            return
        }
        // A failure part-way through carries the data needed to pick up from there.
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            lock.lock()
            let state = resumeStates[task.taskIdentifier]
            lock.unlock()
            state?.resumeData = data
        }
        finish(task.taskIdentifier, with: .failure(error))
    }
}
