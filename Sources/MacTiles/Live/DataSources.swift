import Foundation
import ImageIO
import IOKit.ps

// MARK: - Weather (Open-Meteo: free, no API key, no account)

struct WeatherDay: Identifiable {
    var id: String { date }
    let date: String
    let code: Int
    let hi: Double
    let lo: Double
}

struct WeatherNow {
    let temp: Double
    let feelsLike: Double
    let code: Int
    let isDay: Bool
    let daily: [WeatherDay]
}

struct Place {
    let name: String
    let latitude: Double
    let longitude: Double
    let admin1: String?
    let country: String?
    var label: String { [name, admin1, country].compactMap { $0 }.joined(separator: ", ") }
}

enum WeatherAPI {
    /// Open-Meteo's data is CC BY 4.0: credit it, with a link, wherever it's shown.
    static let attribution = "Weather data by Open-Meteo.com"
    static let attributionURL = URL(string: "https://open-meteo.com/")!

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }

    struct GeoResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
            let country: String?
            let postcodes: [String]?
        }
        let results: [Result]?
    }

    static func fetch(latitude: Double, longitude: Double, fahrenheit: Bool) async throws -> WeatherNow {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let f = try JSONDecoder().decode(Forecast.self, from: data)
        let n = min(f.daily.time.count, f.daily.weather_code.count,
                    f.daily.temperature_2m_max.count, f.daily.temperature_2m_min.count)
        let days = (0..<n).map {
            WeatherDay(date: f.daily.time[$0], code: f.daily.weather_code[$0],
                       hi: f.daily.temperature_2m_max[$0], lo: f.daily.temperature_2m_min[$0])
        }
        return WeatherNow(temp: f.current.temperature_2m, feelsLike: f.current.apparent_temperature,
                          code: f.current.weather_code, isDay: f.current.is_day == 1, daily: days)
    }

    static func geocode(_ query: String) async throws -> Place? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let r = try JSONDecoder().decode(GeoResponse.self, from: data).results?.first else { return nil }
        return Place(name: r.name, latitude: r.latitude, longitude: r.longitude, admin1: r.admin1, country: r.country)
    }

    // MARK: ZIP and postal codes

    /// The country postal codes are looked up in: your Mac's region (Settings → General → Language & Region).
    static var postalCountry: String? { Locale.current.region?.identifier }

    /// "60601", "60601-1234", "SW1A 1AA", "10115" look like postal codes; "Lisbon" doesn't.
    static func looksLikePostalCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard (3...10).contains(t.count), t.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        return t.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
    }

    /// Tidies a typed code: upper-cased, single spaces; a US ZIP+4 becomes its 5-digit ZIP.
    static func normalizePostalCode(_ code: String, country: String?) -> String {
        var t = code.trimmingCharacters(in: .whitespaces).uppercased()
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if country?.uppercased() == "US", let zip = t.range(of: #"^\d{5}"#, options: .regularExpression) {
            t = String(t[zip])
        }
        return t
    }

    /// Looks up a ZIP or postal code (in `country`, if given) and returns its place.
    static func lookupPostalCode(_ code: String, country: String? = postalCountry) async throws -> Place? {
        let cleaned = normalizePostalCode(code, country: country)
        guard !cleaned.isEmpty else { return nil }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        var items = [
            URLQueryItem(name: "name", value: cleaned),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        if let country, country.count == 2 { items.append(URLQueryItem(name: "countryCode", value: country.uppercased())) }
        c.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try placeForPostalCode(cleaned, in: data)
    }

    /// The result that lists this postal code; otherwise the first result.
    static func placeForPostalCode(_ code: String, in data: Data) throws -> Place? {
        let results = try JSONDecoder().decode(GeoResponse.self, from: data).results ?? []
        let squash = { (s: String) in s.uppercased().replacingOccurrences(of: " ", with: "") }
        let wanted = squash(code)
        let match = results.first { ($0.postcodes ?? []).contains { squash($0) == wanted } } ?? results.first
        guard let r = match else { return nil }
        return Place(name: r.name, latitude: r.latitude, longitude: r.longitude, admin1: r.admin1, country: r.country)
    }

    /// WMO weather code → SF Symbol.
    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...55: return "Drizzle"
        case 56, 57, 66, 67: return "Freezing rain"
        case 61...65: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorms"
        default: return "—"
        }
    }

    static func weekday(_ isoDate: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: isoDate) else { return "" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: - News (any RSS 2.0 or Atom feed)

struct Headline: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let link: URL?
}

struct FeedResult {
    let title: String
    let items: [Headline]
    /// The feed's own address: differs from what was typed when a web page pointed to its feed.
    let feedURL: String
}

