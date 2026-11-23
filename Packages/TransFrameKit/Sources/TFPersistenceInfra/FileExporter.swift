import Foundation
import TFDomain

/// Writes exported files with unique names (EXP-01) after checking location and free space (EXP-02).
public struct FileExporter: FileExporting {
    public init() {}

    private var fileManager: FileManager { .default }

    public func write(_ data: Data, baseName: String, fileExtension: String, to directory: URL) async throws(AppError) -> URL {
        try check(directory: directory, bytes: data.count)
        let url = uniqueURL(baseName: baseName, fileExtension: fileExtension, in: directory)
        try write(data, url: url)
        return url
    }

    public func write(_ data: Data, to url: URL) async throws(AppError) {
        try check(directory: url.deletingLastPathComponent(), bytes: data.count)
        try write(data, url: url)
    }

    /// `name.ext`, then `name (1).ext`, `name (2).ext`, … (1.x behaviour).
    public func uniqueURL(baseName: String, fileExtension: String, in directory: URL) -> URL {
        var candidate = directory.appending(path: "\(baseName).\(fileExtension)", directoryHint: .notDirectory)
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(baseName) (\(counter)).\(fileExtension)", directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }

    private func check(directory: URL, bytes: Int) throws(AppError) {
        var isDirectory: ObjCBool = false
        let path = directory.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: path) else { throw .export(.invalidLocation) }
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, available < Int64(bytes) + 1_048_576 {
            throw .export(.diskFull)
        }
    }

    private func write(_ data: Data, url: URL) throws(AppError) {
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw .export(.diskFull)
        } catch {
            throw .export(.invalidLocation)
        }
    }
}
