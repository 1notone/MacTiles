import Foundation

/// Talks to each service's own API and turns the answers into `ServiceSnapshot`s.
/// The `parse…` functions are pure, so tests can feed them sample responses.
enum ServiceAPI {

    // MARK: Entry points

    static func fetch(_ c: ServiceClient, widget: ServiceWidget, entity: String?) async throws -> ServiceSnapshot {
        switch (c.integration.kind, widget) {
        case (.plex, .nowPlaying): return try await plexNowPlaying(c)
        case (.plex, _): return try await plexRecent(c)
        case (.jellyfin, .nowPlaying), (.emby, .nowPlaying): return try await jellyNowPlaying(c)
        case (.jellyfin, _), (.emby, _): return try await jellyRecent(c)
        case (.sonarr, _): return try await sonarr(c)
        case (.radarr, _): return try await radarr(c)
        case (.overseerr, _): return try await overseerr(c)
        case (.pihole, _): return try await pihole(c)
        case (.adguard, _): return try await adguard(c)
        case (.homeAssistant, _):
            guard let entity, !entity.isEmpty else { throw ServiceError.missing("Choose an entity for this tile.") }
            return try await haEntity(c, entity)
        case (.unifi, _): return try await unifi(c)
        case (.opnsense, _): return try await opnsense(c)
        case (.proxmox, _): return try await proxmox(c)
        case (.truenas, _): return try await truenas(c)
        case (.unraid, .containers): return try await unraidContainers(c)
        case (.unraid, _): return try await unraid(c)
        case (.glances, _): return try await glances(c)
        case (.docker, _): return try await docker(c)
        case (.beszel, _): return try await beszel(c, only: entity)
        case (.comfyui, _): return try await comfyui(c)
        }
    }

    static func perform(_ c: ServiceClient, _ action: ServiceAction) async throws {
        switch (c.integration.kind, action) {
        case (.pihole, .pauseBlocking(let seconds)): try await piholeBlocking(c, on: false, seconds: seconds)
        case (.pihole, .resumeBlocking): try await piholeBlocking(c, on: true, seconds: nil)
        case (.adguard, .pauseBlocking(let seconds)): try await adguardProtection(c, on: false, seconds: seconds)
        case (.adguard, .resumeBlocking): try await adguardProtection(c, on: true, seconds: nil)
        case (.homeAssistant, .toggleEntity(let id)), (.homeAssistant, .runEntity(let id)):
            try await haActivate(c, id)
        case (.docker, .container(let id, let verb)): try await dockerAction(c, id: id, verb: verb)
        case (.comfyui, .interrupt): try await c.send("/interrupt", method: "POST", json: [String: Any]()).check()
        case (.comfyui, .clearQueue): try await c.send("/queue", method: "POST", json: ["clear": true]).check()
        default: throw ServiceError.unexpected("That isn't supported for \(c.integration.kind.title).")
        }
    }

    /// For the Test button: tries the first widget and reports what it found.
    static func test(_ c: ServiceClient) async throws -> String {
        switch c.integration.kind {
        case .homeAssistant:
            let entities = try await haEntities(c)
            return "Connected — \(entities.count) entities."
        case .docker:
            let snap = try await docker(c)
            return "Connected — \(snap.items.count) containers."
        case .beszel:
            let snap = try await beszel(c, only: nil)
            return "Connected — \(snap.headline) \(snap.caption)."
        case .comfyui:
            let stats = try await c.send("/system_stats").json()
            let version = stats["system"]["comfyui_version"].string.map { " \($0)" } ?? ""
            let gpu = comfyDeviceName(stats["devices"][0]["name"].string)
            return "Connected — ComfyUI\(version)" + (gpu.isEmpty ? "." : " on \(gpu).")
        default:
            let snap = try await fetch(c, widget: c.integration.kind.widgets[0], entity: nil)
            let summary = [snap.headline, snap.caption].filter { !$0.isEmpty }.joined(separator: " ")
            return summary.isEmpty ? "Connected." : "Connected — \(summary)."
        }
    }

    // MARK: - Plex

    private static func plexHeaders(_ c: ServiceClient) -> [String: String] {
        ["X-Plex-Token": c.secret, "X-Plex-Client-Identifier": "\(Edition.name)", "X-Plex-Product": "\(Edition.name)"]
    }

    private static func plexImage(_ c: ServiceClient, _ path: String?) -> URL? {
        guard let path, !path.isEmpty, let base = c.integration.baseURL else { return nil }
        return URL(string: base.absoluteString + path + "?X-Plex-Token=" + Fmt.query(c.secret))
    }

    static func plexNowPlaying(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let j = try await c.send("/status/sessions", headers: plexHeaders(c)).json()
        return parsePlexSessions(j) { plexImage(c, $0) }
    }