enum FeedParser {
    /// Reads a feed. Given a web page instead (bbc.com, theverge.com), follows the page's
    /// own link to its feed.
    static func fetch(_ urlString: String) async throws -> FeedResult {
        guard let url = URL(string: urlString), WebLink.isFetchable(url) else { throw URLError(.badURL) }
        let data = try await download(url)
        let parsed = parse(data)
        if !parsed.items.isEmpty {
            return FeedResult(title: parsed.title, items: parsed.items, feedURL: urlString)
        }
        let html = String(decoding: data.prefix(768_000), as: UTF8.self)
        for feed in discoverFeeds(in: html, base: url).prefix(2) {
            guard let data = try? await download(feed) else { continue }
            let found = parse(data)
            if !found.items.isEmpty {
                return FeedResult(title: found.title, items: found.items, feedURL: feed.absoluteString)
            }
        }
        throw URLError(.cannotParseResponse)
    }

    private static func download(_ url: URL) async throws -> Data {
        guard WebLink.isFetchable(url) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard data.count <= 5_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    /// RSS 2.0 or Atom → the feed's title and up to 15 headlines.
    static func parse(_ data: Data) -> (title: String, items: [Headline]) {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.channelTitle, Array(delegate.items.prefix(15)))
    }

    /// Feeds a web page advertises: <link rel="alternate" type="application/rss+xml" href="…">.
    static func discoverFeeds(in html: String, base: URL) -> [URL] {
        guard let tagRegex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var found: [URL] = []
        for match in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = WebPage.attributes(of: ns.substring(with: match.range))
            guard let rel = attrs["rel"]?.lowercased(), rel.split(separator: " ").contains("alternate"),
                  let type = attrs["type"]?.lowercased(), type.contains("rss") || type.contains("atom"),
                  let href = attrs["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  WebLink.isFetchable(url), !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }
}

/// Feeds offered in the News tile panel's "Popular feeds" menu.
enum NewsFeeds {
    static let defaultFeed = "https://feeds.bbci.co.uk/news/world/rss.xml"

    static let popular: [(name: String, url: String)] = [
        ("BBC News – World", defaultFeed),
        ("BBC News – Technology", "https://feeds.bbci.co.uk/news/technology/rss.xml"),
        ("NPR News", "https://feeds.npr.org/1001/rss.xml"),
        ("The New York Times", "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
        ("The Verge", "https://www.theverge.com/rss/index.xml"),
        ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/index"),
        ("Hacker News", "https://hnrss.org/frontpage"),
    ]
}

final class FeedDelegate: NSObject, XMLParserDelegate {
    /// Clicking the News tile opens the headline, so only web links are kept: a feed can't
    /// make MacTiles open a local file or launch an app through a custom URL scheme.
    static func safeLink(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              WebLink.isFetchable(url), url.host != nil else { return nil }
        return url
    }

    var items: [Headline] = []
    var channelTitle = ""
    private var inItem = false
    private var text = ""
    private var title = ""
    private var link = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "item" || elementName == "entry" {
            inItem = true; title = ""; link = ""
        }
        if elementName == "link", inItem, let href = attributeDict["href"], link.isEmpty {
            link = href   // Atom
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if inItem { title = t } else if channelTitle.isEmpty { channelTitle = t }
        case "link":
            if inItem && link.isEmpty && !t.isEmpty { link = t }
        case "item", "entry":
            inItem = false
            if !title.isEmpty { items.append(Headline(title: title, link: Self.safeLink(link))) }
        default:
            break
        }
        text = ""
    }
}

// MARK: - CPU & memory (Mach host statistics)

enum SystemStats {
    private static let host = mach_host_self()

    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Roughly Activity Monitor's "Memory Used": app memory + wired + compressed.
    static func memoryUsed() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let pages = appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)
        return pages * Double(pageSize)
    }
}

// MARK: - Battery (IOKit power sources)

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
}

enum PowerInfo {
    static func read() -> BatteryState? {
        guard let infoRef = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(info) else { return nil }
        let list = listRef.takeRetainedValue() as NSArray
        for source in list {
            guard let descRef = IOPSGetPowerSourceDescription(info, source as AnyObject) else { continue }
            let desc = descRef.takeUnretainedValue() as NSDictionary
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(desc[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let minutes = desc[kIOPSTimeToEmptyKey] as? Int
            return BatteryState(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }
}

// MARK: - Images

enum ImageLoader {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif"]

    static func listImages(in folder: String, limit: Int = 400) -> [URL] {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where extensions.contains(url.pathExtension.lowercased()) {
            out.append(url)
            if out.count >= limit { break }
        }
        return out
    }

    /// Decodes a downsampled thumbnail, so a 48 MP photo costs about a megabyte, not 190.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
