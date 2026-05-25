import Foundation

// MARK: - BoundedJSONError

enum BoundedJSONError: LocalizedError {
    case exceedsMaxBytes(actual: Int, limit: Int)
    case exceedsMaxDepth(actual: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .exceedsMaxBytes(let actual, let limit):
            return "JSON payload \(actual) bytes exceeds \(limit)-byte limit."
        case .exceedsMaxDepth(let actual, let limit):
            return "JSON nesting depth \(actual) exceeds \(limit)-level limit."
        }
    }
}

// MARK: - decodeBoundedJSON

/// Decodes a Decodable value from JSON data, refusing payloads that exceed size or
/// nesting-depth limits before any allocating parse is attempted.
func decodeBoundedJSON<T: Decodable>(
    _ data: Data,
    as type: T.Type = T.self,
    maxBytes: Int = 1 << 20,
    maxDepth: Int = 16
) throws -> T {
    guard data.count <= maxBytes else {
        throw BoundedJSONError.exceedsMaxBytes(actual: data.count, limit: maxBytes)
    }
    try assertJSONDepth(data, maxDepth: maxDepth)
    return try JSONDecoder().decode(type, from: data)
}

// MARK: - assertJSONDepth

/// Single-pass byte scan counting `{`/`[` nesting depth. String content is skipped
/// correctly (handles `\"` escapes). Throws `BoundedJSONError.exceedsMaxDepth` if peak
/// nesting exceeds `maxDepth`.
func assertJSONDepth(_ data: Data, maxDepth: Int) throws {
    var depth = 0
    var maxSeen = 0
    var inString = false
    var escapeNext = false
    for byte in data {
        if escapeNext { escapeNext = false; continue }
        if inString {
            if byte == 0x5C { escapeNext = true }
            else if byte == 0x22 { inString = false }
            continue
        }
        switch byte {
        case 0x22:          inString = true
        case 0x7B, 0x5B:
            depth += 1
            if depth > maxSeen { maxSeen = depth }
        case 0x7D, 0x5D:   depth -= 1
        default:            break
        }
    }
    if maxSeen > maxDepth {
        throw BoundedJSONError.exceedsMaxDepth(actual: maxSeen, limit: maxDepth)
    }
}
