import Foundation

enum JSONHelpers {
    static func prettyString(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object) || object is NSNumber || object is String || object is NSNull else {
            return "\(object)"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: wrapIfNeeded(object), options: [.prettyPrinted, .sortedKeys]) else {
            return "\(object)"
        }
        var str = String(data: data, encoding: .utf8) ?? "\(object)"
        // If we wrapped a scalar, unwrap the pretty output isn't trivial; keep as-is for objects/arrays.
        if let unwrapped = unwrapIfNeeded(object, printed: str) {
            str = unwrapped
        }
        return str
    }

    private static func wrapIfNeeded(_ object: Any) -> Any {
        if object is [String: Any] || object is [Any] {
            return object
        }
        return ["value": object]
    }

    private static func unwrapIfNeeded(_ object: Any, printed: String) -> String? {
        if object is [String: Any] || object is [Any] {
            return nil
        }
        return "\(object)"
    }

    /// Parses a JSON object string, e.g. for `remixa call <method> <json>`.
    static func parseParams(_ jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8) else {
            throw CLIError.message("JSON をパースできません")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw CLIError.message("JSON はオブジェクト（{...}）である必要があります")
        }
        return obj
    }
}
