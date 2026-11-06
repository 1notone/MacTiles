import Foundation

// MARK: - What a service tile shows

/// A service-agnostic picture of a widget's data: a headline, a few stats, gauges and a list.
/// Every service is parsed into this shape, so the tiles can draw any of them.
struct ServiceSnapshot: Equatable, Sendable {
    struct Stat: Equatable, Sendable {
        var label: String
        var value: String
    }

    struct Gauge: Equatable, Sendable {
        var label: String
        var fraction: Double        // 0…1
        var detail: String = ""
    }

    struct Item: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var subtitle: String = ""
        var progress: Double?       // playback position, download progress…
        var image: URL?             // poster
        var isActive = false        // playing, running, downloaded…
    }

    var headline = ""
    var caption = ""
    var stats: [Stat] = []
    var gauges: [Gauge] = []
    var items: [Item] = []
    /// On/off for things you can switch: Pi-hole blocking, a Home Assistant light…
    var isOn: Bool?
    /// A symbol that describes the current state (Home Assistant entities).
    var symbol: String?
    var emptyText = ""
    /// Live throughput per interface (OPNsense), fastest-moving context first.
    var traffic: [Traffic] = []
    /// Recent values for a sparkline, scaled 0…1.
    var series: [Double] = []
    /// Progress of the job running now (ComfyUI), 0…1.
    var progress: Double?
    /// Something is running; the tile stays on its live face instead of flipping.
    var busy = false
    /// What the tile is about, when it's one thing (a Beszel system); used as its label.
    var name: String?

    struct Traffic: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var down: Double        // bytes per second
        var up: Double
    }
}

/// Something you can do to a service from its tile.
enum ServiceAction: Hashable, Sendable {
    case pauseBlocking(seconds: Int?)       // nil = until you turn it back on
    case resumeBlocking
    case toggleEntity(String)
    case runEntity(String)
    case container(id: String, verb: String)    // start, stop, restart
    case interrupt                              // stop the job running now (ComfyUI)
    case clearQueue                             // drop jobs waiting to run (ComfyUI)
}

enum ServiceError: LocalizedError, Equatable {
    case badAddress
    case unauthorized
    case http(Int)
    case unreachable(String)
    case unexpected(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "Check the address in Settings → Integrations."
        case .unauthorized: return "Sign-in failed. Check the key or password."
        case .http(let code): return code == 404 ? "Not found (404). Is this the right address and port?" : "The service answered with error \(code)."
        case .unreachable(let why): return why
        case .unexpected(let what): return what
        case .missing(let what): return what
        }
    }
}

// MARK: - JSON

/// A forgiving view into decoded JSON: missing keys give empty values instead of throwing.
struct JSON {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) throws {
        do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ServiceError.unexpected("The service didn't send the data MacTiles expected.") }
    }

    subscript(key: String) -> JSON { JSON((raw as? [String: Any])?[key]) }
    subscript(index: Int) -> JSON {
        guard let a = raw as? [Any], a.indices.contains(index) else { return JSON(nil) }
        return JSON(a[index])
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var isArray: Bool { raw is [Any] }
    var dict: [String: JSON] { ((raw as? [String: Any]) ?? [:]).mapValues(JSON.init) }
    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    var int: Int? { double.map { Int($0) } }
    /// A number under `key`, or 0 — keeps sums simple for the compiler.
    func num(_ key: String) -> Double { self[key].double ?? 0 }
    func whole(_ key: String) -> Int { self[key].int ?? 0 }
    var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return ["true", "1", "yes", "on", "enabled"].contains(s.lowercased()) }
        return nil
    }
}

// MARK: - HTTP

