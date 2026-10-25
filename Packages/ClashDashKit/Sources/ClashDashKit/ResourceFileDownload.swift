import Foundation

/// A bounded disk download keeps large public geodata out of the App's and extension's heaps.
public final class ResourceFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<URL, Error>?
    private var exceededLimit = false
    private var cancelled = false
    private let limit: Int64
    private let destination: URL
    public init(destination: URL, maximumBytes: Int64 = 64 * 1024 * 1024) { self.destination = destination; self.limit = maximumBytes }

    public func download(_ url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw DashError.message("地理数据库资源需要有效的 HTTPS 地址。")
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 180
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.setValue("ClashDash/0.1 mihomo", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                lock.lock(); continuation = pending; self.session = session; self.task = task; let shouldCancel = cancelled; lock.unlock()
                if shouldCancel { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { exceededLimit = true; downloadTask.cancel() }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw DashError.message("地理数据库下载失败（HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)）。原配置保持不变。")
            }
            let count = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard count > 0, count <= limit else { throw DashError.message("地理数据库大小无效或超过 64 MB。") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            var file = destination; var values = URLResourceValues(); values.isExcludedFromBackup = true; try file.setResourceValues(values)
            result = .success(destination)
        } catch { result = .failure(error) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completed: Result<URL, Error>
        if exceededLimit { completed = .failure(DashError.message("地理数据库超过 64 MB 限制，下载已取消。")) }
        else if let error { completed = .failure(error) }
        else { completed = result ?? .failure(DashError.message("没有收到地理数据库文件。")) }
        lock.lock(); let pending = continuation; continuation = nil; self.task = nil; self.session = nil; lock.unlock()
        session.finishTasksAndInvalidate(); pending?.resume(with: completed)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.user == nil, request.url?.password == nil else { completionHandler(nil); return }
        var safe = request
        if response.url?.host != request.url?.host {
            for name in safe.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys {
                let field = name.lowercased()
                if field == "authorization" || field == "cookie" || field.contains("token") || field.contains("secret") || field.contains("key") { safe.setValue(nil, forHTTPHeaderField: name) }
            }
        }
        completionHandler(safe)
    }
}
