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
///
/// - Parameters:
///   - data:     Raw JSON bytes.
///   - type:     Expected Decodable type. Can be inferred when calling with an explicit
///               return-type annotation.
///   - maxBytes: Hard ceiling on `data.count`. Default 1 MiB.
///   - maxDepth: Maximum `{` / `[` nesting. Default 16 levels.
///               The check is a single-pass byte scan that counts openers against closers;
///               no intermediate allocation is performed.
/// - Throws: `BoundedJSONError` if either limit is exceeded; otherwise a `DecodingError`
///           or Swift Foundation JSON parse error.
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

/// Single-pass byte scan: counts `{` and `[` nesting; throws if peak depth exceeds `maxDepth`.
///
/// String contents are skipped correctly (handles `\"` escape sequences) so structural
/// braces inside string values are ignored. No allocation beyond the iterator.
func assertJSONDepth(_ data: Data, maxDepth: Int) throws {
    var depth = 0
    var maxSeen = 0
    var inString = false
    var escapeNext = false
    for byte in data {
        if escapeNext { escapeNext = false; continue }
        if inString {
            if byte == 0x5C { escapeNext = true }      // backslash — next char is escaped
            else if byte == 0x22 { inString = false }  // closing "
            continue
        }
        switch byte {
        case 0x22:          inString = true            // opening "
        case 0x7B, 0x5B:                               // { or [
            depth += 1
            if depth > maxSeen { maxSeen = depth }
        case 0x7D, 0x5D:   depth -= 1                 // } or ]
        default:            break
        }
    }
    if maxSeen > maxDepth {
        throw BoundedJSONError.exceedsMaxDepth(actual: maxSeen, limit: maxDepth)
    }
}