/// One connection to one service. Keeps cookies and sign-in sessions between polls, and can
/// accept the self-signed certificates homelab servers usually have (only when you allow it).
final class ServiceClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let data: Data
        let headers: [String: String]     // lowercased names

        var ok: Bool { (200..<300).contains(status) }

        func check() throws {
            if status == 401 || status == 403 { throw ServiceError.unauthorized }
            if !ok { throw ServiceError.http(status) }
        }

        func json() throws -> JSON {
            try check()
            return try JSON(data: data)
        }
    }

    let integration: Integration
    let secret: String
    /// Identifies the settings this client was made with; a change makes a new client.
    let fingerprint: String
    private var session: URLSession!
    private let lock = NSLock()
    private var state: [String: String] = [:]
    private var traffic: TrafficSample?
    /// ComfyUI's live progress feed (its WebSocket), for ComfyUI connections only.
    let comfy: ComfyMonitor?
    private var history: [Double] = []

    init(integration: Integration, secret: String) {
        self.integration = integration
        self.secret = secret
        self.fingerprint = Self.fingerprint(integration, secret: secret)
        self.comfy = integration.kind == .comfyui ? ComfyMonitor() : nil
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// URLSession keeps its delegate alive, so a client must be closed when it's replaced.
    func invalidate() {
        comfy?.stop()
        session.invalidateAndCancel()
    }

    static func fingerprint(_ i: Integration, secret: String) -> String {
        [i.kind.rawValue, i.url, i.username, i.allowSelfSigned ? "1" : "0", String(secret.hashValue)].joined(separator: "|")
    }

    // Session state (Pi-hole session IDs, UniFi's CSRF token, cached titles…).
    func value(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return state[key]
    }

    /// The previous interface counters, to turn byte totals into speeds.
    func trafficSample() -> TrafficSample? {
        lock.lock(); defer { lock.unlock() }
        return traffic
    }

    func setTrafficSample(_ sample: TrafficSample) {
        lock.lock(); defer { lock.unlock() }
        traffic = sample
    }

    /// Keeps the last 30 values of a reading (for a sparkline) and returns them.
    func record(_ value: Double) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        history.append(value)
        if history.count > 30 { history.removeFirst(history.count - 30) }
        return history
    }

    func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        state[key] = value
    }

    var base: URL {
        get throws {
            guard let url = integration.baseURL else { throw ServiceError.badAddress }
            return url
        }
    }

    /// Sends a request to `path` (which may include a query string) under the service's address.
    func send(_ path: String, method: String = "GET", headers: [String: String] = [:],
              json: Any? = nil, body: Data? = nil, absolute: URL? = nil) async throws -> Response {
        let url: URL
        if let absolute {
            url = absolute
        } else {
            guard let u = URL(string: try base.absoluteString + path) else { throw ServiceError.badAddress }
            url = u
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacTiles", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.unexpected("No response from the service.") }
            var lowered: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { lowered[k.lowercased()] = v }
            }
            return Response(status: http.statusCode, data: data, headers: lowered)
        } catch let error as URLError {
            throw Self.explain(error, selfSignedAllowed: integration.allowSelfSigned)
        }
    }

    /// Fetches an image (a poster) through this connection, so self-signed servers work too.
    func image(_ url: URL) async throws -> Data {
        let r = try await send("", absolute: url)
        try r.check()
        return r.data
    }

    /// A WebSocket on this connection (TrueNAS's JSON-RPC API).
    func webSocket(_ url: URL) -> URLSessionWebSocketTask { session.webSocketTask(with: url) }

    static func explain(_ error: URLError, selfSignedAllowed: Bool) -> ServiceError {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return .unreachable(selfSignedAllowed
                ? "The secure connection failed."
                : "The server's certificate isn't trusted. Turn on \"Allow self-signed certificate\" if it's yours.")
        case .timedOut:
            return .unreachable("Timed out. Is the service running?")
        case .cannotConnectToHost:
            return .unreachable("Couldn't connect. Check the address and port.")
        case .cannotFindHost, .dnsLookupFailed:
            return .unreachable("Couldn't find that server.")
        case .notConnectedToInternet, .networkConnectionLost:
            return .unreachable("No network connection.")
        case .appTransportSecurityRequiresSecureConnection:
            return .unreachable("macOS blocked the plain-HTTP connection.")
        default:
            return .unreachable(error.localizedDescription)
        }
    }

    // Accept the server's certificate as-is, only when the integration says so — and only for
    // the service's own server, never for another site it links to (posters) or redirects to.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if Self.trustsSelfSigned(integration, host: challenge.protectionSpace.host),
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func trustsSelfSigned(_ integration: Integration, host: String) -> Bool {
        guard integration.allowSelfSigned, let own = integration.baseURL?.host else { return false }
        return own.caseInsensitiveCompare(host) == .orderedSame
    }

    // A redirect to another server doesn't get the service's API key, token or session headers.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.redirect(request, from: task.originalRequest?.url))
    }

    static func redirect(_ request: URLRequest, from original: URL?) -> URLRequest {
        guard let to = request.url?.host, let from = original?.host,
              to.caseInsensitiveCompare(from) != .orderedSame, let url = request.url else { return request }
        var safe = URLRequest(url: url)
        safe.httpMethod = "GET"
        safe.setValue("MacTiles", forHTTPHeaderField: "User-Agent")
        safe.setValue(request.value(forHTTPHeaderField: "Accept"), forHTTPHeaderField: "Accept")
        safe.httpShouldHandleCookies = true      // cookies are scoped to their own domain by URLSession
        return safe
    }
}

