import AppKit
import SwiftUI

enum AppEntry: Identifiable {
    case header(String)
    case app(AppInfo)

    var id: String {
        switch self {
        case .header(let letter): return "header-" + letter
        case .app(let app): return app.path
        }
    }
}

/// The Windows 8.1 "Apps" view: every installed app, alphabetically, grouped by letter.
@MainActor
struct AppsView: View {
    let metrics: Metrics
    @EnvironmentObject private var catalog: AppCatalog

    var body: some View {
        if catalog.apps.isEmpty {
            Text("Finding apps…")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.leading, metrics.leftMargin)
        } else {
            AppGrid(entries: Self.entries(for: catalog.apps), metrics: metrics)
        }
    }

    static func entries(for apps: [AppInfo]) -> [AppEntry] {
        var out: [AppEntry] = []
        var current = ""
        for app in apps {
            let letter = letter(for: app.name)
            if letter != current {
                out.append(.header(letter))
                current = letter
            }
            out.append(.app(app))
        }
        return out
    }

    static func letter(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard let first = folded.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

@MainActor
struct SearchResultsView: View {
    let metrics: Metrics
    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        let results = launcher.results
        VStack(alignment: .leading, spacing: 18) {
            // What you've typed, big, with a caret — there is no search box.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(launcher.query)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Caret()
                }
                Text(results.isEmpty ? "No apps match"
                                     : results.count == 1 ? "1 app · Return to open" : "\(results.count) apps · Return opens the first")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.leading, metrics.leftMargin)
            if !results.isEmpty {
                AppGrid(entries: results.prefix(60).map { .app($0) }, metrics: metrics, highlightFirst: true)
            }
        }
    }
}

/// A blinking text cursor, so it's clear typing goes somewhere.
struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: 40)
                .opacity(on ? 0.9 : 0)
                .offset(y: 6)
        }
    }
}

@MainActor
struct AppGrid: View {
    let entries: [AppEntry]
    let metrics: Metrics
    var highlightFirst = false

    var body: some View {
        GeometryReader { geo in
            let rowHeight: CGFloat = 46
            let rows = max(3, Int((geo.size.height - 16) / (rowHeight + 6)))
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(rowHeight), spacing: 6, alignment: .leading), count: rows),
                          alignment: .top, spacing: 28) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        switch entry {
                        case .header(let letter):
                            Text(letter)
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 240, alignment: .bottomLeading)
                        case .app(let app):
                            AppRow(app: app, highlighted: highlightFirst && index == 0)
                        }
                    }
                }
                .padding(.leading, metrics.leftMargin)
                .padding(.trailing, 80)
            }
            .scrollIndicators(.hidden)
            .contextMenu { BackgroundMenu() }   // empty space around the apps
        }
    }
}

@MainActor
struct AppRow: View {
    let app: AppInfo
    var highlighted = false

    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var catalog: AppCatalog
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var running: RunningApps
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: catalog.icon(for: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottom) {
                    if store.settings.showRunningIndicator && running.isRunning(path: app.path) {
                        RunningDot(size: 4).offset(y: 5)
                    }
                }
            Text(app.name)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: 240, height: 46)
        .background(Color.white.opacity(hovering || highlighted ? 0.14 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { launcher.launch(path: app.path) }
        .contextMenu {
            if store.isPinned(app.path) {
                Button("Unpin from Start") { store.unpin(path: app.path) }
            } else {
                Button("Pin to Start") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { _ = store.pin(path: app.path) }
                }
            }
            Button("Show in Finder") { launcher.reveal(path: app.path) }
            if running.isRunning(path: app.path) {
                Divider()
                QuitMenuItems(path: app.path, name: app.name)
            }
        }
    }
}
