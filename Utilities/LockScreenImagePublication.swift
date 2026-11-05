import Foundation

/// File-only staging; it never discovers or opens the production App Group.
/// The caller commits preferences on its owning actor only after stage succeeds.
enum LockScreenImagePublication {
    struct Staged: Sendable {
        let directory: URL
        let requestID: UUID
        let filesByDisplay: [UInt32: URL]
    }

    static func stage(
        data: Data, fileExtension: String, displayIDs: [UInt32], directory: URL, requestID: UUID,
        validate: (URL) throws -> Void = { _ = try WallpaperBoundedImageDecoder.decode(url: $0).get() }
    ) throws -> Staged {
        guard ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"].contains(fileExtension),
              !displayIDs.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [UInt32: URL] = [:]
        do {
            for displayID in Set(displayIDs).sorted() {
                let name = "display-\(displayID)-\(requestID.uuidString.lowercased()).\(fileExtension)"
                let url = directory.appendingPathComponent(name)
                files[displayID] = url
                try data.write(to: url, options: .atomic)
                try validate(url)
            }
            return Staged(directory: directory, requestID: requestID, filesByDisplay: files)
        } catch {
            discard(Staged(directory: directory, requestID: requestID, filesByDisplay: files))
            throw error
        }
    }

    /// Cancellation/commit failure can remove only the unpublished request's
    /// UUID paths. Existing images and other requests are never removed here.
    static func discard(_ staged: Staged) {
        let directory = staged.directory.standardizedFileURL
        for (displayID, url) in staged.filesByDisplay {
            guard url.standardizedFileURL.deletingLastPathComponent() == directory,
                  url.lastPathComponent.hasPrefix("display-\(displayID)-\(staged.requestID.uuidString.lowercased()).") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Keep all referenced images plus the previous image of the affected
    /// displays. A grace period protects in-flight readers and staged writers.
    static func prune(
        directory: URL, displayIDs: [UInt32], protectedPaths: Set<String>,
        now: Date = Date(), gracePeriod: TimeInterval = 300
    ) {
        let fm = FileManager.default
        let protected = Set(protectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let files = (try? fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        for url in files {
            let name = url.lastPathComponent
            guard displayIDs.contains(where: { name.hasPrefix("display-\($0)-") || name.hasPrefix("display-\($0).") }),
                  !protected.contains(url.standardizedFileURL.path),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= gracePeriod else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