    static func parsePlexSessions(_ j: JSON, image: (String?) -> URL? = { _ in nil }) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let sessions = j["MediaContainer"]["Metadata"].array
        s.items = sessions.enumerated().map { i, m in
            let duration = m["duration"].double ?? 0
            let offset = m["viewOffset"].double ?? 0
            let user = m["User"]["title"].string ?? ""
            let player = m["Player"]["title"].string ?? m["Player"]["product"].string ?? ""
            let paused = m["Player"]["state"].string == "paused"
            return ServiceSnapshot.Item(
                id: m["sessionKey"].string ?? "\(i)",
                title: plexTitle(m),
                subtitle: [user, player].filter { !$0.isEmpty }.joined(separator: " · ") + (paused ? " · Paused" : ""),
                progress: duration > 0 ? offset / duration : nil,
                image: image(m["grandparentThumb"].string ?? m["thumb"].string),
                isActive: !paused)
        }
        s.headline = "\(s.items.count)"
        s.caption = s.items.count == 1 ? "stream" : "streams"
        s.emptyText = "Nothing playing"
        return s
    }

    static func plexTitle(_ m: JSON) -> String {
        let title = m["title"].string ?? "Untitled"
        switch m["type"].string {
        case "episode":
            let show = m["grandparentTitle"].string ?? ""
            if let season = m["parentIndex"].int, let episode = m["index"].int {
                return "\(show) S\(season)E\(episode) · \(title)"
            }
            return show.isEmpty ? title : "\(show) · \(title)"
        case "season":
            return [m["parentTitle"].string, title].compactMap { $0 }.joined(separator: " · ")
        case "track":
            return [m["grandparentTitle"].string, title].compactMap { $0 }.joined(separator: " — ")
        default:
            if let year = m["year"].int { return "\(title) (\(year))" }
            return title
        }
    }

    static func plexRecent(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let j = try await c.send("/library/recentlyAdded?X-Plex-Container-Start=0&X-Plex-Container-Size=12",
                                 headers: plexHeaders(c)).json()
        var s = ServiceSnapshot()
        s.items = j["MediaContainer"]["Metadata"].array.enumerated().map { i, m in
            let added = m["addedAt"].double.map { Date(timeIntervalSince1970: $0) }
            return ServiceSnapshot.Item(
                id: m["ratingKey"].string ?? "\(i)",
                title: plexTitle(m),
                subtitle: added.map { "Added " + Fmt.when($0, withTime: false) } ?? "",
                image: plexImage(c, m["parentThumb"].string ?? m["thumb"].string))
        }
        s.headline = "\(s.items.count)"
        s.caption = "recently added"
        s.emptyText = "Nothing new"
        return s
    }

    // MARK: - Jellyfin & Emby

    private static func jellyPrefix(_ c: ServiceClient) -> String { c.integration.kind == .emby ? "/emby" : "" }

    private static func jellyHeaders(_ c: ServiceClient) -> [String: String] {
        var h = ["X-Emby-Token": c.secret]
        if c.integration.kind == .jellyfin { h["Authorization"] = "MediaBrowser Token=\"\(c.secret)\"" }
        return h
    }

    private static func jellyImage(_ c: ServiceClient, _ id: String?) -> URL? {
        guard let id, let base = c.integration.baseURL else { return nil }
        return URL(string: base.absoluteString + jellyPrefix(c) + "/Items/\(Fmt.segment(id))/Images/Primary?maxHeight=360&api_key=" + Fmt.query(c.secret))
    }

    static func jellyNowPlaying(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let j = try await c.send(jellyPrefix(c) + "/Sessions?activeWithinSeconds=960", headers: jellyHeaders(c)).json()
        return parseJellySessions(j) { jellyImage(c, $0) }
    }

    static func parseJellySessions(_ j: JSON, image: (String?) -> URL? = { _ in nil }) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        s.items = j.array.filter { $0["NowPlayingItem"].exists }.enumerated().map { i, session in
            let item = session["NowPlayingItem"]
            let runtime = item["RunTimeTicks"].double ?? 0
            let position = session["PlayState"]["PositionTicks"].double ?? 0
            let paused = session["PlayState"]["IsPaused"].bool ?? false
            let user = session["UserName"].string ?? ""
            let device = session["DeviceName"].string ?? session["Client"].string ?? ""
            return ServiceSnapshot.Item(
                id: session["Id"].string ?? "\(i)",
                title: jellyTitle(item),
                subtitle: [user, device].filter { !$0.isEmpty }.joined(separator: " · ") + (paused ? " · Paused" : ""),
                progress: runtime > 0 ? position / runtime : nil,
                image: image(item["SeriesId"].string ?? item["Id"].string),
                isActive: !paused)
        }
        s.headline = "\(s.items.count)"
        s.caption = s.items.count == 1 ? "stream" : "streams"
        s.emptyText = "Nothing playing"
        return s
    }

    static func jellyTitle(_ item: JSON) -> String {
        let name = item["Name"].string ?? "Untitled"
        if item["Type"].string == "Episode" {
            let series = item["SeriesName"].string ?? ""
            if let season = item["ParentIndexNumber"].int, let episode = item["IndexNumber"].int {
                return "\(series) S\(season)E\(episode) · \(name)"
            }
            return series.isEmpty ? name : "\(series) · \(name)"
        }
        if let year = item["ProductionYear"].int { return "\(name) (\(year))" }
        return name
    }

    static func jellyRecent(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let path = jellyPrefix(c) + "/Items?SortBy=DateCreated&SortOrder=Descending&Recursive=true"
            + "&IncludeItemTypes=Movie,Episode&Limit=12&Fields=DateCreated"
        let j = try await c.send(path, headers: jellyHeaders(c)).json()
        var s = ServiceSnapshot()
        s.items = j["Items"].array.enumerated().map { i, item in
            let added = Fmt.isoDate(item["DateCreated"].string)
            return ServiceSnapshot.Item(
                id: item["Id"].string ?? "\(i)",
                title: jellyTitle(item),
                subtitle: added.map { "Added " + Fmt.when($0, withTime: false) } ?? "",
                image: jellyImage(c, item["SeriesId"].string ?? item["Id"].string))
        }
        s.headline = "\(s.items.count)"
        s.caption = "recently added"
        s.emptyText = "Nothing new"
        return s
    }

    // MARK: - Sonarr & Radarr

    private static func arrHeaders(_ c: ServiceClient) -> [String: String] { ["X-Api-Key": c.secret] }

    private static func poster(_ images: JSON) -> URL? {
        let all = images.array
        let pick = all.first { $0["coverType"].string == "poster" } ?? all.first
        return (pick?["remoteUrl"].string ?? pick?["url"].string).flatMap(URL.init(string:))
    }

    private static func totalRecords(_ c: ServiceClient, _ path: String) async -> Int? {
        guard let j = try? await c.send(path, headers: arrHeaders(c)).json() else { return nil }
        return j["totalRecords"].int
    }

    static func sonarr(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let end = start.addingTimeInterval(14 * 86_400)
        let path = "/api/v3/calendar?start=\(Fmt.query(Fmt.iso(start)))&end=\(Fmt.query(Fmt.iso(end)))&includeSeries=true&unmonitored=false"
        let j = try await c.send(path, headers: arrHeaders(c)).json()
        var s = parseSonarrCalendar(j, now: now)
        if let queue = await totalRecords(c, "/api/v3/queue?pageSize=1") { s.stats.append(.init(label: "Queue", value: "\(queue)")) }
        if let missing = await totalRecords(c, "/api/v3/wanted/missing?pageSize=1") { s.stats.append(.init(label: "Missing", value: "\(missing)")) }
        return s
    }

    static func parseSonarrCalendar(_ j: JSON, now: Date = Date()) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let episodes = j.array.sorted { (Fmt.isoDate($0["airDateUtc"].string) ?? .distantFuture) < (Fmt.isoDate($1["airDateUtc"].string) ?? .distantFuture) }
        s.items = episodes.prefix(12).enumerated().map { i, e in
            let series = e["series"]["title"].string ?? "Unknown series"
            let code = String(format: "S%02dE%02d", e["seasonNumber"].int ?? 0, e["episodeNumber"].int ?? 0)
            let air = Fmt.isoDate(e["airDateUtc"].string)
            let title = e["title"].string.map { " · \($0)" } ?? ""
            return ServiceSnapshot.Item(
                id: e["id"].string ?? "\(i)",
                title: series,
                subtitle: [air.map { Fmt.when($0, now: now) }, code + title].compactMap { $0 }.joined(separator: " · "),
                image: poster(e["series"]["images"]),
                isActive: e["hasFile"].bool ?? false)
        }
        s.headline = "\(episodes.count)"
        s.caption = episodes.count == 1 ? "episode in 2 weeks" : "episodes in 2 weeks"
        s.emptyText = "Nothing airing soon"
        return s
    }

    static func radarr(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let end = start.addingTimeInterval(30 * 86_400)
        let path = "/api/v3/calendar?start=\(Fmt.query(Fmt.iso(start)))&end=\(Fmt.query(Fmt.iso(end)))&unmonitored=false"
        let j = try await c.send(path, headers: arrHeaders(c)).json()
        var s = parseRadarrCalendar(j, from: start, now: now)
        if let queue = await totalRecords(c, "/api/v3/queue?pageSize=1") { s.stats.append(.init(label: "Queue", value: "\(queue)")) }
        if let missing = await totalRecords(c, "/api/v3/wanted/missing?pageSize=1") { s.stats.append(.init(label: "Missing", value: "\(missing)")) }
        return s
    }

    /// A movie's next release in the window: in cinemas, digital or physical.
    static func radarrRelease(_ m: JSON, from start: Date) -> (date: Date, kind: String)? {
        let releases: [(String, String)] = [("inCinemas", "In cinemas"), ("digitalRelease", "Digital"), ("physicalRelease", "Physical")]
        let found: [(date: Date, kind: String)] = releases.compactMap { release in
            guard let d = Fmt.isoDate(m[release.0].string), d >= start else { return nil }
            return (date: d, kind: release.1)
        }
        return found.min { $0.date < $1.date }
    }

    static func parseRadarrCalendar(_ j: JSON, from start: Date, now: Date = Date()) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let movies = j.array.compactMap { m -> (JSON, Date, String)? in
            guard let r = radarrRelease(m, from: start) else { return nil }
            return (m, r.date, r.kind)
        }.sorted { $0.1 < $1.1 }
        s.items = movies.prefix(12).enumerated().map { i, entry in
            let (m, date, kind) = entry
            var title = m["title"].string ?? "Untitled"
            if let year = m["year"].int { title += " (\(year))" }
            return ServiceSnapshot.Item(
                id: m["id"].string ?? "\(i)",
                title: title,
                subtitle: "\(kind) · \(Fmt.when(date, now: now, withTime: false))",
                image: poster(m["images"]),
                isActive: m["hasFile"].bool ?? false)
        }
        s.headline = "\(movies.count)"
        s.caption = movies.count == 1 ? "release this month" : "releases this month"
        s.emptyText = "No releases soon"
        return s
    }

    // MARK: - Overseerr / Jellyseerr

    static func overseerr(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let count = try await c.send("/api/v1/request/count", headers: arrHeaders(c)).json()
        let list = try await c.send("/api/v1/request?take=8&skip=0&sort=added&filter=all", headers: arrHeaders(c)).json()
        var s = parseOverseerrCount(count)
        var items: [ServiceSnapshot.Item] = []
        for (i, r) in list["results"].array.prefix(8).enumerated() {
            let type = r["type"].string ?? r["media"]["mediaType"].string ?? "movie"
            let tmdb = r["media"]["tmdbId"].int ?? 0
            let info = await overseerrTitle(c, type: type, tmdb: tmdb)
            let who = r["requestedBy"]["displayName"].string ?? ""
            items.append(.init(
                id: r["id"].string ?? "\(i)",
                title: info.title,
                subtitle: [overseerrStatus(r), who].filter { !$0.isEmpty }.joined(separator: " · "),
                image: info.poster,
                isActive: r["media"]["status"].int == 5))
        }
        s.items = items
        return s
    }

    static func parseOverseerrCount(_ j: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let pending = j["pending"].int ?? 0
        s.headline = "\(pending)"
        s.caption = pending == 1 ? "pending request" : "pending requests"
        s.stats = [
            .init(label: "Approved", value: "\(j["approved"].int ?? 0)"),
            .init(label: "Processing", value: "\(j["processing"].int ?? 0)"),
            .init(label: "Available", value: "\(j["available"].int ?? 0)"),
            .init(label: "Total", value: "\(j["total"].int ?? 0)"),
        ]
        s.emptyText = "No requests yet"
        return s
    }

    static func overseerrStatus(_ r: JSON) -> String {
        if r["media"]["status"].int == 5 { return "Available" }
        switch r["status"].int {
        case 1: return "Pending"
        case 2: return r["media"]["status"].int == 3 ? "Processing" : "Approved"
        case 3: return "Declined"
        case 4: return "Failed"
        default: return ""
        }
    }

    private static func overseerrTitle(_ c: ServiceClient, type: String, tmdb: Int) async -> (title: String, poster: URL?) {
        let key = "tmdb.\(type).\(tmdb)"
        if let cached = c.value(key) {
            let parts = cached.components(separatedBy: "\n")
            return (parts[0], parts.count > 1 ? URL(string: parts[1]) : nil)
        }
        let path = type == "tv" ? "/api/v1/tv/\(tmdb)" : "/api/v1/movie/\(tmdb)"
        guard tmdb > 0, let j = try? await c.send(path, headers: arrHeaders(c)).json() else {
            return (type == "tv" ? "TV show" : "Movie", nil)
        }
        var title = j["title"].string ?? j["name"].string ?? "Untitled"
        if let year = (j["releaseDate"].string ?? j["firstAirDate"].string)?.prefix(4), year.count == 4 { title += " (\(year))" }
        let poster = j["posterPath"].string.map { "https://image.tmdb.org/t/p/w300" + $0 }
        c.set(key, title + "\n" + (poster ?? ""))
        return (title, poster.flatMap(URL.init(string:)))
    }

    // MARK: - Pi-hole (v6, with a fallback for v5)

    static func pihole(_ c: ServiceClient) async throws -> ServiceSnapshot {
        if c.value("pihole.v5") == nil {
            do {
                let summary = try await piholeV6(c, "/api/stats/summary")
                let blocking = try? await piholeV6(c, "/api/dns/blocking")
                return parsePiholeSummary(summary, blocking: blocking ?? JSON(nil))
            } catch ServiceError.http(let code) where code == 404 {
                c.set("pihole.v5", "1")
            }
        }
        let auth = c.secret.isEmpty ? "" : "&auth=" + Fmt.query(c.secret)
        let j = try await c.send("/admin/api.php?summaryRaw" + auth).json()
        if j.isArray { throw ServiceError.unauthorized }     // v5 answers [] when the token is wrong
        return parsePiholeV5(j)
    }

    private static func piholeV6(_ c: ServiceClient, _ path: String, method: String = "GET", json: Any? = nil) async throws -> JSON {
        for attempt in 0..<2 {
            var headers: [String: String] = [:]
            if let sid = c.value("pihole.sid"), !sid.isEmpty { headers["X-FTL-SID"] = sid }
            let r = try await c.send(path, method: method, headers: headers, json: json)
            if r.status == 401, attempt == 0 {
                try await piholeLogin(c)
                continue
            }
            return try r.json()
        }
        throw ServiceError.unauthorized
    }

    /// Pi-hole limits sign-in sessions, so one is kept per integration and reused.
    private static func piholeLogin(_ c: ServiceClient) async throws {
        let r = try await c.send("/api/auth", method: "POST", json: ["password": c.secret])
        if r.status == 404 { throw ServiceError.http(404) }
        if r.status == 429 { throw ServiceError.unreachable("Pi-hole has too many sessions open. Try again in a few minutes.") }
        let j = try JSON(data: r.data)
        guard j["session"]["valid"].bool == true else { throw ServiceError.unauthorized }
        c.set("pihole.sid", j["session"]["sid"].string ?? "")
    }

    static func parsePiholeSummary(_ j: JSON, blocking: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let total = j["queries"]["total"].double ?? 0
        let blocked = j["queries"]["blocked"].double ?? 0
        let computed: Double = total > 0 ? blocked / total * 100 : 0
        let percent: Double = j["queries"]["percent_blocked"].double ?? computed
        s.headline = String(format: "%.1f%%", percent)
        s.caption = "blocked today"
        s.stats = [
            .init(label: "Queries", value: Fmt.count(total)),
            .init(label: "Blocked", value: Fmt.count(blocked)),
            .init(label: "Clients", value: "\(j["clients"]["active"].int ?? 0)"),
            .init(label: "Blocklist", value: Fmt.count(j["gravity"]["domains_being_blocked"].double ?? 0)),
        ]
        s.gauges = [.init(label: "Blocked", fraction: percent / 100, detail: Fmt.count(blocked))]
        if let state = blocking["blocking"].string { s.isOn = state == "enabled" }
        return s
    }

    static func parsePiholeV5(_ j: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let total = j["dns_queries_today"].double ?? 0
        let blocked = j["ads_blocked_today"].double ?? 0
        let computed: Double = total > 0 ? blocked / total * 100 : 0
        let percent: Double = j["ads_percentage_today"].double ?? computed
        s.headline = String(format: "%.1f%%", percent)
        s.caption = "blocked today"
        s.stats = [
            .init(label: "Queries", value: Fmt.count(total)),
            .init(label: "Blocked", value: Fmt.count(blocked)),
            .init(label: "Clients", value: "\(j["unique_clients"].int ?? 0)"),
            .init(label: "Blocklist", value: Fmt.count(j["domains_being_blocked"].double ?? 0)),
        ]
        s.gauges = [.init(label: "Blocked", fraction: percent / 100, detail: Fmt.count(blocked))]
        if let status = j["status"].string { s.isOn = status == "enabled" }
        return s
    }

    private static func piholeBlocking(_ c: ServiceClient, on: Bool, seconds: Int?) async throws {
        if c.value("pihole.v5") != nil {
            let auth = "&auth=" + Fmt.query(c.secret)
            let query = on ? "enable" : "disable" + (seconds.map { "=\($0)" } ?? "")
            try await c.send("/admin/api.php?" + query + auth).check()
            return
        }
        var body: [String: Any] = ["blocking": on]
        if !on, let seconds { body["timer"] = seconds } else { body["timer"] = NSNull() }
        _ = try await piholeV6(c, "/api/dns/blocking", method: "POST", json: body)
    }

    // MARK: - AdGuard Home

    private static func basicAuth(_ c: ServiceClient) -> [String: String] {
        guard !c.integration.username.isEmpty || !c.secret.isEmpty else { return [:] }
        let token = Data("\(c.integration.username):\(c.secret)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    static func adguard(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let stats = try await c.send("/control/stats", headers: basicAuth(c)).json()
        let status = try? await c.send("/control/status", headers: basicAuth(c)).json()
        return parseAdGuard(stats, status: status ?? JSON(nil))
    }

    static func parseAdGuard(_ j: JSON, status: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let total = j["num_dns_queries"].double ?? 0
        let filtered: Double = j.num("num_blocked_filtering")
        let safeBrowsing: Double = j.num("num_replaced_safebrowsing")
        let parental: Double = j.num("num_replaced_parental")
        let blocked: Double = filtered + safeBrowsing + parental
        let fraction = total > 0 ? blocked / total : 0
        s.headline = Fmt.percent(fraction, digits: 1)
        s.caption = "blocked"
        let ms = (j["avg_processing_time"].double ?? 0) * 1000
        s.stats = [
            .init(label: "Queries", value: Fmt.count(total)),
            .init(label: "Blocked", value: Fmt.count(blocked)),
            .init(label: "Avg time", value: String(format: "%.0f ms", ms)),
        ]
        s.gauges = [.init(label: "Blocked", fraction: fraction, detail: Fmt.count(blocked))]
        s.isOn = status["protection_enabled"].bool
        return s
    }

    private static func adguardProtection(_ c: ServiceClient, on: Bool, seconds: Int?) async throws {
        var body: [String: Any] = ["enabled": on]
        if !on, let seconds { body["duration"] = seconds * 1000 }
        let r = try await c.send("/control/protection", method: "POST", headers: basicAuth(c), json: body)
        if r.status == 404 || r.status == 405 {
            // Older AdGuard Home versions.
            try await c.send("/control/dns_config", method: "POST", headers: basicAuth(c), json: ["protection_enabled": on]).check()
            return
        }
        try r.check()
    }

    // MARK: - Home Assistant

    struct HAEntity: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let state: String
        var domain: String { HomeAssistant.domain(id) }
    }

    private static func haHeaders(_ c: ServiceClient) -> [String: String] { ["Authorization": "Bearer \(c.secret)"] }

    static func haEntities(_ c: ServiceClient) async throws -> [HAEntity] {
        let j = try await c.send("/api/states", headers: haHeaders(c)).json()
        return j.array.compactMap { e -> HAEntity? in
            guard let id = e["entity_id"].string else { return nil }
            return HAEntity(id: id, name: e["attributes"]["friendly_name"].string ?? id, state: e["state"].string ?? "")
        }
        .sorted { a, b in
            let ra = HomeAssistant.rank(a.domain), rb = HomeAssistant.rank(b.domain)
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func haEntity(_ c: ServiceClient, _ id: String) async throws -> ServiceSnapshot {
        let r = try await c.send("/api/states/" + Fmt.segment(id), headers: haHeaders(c))
        if r.status == 404 { throw ServiceError.missing("Home Assistant has no entity \(id).") }
        return HomeAssistant.parse(try r.json())
    }

    private static func haActivate(_ c: ServiceClient, _ id: String) async throws {
        let domain = HomeAssistant.domain(id)
        var state = ""
        if domain == "lock" {
            state = (try? await c.send("/api/states/" + Fmt.segment(id), headers: haHeaders(c)).json())?["state"].string ?? ""
        }
        guard let service = HomeAssistant.service(for: domain, state: state) else {
            throw ServiceError.unexpected("\(id) can't be switched from a tile.")
        }
        try await c.send("/api/services/\(service.domain)/\(service.name)", method: "POST",
                         headers: haHeaders(c), json: ["entity_id": id]).check()
    }

    // MARK: - UniFi Network

    private static func unifiLogin(_ c: ServiceClient) async throws {
        let body: [String: Any] = ["username": c.integration.username, "password": c.secret, "remember": true]
        // UniFi OS consoles (UDM, UCG, Cloud Key Gen2+).
        let os = try await c.send("/api/auth/login", method: "POST", json: body)
        if os.ok {
            c.set("unifi.prefix", "/proxy/network")
            c.set("unifi.csrf", os.headers["x-csrf-token"])
            return
        }
        if os.status == 401 || os.status == 403 { throw ServiceError.unauthorized }
        // The classic Network Application (usually port 8443).
        let classic = try await c.send("/api/login", method: "POST", json: body)
        if classic.ok {
            c.set("unifi.prefix", "")
            return
        }
        if classic.status == 400 || classic.status == 401 || classic.status == 403 { throw ServiceError.unauthorized }
        throw ServiceError.http(classic.status)
    }

    static func unifi(_ c: ServiceClient) async throws -> ServiceSnapshot {
        for attempt in 0..<2 {
            if c.value("unifi.prefix") == nil { try await unifiLogin(c) }
            var headers: [String: String] = [:]
            if let csrf = c.value("unifi.csrf") { headers["X-CSRF-Token"] = csrf }
            let r = try await c.send((c.value("unifi.prefix") ?? "") + "/api/s/default/stat/health", headers: headers)
            if (r.status == 401 || r.status == 403), attempt == 0 {
                c.set("unifi.prefix", nil)
                continue
            }
            return parseUniFiHealth(try r.json())
        }
        throw ServiceError.unauthorized
    }

    static func parseUniFiHealth(_ j: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        var sub: [String: JSON] = [:]
        for item in j["data"].array { if let name = item["subsystem"].string { sub[name] = item } }
        let wlan = sub["wlan"] ?? JSON(nil), lan = sub["lan"] ?? JSON(nil)
        let wan = sub["wan"] ?? JSON(nil), www = sub["www"] ?? JSON(nil)
        let wifi: Int = wlan.whole("num_user") + wlan.whole("num_guest")
        let wired: Int = lan.whole("num_user") + lan.whole("num_guest")
        s.headline = "\(wifi + wired)"
        s.caption = "clients"
        let devices: Int = wlan.whole("num_ap") + lan.whole("num_sw") + wan.whole("num_gw")
        s.stats = [
            .init(label: "Wi-Fi", value: "\(wifi)"),
            .init(label: "Wired", value: "\(wired)"),
            .init(label: "Devices", value: "\(devices)"),
        ]
        if let latency = www["latency"].double { s.stats.append(.init(label: "Latency", value: String(format: "%.0f ms", latency))) }
        if let down = www["xput_down"].double, let up = www["xput_up"].double, down > 0 {
            s.stats.append(.init(label: "Speed", value: "↓\(Fmt.speed(down)) ↑\(Fmt.speed(up))"))
        }
        if let ip = wan["wan_ip"].string { s.stats.append(.init(label: "WAN IP", value: ip)) }
        let gw = wan["gw_system-stats"]
        if let cpu = gw["cpu"].double { s.gauges.append(.init(label: "Gateway CPU", fraction: cpu / 100, detail: Fmt.percent(cpu / 100))) }
        if let mem = gw["mem"].double { s.gauges.append(.init(label: "Gateway memory", fraction: mem / 100, detail: Fmt.percent(mem / 100))) }
        if let status = (www["status"].string ?? wan["status"].string) { s.isOn = status == "ok" }
        return s
    }

    // MARK: - OPNsense

    /// API key and secret, sent as HTTP Basic auth. Newer OPNsense uses snake_case commands
    /// (system_time); older releases used camelCase (systemTime), so both are tried.
    /// Each part is optional, so a key without every privilege still shows what it can see.
    static func opnsense(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let auth = basicAuth(c)
        var firstError: Error?
        func get(_ snake: String, _ camel: String? = nil) async -> JSON {
            do {
                let r = try await c.send("/api/" + snake, headers: auth)
                if r.status == 404, let camel { return try await c.send("/api/" + camel, headers: auth).json() }
                return try r.json()
            } catch {
                if firstError == nil || error as? ServiceError == .unauthorized { firstError = error }
                return JSON(nil)
            }
        }

        var traffic: [ServiceSnapshot.Traffic] = []
        var history: [Double] = []
        let counters = await get("diagnostics/traffic/interface", "diagnostics/traffic/_interface")
        if var now = parseOPNsenseCounters(counters, receivedAt: Date().timeIntervalSince1970) {
            var previous = c.trafficSample()
            // First look (or a long gap): take a second reading a moment later so speeds show right away.
            if previous == nil || now.time - (previous?.time ?? 0) > 120 {
                previous = now
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let again = await get("diagnostics/traffic/interface", "diagnostics/traffic/_interface")
                if let later = parseOPNsenseCounters(again, receivedAt: Date().timeIntervalSince1970) { now = later }
            }
            if let previous { traffic = opnsenseRates(from: previous, to: now) }
            c.setTrafficSample(now)
            if let wan = traffic.first(where: { $0.id == "wan" }) ?? traffic.first { history = c.record(wan.down) }
        }

        let time = await get("diagnostics/system/system_time", "diagnostics/system/systemTime")
        let resources = await get("diagnostics/system/system_resources", "diagnostics/system/systemResources")
        let info = await get("diagnostics/system/system_information", "diagnostics/system/systemInformation")
        let states = await get("diagnostics/firewall/pf_states", "diagnostics/firewall/pfStates")
        let gateways = await get("routes/gateway/status")
        if traffic.isEmpty, !time.exists, !resources.exists, !info.exists, !states.exists, !gateways.exists {
            throw firstError ?? ServiceError.unexpected("OPNsense didn't return any data.")
        }
        return parseOPNsense(time: time, resources: resources, info: info, states: states, gateways: gateways,
                             traffic: traffic, history: history)
    }

    /// Reads interface byte counters from diagnostics/traffic/interface. Field names have varied
    /// between releases, so several spellings are accepted.
    static func parseOPNsenseCounters(_ j: JSON, receivedAt: Double) -> TrafficSample? {
        let list = j["interfaces"].exists ? j["interfaces"].dict : j.dict
        var counters: [String: TrafficSample.Counter] = [:]
        func number(_ e: JSON, _ keys: [String]) -> Double? { keys.lazy.compactMap { e[$0].double }.first }
        for (id, e) in list {
            guard let inBytes = number(e, ["inbytes", "ibytes", "bytes received", "bytes_received", "rx_bytes", "in_bytes"]),
                  let outBytes = number(e, ["outbytes", "obytes", "bytes transmitted", "bytes_transmitted", "tx_bytes", "out_bytes"])
            else { continue }
            let device = e["device"].string ?? ""
            if device.hasPrefix("lo") || id.lowercased() == "lo0" { continue }      // loopback
            let name = e["name"].string ?? e["descr"].string ?? e["description"].string ?? id.uppercased()
            counters[id] = .init(name: name, inBytes: inBytes, outBytes: outBytes)
        }
        guard !counters.isEmpty else { return nil }
        return TrafficSample(time: j["time"].double ?? receivedAt, counters: counters)
    }

    /// Speeds between two readings. WAN first, then the busiest interfaces.
    static func opnsenseRates(from a: TrafficSample, to b: TrafficSample) -> [ServiceSnapshot.Traffic] {
        let seconds = b.time - a.time
        guard seconds > 0.2 else { return [] }
        let rates = b.counters.compactMap { id, now -> ServiceSnapshot.Traffic? in
            guard let before = a.counters[id] else { return nil }
            // Counters reset when an interface restarts; don't show a negative speed.
            let down = max(0, now.inBytes - before.inBytes) / seconds
            let up = max(0, now.outBytes - before.outBytes) / seconds
            return .init(id: id, name: now.name, down: down, up: up)
        }
        return rates.sorted { x, y in
            if (x.id == "wan") != (y.id == "wan") { return x.id == "wan" }
            if x.down + x.up != y.down + y.up { return x.down + x.up > y.down + y.up }
            return x.name < y.name
        }
    }

    static func opnsenseGatewayOnline(_ g: JSON) -> Bool {
        let status = (g["status"].string ?? "").lowercased()
        let translated = (g["status_translated"].string ?? "").lowercased()
        if !translated.isEmpty { return translated == "online" }
        return status == "none" || status == "online"
    }

    static func parseOPNsense(time: JSON, resources: JSON, info: JSON, states: JSON, gateways: JSON,
                              traffic: [ServiceSnapshot.Traffic] = [], history: [Double] = []) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let gws = gateways["items"].array.filter { $0["name"].exists }
        let online = gws.filter(opnsenseGatewayOnline)
        let host = info["name"].string ?? "OPNsense"
        s.traffic = traffic
        if let main = traffic.first {
            // The headline is live WAN download speed; upload goes in the caption.
            s.headline = Fmt.bitrate(main.down)
            s.caption = "↓ \(main.name) · ↑ \(Fmt.bitrate(main.up))"
            let peak = history.max() ?? 0
            if history.count > 1, peak > 0 { s.series = history.map { $0 / peak } }
        } else if gws.isEmpty {
            s.headline = "Online"
            s.caption = host
        } else {
            s.headline = "\(online.count)/\(gws.count)"
            s.caption = gws.count == 1 ? "gateway online" : "gateways online"
        }
        if !gws.isEmpty {
            s.isOn = online.count == gws.count
            if !traffic.isEmpty { s.stats.append(.init(label: "Gateways", value: "\(online.count)/\(gws.count) online")) }
        }
        let memory = resources["memory"]
        if let used = memory["used"].double, let total = memory["total"].double, total > 0 {
            s.gauges.append(.init(label: "Memory", fraction: used / total, detail: "\(Fmt.bytes(used)) of \(Fmt.bytes(total))"))
        }
        if let current = states["current"].double, let limit = states["limit"].double, limit > 0 {
            s.gauges.append(.init(label: "Firewall states", fraction: current / limit, detail: "\(Fmt.count(current)) of \(Fmt.count(limit))"))
        }
        if let uptime = time["uptime"].string { s.stats.append(.init(label: "Uptime", value: uptime)) }
        if let load = time["loadavg"].string { s.stats.append(.init(label: "Load", value: load.replacingOccurrences(of: ",", with: ""))) }
        if let version = info["versions"][0].string { s.stats.append(.init(label: "Version", value: version.replacingOccurrences(of: "OPNsense ", with: ""))) }
        if !gws.isEmpty || !traffic.isEmpty { s.stats.append(.init(label: "Host", value: host)) }
        s.items = gws.map { g in
            let name = g["name"].string ?? "Gateway"
            let parts = [g["status_translated"].string, g["delay"].string, g["loss"].string.flatMap { $0 == "~" ? nil : "\($0) loss" }]
                .compactMap { $0 }.filter { !$0.isEmpty && $0 != "~" }
            return ServiceSnapshot.Item(id: name, title: name, subtitle: parts.joined(separator: " · "), isActive: opnsenseGatewayOnline(g))
        }
        return s
    }

    // MARK: - Proxmox VE

    static func proxmox(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let auth = ["Authorization": "PVEAPIToken=\(c.integration.username)=\(c.secret)"]
        let j = try await c.send("/api2/json/cluster/resources", headers: auth).json()
        return parseProxmox(j)
    }

    static func parseProxmox(_ j: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let all = j["data"].array
        let nodes = all.filter { $0["type"].string == "node" }
        let guests = all.filter { ["qemu", "lxc"].contains($0["type"].string ?? "") }
        var seenStorage = Set<String>()
        let storage = all.filter { r in
            guard r["type"].string == "storage", r["status"].string != "unknown" else { return false }
            // Shared storage is listed once per node; count it once.
            let key = (r["shared"].int == 1) ? (r["storage"].string ?? "") : (r["id"].string ?? "")
            return seenStorage.insert(key).inserted
        }
        let online = nodes.filter { $0["status"].string == "online" }
        func total(_ list: [JSON], _ key: String) -> Double { list.reduce(0.0) { sum, e in sum + e.num(key) } }
        let cores: Double = total(online, "maxcpu")
        let busy: Double = online.reduce(0.0) { sum, e in sum + e.num("cpu") * e.num("maxcpu") }
        let mem: Double = total(online, "mem")
        let maxMem: Double = total(online, "maxmem")
        let disk: Double = total(storage, "disk")
        let maxDisk: Double = total(storage, "maxdisk")
        let running = guests.filter { $0["status"].string == "running" }

        s.headline = "\(running.count)/\(guests.count)"
        s.caption = "guests running"
        if cores > 0 { s.gauges.append(.init(label: "CPU", fraction: busy / cores, detail: Fmt.percent(busy / cores))) }
        if maxMem > 0 { s.gauges.append(.init(label: "Memory", fraction: mem / maxMem, detail: "\(Fmt.bytes(mem)) of \(Fmt.bytes(maxMem))")) }
        if maxDisk > 0 { s.gauges.append(.init(label: "Storage", fraction: disk / maxDisk, detail: "\(Fmt.bytes(disk)) of \(Fmt.bytes(maxDisk))")) }
        s.stats = [.init(label: "Nodes", value: "\(online.count)/\(nodes.count) online")]
        if let up = online.compactMap({ $0["uptime"].double }).max() { s.stats.append(.init(label: "Uptime", value: Fmt.duration(up))) }
        s.items = guests.sorted { a, b in
            let ra = a["status"].string == "running", rb = b["status"].string == "running"
            if ra != rb { return ra }
            return (a["name"].string ?? "") < (b["name"].string ?? "")
        }.prefix(12).map { g -> ServiceSnapshot.Item in
            let isRunning = g["status"].string == "running"
            let cpu = (g["cpu"].double ?? 0)
            return .init(id: g["id"].string ?? UUID().uuidString,
                         title: g["name"].string ?? "VM \(g["vmid"].int ?? 0)",
                         subtitle: isRunning ? "\(g["type"].string == "lxc" ? "CT" : "VM") \(g["vmid"].int ?? 0) · CPU \(Fmt.percent(cpu))" : (g["status"].string ?? "stopped").capitalized,
                         isActive: isRunning)
        }
        s.isOn = !online.isEmpty
        return s
    }

    // MARK: - TrueNAS

    static func truenas(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let auth = ["Authorization": "Bearer \(c.secret)"]
        if c.value("truenas.rpc") == nil {
            let info = try await c.send("/api/v2.0/system/info", headers: auth)
            if info.status != 404 && info.status != 410 {
                let pools = try await c.send("/api/v2.0/pool", headers: auth).json()
                return parseTrueNAS(info: try info.json(), pools: pools)
            }
            c.set("truenas.rpc", "1")      // REST is gone on newer TrueNAS; use JSON-RPC.
        }
        let results = try await truenasRPC(c, calls: [("system.info", []), ("pool.query", [])])
        return parseTrueNAS(info: results[0], pools: results[1])
    }

    /// TrueNAS 25.04+ JSON-RPC 2.0 over a WebSocket at /api/current.
    private static func truenasRPC(_ c: ServiceClient, calls: [(String, [Any])]) async throws -> [JSON] {
        let base = try c.base
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ServiceError.badAddress }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.path += "/api/current"
        guard let url = parts.url else { throw ServiceError.badAddress }
        let socket = c.webSocket(url)
        socket.resume()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            watchdog.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        func call(_ id: Int, _ method: String, _ params: [Any]) async throws -> JSON {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            let text = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8) ?? ""
            do {
                try await socket.send(.string(text))
                while true {
                    let reply = try await socket.receive()
                    let data: Data
                    switch reply {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    let j = try JSON(data: data)
                    guard j["id"].int == id else { continue }      // skip notifications
                    if j["error"].exists {
                        throw ServiceError.unexpected(j["error"]["message"].string ?? "TrueNAS returned an error.")
                    }
                    return j["result"]
                }
            } catch let e as URLError {
                throw ServiceClient.explain(e, selfSignedAllowed: c.integration.allowSelfSigned)
            }
        }

        let login = try await call(1, "auth.login_with_api_key", [c.secret])
        guard login.bool == true else { throw ServiceError.unauthorized }
        var out: [JSON] = []
        for (i, entry) in calls.enumerated() { out.append(try await call(i + 2, entry.0, entry.1)) }
        return out
    }

    static func parseTrueNAS(info: JSON, pools: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let list = pools.array
        let healthy = list.filter { $0["healthy"].bool ?? ($0["status"].string == "ONLINE") }
        s.headline = list.isEmpty ? "—" : (healthy.count == list.count ? "Healthy" : "Degraded")
        s.caption = info["hostname"].string ?? "TrueNAS"
        let cores = info["cores"].double ?? 0
        if cores > 0, let load = info["loadavg"][0].double {
            s.gauges.append(.init(label: "Load", fraction: load / cores, detail: String(format: "%.2f", load)))
        }
        for p in list.prefix(3) {
            let size = p["size"].double ?? 0
            let used = p["allocated"].double ?? 0
            if size > 0 { s.gauges.append(.init(label: p["name"].string ?? "Pool", fraction: used / size, detail: "\(Fmt.bytes(used)) of \(Fmt.bytes(size))")) }
        }
        if let up = info["uptime_seconds"].double { s.stats.append(.init(label: "Uptime", value: Fmt.duration(up))) }
        if let version = info["version"].string { s.stats.append(.init(label: "Version", value: version.replacingOccurrences(of: "TrueNAS-", with: ""))) }
        if let mem = info["physmem"].double { s.stats.append(.init(label: "Memory", value: Fmt.bytes(mem))) }
        s.items = list.map { p in
            .init(id: p["name"].string ?? UUID().uuidString, title: p["name"].string ?? "Pool",
                  subtitle: p["status"].string ?? "", isActive: p["healthy"].bool ?? false)
        }
        s.isOn = list.isEmpty ? nil : healthy.count == list.count
        return s
    }

    // MARK: - Unraid (GraphQL API)

    private static func unraidQuery(_ c: ServiceClient, _ query: String) async throws -> JSON {
        let r = try await c.send("/graphql", method: "POST", headers: ["x-api-key": c.secret], json: ["query": query])
        let j = try r.json()
        if !j["data"].exists, let message = j["errors"][0]["message"].string { throw ServiceError.unexpected(message) }
        return j["data"]
    }

    static func unraid(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let info = try await unraidQuery(c, "{ info { os { hostname uptime } cpu { brand cores threads } } }")
        let array = try? await unraidQuery(c, "{ array { state capacity { kilobytes { free used total } } } }")
        let metrics = try? await unraidQuery(c, "{ metrics { cpu { percentTotal } memory { percentTotal total used } } }")
        let containers = try? await unraidContainerList(c)
        return parseUnraid(info: info, array: array ?? JSON(nil), metrics: metrics ?? JSON(nil), containers: containers ?? JSON(nil))
    }

    private static func unraidContainerList(_ c: ServiceClient) async throws -> JSON {
        if let j = try? await unraidQuery(c, "{ dockerContainers { id names state status image } }"), j["dockerContainers"].isArray {
            return j["dockerContainers"]
        }
        return try await unraidQuery(c, "{ docker { containers { id names state status image } } }")["docker"]["containers"]
    }

    static func parseUnraid(info: JSON, array: JSON, metrics: JSON, containers: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let state = array["array"]["state"].string ?? ""
        s.headline = state.isEmpty ? "Online" : state.capitalized
        s.caption = info["info"]["os"]["hostname"].string ?? "Unraid"
        if let cpu = metrics["metrics"]["cpu"]["percentTotal"].double {
            s.gauges.append(.init(label: "CPU", fraction: cpu / 100, detail: Fmt.percent(cpu / 100)))
        }
        if let mem = metrics["metrics"]["memory"]["percentTotal"].double {
            s.gauges.append(.init(label: "Memory", fraction: mem / 100, detail: Fmt.percent(mem / 100)))
        }
        let kb = array["array"]["capacity"]["kilobytes"]
        if let used = kb["used"].double, let total = kb["total"].double, total > 0 {
            s.gauges.append(.init(label: "Array", fraction: used / total, detail: "\(Fmt.bytes(used * 1024)) of \(Fmt.bytes(total * 1024))"))
        }
        let list = containers.array
        if !list.isEmpty {
            let running = list.filter { ($0["state"].string ?? "").lowercased() == "running" }.count
            s.stats.append(.init(label: "Containers", value: "\(running)/\(list.count) running"))
        }
        if let boot = Fmt.isoDate(info["info"]["os"]["uptime"].string) {
            s.stats.append(.init(label: "Uptime", value: Fmt.duration(Date().timeIntervalSince(boot))))
        }
        if let brand = info["info"]["cpu"]["brand"].string { s.stats.append(.init(label: "CPU", value: brand)) }
        s.isOn = state.isEmpty ? nil : state.uppercased() == "STARTED"
        return s
    }

    static func unraidContainers(_ c: ServiceClient) async throws -> ServiceSnapshot {
        parseContainers(try await unraidContainerList(c), idKey: "id", namesKey: "names", stateKey: "state", statusKey: "status", imageKey: "image")
    }

    // MARK: - Glances

    static func glances(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let headers = basicAuth(c)
        var version = c.value("glances.api") ?? "4"
        var cpu = try await c.send("/api/\(version)/cpu", headers: headers)
        if cpu.status == 404, version == "4" {
            version = "3"
            cpu = try await c.send("/api/3/cpu", headers: headers)
        }
        c.set("glances.api", version)
        let mem = try await c.send("/api/\(version)/mem", headers: headers).json()
        let fs = (try? await c.send("/api/\(version)/fs", headers: headers).json()) ?? JSON(nil)
        let load = (try? await c.send("/api/\(version)/load", headers: headers).json()) ?? JSON(nil)
        let uptime = (try? await c.send("/api/\(version)/uptime", headers: headers).json()) ?? JSON(nil)
        let system = (try? await c.send("/api/\(version)/system", headers: headers).json()) ?? JSON(nil)
        return parseGlances(cpu: try cpu.json(), mem: mem, fs: fs, load: load, uptime: uptime, system: system)
    }

    static func parseGlances(cpu: JSON, mem: JSON, fs: JSON, load: JSON, uptime: JSON, system: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let cpuPercent = cpu["total"].double ?? 0
        s.headline = Fmt.percent(cpuPercent / 100)
        s.caption = system["hostname"].string.map { "CPU · \($0)" } ?? "CPU"
        s.gauges.append(.init(label: "CPU", fraction: cpuPercent / 100, detail: Fmt.percent(cpuPercent / 100)))
        if let percent = mem["percent"].double {
            let detail = mem["used"].double.flatMap { used in mem["total"].double.map { "\(Fmt.bytes(used)) of \(Fmt.bytes($0))" } } ?? Fmt.percent(percent / 100)
            s.gauges.append(.init(label: "Memory", fraction: percent / 100, detail: detail))
        }
        let disks = fs.array.filter { ($0["size"].double ?? 0) > 0 }
        let main = disks.first { $0["mnt_point"].string == "/" } ?? disks.max { ($0["size"].double ?? 0) < ($1["size"].double ?? 0) }
        if let d = main, let percent = d["percent"].double {
            s.gauges.append(.init(label: "Disk \(d["mnt_point"].string ?? "")", fraction: percent / 100,
                                  detail: "\(Fmt.bytes(d["used"].double ?? 0)) of \(Fmt.bytes(d["size"].double ?? 0))"))
        }
        if let min1 = load["min1"].double {
            s.stats.append(.init(label: "Load", value: [min1, load["min5"].double ?? 0, load["min15"].double ?? 0].map { String(format: "%.2f", $0) }.joined(separator: " ")))
        }
        if let up = uptime.string { s.stats.append(.init(label: "Uptime", value: up.components(separatedBy: ".").first ?? up)) }
        s.items = disks.prefix(8).map { d in
            .init(id: d["mnt_point"].string ?? UUID().uuidString, title: d["mnt_point"].string ?? "Disk",
                  subtitle: "\(Fmt.percent((d["percent"].double ?? 0) / 100)) of \(Fmt.bytes(d["size"].double ?? 0))",
                  progress: (d["percent"].double ?? 0) / 100)
        }
        return s
    }

    // MARK: - Beszel (a PocketBase app)

    /// Signs in as a regular user, or a superuser (PocketBase 0.23+), or an admin (older PocketBase).
    private static func beszelLogin(_ c: ServiceClient) async throws -> String {
        let body: [String: Any] = ["identity": c.integration.username, "password": c.secret]
        var lastStatus = 0
        for path in ["/api/collections/users/auth-with-password",
                     "/api/collections/_superusers/auth-with-password",
                     "/api/admins/auth-with-password"] {
            let r = try await c.send(path, method: "POST", json: body)
            if r.ok, let token = (try? JSON(data: r.data))?["token"].string {
                c.set("beszel.token", token)
                return token
            }
            lastStatus = r.status
        }
        if lastStatus == 404 { throw ServiceError.http(404) }
        throw ServiceError.unauthorized
    }

    private static func beszelGet(_ c: ServiceClient, _ path: String) async throws -> JSON {
        for attempt in 0..<2 {
            let token: String
            if let saved = c.value("beszel.token") { token = saved } else { token = try await beszelLogin(c) }
            let r = try await c.send(path, headers: ["Authorization": token])
            if (r.status == 401 || r.status == 403), attempt == 0 {
                c.set("beszel.token", nil)       // expired: sign in again
                continue
            }
            return try r.json()
        }
        throw ServiceError.unauthorized
    }

    static func beszel(_ c: ServiceClient, only system: String?) async throws -> ServiceSnapshot {
        let j = try await beszelGet(c, "/api/collections/systems/records?perPage=200&sort=name")
        return parseBeszel(j, only: system)
    }

    /// The systems, for choosing one in the tile editor.
    static func beszelSystems(_ c: ServiceClient) async throws -> [HAEntity] {
        let j = try await beszelGet(c, "/api/collections/systems/records?perPage=200&sort=name")
        return j["items"].array.compactMap { s -> HAEntity? in
            guard let id = s["id"].string else { return nil }
            return HAEntity(id: id, name: s["name"].string ?? id, state: s["status"].string ?? "")
        }
    }

    /// Beszel keeps each system's latest readings in `info`, with short keys:
    /// cpu, mp (memory %), dp (disk %), dt (top temperature), b (network MB/s), u (uptime s),
    /// g (GPU %), la (load averages), h (hostname), v (agent version).
    static func parseBeszel(_ j: JSON, only system: String?) -> ServiceSnapshot {
        let all = j["items"].array
        if let system, !system.isEmpty {
            guard let one = all.first(where: { $0["id"].string == system }) else {
                var s = ServiceSnapshot()
                s.headline = "—"
                s.caption = "System not found"
                return s
            }
            return beszelSystem(one)
        }
        var s = ServiceSnapshot()
        let up = all.filter { $0["status"].string == "up" }
        let watched = all.filter { $0["status"].string != "paused" }
        s.headline = "\(up.count)/\(watched.count)"
        s.caption = "systems up"
        func average(_ key: String) -> Double? {
            let values = up.compactMap { $0["info"][key].double }
            guard !values.isEmpty else { return nil }
            let sum: Double = values.reduce(0, +)
            return sum / Double(values.count)
        }
        if let cpu = average("cpu") { s.gauges.append(.init(label: "Average CPU", fraction: cpu / 100, detail: Fmt.percent(cpu / 100))) }
        if let mem = average("mp") { s.gauges.append(.init(label: "Average memory", fraction: mem / 100, detail: Fmt.percent(mem / 100))) }
        if let disk = average("dp") { s.gauges.append(.init(label: "Average disk", fraction: disk / 100, detail: Fmt.percent(disk / 100))) }
        if let busiest = up.max(by: { $0["info"].num("cpu") < $1["info"].num("cpu") }), let name = busiest["name"].string {
            s.stats.append(.init(label: "Busiest", value: "\(name) · \(Fmt.percent(busiest["info"].num("cpu") / 100))"))
        }
        let down = watched.count - up.count
        if down > 0 { s.stats.append(.init(label: "Down", value: "\(down)")) }
        s.items = all.map { sys -> ServiceSnapshot.Item in
            let info = sys["info"]
            let status = sys["status"].string ?? ""
            let isUp = status == "up"
            let parts: [String] = isUp
                ? ["CPU \(Fmt.percent(info.num("cpu") / 100))", "Mem \(Fmt.percent(info.num("mp") / 100))", "Disk \(Fmt.percent(info.num("dp") / 100))"]
                : [status.isEmpty ? "Unknown" : status.capitalized]
            return .init(id: sys["id"].string ?? UUID().uuidString, title: sys["name"].string ?? "System",
                         subtitle: parts.joined(separator: " · "), progress: isUp ? info.num("cpu") / 100 : nil, isActive: isUp)
        }
        .sorted { a, b in a.isActive != b.isActive ? !a.isActive : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
        s.isOn = watched.isEmpty ? nil : down == 0
        s.emptyText = "No systems yet"
        return s
    }

    /// One system in full.
    static func beszelSystem(_ sys: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let info = sys["info"]
        let status = sys["status"].string ?? ""
        let name = sys["name"].string ?? "System"
        s.name = name
        s.isOn = status == "paused" ? nil : status == "up"
        guard status == "up" else {
            s.headline = status.isEmpty ? "—" : status.capitalized
            s.caption = name
            return s
        }
        let cpu = info.num("cpu")
        s.headline = Fmt.percent(cpu / 100)
        s.caption = "CPU"
        s.gauges.append(.init(label: "CPU", fraction: cpu / 100, detail: Fmt.percent(cpu / 100)))
        if let mem = info["mp"].double { s.gauges.append(.init(label: "Memory", fraction: mem / 100, detail: Fmt.percent(mem / 100))) }
        if let disk = info["dp"].double { s.gauges.append(.init(label: "Disk", fraction: disk / 100, detail: Fmt.percent(disk / 100))) }
        if let gpu = info["g"].double { s.gauges.append(.init(label: "GPU", fraction: gpu / 100, detail: Fmt.percent(gpu / 100))) }
        if let temp = info["dt"].double { s.stats.append(.init(label: "Temp", value: String(format: "%.0f°C", temp))) }
        if let net = info["b"].double { s.stats.append(.init(label: "Network", value: Fmt.bitrate(net * 1_048_576))) }
        if let up = info["u"].double { s.stats.append(.init(label: "Uptime", value: Fmt.duration(up))) }
        let loads = info["la"].array.compactMap(\.double)
        if !loads.isEmpty { s.stats.append(.init(label: "Load", value: loads.map { String(format: "%.2f", $0) }.joined(separator: " "))) }
        if let host = info["h"].string { s.stats.append(.init(label: "Host", value: host)) }
        if let version = info["v"].string { s.stats.append(.init(label: "Agent", value: version)) }
        return s
    }

    // MARK: - ComfyUI

    static func comfyui(_ c: ServiceClient) async throws -> ServiceSnapshot {
        c.comfy?.ensureRunning(c)
        let stats = try await c.send("/system_stats").json()
        let queue = (try? await c.send("/queue").json()) ?? JSON(nil)
        // History holds whole workflows, so it's read less often than the rest.
        var recent: [ServiceSnapshot.Item] = []
        let lastRead = Double(c.value("comfy.historyAt") ?? "") ?? 0
        let running = queue["queue_running"].array.count
        let marker = "\(running)|\(queue["queue_pending"].array.count)"
        if Date().timeIntervalSince1970 - lastRead > 15 || c.value("comfy.queueMarker") != marker,
           let history = try? await c.send("/history?max_items=8").json() {
            recent = parseComfyHistory(history, base: c.integration.baseURL)
            c.set("comfy.historyAt", String(Date().timeIntervalSince1970))
            c.set("comfy.queueMarker", marker)
            c.set("comfy.recent", encodeItems(recent))
        } else {
            recent = decodeItems(c.value("comfy.recent"))
        }
        return parseComfy(stats: stats, queue: queue, live: c.comfy?.snapshot() ?? ComfyMonitor.Live(), recent: recent)
    }

    /// "cuda:0 NVIDIA GeForce RTX 4090 : cudaMallocAsync" → "NVIDIA GeForce RTX 4090"
    static func comfyDeviceName(_ raw: String?) -> String {
        guard var name = raw, !name.isEmpty else { return "" }
        if let colon = name.range(of: " : ") { name = String(name[..<colon.lowerBound]) }
        if let space = name.firstIndex(of: " "), name[..<space].contains(":") { name = String(name[name.index(after: space)...]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func parseComfy(stats: JSON, queue: JSON, live: ComfyMonitor.Live, recent: [ServiceSnapshot.Item]) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let runningJobs = queue["queue_running"].array
        let pending = queue["queue_pending"].array.count
        let isRunning = !runningJobs.isEmpty || live.promptID != nil
        let fraction: Double? = live.max > 0 ? min(live.value / live.max, 1) : nil
        s.busy = isRunning
        if isRunning {
            s.headline = fraction.map { Fmt.percent($0) } ?? "Running"
            var parts: [String] = []
            if live.max > 0 { parts.append("step \(Int(live.value))/\(Int(live.max))") } else { parts.append("generating") }
            if pending > 0 { parts.append("\(pending) queued") }
            s.caption = parts.joined(separator: " · ")
            s.progress = fraction
        } else {
            s.headline = "Idle"
            s.caption = pending > 0 ? "\(pending) queued" : "queue empty"
        }

        // Resources: Crystools (if installed) for live load; ComfyUI itself for memory.
        if let gpu = live.gpu { s.gauges.append(.init(label: "GPU", fraction: gpu / 100, detail: Fmt.percent(gpu / 100))) }
        let device = stats["devices"][0]
        let vramTotal = device.num("vram_total")
        if vramTotal > 0 {
            let used = vramTotal - device.num("vram_free")
            s.gauges.append(.init(label: "VRAM", fraction: used / vramTotal, detail: "\(Fmt.bytes(used)) of \(Fmt.bytes(vramTotal))"))
        } else if let vram = live.vramPercent {
            s.gauges.append(.init(label: "VRAM", fraction: vram / 100, detail: Fmt.percent(vram / 100)))
        }
        let ramTotal = stats["system"].num("ram_total")
        if ramTotal > 0 {
            let used = ramTotal - stats["system"].num("ram_free")
            s.gauges.append(.init(label: "RAM", fraction: used / ramTotal, detail: "\(Fmt.bytes(used)) of \(Fmt.bytes(ramTotal))"))
        }
        if let cpu = live.cpu { s.gauges.append(.init(label: "CPU", fraction: cpu / 100, detail: Fmt.percent(cpu / 100))) }

        s.stats.append(.init(label: "Queue", value: "\(runningJobs.count) running · \(pending) waiting"))
        if let temp = live.gpuTemperature { s.stats.append(.init(label: "GPU temp", value: String(format: "%.0f°C", temp))) }
        let gpuName = comfyDeviceName(device["name"].string)
        if !gpuName.isEmpty { s.stats.append(.init(label: "Device", value: gpuName)) }
        if let version = stats["system"]["comfyui_version"].string { s.stats.append(.init(label: "Version", value: version)) }

        var items = recent
        if isRunning {
            let id = live.promptID ?? runningJobs.first?[1].string ?? "running"
            items.removeAll { $0.id == id }
            items.insert(.init(id: id, title: "Generating…", subtitle: s.caption, progress: fraction, isActive: true), at: 0)
        }
        s.items = items
        s.emptyText = "No images yet"
        return s
    }

    /// Recent runs, newest first, each with its first output image.
    static func parseComfyHistory(_ j: JSON, base: URL?, now: Date = Date()) -> [ServiceSnapshot.Item] {
        struct Run { let id: String; let item: ServiceSnapshot.Item; let order: Double }
        var runs: [Run] = []
        for (id, run) in j.dict {
            let messages = run["status"]["messages"].array
            func time(_ kind: String) -> Double? {
                messages.first { $0[0].string == kind }?[1]["timestamp"].double
            }
            let started = time("execution_start")
            let ended = time("execution_success") ?? time("execution_error") ?? time("execution_interrupted")
            let failed = run["status"]["status_str"].string == "error" || time("execution_error") != nil
            var image: URL?
            outer: for (_, output) in run["outputs"].dict.sorted(by: { $0.key < $1.key }) {
                for picture in output["images"].array where picture["type"].string != "temp" {
                    if let base, let file = picture["filename"].string {
                        let sub = picture["subfolder"].string ?? ""
                        let type = picture["type"].string ?? "output"
                        image = URL(string: base.absoluteString + "/view?filename=\(Fmt.query(file))&subfolder=\(Fmt.query(sub))&type=\(Fmt.query(type))")
                        break outer
                    }
                }
            }
            var parts: [String] = [failed ? "Failed" : "Done"]
            if let ended { parts.append(Fmt.when(Date(timeIntervalSince1970: ended / 1000), now: now)) }
            if let started, let ended, ended >= started { parts.append(String(format: "%.0fs", (ended - started) / 1000)) }
            let number = run["prompt"][0].double ?? 0
            let item = ServiceSnapshot.Item(id: id, title: failed ? "Failed run" : "Image", subtitle: parts.joined(separator: " · "),
                                            image: image, isActive: !failed)
            runs.append(Run(id: id, item: item, order: ended ?? started ?? number))
        }
        return runs.sorted { $0.order > $1.order }.prefix(8).map(\.item)
    }

    // The latest history is kept between polls as a small encoded list.
    private static func encodeItems(_ items: [ServiceSnapshot.Item]) -> String {
        let rows = items.map { [$0.id, $0.title, $0.subtitle, $0.image?.absoluteString ?? "", $0.isActive ? "1" : "0"] }
        return (try? String(data: JSONSerialization.data(withJSONObject: rows), encoding: .utf8)) ?? "[]"
    }

    private static func decodeItems(_ text: String?) -> [ServiceSnapshot.Item] {
        guard let text, let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String]] else { return [] }
        return rows.compactMap { r -> ServiceSnapshot.Item? in
            guard r.count == 5 else { return nil }
            return ServiceSnapshot.Item(id: r[0], title: r[1], subtitle: r[2], image: r[3].isEmpty ? nil : URL(string: r[3]), isActive: r[4] == "1")
        }
    }

    // MARK: - Docker

    /// Either this Mac's Docker socket, or a Docker API address you entered (tcp/http).
    private static func dockerSend(_ c: ServiceClient, _ method: String, _ path: String) async throws -> ServiceClient.Response {
        if c.integration.url.trimmingCharacters(in: .whitespaces).isEmpty {
            if Edition.isAppStore {
                throw ServiceError.unreachable("Enter Docker's network address in Settings → Integrations (the App Store edition can't use Docker's socket on this Mac).")
            }
            guard let socket = UnixSocketHTTP.findDockerSocket() else {
                throw ServiceError.unreachable("Docker isn't running on this Mac.")
            }
            return try await UnixSocketHTTP.request(socket: socket, method: method, target: path)
        }
        return try await c.send(path, method: method)
    }

    static func docker(_ c: ServiceClient) async throws -> ServiceSnapshot {
        let j = try await dockerSend(c, "GET", "/containers/json?all=1").json()
        return parseContainers(j, idKey: "Id", namesKey: "Names", stateKey: "State", statusKey: "Status", imageKey: "Image")
    }

    private static func dockerAction(_ c: ServiceClient, id: String, verb: String) async throws {
        guard ["start", "stop", "restart"].contains(verb) else { return }
        let r = try await dockerSend(c, "POST", "/containers/\(Fmt.segment(id))/\(verb)")
        if r.status == 304 { return }      // already in that state
        try r.check()
    }

    static func parseContainers(_ j: JSON, idKey: String, namesKey: String, stateKey: String, statusKey: String, imageKey: String) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let list = j.array.map { c -> ServiceSnapshot.Item in
            let names = c[namesKey].array.compactMap(\.string)
            let name = (names.first ?? c[namesKey].string ?? String((c[idKey].string ?? "").prefix(12)))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let state = (c[stateKey].string ?? "").lowercased()
            let status = c[statusKey].string ?? state.capitalized
            return .init(id: c[idKey].string ?? name, title: name, subtitle: status, isActive: state == "running")
        }
        .sorted { a, b in a.isActive != b.isActive ? a.isActive : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
        let running = list.filter(\.isActive).count
        s.headline = "\(running)"
        s.caption = "of \(list.count) running"
        s.items = list
        s.stats = [.init(label: "Running", value: "\(running)"), .init(label: "Stopped", value: "\(list.count - running)")]
        s.emptyText = "No containers"
        return s
    }
}

