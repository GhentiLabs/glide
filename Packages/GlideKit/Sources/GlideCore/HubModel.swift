import CryptoKit
import Foundation

/// A model downloaded from one pinned Hugging Face revision. Every file is checked against the hash recorded in code before it is used.
public struct HubModel: Sendable {
    public enum Hash: Sendable {
        /// SHA-256 of the contents, for files stored with Git LFS.
        case sha256(String)
        /// Git's blob id (SHA-1 of a header and the contents), for small files kept in Git itself.
        case blob(String)
    }

    public struct File: Sendable {
        public let path: String
        public let size: Int64
        public let hash: Hash
        /// Where the file goes on disk, when that differs from its path in the repository.
        public let localPath: String
        public init(_ path: String, _ size: Int64, _ hash: Hash, as localPath: String? = nil) {
            (self.path, self.size, self.hash, self.localPath) = (path, size, hash, localPath ?? path)
        }
    }

    public enum DownloadError: LocalizedError {
        case badResponse(String, Int)
        case checksum(String)
        public var errorDescription: String? {
            switch self {
            case .badResponse(let file, let status): "Downloading \(file) failed with HTTP \(status)."
            case .checksum(let file): "\(file) didn't match its recorded checksum."
            }
        }
    }

    public let repo: String
    public let revision: String
    public let files: [File]

    public init(repo: String, revision: String, files: [File]) { (self.repo, self.revision, self.files) = (repo, revision, files) }

    /// True when every file is in place. Sizes only: hashes were checked when the files were downloaded.
    public func isInstalled(at directory: URL) -> Bool {
        files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.localPath).path)[.size]) as? Int64
            return size == file.size
        }
    }

    /// Downloads into a staging folder, keeping files already verified there, and moves it into place only when complete.
    public func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".partial")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = Double(files.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for file in files {
            let target = staging.appendingPathComponent(file.localPath)
            if (try? Self.matches(target, file)) == true {
                done += file.size
                continue
            }
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let base = done
            let fetched = try await Self.fetch(url, name: file.path) { progress((Double(base) + Double($0)) / total) }
            guard try Self.matches(fetched, file) else {
                try? fm.removeItem(at: fetched)
                throw DownloadError.checksum(file.path)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: fetched, to: target)
            done += file.size
            progress(Double(done) / total)
        }
        try? fm.removeItem(at: directory)
        try fm.moveItem(at: staging, to: directory)
    }

    public static func matches(_ url: URL, _ file: File) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch file.hash {
        case .sha256(let expected):
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hex(hasher.finalize()) == expected
        case .blob(let expected):
            let data = try handle.readToEnd() ?? Data()
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(data.count)\0".utf8))
            hasher.update(data: data)
            return hex(hasher.finalize()) == expected
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// One file to a temporary location, reporting bytes received.
    private static func fetch(_ url: URL, name: String, received: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let temp, status == 200 else { return continuation.resume(throwing: DownloadError.badResponse(name, status)) }
                    // The system deletes `temp` when this handler returns.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: temp, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                Task {
                    while task.state == .running {
                        received(task.countOfBytesReceived)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
    }
}
