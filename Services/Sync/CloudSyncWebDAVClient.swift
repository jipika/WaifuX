import Foundation

// MARK: - WebDAV 资源元数据

struct WebDAVResource: Sendable {
    let href: String
    let displayName: String
    let isCollection: Bool
    let contentLength: Int64?
    let lastModified: Date?
}

// MARK: - WebDAV 客户端

/// 底层 WebDAV HTTP 操作封装
final actor CloudSyncWebDAVClient {
    static let shared = CloudSyncWebDAVClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    // MARK: - 认证

    /// 为请求添加 Basic Auth header
    private func authorizedRequest(url: URL, credentials: WebDAVCredentials) -> URLRequest {
        var req = URLRequest(url: url)
        let authStr = "\(credentials.username):\(credentials.password)"
        guard let authData = authStr.data(using: .utf8) else { return req }
        let base64 = authData.base64EncodedString()
        req.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - PROPFIND（枚举目录）

    /// 递归枚举 WebDAV 目录下的文件
    func propFind(
        url: URL,
        credentials: WebDAVCredentials,
        depth: Int = 1
    ) async throws -> [WebDAVResource] {
        var req = authorizedRequest(url: url, credentials: credentials)
        req.httpMethod = "PROPFIND"
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.setValue(depth == 0 ? "0" : "1", forHTTPHeaderField: "Depth")
        // 标准 PROPFIND body（请求所有属性）
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
            <D:allprop/>
        </D:propfind>
        """.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        try checkResponse(response, url: url)

        let resources = try parsePropFindResponse(data: data, baseURL: url)
        return resources
    }

    /// 递归 PROPFIND（Deep scan，用于 GC 和全量扫描）
    func recursivePropFind(
        url: URL,
        credentials: WebDAVCredentials
    ) async throws -> [WebDAVResource] {
        var allResources: [WebDAVResource] = []
        var urlsToScan = [url]

        while !urlsToScan.isEmpty {
            let current = urlsToScan.removeFirst()
            let resources = try await propFind(url: current, credentials: credentials, depth: 1)

            // 收集新的子目录继续扫描
            for resource in resources {
                if resource.isCollection, resource.href != current.lastPathComponent + "/" {
                    // 跳过自身条目，只入队子目录
                    let subURL = buildAbsoluteURL(base: current, href: resource.href)
                    if subURL != current {
                        urlsToScan.append(subURL)
                    }
                }
                allResources.append(resource)
            }
        }

        return allResources
    }

    // MARK: - GET（下载文件）

    func get(
        url: URL,
        credentials: WebDAVCredentials
    ) async throws -> Data {
        let req = authorizedRequest(url: url, credentials: credentials)
        let (data, response) = try await session.data(for: req)
        try checkResponse(response, url: url)
        return data
    }

    // MARK: - PUT（上传文件）

    func put(
        url: URL,
        data: Data,
        contentType: String = "application/octet-stream",
        credentials: WebDAVCredentials
    ) async throws {
        var req = authorizedRequest(url: url, credentials: credentials)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        req.httpBody = data

        let (_, response) = try await session.data(for: req)
        try checkResponse(response, url: url)
    }

    // MARK: - DELETE（删除文件/目录）

    func delete(
        url: URL,
        credentials: WebDAVCredentials
    ) async throws {
        var req = authorizedRequest(url: url, credentials: credentials)
        req.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: req)
        // 404 视为已删除
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            return
        }
        try checkResponse(response, url: url)
    }

    // MARK: - MKCOL（创建目录）

    func mkcol(
        url: URL,
        credentials: WebDAVCredentials
    ) async throws {
        var req = authorizedRequest(url: url, credentials: credentials)
        req.httpMethod = "MKCOL"

        let (_, response) = try await session.data(for: req)
        // 405 = Method Not Allowed（目录已存在），忽略
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 405 {
            return
        }
        try checkResponse(response, url: url)
    }

    // MARK: - 工具方法

    /// 检查 HTTP 响应
    private func checkResponse(_ response: URLResponse, url: URL) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudSyncError.webDAVProtocolError(reason: "非 HTTP 响应")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw CloudSyncError.webDAVAuthenticationFailed
        case 403:
            throw CloudSyncError.fileWriteFailed(path: url.path)
        case 404:
            throw CloudSyncError.webDAVNotFound(path: url.path)
        case 405:
            // Method Not Allowed - MKCOL 已有目录
            return
        case 507:
            throw CloudSyncError.fileWriteFailed(path: url.path)
        default:
            throw CloudSyncError.webDAVProtocolError(
                reason: "HTTP \(httpResponse.statusCode)"
            )
        }
    }

    /// 从基础 URL 和 href 构建绝对 URL
    private func buildAbsoluteURL(base: URL, href: String) -> URL {
        if href.hasPrefix("http") {
            return URL(string: href) ?? base
        }
        // href 是相对路径或绝对路径
        if href.hasPrefix("/") {
            guard let components = URLComponents(url: base, resolvingAgainstBaseURL: false),
                  let baseHost = components.host,
                  let scheme = components.scheme else {
                return base
            }
            // 拼接协议 + host + href
            var result = "\(scheme)://\(baseHost)"
            if let port = components.port {
                result += ":\(port)"
            }
            // 如果 href 有路径，拼接
            let path = href.hasPrefix("/") ? href : "/" + href
            return URL(string: result + path) ?? base
        }
        // 相对路径
        return URL(string: href, relativeTo: base)?.absoluteURL ?? base
    }

    // MARK: - PROPFIND XML 解析

    /// 解析 PROPFIND 的 XML 响应
    private func parsePropFindResponse(data: Data, baseURL: URL) throws -> [WebDAVResource] {
        let parser = WebDAVXMLParser(data: data)
        if !parser.parse() {
            throw CloudSyncError.webDAVProtocolError(
                reason: "PROPFIND XML 解析失败"
            )
        }
        return parser.resources
    }
}

// MARK: - WebDAV XML 解析器

private final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    var resources: [WebDAVResource] = []

    // 解析状态
    private var currentElement = ""
    private var currentHref = ""
    private var currentDisplayName = ""
    private var currentContentLength = ""
    private var currentLastModified = ""
    private var currentIsCollection = false
    private var currentIsPropstat = false
    private var currentIsProp = false
    private var currentStatusOK = false

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Bool {
        resources.removeAll()
        return parser.parse()
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.contains(":") ?
            String(elementName.split(separator: ":").last ?? "") : elementName
        currentElement = localName

        if localName == "response" {
            resetCurrent()
        } else if localName == "propstat" {
            currentIsPropstat = true
        } else if localName == "prop" {
            currentIsProp = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch currentElement {
        case "href":
            currentHref += trimmed
        case "displayname":
            currentDisplayName += trimmed
        case "getcontentlength":
            currentContentLength += trimmed
        case "getlastmodified":
            currentLastModified += trimmed
        case "status":
            if trimmed.contains("200") {
                currentStatusOK = true
            }
        case "collection":
            currentIsCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.contains(":") ?
            String(elementName.split(separator: ":").last ?? "") : elementName

        if localName == "response" {
            // 跳过根路径自身
            if !currentHref.isEmpty && currentStatusOK {
                let resource = WebDAVResource(
                    href: currentHref,
                    displayName: currentDisplayName.isEmpty ? currentHref : currentDisplayName,
                    isCollection: currentIsCollection,
                    contentLength: Int64(currentContentLength),
                    lastModified: parseWebDAVDate(currentLastModified)
                )
                resources.append(resource)
            }
            resetCurrent()
        } else if localName == "propstat" {
            currentIsPropstat = false
        } else if localName == "prop" {
            currentIsProp = false
        }
    }

    private func resetCurrent() {
        currentHref = ""
        currentDisplayName = ""
        currentContentLength = ""
        currentLastModified = ""
        currentIsCollection = false
        currentStatusOK = false
    }

    /// 解析 WebDAV date 格式（RFC 1123 或 ISO 8601）
    private func parseWebDAVDate(_ string: String) -> Date? {
        let formatters = [
            "E, d MMM yyyy HH:mm:ss zzz",   // RFC 1123
            "E, d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",      // ISO 8601
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        for format in formatters {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = format
            if let date = fmt.date(from: string) {
                return date
            }
        }
        return nil
    }
}

// MARK: - WebDAV 凭证模型

struct WebDAVCredentials: Sendable {
    let baseURL: URL
    let username: String
    let password: String

    /// 拼接待同步的根路径 URL
    var syncRootURL: URL {
        baseURL.appendingPathComponent(CloudSyncDirectoryLayout.rootName)
            .appendingPathComponent(CloudSyncDirectoryLayout.versionDir)
    }

    var metadataURL: URL {
        syncRootURL.appendingPathComponent(CloudSyncDirectoryLayout.metadataFileName)
    }

    var manifestURL: URL {
        syncRootURL.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)
    }

    var objectsURL: URL {
        syncRootURL.appendingPathComponent(CloudSyncDirectoryLayout.objectsDirName)
    }
}
