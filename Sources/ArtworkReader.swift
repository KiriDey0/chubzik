import Foundation

// Each request owns its delegate and receives its callbacks on a serial queue.
final class ArtworkReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 5_000_000

    static func local(_ source: URL) -> Data? {
        let url = source.resolvingSymlinksInPath()
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size <= limit,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    private var exceededLimit = false
    private var bytes = Data()
    private let completion: (Data) -> Void

    private init(completion: @escaping (Data) -> Void) { self.completion = completion }

    static func fetch(_ url: URL, completion: @escaping (Data) -> Void) -> URLSessionDataTask {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: ArtworkReader(completion: completion), delegateQueue: nil)
        let task = session.dataTask(with: url)
        task.resume()
        session.finishTasksAndInvalidate()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
        completionHandler(ok && response.expectedContentLength <= Self.limit ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !exceededLimit else { return }
        guard data.count <= Self.limit - bytes.count else {
            exceededLimit = true
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, !exceededLimit, !bytes.isEmpty { completion(bytes) }
    }
}
