import Foundation

/// Percent-encoding for object keys and query values, shared by both clouds.
///
/// Only RFC 3986's unreserved characters pass through; everything else becomes `%XX`.
/// Foundation's own encoders are too permissive for object storage: `URLComponents`
/// leaves `+` bare in a query (Azure reads it as a space, so `prefix=C++/` lists
/// nothing) and `/` bare in a query value (which breaks SigV4), and splitting a key
/// on `/` with `omittingEmptySubsequences` quietly turns `logs/` into `logs` and `a//b`
/// into `a/b` — different objects.
enum StrictPercentEncoding {

    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// One path segment or query component, with nothing but unreserved characters
    /// left bare.
    static func component(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// An object key as a URL path. `/` stays a separator, and every segment is kept —
    /// including empty ones — so a trailing slash, a leading slash, or a doubled slash
    /// all address the key that was actually asked for.
    static func key(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { component(String($0)) }
            .joined(separator: "/")
    }

    /// A query string in the order given, for services that don't need it sorted.
    static func query(_ items: [(name: String, value: String)]) -> String {
        items.map { "\(component($0.name))=\(component($0.value))" }.joined(separator: "&")
    }
}
