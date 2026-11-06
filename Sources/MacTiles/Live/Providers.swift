import AppKit
import EventKit
import SwiftUI

/// Owns every live-tile data provider. Polling only runs while Start is on screen,
/// so MacTiles idles at ~0% CPU when hidden.
@MainActor
final class LiveHub: ObservableObject {
    let store: LayoutStore
    let weather: WeatherProvider
    let news: NewsProvider
    let system: SystemProvider
    let battery: BatteryProvider
    let calendar: CalendarProvider
    let photos: PhotosProvider
    let desktop: DesktopProvider

    init(store: LayoutStore) {
        self.store = store
        weather = WeatherProvider()
        news = NewsProvider()
        system = SystemProvider()
        battery = BatteryProvider()
        calendar = CalendarProvider()
        photos = PhotosProvider()
        desktop = DesktopProvider()
    }

    /// Network-backed tiles: refresh when stale (weather every 15 min, news every 30).
    func refreshStale() {
        if store.has(.weather) { weather.refresh(settings: store.settings) }
        if store.has(.news) { news.refresh(feed: store.settings.newsFeed) }
    }

    private var heartbeat: Task<Void, Never>?

    func setActive(_ active: Bool) {
        if active {
            refreshStale()
            if store.has(.system) { system.start() }
            if store.has(.battery) { battery.start() }
            if store.has(.photos) { photos.start(folder: store.settings.photosFolder) }
            if store.has(.news) { news.startRotating() }
            refreshLocal()
            // With "Keep Start on the desktop", Start can stay on screen for hours; keep the
            // weather, news, calendar and Desktop tiles current while it does.
            if heartbeat == nil {
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.refreshStale()
                        self.refreshLocal()
                    }
                }
            }
        } else {
            heartbeat?.cancel()
            heartbeat = nil
            system.stop()
            battery.stop()
            photos.stop()
            news.stopRotating()
        }
    }

    /// Calendar events and the desktop picture: cheap, local, so they're simply re-read.
    private func refreshLocal() {
        if store.has(.calendar), store.settings.calendarEvents { calendar.refresh() }
        if store.has(.desktop) { desktop.refresh() }
    }

    /// Settings → News feed or Photos folder changed: use the new one now, not the next time Start opens.
    func liveSettingsChanged(active: Bool) {
        if store.has(.news) { news.refresh(feed: store.settings.newsFeed) }
        if active, store.has(.photos) { photos.start(folder: store.settings.photosFolder) }
    }
}

// MARK: - Weather

@MainActor
final class WeatherProvider: ObservableObject {
    @Published private(set) var now: WeatherNow?
    @Published private(set) var status = "Choose a city in Settings"
    private var fetchedAt = Date.distantPast
    private var key = ""
    private var loading = false

    func refresh(settings s: AppSettings, force: Bool = false) {
        guard let lat = s.weatherLat, let lon = s.weatherLon else {
            now = nil
            status = "Choose a city in Settings"
            return
        }
        let newKey = "\(lat),\(lon),\(s.fahrenheit)"
        if !force, newKey == key, Date().timeIntervalSince(fetchedAt) < 15 * 60 { return }
        guard !loading else { return }
        loading = true
        if newKey != key { status = "Loading…" }
        Task {
            defer { self.loading = false }
            do {
                let w = try await WeatherAPI.fetch(latitude: lat, longitude: lon, fahrenheit: s.fahrenheit)
                self.now = w
                self.key = newKey
                self.fetchedAt = Date()
            } catch {
                if self.key != newKey { self.now = nil }
                self.status = "Weather unavailable"
            }
        }
    }
}

// MARK: - News

@MainActor
final class NewsProvider: ObservableObject {
    @Published private(set) var items: [Headline] = []
    @Published private(set) var index = 0
    @Published private(set) var source = ""
    private var fetchedAt = Date.distantPast
    private var feed = ""
    private var loading = false
    private var failedAt: [String: Date] = [:]
    private var rotation: Task<Void, Never>?

    var current: Headline? { items.isEmpty ? nil : items[index % items.count] }