// MARK: - Home Assistant helpers

enum HomeAssistant {
    static func domain(_ entityID: String) -> String {
        String(entityID.split(separator: ".", maxSplits: 1).first ?? "")
    }

    /// Lights and switches first in the entity picker; diagnostics last.
    static func rank(_ domain: String) -> Int {
        let order = ["light", "switch", "fan", "cover", "lock", "climate", "media_player", "scene", "script",
                     "automation", "input_boolean", "button", "sensor", "binary_sensor", "person", "weather"]
        return order.firstIndex(of: domain) ?? order.count
    }

    /// What clicking the tile does, or nil if it just opens Home Assistant.
    static func service(for domain: String, state: String = "") -> (domain: String, name: String)? {
        switch domain {
        case "light", "switch", "fan", "input_boolean", "cover", "siren", "humidifier":
            return (domain, "toggle")
        case "media_player": return (domain, "media_play_pause")
        case "automation": return (domain, "trigger")
        case "script", "scene": return (domain, "turn_on")
        case "button", "input_button": return (domain, "press")
        case "lock": return (domain, state == "locked" ? "unlock" : "lock")
        default: return nil
        }
    }

    /// Whether the entity runs something (scripts, scenes) rather than switching on and off.
    static func isRunnable(_ domain: String) -> Bool {
        ["automation", "script", "scene", "button", "input_button"].contains(domain)
    }

