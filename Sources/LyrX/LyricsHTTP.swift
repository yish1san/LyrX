import Foundation

/// 歌词请求独立于持久 Cookie、凭据和 URL 缓存；禁止明文及跨主机重定向。
enum LyricsHTTP {
    static let allowedHosts: Set<String> = [
        "lrclib.net", "music.163.com", "raw.githubusercontent.com", "api.musixmatch.com"
    ]

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(permitsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    static func permits(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), allowedHosts.contains(host),
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    static func permitsRedirect(from original: URL?, to destination: URL?) -> Bool {
        permits(original) && permits(destination) && original?.host?.lowercased() == destination?.host?.lowercased()
    }

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard permits(request.url) else { throw URLError(.unsupportedURL) }
        var request = request
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