    func refresh(feed newFeed: String) {
        let url = newFeed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { items = []; source = ""; return }
        if url == feed, Date().timeIntervalSince(fetchedAt) < 30 * 60 { return }
        // A feed that just failed isn't retried every minute.
        if let failed = failedAt[url], Date().timeIntervalSince(failed) < 5 * 60 { return }
        guard !loading else { return }
        loading = true
        Task {
            defer { self.loading = false }
            guard let result = try? await FeedParser.fetch(url) else {
                self.failedAt[url] = Date()
                return
            }
            self.failedAt[url] = nil
            self.items = result.items
            self.source = result.title
            self.index = 0
            self.feed = url
            self.fetchedAt = Date()
        }
    }

    func startRotating() {
        guard rotation == nil else { return }
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.items.count > 1 {
                    withAnimation(.easeInOut(duration: 0.6)) { self.index = (self.index + 1) % self.items.count }
                }
            }
        }
    }

    func stopRotating() {
        rotation?.cancel()
        rotation = nil
    }
}

// MARK: - System

@MainActor
final class SystemProvider: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var history: [Double] = []
    @Published private(set) var memUsed: Double = 0
    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    private var previous: (busy: UInt64, total: UInt64)?
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        sample()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sample()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        previous = nil
    }

    private func sample() {
        if let ticks = SystemStats.cpuTicks() {
            if let p = previous, ticks.total > p.total {
                cpu = Double(ticks.busy - p.busy) / Double(ticks.total - p.total)
                history.append(cpu)
                if history.count > 30 { history.removeFirst(history.count - 30) }
            }
            previous = ticks
        }
        if let used = SystemStats.memoryUsed() { memUsed = used }
    }
}

// MARK: - Battery

@MainActor
final class BatteryProvider: ObservableObject {
    @Published private(set) var state: BatteryState?
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        state = PowerInfo.read()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.state = PowerInfo.read()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}

// MARK: - Calendar (opt-in; asks for permission only when enabled in Settings)

struct EventSummary: Identifiable {
    let id = UUID()
    let title: String
    let start: Date

    var whenText: String {
        let time = start.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(start) { return time }
        if cal.isDateInTomorrow(start) { return "Tomorrow, \(time)" }
        return start.formatted(.dateTime.weekday(.wide)) + ", " + time
    }
}

@MainActor
final class CalendarProvider: ObservableObject {
    @Published private(set) var events: [EventSummary] = []
    private let eventStore = EKEventStore()

    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { events = []; return }
        let now = Date()
        let predicate = eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(3 * 86_400), calendars: nil)
        events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(4)
            .map { EventSummary(title: $0.title ?? "Event", start: $0.startDate) }
    }

    func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { refresh(); return }
        Task {
            let granted = (try? await self.eventStore.requestFullAccessToEvents()) ?? false
            if granted { self.refresh() }
        }
    }
}

// MARK: - Photos (slideshow from a folder; defaults to ~/Pictures)

@MainActor
final class PhotosProvider: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isEmpty = false
    private var urls: [URL] = []
    private var folder = ""
    private var loop: Task<Void, Never>?

    func start(folder newFolder: String) {
        if newFolder != folder {
            stop()
            folder = newFolder
            urls = []
        }
        guard loop == nil else { return }
        let folder = self.folder
        loop = Task { [weak self] in
            if self?.urls.isEmpty ?? false {
                let found = await Task.detached(priority: .utility) { ImageLoader.listImages(in: folder) }.value
                self?.urls = found
                self?.isEmpty = found.isEmpty
            }
            while !Task.isCancelled {
                await self?.advance()
                try? await Task.sleep(nanoseconds: 9_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func advance() async {
        guard let url = urls.randomElement() else { return }
        let box = await Task.detached(priority: .utility) { Box(ImageLoader.thumbnail(url, maxPixel: 1000)) }.value
        guard let cg = box.value, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { image = NSImage(cgImage: cg, size: .zero) }
    }
}

// MARK: - Desktop (shows the current wallpaper, like the Windows 8 Desktop tile)

@MainActor
final class DesktopProvider: ObservableObject {
    @Published private(set) var image: NSImage?
    private var fingerprint = ""

    func refresh() {
        let now = DesktopPicture.fingerprint()
        guard now != fingerprint || image == nil else { return }
        fingerprint = now
        Task {
            let result = await DesktopPicture.currentThumbnail(maxPixel: 900)
            if let picture = result.image { self.image = picture }
        }
    }
}