    static func parse(_ e: JSON) -> ServiceSnapshot {
        var s = ServiceSnapshot()
        let id = e["entity_id"].string ?? ""
        let domain = Self.domain(id)
        let attrs = e["attributes"]
        let state = e["state"].string ?? "unknown"
        s.caption = attrs["friendly_name"].string ?? id
        let unit = attrs["unit_of_measurement"].string

        if domain == "climate", let current = attrs["current_temperature"].double {
            s.headline = String(format: "%.0f°", current)
            if let target = attrs["temperature"].double { s.stats.append(.init(label: "Target", value: String(format: "%.0f°", target))) }
            s.stats.append(.init(label: "Mode", value: state.replacingOccurrences(of: "_", with: " ").capitalized))
        } else if let value = Double(state) {
            let digits = value.rounded() == value ? 0 : (abs(value) < 10 ? 1 : 0)
            s.headline = String(format: "%.\(digits)f", value) + (unit.map { $0 == "%" || $0.hasPrefix("°") ? $0 : " \($0)" } ?? "")
        } else if domain == "sensor" && unit != nil {
            s.headline = state + " " + (unit ?? "")
        } else {
            s.headline = label(state)
        }
        if domain == "light", state == "on", let brightness = attrs["brightness"].double {
            s.gauges.append(.init(label: "Brightness", fraction: brightness / 255, detail: Fmt.percent(brightness / 255)))
        }
        if domain == "media_player", let title = attrs["media_title"].string {
            s.stats.append(.init(label: "Playing", value: [attrs["media_artist"].string, title].compactMap { $0 }.joined(separator: " — ")))
        }
        if let changed = Fmt.isoDate(e["last_changed"].string) {
            s.stats.append(.init(label: "Changed", value: changed.formatted(.relative(presentation: .named))))
        }
        switch state {
        case "on", "open", "opening", "playing", "unlocked", "home", "heat", "cool", "heat_cool", "auto": s.isOn = true
        case "off", "closed", "closing", "paused", "idle", "locked", "not_home", "standby": s.isOn = false
        default: break
        }
        if isRunnable(domain) { s.isOn = nil }
        s.symbol = symbol(domain: domain, deviceClass: attrs["device_class"].string, on: s.isOn ?? false)
        return s
    }

