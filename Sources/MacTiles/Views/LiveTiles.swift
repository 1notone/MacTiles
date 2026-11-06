import AppKit
import SwiftUI

// MARK: - Flip ("peek") animation

/// Cycles a live tile between faces, sliding the new face up from the bottom like Windows 8.
/// Pauses entirely while Start is hidden.
@MainActor
struct FlipFaces<Face: View>: View {
    let count: Int
    let interval: Double
    let phase: Double
    @ViewBuilder let face: (Int) -> Face

    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !launcher.tilesLive || count < 2)) { ctx in
            let index = count < 2 ? 0 : Int((ctx.date.timeIntervalSinceReferenceDate + phase) / interval) % count
            ZStack {
                face(index)
                    .id(index)
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.6), value: index)
        }
    }
}

// MARK: - Clock

@MainActor
struct ClockTile: View {
    let size: TileSize
    let phase: Double
    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !launcher.tilesLive)) { ctx in
            let now = ctx.date
            if size == .small {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 17, weight: .light))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FlipFaces(count: 2, interval: 9, phase: phase) { i in
                    if i == 0 {
                        digital(now)
                    } else {
                        AnalogClock(date: now).padding(EdgeInsets(top: 12, leading: 12, bottom: 26, trailing: 12))
                    }
                }
                .overlay(TileLabel(text: "Clock"))
            }
        }
    }

    private func digital(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: size == .medium ? 36 : 56, weight: .ultraLight))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 13))
                .opacity(0.9)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct AnalogClock: View {
    let date: Date

    var body: some View {
        Canvas { ctx, size in
            let radius = min(size.width, size.height) / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            for i in 0..<12 {
                let angle = Double(i) / 12 * 2 * Double.pi
                var tick = Path()
                tick.move(to: AnalogClock.point(center, radius * (i % 3 == 0 ? 0.80 : 0.88), angle))
                tick.addLine(to: AnalogClock.point(center, radius * 0.96, angle))
                ctx.stroke(tick, with: .color(.white.opacity(0.85)), lineWidth: i % 3 == 0 ? 2 : 1)
            }
            let t = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let secs = Double(t.second ?? 0)
            let mins = Double(t.minute ?? 0) + secs / 60
            let hrs = Double((t.hour ?? 0) % 12) + mins / 60
            let hands: [(fraction: Double, length: CGFloat, width: CGFloat, alpha: Double)] = [
                (hrs / 12, 0.5, 3, 1), (mins / 60, 0.74, 2, 1), (secs / 60, 0.84, 1, 0.7),
            ]
            for hand in hands {
                var p = Path()
                p.move(to: center)
                p.addLine(to: AnalogClock.point(center, radius * hand.length, hand.fraction * 2 * Double.pi))
                ctx.stroke(p, with: .color(.white.opacity(hand.alpha)),
                           style: StrokeStyle(lineWidth: hand.width, lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    static func point(_ c: CGPoint, _ length: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + length * CGFloat(sin(angle)), y: c.y - length * CGFloat(cos(angle)))
    }
}

// MARK: - Calendar

@MainActor
struct CalendarTile: View {
    let size: TileSize
    let phase: Double
    @EnvironmentObject private var calendar: CalendarProvider
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 30, paused: !launcher.tilesLive)) { ctx in
            let now = ctx.date
            if size == .small {
                VStack(spacing: -2) {
                    Text(now, format: .dateTime.day()).font(.system(size: 26, weight: .light))
                    Text(now, format: .dateTime.weekday(.abbreviated)).font(.system(size: 10))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let events = store.settings.calendarEvents ? calendar.events : []
                FlipFaces(count: events.isEmpty ? 1 : 2, interval: 8, phase: phase) { i in
                    if i == 0 { dateFace(now) } else { eventsFace(events) }
                }
                .overlay(TileLabel(text: "Calendar"))
            }
        }
    }

    private func dateFace(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: -4) {
            Spacer(minLength: 0)
            Text(now, format: .dateTime.day()).font(.system(size: size == .medium ? 54 : 66, weight: .ultraLight))
            Text(now, format: .dateTime.weekday(.wide)).font(.system(size: 14))
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func eventsFace(_ events: [EventSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(events.prefix(size == .large ? 4 : 1)) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(size == .medium ? 3 : 2)
                    Text(event.whenText).font(.system(size: 11)).opacity(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Weather

@MainActor
struct WeatherTile: View {
    let size: TileSize
    let phase: Double
    @EnvironmentObject private var weather: WeatherProvider
    @EnvironmentObject private var store: LayoutStore

    private var city: String { store.settings.weatherCity ?? "Weather" }

    var body: some View {
        if let w = weather.now {
            switch size {
            case .small:
                VStack(spacing: 2) {
                    Image(systemName: WeatherAPI.symbol(for: w.code, isDay: w.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 20))
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 14, weight: .light))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .large:
                VStack(spacing: 0) {
                    current(w).frame(maxHeight: .infinity)
                    Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1).padding(.horizontal, 14)
                    forecast(w, days: 3).frame(maxHeight: .infinity)
                }
                .overlay(TileLabel(text: city))
            default:
                FlipFaces(count: 2, interval: 7, phase: phase) { i in
                    if i == 0 { current(w) } else { forecast(w, days: size == .wide ? 3 : 1) }
                }
                .overlay(TileLabel(text: city))
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder private func current(_ w: WeatherNow) -> some View {
        let symbol = WeatherAPI.symbol(for: w.code, isDay: w.isDay)
        let hiLo = w.daily.first.map { "\(Int($0.hi.rounded()))° / \(Int($0.lo.rounded()))°" } ?? ""
        if size == .medium {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
                Spacer(minLength: 0)
                Text("\(Int(w.temp.rounded()))°").font(.system(size: 38, weight: .ultraLight))
                Text(WeatherAPI.describe(w.code)).font(.system(size: 11)).opacity(0.9).lineLimit(1)
            }
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 24, trailing: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 50, weight: .ultraLight))
                    Text(WeatherAPI.describe(w.code)).font(.system(size: 13))
                    Text(hiLo).font(.system(size: 12)).opacity(0.85)
                }
                Spacer()
                Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: 44))
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 24, trailing: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func forecast(_ w: WeatherNow, days: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(w.daily.dropFirst().prefix(days))) { day in
                VStack(spacing: 5) {
                    Text(WeatherAPI.weekday(day.date)).font(.system(size: 12, weight: .semibold))
                    Image(systemName: WeatherAPI.symbol(for: day.code, isDay: true))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 22))
                    Text("\(Int(day.hi.rounded()))° \(Int(day.lo.rounded()))°").font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 26))
            if size != .small {
                Text(weather.status).font(.system(size: 11)).opacity(0.9).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(size == .small ? nil : TileLabel(text: "Weather"))
    }
}

// MARK: - System

@MainActor
struct SystemTile: View {
    let size: TileSize
    let phase: Double
    @EnvironmentObject private var sys: SystemProvider

    private var cpuPercent: String { "\(Int((sys.cpu * 100).rounded()))%" }

    var body: some View {
        if size == .small {
            VStack(spacing: 0) {
                Text("CPU").font(.system(size: 10, weight: .semibold)).opacity(0.85)
                Text(cpuPercent).font(.system(size: 18, weight: .light)).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FlipFaces(count: 2, interval: 6, phase: phase) { i in
                if i == 0 { cpu } else { memory }
            }
            .overlay(TileLabel(text: "System"))
        }
    }

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU").font(.system(size: 12, weight: .semibold)).opacity(0.85)
            Text(cpuPercent).font(.system(size: size == .medium ? 34 : 46, weight: .ultraLight)).monospacedDigit()
            Sparkline(values: sys.history).frame(maxHeight: size == .large ? 120 : 30)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var memory: some View {
        let gib = 1_073_741_824.0
        let used = sys.memUsed / gib
        let total = sys.memTotal / gib
        return VStack(alignment: .leading, spacing: 6) {
            Text("Memory").font(.system(size: 12, weight: .semibold)).opacity(0.85)
            Text(String(format: "%.1f GB", used)).font(.system(size: size == .medium ? 28 : 40, weight: .ultraLight))
            Text(String(format: "of %.0f GB", total)).font(.system(size: 11)).opacity(0.85)
            ProgressView(value: min(1, used / max(total, 0.1)))
                .progressViewStyle(.linear)
                .tint(.white)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            let slots = 30
            let w = size.width / CGFloat(slots)
            for (i, v) in values.suffix(slots).enumerated() {
                let h = max(1, CGFloat(min(max(v, 0), 1)) * size.height)
                let rect = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(1, w - 1.5), height: h)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.75)))
            }
        }
    }
}

