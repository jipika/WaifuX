import Foundation

/// Cost and recency accounting for decoded posters. Pixel decoding remains in
/// the AppKit caller; this policy never allocates image buffers.
struct VideoPosterCacheBudget {
    static let maximumDimension = 2_048
    static let maximumImageBytes = 16 * 1_024 * 1_024
    static let maximumDecodedBytes = 64 * 1_024 * 1_024
    static let maximumSourceBytes = 32 * 1_024 * 1_024
    static let maximumEntries = 24

    private var costs: [String: Int] = [:]
    private var recency: [String] = []
    private(set) var byteCount = 0
    var count: Int { costs.count }

    static func decodedByteCount(bytesPerRow: Int, height: Int) -> Int? {
        guard bytesPerRow > 0, height > 0 else { return nil }
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, bytes <= maximumImageBytes else { return nil }
        return bytes
    }

    mutating func touch(_ key: String) {
        guard costs[key] != nil else { return }
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    /// Returns every key whose cached image must be released by the caller.
    mutating func insert(_ key: String, decodedBytes: Int) -> [String] {
        if let previousCost = costs.removeValue(forKey: key) { byteCount -= previousCost }
        recency.removeAll { $0 == key }
        guard decodedBytes > 0, decodedBytes <= Self.maximumImageBytes else { return [key] }
        costs[key] = decodedBytes
        byteCount += decodedBytes
        recency.append(key)
        var evicted: [String] = []
        while count > Self.maximumEntries || byteCount > Self.maximumDecodedBytes {
            guard !recency.isEmpty else { break }
            let oldest = recency.removeFirst()
            if let cost = costs.removeValue(forKey: oldest) { byteCount -= cost }
            evicted.append(oldest)
        }
        return evicted
    }
}
