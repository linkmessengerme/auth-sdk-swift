import Foundation
#if canImport(LinkAuthCore)
import LinkAuthCore
#endif

/// A dedicated ephemeral URLSession. POST bodies are streamed once; redirects,
/// cookies, cached responses and interactive HTTP authentication are disabled.
public final class URLSessionTransport: NSObject, HttpTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Operation {
        let continuation: CheckedContinuation<HttpResponse, Error>
        let maximumBytes: Int
        var requestBody: Data
        var suppliedBody = false
        var response: HTTPURLResponse?
        var data = Data()
        var deadline: DispatchWorkItem?
        var task: URLSessionTask?
        init(_ continuation: CheckedContinuation<HttpResponse, Error>, _ maximumBytes: Int, _ body: Data) {
            self.continuation = continuation; self.maximumBytes = maximumBytes; requestBody = body
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var task: URLSessionTask?
        func install(_ task: URLSessionTask) {
            lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
            if cancel { task.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let current = task; lock.unlock()
            current?.cancel()
        }
    }
    private let lock = NSLock()
    private var operations: [Int: Operation] = [:]
    private var session: URLSession!
    private var closed = false
    private let maximumTimeout: TimeInterval

    public init(maximumTimeout: TimeInterval = 15) {
        precondition(maximumTimeout > 0 && maximumTimeout.isFinite)
        self.maximumTimeout = maximumTimeout
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = maximumTimeout
        config.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    public func execute(request: HttpRequest) async throws -> HttpResponse {
        guard let url = URL(string: request.url()), ["GET", "POST"].contains(request.method()) else { throw TransportFailure.RequestFailed }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let body = request.body()
                let timeout = min(Double(request.timeoutMillis()) / 1000, maximumTimeout)
                var native = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                native.httpMethod = request.method(); native.httpShouldHandleCookies = false
                for header in request.headers() { native.setValue(header.value, forHTTPHeaderField: header.name) }
                let operation = Operation(continuation, Int(request.maxResponseBytes()), body)
                let task: URLSessionTask
                if request.method() == "POST" {
                    native.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
                    task = session.uploadTask(withStreamedRequest: native)
                } else { task = session.dataTask(with: native) }
                operation.task = task
                let deadline = DispatchWorkItem { [weak self, weak task] in
                    guard let task else { return }
                    self?.finish(task.taskIdentifier, failure: true); task.cancel()
                }
                operation.deadline = deadline
                lock.lock()
                if closed {
                    lock.unlock(); task.cancel(); continuation.resume(throwing: TransportFailure.RequestFailed); return
                }
                operations[task.taskIdentifier] = operation
                lock.unlock()
                cancellation.install(task)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                task.resume()
            }
        }, onCancel: { cancellation.cancel() })
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        lock.lock()
        let operation = operations[task.taskIdentifier]
        let stream = operation.flatMap { $0.suppliedBody ? nil : InputStream(data: $0.requestBody) }
        operation?.suppliedBody = true
        lock.unlock()
        completionHandler(stream) // A resend cannot obtain a second body stream.
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let operation = operations[dataTask.taskIdentifier]
        let accepted = operation != nil && response is HTTPURLResponse && response.expectedContentLength <= Int64(operation!.maximumBytes)
        if accepted { operation?.response = response as? HTTPURLResponse }
        lock.unlock()
        if !accepted { finish(dataTask.taskIdentifier, failure: true) }
        completionHandler(accepted ? .allow : .cancel)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let operation = operations[dataTask.taskIdentifier]
        let accepted = operation != nil && operation!.data.count + data.count <= operation!.maximumBytes
        if accepted { operation?.data.append(data) }
        lock.unlock()
        if !accepted { finish(dataTask.taskIdentifier, failure: true); dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task.taskIdentifier, failure: error != nil)
    }
    private func finish(_ id: Int, failure: Bool) {
        lock.lock(); let operation = operations.removeValue(forKey: id); lock.unlock()
        guard let operation else { return }
        operation.deadline?.cancel()
        if !failure, let response = operation.response, let url = response.url,
            let status = UInt16(exactly: response.statusCode) {
            operation.continuation.resume(returning: HttpResponse(status: status, url: url.absoluteString,
                contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "", body: operation.data))
        } else { operation.continuation.resume(throwing: TransportFailure.RequestFailed) }
        operation.requestBody.resetBytes(in: 0..<operation.requestBody.count)
        operation.data.resetBytes(in: 0..<operation.data.count)
    }

    /// Cancel this client's current requests without disposing the transport.
    /// Pair with core.cancelSignIn() when cancelling login. Swift Task.cancel()
    /// alone does not cancel a generated UniFFI 0.31.2 Rust future.
    public func cancelRequests() {
        lock.lock(); let pending = operations.map { ($0.key, $0.value.task) }; lock.unlock()
        for (id, task) in pending { finish(id, failure: true); task?.cancel() }
    }

    /// Call when disposing this SDK instance to release URLSession's delegate.
    public func close() {
        lock.lock(); closed = true; lock.unlock()
        cancelRequests()
        session.invalidateAndCancel()
    }
}