    static func label(_ state: String) -> String {
        switch state {
        case "on": return "On"
        case "off": return "Off"
        case "unavailable": return "Unavailable"
        case "not_home": return "Away"
        case "home": return "Home"
        default:
            if Fmt.isoDate(state) != nil { return "Ready" }     // scenes and buttons report a timestamp
            return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func symbol(domain: String, deviceClass: String?, on: Bool) -> String {
        switch domain {
        case "light": return on ? "lightbulb.fill" : "lightbulb"
        case "switch", "input_boolean": return on ? "power.circle.fill" : "power.circle"
        case "fan": return "fan"
        case "cover": return on ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "lock": return on ? "lock.open" : "lock.fill"
        case "climate": return "thermometer.medium"
        case "media_player": return on ? "play.circle.fill" : "hifispeaker"
        case "automation": return "gearshape.2"
        case "script": return "scroll"
        case "scene": return "sparkles"
        case "button", "input_button": return "hand.tap"
        case "person", "device_tracker": return on ? "house.fill" : "figure.walk"
        case "weather": return "cloud.sun"
        case "camera": return "video"
        case "vacuum": return "fan.floor"
        case "binary_sensor":
            switch deviceClass {
            case "door", "garage_door", "opening": return on ? "door.left.hand.open" : "door.left.hand.closed"
            case "window": return on ? "window.vertical.open" : "window.vertical.closed"
            case "motion", "occupancy", "presence": return on ? "figure.walk.motion" : "figure.stand"
            case "moisture": return "drop"
            case "smoke": return "smoke"
            default: return on ? "circle.fill" : "circle"
            }
        case "sensor":
            switch deviceClass {
            case "temperature": return "thermometer.medium"
            case "humidity": return "humidity"
            case "power", "energy", "current", "voltage": return "bolt"
            case "battery": return "battery.75percent"
            case "illuminance": return "sun.max"
            case "pressure": return "gauge.with.dots.needle.50percent"
            default: return "gauge.with.dots.needle.33percent"
            }
        default: return "house"
        }
    }
}