// MARK: - ComfyUI live progress

/// Listens to ComfyUI's WebSocket for step-by-step progress (and Crystools' monitor, if
/// installed) between polls. It disconnects by itself when Start stops asking.
final class ComfyMonitor: @unchecked Sendable {
    struct Live: Equatable, Sendable {
        var promptID: String?
        var value: Double = 0
        var max: Double = 0
        var queueRemaining: Int?
        // From the Crystools custom node, when installed.
        var cpu: Double?
        var gpu: Double?
        var gpuTemperature: Double?
        var vramPercent: Double?
        var ramPercent: Double?
        var monitorAt: Date?
    }

    private let lock = NSLock()
    private var live = Live()
    private var task: URLSessionWebSocketTask?
    private var wantedAt = Date()

    func snapshot() -> Live {
        lock.lock(); defer { lock.unlock() }
        // Crystools figures go stale if the node stops sending.
        var copy = live
        if let at = copy.monitorAt, Date().timeIntervalSince(at) > 15 {
            copy.cpu = nil; copy.gpu = nil; copy.gpuTemperature = nil; copy.vramPercent = nil; copy.ramPercent = nil
        }
        return copy
    }

    /// Opens the feed if it isn't open. Called on every poll; the feed closes ~90 s after the last.
    func ensureRunning(_ client: ServiceClient) {
        lock.lock()
        wantedAt = Date()
        let running = task.map { $0.state == .running } ?? false
        lock.unlock()
        guard !running, let base = client.integration.baseURL,
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.path += "/ws"
        parts.queryItems = [URLQueryItem(name: "clientId", value: "mactiles-" + UUID().uuidString)]
        guard let url = parts.url else { return }
        let socket = client.webSocket(url)
        lock.lock(); task = socket; lock.unlock()
        socket.resume()
        Task.detached { [weak self] in await self?.listen(socket) }
    }

    func stop() {
        lock.lock(); let t = task; task = nil; lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
    }

    private func listen(_ socket: URLSessionWebSocketTask) async {
        while shouldKeepListening(to: socket) {
            guard let message = try? await socket.receive() else { break }
            if case .string(let text) = message { handle(Data(text.utf8)) }     // binary frames are image previews
        }
        socket.cancel(with: .goingAway, reason: nil)
        forget(socket)
    }

    // The lock is only taken in these synchronous helpers, never across an await.
    private func shouldKeepListening(to socket: URLSessionWebSocketTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return task === socket && Date().timeIntervalSince(wantedAt) <= 90
    }

    private func forget(_ socket: URLSessionWebSocketTask) {
        lock.lock(); defer { lock.unlock() }
        if task === socket { task = nil }
    }

    func handle(_ data: Data) {
        guard let j = try? JSON(data: data), let type = j["type"].string else { return }
        let d = j["data"]
        lock.lock(); defer { lock.unlock() }
        live = Self.apply(type: type, data: d, to: live)
    }

    /// Updates the live state with one message. Pure, for tests.
    static func apply(type: String, data d: JSON, to state: Live, now: Date = Date()) -> Live {
        var live = state
        switch type {
        case "status":
            live.queueRemaining = d["status"]["exec_info"]["queue_remaining"].int
        case "execution_start":
            live.promptID = d["prompt_id"].string
            live.value = 0
            live.max = 0
        case "progress":
            live.promptID = d["prompt_id"].string ?? live.promptID
            live.value = d["value"].double ?? 0
            live.max = d["max"].double ?? 0
        case "executing":
            if !d["node"].exists && d["prompt_id"].string == live.promptID {
                live.promptID = nil; live.value = 0; live.max = 0      // node null: the run finished
            } else if let id = d["prompt_id"].string {
                live.promptID = id
            }
        case "execution_success", "execution_error", "execution_interrupted":
            if d["prompt_id"].string == nil || d["prompt_id"].string == live.promptID {
                live.promptID = nil; live.value = 0; live.max = 0
            }
        case "crystools.monitor":
            live.cpu = d["cpu_utilization"].double
            live.ramPercent = d["ram_used_percent"].double
            let gpu = d["gpus"][0]
            live.gpu = gpu["gpu_utilization"].double
            live.gpuTemperature = gpu["gpu_temperature"].double
            live.vramPercent = gpu["vram_used_percent"].double
            live.monitorAt = now
        default:
            break
        }
        return live
    }
}

/// Byte counters for every interface at one moment.
struct TrafficSample: Equatable, Sendable {
    struct Counter: Equatable, Sendable {
        var name: String
        var inBytes: Double
        var outBytes: Double
    }