// MARK: - Battery

@MainActor
struct BatteryTile: View {
    let size: TileSize
    @EnvironmentObject private var battery: BatteryProvider

    var body: some View {
        VStack(spacing: 4) {
            if let s = battery.state {
                Image(systemName: symbol(s)).font(.system(size: size == .small ? 20 : 30))
                Text("\(s.percent)%").font(.system(size: size == .small ? 13 : 26, weight: .light))
                if size != .small { Text(detail(s)).font(.system(size: 11)).opacity(0.85) }
            } else {
                Image(systemName: "powerplug.fill").font(.system(size: size == .small ? 20 : 30))
                if size != .small { Text("On power").font(.system(size: 12)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(_ s: BatteryState) -> String {
        if s.charging { return "battery.100percent.bolt" }
        switch s.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func detail(_ s: BatteryState) -> String {
        if s.charging { return "Charging" }
        if s.onAC { return "On power" }
        if let m = s.minutesLeft { return "\(m / 60)h \(m % 60)m left" }
        return "On battery"
    }
}

// MARK: - Photos

@MainActor
struct PhotosTile: View {
    let size: TileSize
    let frame: CGSize
    @EnvironmentObject private var photos: PhotosProvider

    var body: some View {
        ZStack {
            if let image = photos.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30))
                    if size != .small && photos.isEmpty {
                        Text("Add pictures to your Pictures folder")
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .opacity(0.85)
                    }
                }
                .padding(10)
            }
            if size != .small { TileLabel(text: "Photos") }
        }
        .frame(width: frame.width, height: frame.height)
    }
}

// MARK: - News

@MainActor
struct NewsTile: View {
    let size: TileSize
    @EnvironmentObject private var news: NewsProvider

    private var fontSize: CGFloat {
        switch size {
        case .large: return 20
        case .wide: return 16
        default: return 13
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let headline = news.current {
                Text(headline.title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .lineLimit(size == .large ? 7 : 4)
                    .multilineTextAlignment(.leading)
                    .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(headline.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top)))
            } else {
                Image(systemName: "newspaper")
                    .font(.system(size: 26))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            TileLabel(text: news.source.isEmpty ? "News" : news.source)
        }
        .clipped()
    }
}

// MARK: - Desktop

@MainActor
struct DesktopTile: View {
    let size: TileSize
    let frame: CGSize
    @EnvironmentObject private var desktop: DesktopProvider

    var body: some View {
        ZStack {
            if let image = desktop.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
            } else {
                LinearGradient(colors: [Color(hex: "#0F4C81"), Color(hex: "#3A7BD5")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            TileLabel(text: "Desktop")
        }
        .frame(width: frame.width, height: frame.height)
    }
}