    var time: Double                    // seconds; the firewall's clock when it sends one
    var counters: [String: Counter]     // by interface identifier (wan, lan, opt1…)
}

// MARK: - HTTP over a Unix socket (Docker on this Mac)

/// Docker Desktop, OrbStack, Colima and Rancher Desktop all serve the Docker API on a Unix socket.
enum UnixSocketHTTP {
    static func candidates(home: String = NSHomeDirectory()) -> [String] {
        [
            home + "/.docker/run/docker.sock",
            "/var/run/docker.sock",
            home + "/.orbstack/run/docker.sock",
            home + "/.colima/default/docker.sock",
            home + "/.colima/docker.sock",
            home + "/.rd/docker.sock",
        ]
    }

    static func findDockerSocket() -> String? {
        candidates().first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Sends one HTTP/1.0 request and reads the whole reply. Runs off the main thread.
    static func request(socket path: String, method: String, target: String, timeout: Int = 6) async throws -> ServiceClient.Response {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try requestSync(socket: path, method: method, target: target, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func requestSync(socket path: String, method: String, target: String, timeout: Int) throws -> ServiceClient.Response {
        guard isSafeRequest(method: method, target: target) else {
            throw ServiceError.unexpected("MacTiles refused an unusual Docker request.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceError.unreachable("Couldn't open a socket.") }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ServiceError.unreachable("The Docker socket path is too long.")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in dst.copyMemory(from: src) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ServiceError.unreachable("Docker isn't running.") }

        let request = "\(method) \(target) HTTP/1.0\r\nHost: docker\r\nUser-Agent: MacTiles\r\nContent-Length: 0\r\n\r\n"
        let out = Array(request.utf8)
        var sent = 0
        while sent < out.count {
            let n = out[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw ServiceError.unreachable("Couldn't talk to Docker.") }
            sent += n
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { reply.append(contentsOf: buffer[0..<n]) } else { break }
            if reply.count > 8_000_000 { break }
        }
        guard let parsed = parse(reply) else { throw ServiceError.unexpected("Docker sent a reply MacTiles couldn't read.") }
        return parsed
    }

    /// Only GET/POST, and a target that can't smuggle extra lines into the request.
    static func isSafeRequest(method: String, target: String) -> Bool {
        ["GET", "POST"].contains(method) && target.hasPrefix("/")
            && target.rangeOfCharacter(from: CharacterSet(charactersIn: " \r\n\t")) == nil
    }

    /// Splits a raw HTTP reply into status, headers and body (de-chunking if needed).
    static func parse(_ reply: Data) -> ServiceClient.Response? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = reply.range(of: separator),
              let head = String(data: reply[reply.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(reply[range.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { body = dechunk(body) }
        return ServiceClient.Response(status: status, data: body, headers: headers)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex),
                  let sizeText = String(data: data[i..<lineEnd.lowerBound], encoding: .utf8),
                  let size = Int(sizeText.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16)
            else { break }
            if size == 0 { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}

// MARK: - Formatting

enum Fmt {
    /// One path segment ("light.kitchen", a container ID) made safe to put between slashes:
    /// "/", "?", "#", "%" and spaces are percent-encoded so a value can't change the request.
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func count(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", n / 1_000) }
        if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        return String(Int(n))
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", min(max(fraction, 0), 1) * 100)
    }

    static func bytes(_ n: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(n, 0)), countStyle: .binary)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Bytes per second as a network speed: "820 kb/s", "48.2 Mb/s", "1.2 Gb/s".
    static func bitrate(_ bytesPerSecond: Double) -> String {
        let bits = max(bytesPerSecond, 0) * 8
        if bits >= 1e9 { return String(format: "%.1f Gb/s", bits / 1e9) }
        if bits >= 1e7 { return String(format: "%.0f Mb/s", bits / 1e6) }
        if bits >= 1e6 { return String(format: "%.1f Mb/s", bits / 1e6) }
        if bits >= 1e3 { return String(format: "%.0f kb/s", bits / 1e3) }
        return String(format: "%.0f b/s", bits)
    }

    static func speed(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.1f Gbps", mbps / 1000) : String(format: "%.0f Mbps", mbps)
    }

    /// "Today 8:00 PM", "Tomorrow", "Fri 14".
    static func when(_ date: Date, now: Date = Date(), withTime: Bool = true) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return withTime ? "Today \(time)" : "Today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return withTime ? "Tomorrow \(time)" : "Tomorrow"
        }
        if date < now, let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    static func isoDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: String(s.prefix(10)))
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// For query strings: encodes everything except unreserved characters.
    static func query(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
