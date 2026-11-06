import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import MacTiles

// MARK: - Tile packing (Windows 8.1 column flow)

final class PackerTests: XCTestCase {
    private func tiles(_ sizes: [TileSize]) -> [Tile] {
        sizes.map { Tile(kind: .app, appPath: "/Applications/X.app", size: $0) }
    }

    private func positions(_ r: Packer.Result) -> [[Int]] { r.items.map { [$0.x, $0.y] } }

    func testMediumTilesFillABandLeftToRightTopToBottom() {
        let r = Packer.pack(tiles([.medium, .medium, .medium]), rows: 4)
        XCTAssertEqual(positions(r), [[0, 0], [2, 0], [0, 2]])
        XCTAssertEqual(r.width, 4)
    }

    func testSmallTilesBackFillBesideWideTile() {
        let r = Packer.pack(tiles([.wide, .small, .small, .small, .small]), rows: 4)
        XCTAssertEqual(positions(r), [[0, 0], [0, 2], [1, 2], [2, 2], [3, 2]])
    }

    func testFullBandSpillsIntoNextBand() {
        let r = Packer.pack(tiles(Array(repeating: .medium, count: 5)), rows: 4)
        XCTAssertEqual(positions(r).last, [4, 0])
        XCTAssertEqual(r.width, 6)
    }

    func testLargeTileTakesWholeBandWhenRowsAreFour() {
        let r = Packer.pack(tiles([.large, .medium]), rows: 4)
        XCTAssertEqual(positions(r), [[0, 0], [4, 0]])
    }

    func testEmptyGroupStillHasWidth() {
        XCTAssertEqual(Packer.pack([], rows: 6).width, 2)
    }
}

// MARK: - Search ranking

final class AppSearchTests: XCTestCase {
    private let apps = ["Visual Studio Code", "Safari", "Calculator", "Calendar", "Music"].map {
        AppInfo(path: "/Applications/\($0).app", name: $0)
    }

    private func names(_ q: String) -> [String] { AppSearch.rank(q, in: apps).map(\.name) }

    func testEmptyQueryReturnsNothing() {
        XCTAssertEqual(names("   "), [])
    }

    func testExactMatchComesFirst() {
        XCTAssertEqual(names("safari").first, "Safari")
    }

    func testPrefixMatchesPreferShorterNames() {
        XCTAssertEqual(names("cal"), ["Calendar", "Calculator"])
    }

    func testWordPrefixMatches() {
        XCTAssertEqual(names("studio"), ["Visual Studio Code"])
    }

    func testInitialsMatchAsSubsequence() {
        XCTAssertEqual(names("vsc"), ["Visual Studio Code"])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(names("MUS"), ["Music"])
    }
}

// MARK: - App folder watching

final class AppScannerTests: XCTestCase {
    func testEnclosingBundle() {
        XCTAssertEqual(AppScanner.enclosingBundle("/Applications/Foo.app/Contents/Info.plist"), "/Applications/Foo.app")
        XCTAssertEqual(AppScanner.enclosingBundle("/Applications/Foo.app"), "/Applications/Foo.app")
        XCTAssertNil(AppScanner.enclosingBundle("/Applications/Utilities"))
        XCTAssertNil(AppScanner.enclosingBundle("/Applications/Foo.application/x"))
    }

    func testDisplayNameDropsAppExtension() {
        XCTAssertFalse(AppScanner.displayName("/System/Applications/Calculator.app").hasSuffix(".app"))
    }
}

// MARK: - Layout file

final class LayoutFileTests: XCTestCase {
    func testLenientDecodingKeepsGoodTilesAndFillsDefaults() throws {
        let json = """
        {
          "groups": [
            { "name": "Mine", "tiles": [
              { "kind": "clock" },
              { "kind": "hologram", "size": "medium" },
              { "kind": "app", "appPath": "/Applications/Safari.app", "size": "wide", "color": "#00A300" }
            ]}
          ]
        }
        """
        let file = try JSONDecoder().decode(LayoutFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.groups.count, 1)
        let tiles = file.groups[0].tiles
        XCTAssertEqual(tiles.map(\.kind), [.clock, .app], "unknown tile kinds are skipped, not fatal")
        XCTAssertEqual(tiles[0].size, TileKind.clock.defaultSize)
        XCTAssertEqual(tiles[1].size, .wide)
        XCTAssertEqual(tiles[1].color, "#00A300")
        XCTAssertTrue(file.settings.keepOnDesktop, "missing settings fall back to defaults")
    }

    func testRoundTrip() throws {
        let original = LayoutFile(settings: AppSettings(), groups: [
            TileGroup(name: "A", tiles: [Tile(kind: .weather), .app("/Applications/Safari.app", size: .small)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LayoutFile.self, from: data)
        XCTAssertEqual(decoded.groups, original.groups)
        XCTAssertEqual(decoded.settings, original.settings)
    }
}

// MARK: - Feeds, weather, colors

final class FeedParserTests: XCTestCase {
    private func parse(_ xml: String) -> FeedDelegate {
        let d = FeedDelegate()
        let p = XMLParser(data: Data(xml.utf8))
        p.delegate = d
        p.parse()
        return d
    }

    func testRSS() {
        let d = parse("""
        <rss><channel><title>World</title>
          <item><title>First</title><link>https://example.com/1</link></item>
          <item><title><![CDATA[Second & more]]></title><link>https://example.com/2</link></item>
        </channel></rss>
        """)
        XCTAssertEqual(d.channelTitle, "World")
        XCTAssertEqual(d.items.map(\.title), ["First", "Second & more"])
        XCTAssertEqual(d.items.first?.link?.absoluteString, "https://example.com/1")
    }

    func testAtom() {
        let d = parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title>
          <entry><title>Post</title><link href="https://example.com/post"/></entry>
        </feed>
        """)
        XCTAssertEqual(d.channelTitle, "Blog")
        XCTAssertEqual(d.items.map(\.title), ["Post"])
        XCTAssertEqual(d.items.first?.link?.absoluteString, "https://example.com/post")
    }
}

final class MiscTests: XCTestCase {
    func testWeatherSymbols() {
        XCTAssertEqual(WeatherAPI.symbol(for: 0, isDay: true), "sun.max.fill")
        XCTAssertEqual(WeatherAPI.symbol(for: 0, isDay: false), "moon.stars.fill")
        XCTAssertEqual(WeatherAPI.symbol(for: 63, isDay: true), "cloud.rain.fill")
        XCTAssertEqual(WeatherAPI.describe(95), "Thunderstorms")
    }

    func testTileColorIsStableAcrossLaunches() {
        // Must not depend on Swift's per-launch randomized hashValue.
        XCTAssertEqual(Palette.stableIndex("/Applications/Safari.app", modulo: 14), 5)
    }

    func testHotKeyPresetsAreUnique() {
        XCTAssertEqual(Set(HotKeyPreset.all.map(\.id)).count, HotKeyPreset.all.count)
        XCTAssertNotNil(HotKeyPreset.find(AppSettings().hotKey))
    }
}

@MainActor
final class AppsViewTests: XCTestCase {
    func testLetterHeadings() {
        XCTAssertEqual(AppsView.letter(for: "Éclair"), "E")
        XCTAssertEqual(AppsView.letter(for: "1Password"), "#")
        XCTAssertEqual(AppsView.letter(for: "safari"), "S")
    }
}

// MARK: - Type to search

final class TypeToSearchTests: XCTestCase {
    private func act(_ code: UInt16, _ chars: String?, _ flags: NSEvent.ModifierFlags = [], query: String = "") -> TypeToSearch.Action {
        TypeToSearch.action(keyCode: code, characters: chars, flags: flags, query: query)
    }

    func testLettersAppend() {
        XCTAssertEqual(act(0, "a"), .append("a"))
        XCTAssertEqual(act(0, "A", .shift), .append("A"))
        XCTAssertEqual(act(14, "é", .option, query: "caf"), .append("é"))   // ⌥ types accents
    }

    func testShortcutsAreNotTyping() {
        XCTAssertEqual(act(8, "c", .command), .ignore)
        XCTAssertEqual(act(8, "c", .control), .ignore)
    }

    func testArrowAndFunctionKeysAreIgnored() {
        XCTAssertEqual(act(123, "\u{F702}"), .ignore)      // ←
        XCTAssertEqual(act(122, "\u{F704}"), .ignore)      // F1
        XCTAssertEqual(act(48, "\t"), .ignore)             // Tab
    }

    func testLeadingSpaceIgnoredButInnerSpaceKept() {
        XCTAssertEqual(act(49, " "), .ignore)
        XCTAssertEqual(act(49, " ", query: "visual"), .append(" "))
    }

    func testDeleteVariants() {
        XCTAssertEqual(act(51, "\u{7F}"), .ignore)                                   // nothing to delete
        XCTAssertEqual(act(51, "\u{7F}", query: "abc"), .deleteBackward)
        XCTAssertEqual(act(51, "\u{7F}", .option, query: "abc"), .deleteWord)
        XCTAssertEqual(act(51, "\u{7F}", .command, query: "abc"), .clear)
    }

    func testReturnSubmitsOnlyWithAQuery() {
        XCTAssertEqual(act(36, "\r"), .ignore)
        XCTAssertEqual(act(36, "\r", query: "saf"), .submit)
        XCTAssertEqual(act(76, "\u{3}", query: "saf"), .submit)                       // keypad Enter
    }

    func testApply() {
        XCTAssertEqual(TypeToSearch.apply(.append("i"), to: "safar"), "safari")
        XCTAssertEqual(TypeToSearch.apply(.deleteBackward, to: "safari"), "safar")
        XCTAssertEqual(TypeToSearch.apply(.deleteWord, to: "visual studio "), "visual ")
        XCTAssertEqual(TypeToSearch.apply(.clear, to: "anything"), "")
    }
}

// MARK: - Background colors

final class ColorTests: XCTestCase {
    func testNormalizedHex() {
        XCTAssertEqual(Palette.normalizedHex("25115a"), "#25115A")
        XCTAssertEqual(Palette.normalizedHex(" #25115A "), "#25115A")
        XCTAssertNil(Palette.normalizedHex("#25115"))
        XCTAssertNil(Palette.normalizedHex("purple"))
    }

    func testColorWheelRoundTripKeepsHex() {
        for hex in Palette.backgrounds + ["#000000", "#FFFFFF", "#7F3FBF"] {
            XCTAssertEqual(NSColor(Color(hex: hex)).hexString, hex)
        }
    }
}

// MARK: - Tile shape

final class TileShapeTests: XCTestCase {
    func testDefaultsToSquareAndOldLayoutsStaySquare() throws {
        XCTAssertEqual(AppSettings().tileShape, .square)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(##"{"background":"#25115A"}"##.utf8))
        XCTAssertEqual(old.tileShape, .square)
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.tileShape = .round
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.tileShape, .round)
    }

    func testMetricsFollowShapeAndScale() {
        let size = CGSize(width: 1440, height: 900)
        let square = Metrics(size: size, scale: 1, shape: .square)
        let round = Metrics(size: size, scale: 1, shape: .round)
        XCTAssertEqual(square.cornerRadius, 0)
        XCTAssertEqual(square.gap, 8)
        XCTAssertEqual(round.cornerRadius, 20)
        XCTAssertEqual(round.gap, 12)
        XCTAssertEqual(Metrics(size: size, scale: 1.5, shape: .soft).cornerRadius, 18)
    }

    func testCornersNeverSwallowASmallTile() {
        // The roundest corner at the smallest scale still leaves a flat edge on a small tile.
        let m = Metrics(size: CGSize(width: 1440, height: 900), scale: 0.8, shape: .round)
        XCTAssertLessThan(m.cornerRadius * 2, m.tile)
    }
}

// MARK: - Group order

final class GroupOrderTests: XCTestCase {
    private let groups = ["A", "B", "C", "D"].map { TileGroup(name: $0, tiles: [Tile(kind: .clock)]) }
    private func names(_ g: [TileGroup]) -> [String] { g.map(\.name) }

    func testDraggingRightLandsAfterTarget() {
        XCTAssertEqual(names(LayoutStore.movingGroup(groups[0].id, to: groups[1].id, in: groups)), ["B", "A", "C", "D"])
        XCTAssertEqual(names(LayoutStore.movingGroup(groups[0].id, to: groups[3].id, in: groups)), ["B", "C", "D", "A"])
    }

    func testDraggingLeftLandsBeforeTarget() {
        XCTAssertEqual(names(LayoutStore.movingGroup(groups[3].id, to: groups[1].id, in: groups)), ["A", "D", "B", "C"])
        XCTAssertEqual(names(LayoutStore.movingGroup(groups[2].id, to: groups[0].id, in: groups)), ["C", "A", "B", "D"])
    }

    func testMovingOntoItselfOrUnknownChangesNothing() {
        XCTAssertEqual(names(LayoutStore.movingGroup(groups[1].id, to: groups[1].id, in: groups)), ["A", "B", "C", "D"])
        XCTAssertEqual(names(LayoutStore.movingGroup(UUID(), to: groups[1].id, in: groups)), ["A", "B", "C", "D"])
    }

    func testTilesTravelWithTheirGroup() {
        let moved = LayoutStore.movingGroup(groups[0].id, to: groups[2].id, in: groups)
        XCTAssertEqual(moved[2].tiles, groups[0].tiles)
    }
}

// MARK: - Wallpapers

final class WallpaperTests: XCTestCase {
    func testSettingsDefaultsAndOldLayoutsKeepTheirColor() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(##"{"background":"#003E00"}"##.utf8))
        XCTAssertEqual(old.backgroundStyle, .color)
        XCTAssertEqual(old.liveWallpaper, .aurora)
        XCTAssertNil(old.wallpaperFile)
        XCTAssertEqual(old.wallpaperDim, 0.25)
    }

    func testSettingsRoundTripAndDimIsClamped() throws {
        var s = AppSettings()
        s.backgroundStyle = .live
        s.liveWallpaper = .bokeh
        s.wallpaperFile = "1a2b3c4d-Beach.mov"
        s.wallpaperDim = 0.4
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let wild = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"wallpaperDim": 5}"#.utf8))
        XCTAssertEqual(wild.wallpaperDim, 0.7, "the Dim slider's maximum")
    }

    func testUnknownStyleFallsBackToColor() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"backgroundStyle": "hologram"}"#.utf8))
        XCTAssertEqual(s.backgroundStyle, .color)
    }

    func testURLsAndNames() {
        XCTAssertNil(Wallpapers.url(for: nil))
        XCTAssertNil(Wallpapers.url(for: "  "))
        XCTAssertEqual(Wallpapers.url(for: "/Users/me/Movies/a.mp4")?.path, "/Users/me/Movies/a.mp4")
        XCTAssertEqual(Wallpapers.url(for: "1a2b3c4d-Beach.mov")?.deletingLastPathComponent().lastPathComponent, "Wallpapers")
        XCTAssertEqual(Wallpapers.displayName("1a2b3c4d-Beach.mov"), "Beach.mov")
        XCTAssertEqual(Wallpapers.displayName("/Users/me/Movies/a.mp4"), "a.mp4")
    }

    func testKinds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(Wallpapers.kind(of: dir.appendingPathComponent("clip.mov")), .video)
        XCTAssertEqual(Wallpapers.kind(of: dir.appendingPathComponent("clip.mp4")), .video)
        XCTAssertNil(Wallpapers.kind(of: dir.appendingPathComponent("notes.txt")))

        let png = dir.appendingPathComponent("still.png")
        try writeImage(to: png, type: .png, frames: 1)
        XCTAssertEqual(Wallpapers.kind(of: png), .still)

        let gif = dir.appendingPathComponent("anim.gif")
        try writeImage(to: gif, type: .gif, frames: 3)
        XCTAssertEqual(Wallpapers.kind(of: gif), .animated)
        let decoded = try XCTUnwrap(AnimatedImageDecoder.decode(gif))
        XCTAssertEqual(decoded.images.count, 3)
        XCTAssertEqual(decoded.keyTimes.count, 4)
        XCTAssertEqual(decoded.duration, 0.15, accuracy: 0.001)
    }

    func testFrameDelays() {
        let gif = kCGImagePropertyGIFDictionary
        XCTAssertEqual(AnimatedImageDecoder.frameDelay([gif: [kCGImagePropertyGIFUnclampedDelayTime: 0.05]]), 0.05)
        XCTAssertEqual(AnimatedImageDecoder.frameDelay([gif: [kCGImagePropertyGIFDelayTime: 0.0]]), 0.1)   // browsers' rule
        XCTAssertEqual(AnimatedImageDecoder.frameDelay([:]), 0.1)
    }

    func testKeyTimesAreNormalized() {
        let f = AnimatedImageDecoder.frames(images: [], delays: [0.1, 0.3])
        XCTAssertEqual(f.keyTimes.count, 3)
        XCTAssertEqual(f.keyTimes[0], 0)
        XCTAssertEqual(f.keyTimes[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.keyTimes[2], 1)
        XCTAssertEqual(f.duration, 0.4, accuracy: 1e-9)
    }

    func testLivePaletteAlwaysHasVisibleColor() {
        let grey = LivePalette.hsb("#1D1D1D")
        XCTAssertEqual(grey.count, 4)
        XCTAssertTrue(grey.allSatisfy { $0.s >= 0.25 && $0.b >= 0.6 })
        XCTAssertEqual(LivePalette.colors("#25115A").count, 4)
    }

    func testLiveRandomIsDeterministicAndInRange() {
        XCTAssertEqual(LiveDraw.rand(3, 7), LiveDraw.rand(3, 7))
        XCTAssertNotEqual(LiveDraw.rand(3, 7), LiveDraw.rand(4, 7))
        for i in 0..<200 { XCTAssertTrue((0..<1).contains(LiveDraw.rand(i, i * 3))) }
    }

    private func writeImage(to url: URL, type: UTType, frames: Int) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for i in 0..<frames {
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(i) / 3, green: 0.5, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let props: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]]
            CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Web tiles

final class WebTileTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(WebLink.normalize("apple.com")?.absoluteString, "https://apple.com")
        XCTAssertEqual(WebLink.normalize("  https://www.apple.com/mac/ ")?.absoluteString, "https://www.apple.com/mac/")
        XCTAssertEqual(WebLink.normalize("http://example.org")?.scheme, "http")
        XCTAssertEqual(WebLink.normalize("localhost:3000/docs")?.absoluteString, "https://localhost:3000/docs")
        XCTAssertEqual(WebLink.normalize("192.168.1.10")?.host, "192.168.1.10")
        XCTAssertEqual(WebLink.normalize("mailto:me@example.com")?.scheme, "mailto")
        XCTAssertNil(WebLink.normalize(""))
        XCTAssertNil(WebLink.normalize("not a url"))
        XCTAssertNil(WebLink.normalize("apple"))
        XCTAssertNil(WebLink.normalize("https://"))
    }

    func testDisplayHost() {
        XCTAssertEqual(WebLink.displayHost(URL(string: "https://www.Apple.com/mac")!), "apple.com")
        XCTAssertEqual(WebLink.displayHost(URL(string: "https://news.ycombinator.com")!), "news.ycombinator.com")
    }

    func testPageTitle() {
        XCTAssertEqual(WebPage.title(in: "<html><head><title>\n  Apple &amp; Friends  </title></head>"), "Apple & Friends")
        XCTAssertNil(WebPage.title(in: "<html><title> </title></html>"))
        XCTAssertNil(WebPage.title(in: "<html></html>"))
        XCTAssertEqual(WebPage.title(in: "<title>" + String(repeating: "x", count: 100) + "</title>")?.count, 60)
    }

    func testIconCandidatesLargestFirstWithManifest() {
        let html = """
        <link rel="icon" href="/favicon-16.png" sizes="16x16">
        <link rel='icon' href='https://cdn.example.com/icon-192.png' sizes='192x192'>
        <link rel="mask-icon" href="/mask.svg">
        <link href="/touch.png" rel="apple-touch-icon">
        <link rel="manifest" href="/site.webmanifest">
        <link rel="stylesheet" href="/style.css">
        """
        let found = WebPage.iconCandidates(in: html, base: URL(string: "https://example.com/docs/page")!)
        XCTAssertEqual(found.icons.map(\.url.absoluteString), [
            "https://cdn.example.com/icon-192.png",
            "https://example.com/touch.png",          // apple-touch-icon without sizes counts as 180
            "https://example.com/favicon-16.png",
        ])
        XCTAssertEqual(found.manifest?.absoluteString, "https://example.com/site.webmanifest")
    }

    func testManifestIcons() {
        let json = #"{"icons":[{"src":"/a-192.png","sizes":"192x192"},{"src":"b-512.png","sizes":"512x512","purpose":"any maskable"},{"src":"/mono.png","sizes":"512x512","purpose":"monochrome"}]}"#
        let icons = WebPage.manifestIcons(Data(json.utf8), base: URL(string: "https://example.com/app/site.webmanifest")!)
        XCTAssertEqual(icons.map(\.url.absoluteString), ["https://example.com/app/b-512.png", "https://example.com/a-192.png"])
        XCTAssertEqual(icons.map(\.size), [512, 192])
    }

    func testConventionalAndFallbackIcons() {
        let conventional = WebPage.conventionalIcons(for: URL(string: "https://www.example.com/a/b")!).map(\.url.absoluteString)
        XCTAssertEqual(conventional.first, "https://www.example.com/apple-touch-icon.png")
        XCTAssertTrue(conventional.contains("https://www.example.com/favicon.ico"))
        let fallback = WebPage.fallbackIcon(for: "example.com")?.url.absoluteString ?? ""
        XCTAssertTrue(fallback.contains("domain=example.com"))
        XCTAssertEqual(WebPage.parseSizes("16x16 32x32"), 32)
        XCTAssertEqual(WebPage.parseSizes("any"), 512)
        XCTAssertEqual(WebPage.parseSizes(nil), 0)
    }

    func testWebTilesAreNotLiveTilesAndRoundTrip() throws {
        XCTAssertFalse(TileKind.liveKinds.contains(.web))
        let tile = Tile.web("https://apple.com", title: "Apple")
        let back = try JSONDecoder().decode(Tile.self, from: JSONEncoder().encode(tile))
        XCTAssertEqual(back, tile)
        XCTAssertEqual(back.size, .medium)
    }

    func testWebTileWithoutAddressIsSkipped() throws {
        let json = #"{"name":"G","tiles":[{"kind":"web"},{"kind":"web","url":"https://apple.com"},{"kind":"clock"}]}"#
        let group = try JSONDecoder().decode(TileGroup.self, from: Data(json.utf8))
        XCTAssertEqual(group.tiles.map(\.kind), [.web, .clock])
    }
}

// MARK: - Tile finish & shadow

final class TileLookTests: XCTestCase {
    func testDefaultsKeepTheFlatLook() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(##"{"background":"#25115A"}"##.utf8))
        XCTAssertEqual(old.tileFinish, .flat)
        XCTAssertEqual(old.tileShadow, .none)
        XCTAssertEqual(old.glassTint, 0.45)
    }

    func testRoundTripAndClamping() throws {
        var s = AppSettings()
        s.tileFinish = .glass
        s.glassTint = 0.3
        s.tileShadow = .strong
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)), s)
        let wild = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"glassTint": 3, "tileShadow": "huge"}"#.utf8))
        XCTAssertEqual(wild.glassTint, 0.9)
        XCTAssertEqual(wild.tileShadow, .none)
    }

    func testShadowLevelsGetStronger() {
        let p = TileShadow.allCases.map(\.parameters)
        XCTAssertEqual(p.first?.opacity, 0)
        for (a, b) in zip(p, p.dropFirst()) {
            XCTAssertLessThan(a.opacity, b.opacity)
            XCTAssertLessThan(a.radius, b.radius)
            XCTAssertLessThanOrEqual(a.y, b.y)
        }
    }
}

// MARK: - Running indicator

@MainActor
final class RunningAppsTests: XCTestCase {
    func testMatchesByPathRegardlessOfCaseOrTrailingSlash() {
        let r = RunningApps(observe: false)
        r.set(bundleIDs: [], paths: ["/Applications/Safari.app"])
        XCTAssertTrue(r.isRunning(path: "/Applications/Safari.app"))
        XCTAssertTrue(r.isRunning(path: "/applications/safari.app/"))
        XCTAssertFalse(r.isRunning(path: "/Applications/Mail.app"))
    }

    func testMatchesByBundleIdentifier() {
        // Calculator is on every Mac; match it by its bundle identifier even if the path differs.
        let r = RunningApps(observe: false)
        r.set(bundleIDs: ["com.apple.calculator"], paths: [])
        XCTAssertTrue(r.isRunning(path: "/System/Applications/Calculator.app"))
        r.set(bundleIDs: [], paths: [])
        XCTAssertFalse(r.isRunning(path: "/System/Applications/Calculator.app"))
    }

    func testSettingDefaultsOn() throws {
        XCTAssertTrue(AppSettings().showRunningIndicator)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showRunningIndicator": false}"#.utf8))
        XCTAssertFalse(off.showRunningIndicator)
    }
}

// MARK: - Service integrations

final class IntegrationModelTests: XCTestCase {
    func testAddressNormalization() {
        XCTAssertEqual(Integration.normalize("192.168.1.10:8989/")?.absoluteString, "http://192.168.1.10:8989")
        XCTAssertEqual(Integration.normalize(" https://pve.local:8006// ")?.absoluteString, "https://pve.local:8006")
        XCTAssertEqual(Integration.normalize("tcp://nas.local:2375")?.absoluteString, "http://nas.local:2375")
        XCTAssertNil(Integration.normalize(""))
        XCTAssertNil(Integration.normalize("not an address"))
    }

    func testEveryServiceHasWidgetsAndSensibleFields() {
        for kind in ServiceKind.allCases {
            XCTAssertFalse(kind.widgets.isEmpty, kind.title)
            if kind.secretRequired { XCTAssertNotNil(kind.secretLabel, kind.title) }
            XCTAssertFalse(kind.help.isEmpty, kind.title)
        }
        for widget in ServiceWidget.allCases {
            XCTAssertTrue(widget.sizes.contains(widget.defaultSize), widget.title)
            XCTAssertGreaterThan(widget.interval, 0)
        }
        XCTAssertEqual(Set(ServiceKind.Category.allCases.flatMap(ServiceKind.inCategory)), Set(ServiceKind.allCases))
    }

    func testSettingsKeepIntegrationsButNotSecrets() throws {
        var settings = AppSettings()
        var pihole = Integration(kind: .pihole, name: "Pi", url: "http://pi.hole")
        pihole.username = ""
        settings.integrations = [pihole, Integration(kind: .proxmox, url: "https://pve:8006", username: "root@pam!mt")]
        let data = try JSONEncoder().encode(settings)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("secret"))
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.integrations, settings.integrations)
        XCTAssertTrue(back.integrations[1].allowSelfSigned, "Proxmox defaults to allowing its self-signed certificate")
    }

    func testUnknownServiceIsSkippedNotFatal() throws {
        let json = #"{"integrations": [{"kind": "someFutureThing", "url": "x"}, {"kind": "docker"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.integrations.map(\.kind), [.docker])
    }

    func testServiceTileRoundTripAndValidation() throws {
        let id = UUID()
        let tile = Tile.service(id, widget: .entity, entity: "light.kitchen")
        let back = try JSONDecoder().decode(Tile.self, from: JSONEncoder().encode(tile))
        XCTAssertEqual(back.integrationID, id)
        XCTAssertEqual(back.widget, .entity)
        XCTAssertEqual(back.entity, "light.kitchen")
        XCTAssertEqual(back.sizes, ServiceWidget.entity.sizes)
        // A service tile with no integration is dropped when its group loads.
        let group = #"{"name": "Lab", "tiles": [{"kind": "service"}, {"kind": "clock"}]}"#
        let decoded = try JSONDecoder().decode(TileGroup.self, from: Data(group.utf8))
        XCTAssertEqual(decoded.tiles.map(\.kind), [.clock])
        XCTAssertFalse(TileKind.liveKinds.contains(.service))
    }

    func testHubKeySharedByIdenticalTiles() {
        let id = UUID()
        XCTAssertEqual(ServiceHub.key(.service(id, widget: .dnsSummary)), ServiceHub.key(.service(id, widget: .dnsSummary)))
        XCTAssertNotEqual(ServiceHub.key(.service(id, widget: .nowPlaying)), ServiceHub.key(.service(id, widget: .recentlyAdded)))
    }
}

final class ServiceParserTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testPiholeV6Summary() throws {
        let summary = try json(#"{"queries": {"total": 25000, "blocked": 3100, "percent_blocked": 12.4}, "clients": {"active": 14, "total": 20}, "gravity": {"domains_being_blocked": 123456}}"#)
        let s = ServiceAPI.parsePiholeSummary(summary, blocking: try json(#"{"blocking": "disabled", "timer": 120}"#))
        XCTAssertEqual(s.headline, "12.4%")
        XCTAssertEqual(s.stats.first?.value, "25k")
        XCTAssertEqual(s.stats[2].value, "14")
        XCTAssertEqual(s.isOn, false)
        XCTAssertEqual(s.gauges.first?.fraction ?? 0, 0.124, accuracy: 0.0001)
    }

    func testPiholeV5Summary() throws {
        let s = ServiceAPI.parsePiholeV5(try json(#"{"dns_queries_today": 900, "ads_blocked_today": 90, "ads_percentage_today": 10.0, "unique_clients": 3, "domains_being_blocked": 1000, "status": "enabled"}"#))
        XCTAssertEqual(s.headline, "10.0%")
        XCTAssertEqual(s.stats[0].value, "900")
        XCTAssertEqual(s.stats[3].value, "1.0k")
        XCTAssertEqual(s.isOn, true)
    }

    func testAdGuard() throws {
        let s = ServiceAPI.parseAdGuard(try json(#"{"num_dns_queries": 1000, "num_blocked_filtering": 150, "num_replaced_safebrowsing": 40, "num_replaced_parental": 10, "avg_processing_time": 0.012}"#),
                                        status: try json(#"{"protection_enabled": true}"#))
        XCTAssertEqual(s.headline, "20.0%")
        XCTAssertEqual(s.stats[2].value, "12 ms")
        XCTAssertEqual(s.isOn, true)
    }

    func testPlexSessions() throws {
        let j = try json(#"""
        {"MediaContainer": {"size": 2, "Metadata": [
          {"sessionKey": "7", "type": "episode", "title": "Pilot", "grandparentTitle": "Severance", "parentIndex": 1, "index": 1,
           "duration": 1000, "viewOffset": 250, "User": {"title": "alex"}, "Player": {"title": "Apple TV", "state": "playing"}, "grandparentThumb": "/thumb/1"},
          {"sessionKey": "8", "type": "movie", "title": "Arrival", "year": 2016, "duration": 0, "Player": {"product": "Plex Web", "state": "paused"}}
        ]}}
        """#)
        let s = ServiceAPI.parsePlexSessions(j) { $0.flatMap { URL(string: "http://plex" + $0) } }
        XCTAssertEqual(s.headline, "2")
        XCTAssertEqual(s.items[0].title, "Severance S1E1 · Pilot")
        XCTAssertEqual(s.items[0].subtitle, "alex · Apple TV")
        XCTAssertEqual(s.items[0].progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(s.items[0].image?.absoluteString, "http://plex/thumb/1")
        XCTAssertTrue(s.items[0].isActive)
        XCTAssertEqual(s.items[1].title, "Arrival (2016)")
        XCTAssertTrue(s.items[1].subtitle.hasSuffix("Paused"))
        XCTAssertNil(s.items[1].progress)
        XCTAssertFalse(s.items[1].isActive)
    }

    func testJellyfinSessionsSkipIdleClients() throws {
        let j = try json(#"""
        [{"Id": "a", "UserName": "sam", "DeviceName": "iPad", "PlayState": {"PositionTicks": 50, "IsPaused": false},
          "NowPlayingItem": {"Id": "i1", "SeriesId": "s1", "Type": "Episode", "Name": "Rain", "SeriesName": "Dark", "ParentIndexNumber": 2, "IndexNumber": 3, "RunTimeTicks": 100}},
         {"Id": "b", "UserName": "idle", "DeviceName": "TV"}]
        """#)
        let s = ServiceAPI.parseJellySessions(j)
        XCTAssertEqual(s.items.count, 1)
        XCTAssertEqual(s.items[0].title, "Dark S2E3 · Rain")
        XCTAssertEqual(s.items[0].progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.caption, "stream")
    }

    func testSonarrCalendarSortedByAirDate() throws {
        let j = try json(#"""
        [{"id": 2, "seasonNumber": 1, "episodeNumber": 2, "title": "Later", "airDateUtc": "2030-01-05T01:00:00Z", "hasFile": false, "series": {"title": "B"}},
         {"id": 1, "seasonNumber": 3, "episodeNumber": 10, "title": "Sooner", "airDateUtc": "2030-01-02T01:00:00Z", "hasFile": true,
          "series": {"title": "A", "images": [{"coverType": "banner", "remoteUrl": "https://x/banner.jpg"}, {"coverType": "poster", "remoteUrl": "https://x/poster.jpg"}]}}]
        """#)
        let s = ServiceAPI.parseSonarrCalendar(j, now: Fmt.isoDate("2030-01-01T00:00:00Z")!)
        XCTAssertEqual(s.headline, "2")
        XCTAssertEqual(s.items.map(\.title), ["A", "B"])
        XCTAssertTrue(s.items[0].subtitle.contains("S03E10 · Sooner"))
        XCTAssertEqual(s.items[0].image?.absoluteString, "https://x/poster.jpg")
        XCTAssertTrue(s.items[0].isActive)
    }

    func testRadarrPicksNextReleaseInWindow() throws {
        let start = Fmt.isoDate("2030-03-01T00:00:00Z")!
        let j = try json(#"""
        [{"id": 1, "title": "Dune", "year": 2030, "inCinemas": "2030-02-01T00:00:00Z", "digitalRelease": "2030-03-20T00:00:00Z"},
         {"id": 2, "title": "Old", "inCinemas": "2020-01-01T00:00:00Z"}]
        """#)
        let s = ServiceAPI.parseRadarrCalendar(j, from: start, now: start)
        XCTAssertEqual(s.items.count, 1)
        XCTAssertEqual(s.items[0].title, "Dune (2030)")
        XCTAssertTrue(s.items[0].subtitle.hasPrefix("Digital"))
    }

    func testOverseerrCountsAndStatus() throws {
        let s = ServiceAPI.parseOverseerrCount(try json(#"{"total": 40, "movie": 25, "tv": 15, "pending": 3, "approved": 30, "declined": 2, "processing": 4, "available": 20}"#))
        XCTAssertEqual(s.headline, "3")
        XCTAssertEqual(s.caption, "pending requests")
        XCTAssertEqual(ServiceAPI.overseerrStatus(try json(#"{"status": 2, "media": {"status": 3}}"#)), "Processing")
        XCTAssertEqual(ServiceAPI.overseerrStatus(try json(#"{"status": 2, "media": {"status": 5}}"#)), "Available")
        XCTAssertEqual(ServiceAPI.overseerrStatus(try json(#"{"status": 1, "media": {"status": 2}}"#)), "Pending")
    }

    func testUniFiHealth() throws {
        let j = try json(#"""
        {"meta": {"rc": "ok"}, "data": [
          {"subsystem": "wlan", "num_user": 20, "num_guest": 2, "num_ap": 3, "status": "ok"},
          {"subsystem": "wan", "status": "ok", "wan_ip": "203.0.113.5", "num_gw": 1, "gw_system-stats": {"cpu": "12.5", "mem": "40"}},
          {"subsystem": "www", "status": "ok", "latency": 9, "xput_down": 940.2, "xput_up": 35.1},
          {"subsystem": "lan", "num_user": 8, "num_sw": 2, "status": "ok"}]}
        """#)
        let s = ServiceAPI.parseUniFiHealth(j)
        XCTAssertEqual(s.headline, "30")
        XCTAssertEqual(s.stats.first { $0.label == "Devices" }?.value, "6")
        XCTAssertEqual(s.stats.first { $0.label == "Latency" }?.value, "9 ms")
        XCTAssertEqual(s.stats.first { $0.label == "WAN IP" }?.value, "203.0.113.5")
        XCTAssertEqual(s.gauges.first?.fraction ?? 0, 0.125, accuracy: 0.0001)
        XCTAssertEqual(s.isOn, true)
    }

    func testOPNsense() throws {
        let s = ServiceAPI.parseOPNsense(
            time: try json(#"{"uptime": "12 days, 03:04:05", "loadavg": "0.21, 0.30, 0.35"}"#),
            resources: try json(#"{"memory": {"total": "8589934592", "used": 2147483648}}"#),
            info: try json(#"{"name": "fw.home", "versions": ["OPNsense 25.7.4-amd64", "FreeBSD 14.3"]}"#),
            states: try json(#"{"current": "1500", "limit": "100000"}"#),
            gateways: try json(#"""
            {"items": [
              {"name": "WAN_DHCP", "status": "none", "status_translated": "Online", "delay": "9.8 ms", "loss": "0.0 %"},
              {"name": "WAN2_PPPOE", "status": "down", "status_translated": "Offline", "delay": "~", "loss": "~"}],
             "status": "ok"}
            """#))
        XCTAssertEqual(s.headline, "1/2")
        XCTAssertEqual(s.caption, "gateways online")
        XCTAssertEqual(s.isOn, false)
        XCTAssertEqual(s.gauges.map(\.label), ["Memory", "Firewall states"])
        XCTAssertEqual(s.gauges[0].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(s.gauges[1].fraction, 0.015, accuracy: 0.0001)
        XCTAssertEqual(s.stats.first { $0.label == "Load" }?.value, "0.21 0.30 0.35")
        XCTAssertEqual(s.stats.first { $0.label == "Version" }?.value, "25.7.4-amd64")
        XCTAssertEqual(s.items.map(\.title), ["WAN_DHCP", "WAN2_PPPOE"])
        XCTAssertEqual(s.items[0].subtitle, "Online · 9.8 ms · 0.0 % loss")
        XCTAssertEqual(s.items[1].subtitle, "Offline")
        XCTAssertFalse(s.items[1].isActive)
        // Without gateways it still reports the box itself.
        let bare = ServiceAPI.parseOPNsense(time: try json("{}"), resources: JSON(nil), info: try json(#"{"name": "fw"}"#), states: JSON(nil), gateways: JSON(nil))
        XCTAssertEqual(bare.headline, "Online")
        XCTAssertEqual(bare.caption, "fw")
        XCTAssertNil(bare.isOn)
    }

    func testOPNsenseTrafficSpeeds() throws {
        let first = try json(#"""
        {"interfaces": {
          "wan": {"name": "WAN", "device": "igb0", "inbytes": "1000000", "outbytes": "500000"},
          "lan": {"name": "LAN", "device": "igb1", "inbytes": 200000, "outbytes": 900000},
          "lo0": {"name": "Loopback", "device": "lo0", "inbytes": 5, "outbytes": 5},
          "opt9": {"name": "No counters"}},
         "time": 100.0}
        """#)
        let second = try json(#"""
        {"interfaces": {
          "wan": {"name": "WAN", "device": "igb0", "inbytes": "7000000", "outbytes": "1000000"},
          "lan": {"name": "LAN", "device": "igb1", "inbytes": 100, "outbytes": 6900000}},
         "time": 102.0}
        """#)
        let a = try XCTUnwrap(ServiceAPI.parseOPNsenseCounters(first, receivedAt: 0))
        let b = try XCTUnwrap(ServiceAPI.parseOPNsenseCounters(second, receivedAt: 0))
        XCTAssertEqual(Set(a.counters.keys), ["wan", "lan"], "Loopback and counter-less interfaces are skipped")
        XCTAssertEqual(a.time, 100)

        let rates = ServiceAPI.opnsenseRates(from: a, to: b)
        XCTAssertEqual(rates.map(\.id), ["wan", "lan"], "WAN comes first")
        XCTAssertEqual(rates[0].down, 3_000_000, accuracy: 0.1)     // 6 MB over 2 s
        XCTAssertEqual(rates[0].up, 250_000, accuracy: 0.1)
        XCTAssertEqual(rates[1].down, 0, "A counter that went backwards (reset) reads as zero")
        XCTAssertEqual(rates[1].up, 3_000_000, accuracy: 0.1)

        let s = ServiceAPI.parseOPNsense(time: JSON(nil), resources: JSON(nil), info: JSON(nil), states: JSON(nil),
                                         gateways: try json(#"{"items": [{"name": "WAN_GW", "status_translated": "Online"}]}"#),
                                         traffic: rates, history: [1_000_000, 3_000_000])
        XCTAssertEqual(s.headline, "24 Mb/s")
        XCTAssertEqual(s.caption, "↓ WAN · ↑ 2.0 Mb/s")
        XCTAssertEqual(s.series, [1.0 / 3, 1.0])
        XCTAssertEqual(s.traffic.count, 2)
        XCTAssertEqual(s.stats.first?.value, "1/1 online")
        XCTAssertEqual(s.isOn, true)

        // Some releases send the interfaces at the top level, with other counter names.
        let flat = try json(#"{"wan": {"name": "WAN", "bytes received": 10, "bytes transmitted": 20}}"#)
        XCTAssertEqual(ServiceAPI.parseOPNsenseCounters(flat, receivedAt: 5)?.counters["wan"]?.outBytes, 20)
        XCTAssertNil(ServiceAPI.parseOPNsenseCounters(try json("{}"), receivedAt: 5))
    }

    func testBitrate() {
        XCTAssertEqual(Fmt.bitrate(0), "0 b/s")
        XCTAssertEqual(Fmt.bitrate(100_000), "800 kb/s")
        XCTAssertEqual(Fmt.bitrate(250_000), "2.0 Mb/s")
        XCTAssertEqual(Fmt.bitrate(6_000_000), "48 Mb/s")
        XCTAssertEqual(Fmt.bitrate(150_000_000), "1.2 Gb/s")
    }

    func testBeszelFleetAndSingleSystem() throws {
        let j = try json(#"""
        {"page": 1, "items": [
          {"id": "a1", "name": "nas", "status": "up", "info": {"cpu": 10, "mp": 40, "dp": 70, "dt": 51.4, "b": 1.5, "u": 90000, "la": [0.5, 0.4, 0.3], "h": "nas.local", "v": "0.16.1", "g": 20}},
          {"id": "b2", "name": "pi", "status": "up", "info": {"cpu": 30, "mp": 60, "dp": 30}},
          {"id": "c3", "name": "old", "status": "down", "info": {}},
          {"id": "d4", "name": "lab", "status": "paused", "info": {}}]}
        """#)
        let fleet = ServiceAPI.parseBeszel(j, only: nil)
        XCTAssertEqual(fleet.headline, "2/3", "Paused systems aren't counted")
        XCTAssertEqual(fleet.caption, "systems up")
        XCTAssertEqual(fleet.gauges[0].fraction, 0.2, accuracy: 0.0001)   // average of 10 and 30
        XCTAssertEqual(fleet.stats.first?.value, "pi · 30%")
        XCTAssertEqual(fleet.isOn, false)
        XCTAssertEqual(fleet.items.first?.title, "lab", "Systems that aren't up come first")
        XCTAssertEqual(fleet.items.first { $0.title == "nas" }?.subtitle, "CPU 10% · Mem 40% · Disk 70%")

        let nas = ServiceAPI.parseBeszel(j, only: "a1")
        XCTAssertEqual(nas.headline, "10%")
        XCTAssertEqual(nas.name, "nas")
        XCTAssertEqual(nas.gauges.map(\.label), ["CPU", "Memory", "Disk", "GPU"])
        XCTAssertEqual(nas.stats.first { $0.label == "Temp" }?.value, "51°C")
        XCTAssertEqual(nas.stats.first { $0.label == "Network" }?.value, "13 Mb/s")
        XCTAssertEqual(nas.stats.first { $0.label == "Load" }?.value, "0.50 0.40 0.30")
        XCTAssertEqual(nas.isOn, true)

        let old = ServiceAPI.parseBeszel(j, only: "c3")
        XCTAssertEqual(old.headline, "Down")
        XCTAssertEqual(old.isOn, false)
        XCTAssertEqual(ServiceAPI.parseBeszel(j, only: "zz").caption, "System not found")
    }

    func testComfyIdleAndRunning() throws {
        let stats = try json(#"""
        {"system": {"os": "posix", "ram_total": 68719476736, "ram_free": 51539607552, "comfyui_version": "0.3.60"},
         "devices": [{"name": "cuda:0 NVIDIA GeForce RTX 4090 : cudaMallocAsync", "type": "cuda", "vram_total": 25769803776, "vram_free": 6442450944}]}
        """#)
        let idle = ServiceAPI.parseComfy(stats: stats, queue: try json(#"{"queue_running": [], "queue_pending": []}"#),
                                         live: ComfyMonitor.Live(), recent: [])
        XCTAssertEqual(idle.headline, "Idle")
        XCTAssertEqual(idle.caption, "queue empty")
        XCTAssertFalse(idle.busy)
        XCTAssertEqual(idle.gauges.map(\.label), ["VRAM", "RAM"])
        XCTAssertEqual(idle.gauges[0].fraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(idle.gauges[1].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(idle.stats.first { $0.label == "Device" }?.value, "NVIDIA GeForce RTX 4090")

        var live = ComfyMonitor.Live()
        live.promptID = "p1"; live.value = 5; live.max = 20
        live.gpu = 97; live.gpuTemperature = 71; live.cpu = 12
        let busy = ServiceAPI.parseComfy(stats: stats,
                                         queue: try json(#"{"queue_running": [[3, "p1", {}, {}, []]], "queue_pending": [[4, "p2"], [5, "p3"]]}"#),
                                         live: live, recent: [.init(id: "old", title: "Image")])
        XCTAssertEqual(busy.headline, "25%")
        XCTAssertEqual(busy.caption, "step 5/20 · 2 queued")
        XCTAssertTrue(busy.busy)
        XCTAssertEqual(busy.progress ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(busy.gauges.map(\.label), ["GPU", "VRAM", "RAM", "CPU"])
        XCTAssertEqual(busy.stats.first { $0.label == "GPU temp" }?.value, "71°C")
        XCTAssertEqual(busy.items.map(\.id), ["p1", "old"], "The running job is listed first")
    }

    func testComfyHistoryNewestFirstWithImages() throws {
        let j = try json(#"""
        {"aaa": {"prompt": [1, "aaa"], "outputs": {"9": {"images": [{"filename": "ComfyUI_0001_.png", "subfolder": "", "type": "output"}]}},
                 "status": {"status_str": "success", "completed": true, "messages": [["execution_start", {"timestamp": 1000000}], ["execution_success", {"timestamp": 1012000}]]}},
         "bbb": {"prompt": [2, "bbb"], "outputs": {},
                 "status": {"status_str": "error", "completed": false, "messages": [["execution_start", {"timestamp": 2000000}], ["execution_error", {"timestamp": 2001000}]]}}}
        """#)
        let items = ServiceAPI.parseComfyHistory(j, base: URL(string: "http://gpu:8188"), now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(items.map(\.id), ["bbb", "aaa"])
        XCTAssertEqual(items[0].title, "Failed run")
        XCTAssertFalse(items[0].isActive)
        XCTAssertEqual(items[1].image?.absoluteString, "http://gpu:8188/view?filename=ComfyUI_0001_.png&subfolder=&type=output")
        XCTAssertTrue(items[1].subtitle.hasSuffix("12s"))
    }

    func testComfyLiveMessages() throws {
        var live = ComfyMonitor.Live()
        live = ComfyMonitor.apply(type: "status", data: try json(#"{"status": {"exec_info": {"queue_remaining": 3}}}"#), to: live)
        XCTAssertEqual(live.queueRemaining, 3)
        live = ComfyMonitor.apply(type: "execution_start", data: try json(#"{"prompt_id": "p1"}"#), to: live)
        live = ComfyMonitor.apply(type: "progress", data: try json(#"{"value": 7, "max": 30, "prompt_id": "p1", "node": "3"}"#), to: live)
        XCTAssertEqual(live.promptID, "p1")
        XCTAssertEqual(live.value, 7)
        XCTAssertEqual(live.max, 30)
        live = ComfyMonitor.apply(type: "executing", data: try json(#"{"node": null, "prompt_id": "p1"}"#), to: live)
        XCTAssertNil(live.promptID, "node null means the run finished")
        XCTAssertEqual(live.max, 0)
        let at = Date()
        live = ComfyMonitor.apply(type: "crystools.monitor",
                                  data: try json(#"{"cpu_utilization": 15.5, "ram_used_percent": 40, "gpus": [{"gpu_utilization": 88, "gpu_temperature": 66, "vram_used_percent": 70}]}"#),
                                  to: live, now: at)
        XCTAssertEqual(live.gpu, 88)
        XCTAssertEqual(live.gpuTemperature, 66)
        XCTAssertEqual(live.cpu, 15.5)
        XCTAssertEqual(live.monitorAt, at)
        XCTAssertEqual(ServiceAPI.comfyDeviceName("mps"), "mps")
        XCTAssertEqual(ServiceAPI.comfyDeviceName(nil), "")
    }

    func testProxmoxCountsSharedStorageOnce() throws {
        let j = try json(#"""
        {"data": [
          {"type": "node", "node": "pve1", "status": "online", "cpu": 0.5, "maxcpu": 8, "mem": 8, "maxmem": 32, "uptime": 90000},
          {"type": "node", "node": "pve2", "status": "online", "cpu": 0.25, "maxcpu": 8, "mem": 8, "maxmem": 32, "uptime": 1000},
          {"type": "qemu", "id": "qemu/100", "vmid": 100, "name": "web", "status": "running", "cpu": 0.1},
          {"type": "lxc", "id": "lxc/101", "vmid": 101, "name": "dns", "status": "running", "cpu": 0.01},
          {"type": "qemu", "id": "qemu/102", "vmid": 102, "name": "spare", "status": "stopped"},
          {"type": "storage", "id": "storage/pve1/nfs", "storage": "nfs", "shared": 1, "status": "available", "disk": 50, "maxdisk": 100},
          {"type": "storage", "id": "storage/pve2/nfs", "storage": "nfs", "shared": 1, "status": "available", "disk": 50, "maxdisk": 100},
          {"type": "storage", "id": "storage/pve1/local", "storage": "local", "shared": 0, "status": "available", "disk": 10, "maxdisk": 100}]}
        """#)
        let s = ServiceAPI.parseProxmox(j)
        XCTAssertEqual(s.headline, "2/3")
        XCTAssertEqual(s.gauges[0].fraction, 0.375, accuracy: 0.0001)        // (4 + 2) of 16 cores
        XCTAssertEqual(s.gauges[1].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(s.gauges[2].fraction, 0.3, accuracy: 0.0001)          // (50 + 10) of 200
        XCTAssertEqual(s.items.map(\.title), ["dns", "web", "spare"])
        XCTAssertEqual(s.stats.first?.value, "2/2 online")
    }

    func testTrueNAS() throws {
        let info = try json(#"{"hostname": "nas", "version": "TrueNAS-SCALE-24.10.2", "uptime_seconds": 200000, "physmem": 34359738368, "loadavg": [2.0, 1.0, 0.5], "cores": 8}"#)
        let pools = try json(#"[{"name": "tank", "status": "ONLINE", "healthy": true, "size": 1000, "allocated": 600}, {"name": "fast", "status": "DEGRADED", "healthy": false, "size": 100, "allocated": 10}]"#)
        let s = ServiceAPI.parseTrueNAS(info: info, pools: pools)
        XCTAssertEqual(s.headline, "Degraded")
        XCTAssertEqual(s.caption, "nas")
        XCTAssertEqual(s.gauges[0].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(s.gauges[1].fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(s.isOn, false)
    }

    func testUnraid() throws {
        let info = try json(#"{"info": {"os": {"hostname": "tower"}, "cpu": {"brand": "Ryzen 7"}}}"#)
        let array = try json(#"{"array": {"state": "STARTED", "capacity": {"kilobytes": {"free": "750", "used": "250", "total": "1000"}}}}"#)
        let metrics = try json(#"{"metrics": {"cpu": {"percentTotal": 12.0}, "memory": {"percentTotal": 50.0}}}"#)
        let containers = try json(#"[{"id": "1", "names": ["/plex"], "state": "RUNNING"}, {"id": "2", "names": ["/old"], "state": "EXITED"}]"#)
        let s = ServiceAPI.parseUnraid(info: info, array: array, metrics: metrics, containers: containers)
        XCTAssertEqual(s.headline, "Started")
        XCTAssertEqual(s.caption, "tower")
        XCTAssertEqual(s.gauges.map(\.label), ["CPU", "Memory", "Array"])
        XCTAssertEqual(s.gauges[2].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(s.stats.first?.value, "1/2 running")
        XCTAssertEqual(s.isOn, true)
    }

    func testGlances() throws {
        let s = ServiceAPI.parseGlances(
            cpu: try json(#"{"total": 23.7}"#),
            mem: try json(#"{"percent": 61.0, "total": 16000000000, "used": 9760000000}"#),
            fs: try json(#"[{"mnt_point": "/boot", "percent": 30, "size": 500, "used": 150}, {"mnt_point": "/", "percent": 45, "size": 1000, "used": 450}]"#),
            load: try json(#"{"min1": 0.5, "min5": 0.4, "min15": 0.3}"#),
            uptime: try json(#""3 days, 4:05:06""#),
            system: try json(#"{"hostname": "box"}"#))
        XCTAssertEqual(s.headline, "24%")
        XCTAssertEqual(s.caption, "CPU · box")
        XCTAssertEqual(s.gauges.map(\.label), ["CPU", "Memory", "Disk /"])
        XCTAssertEqual(s.stats.first { $0.label == "Uptime" }?.value, "3 days, 4:05:06")
    }

    func testDockerContainersRunningFirst() throws {
        let j = try json(#"[{"Id": "b", "Names": ["/zeta"], "State": "running", "Status": "Up 2 hours"}, {"Id": "a", "Names": ["/alpha"], "State": "exited", "Status": "Exited (0)"}, {"Id": "c", "Names": ["/beta"], "State": "running", "Status": "Up 1 minute"}]"#)
        let s = ServiceAPI.parseContainers(j, idKey: "Id", namesKey: "Names", stateKey: "State", statusKey: "Status", imageKey: "Image")
        XCTAssertEqual(s.items.map(\.title), ["beta", "zeta", "alpha"])
        XCTAssertEqual(s.headline, "2")
        XCTAssertEqual(s.caption, "of 3 running")
    }

    func testHomeAssistantEntities() throws {
        let light = HomeAssistant.parse(try json(#"{"entity_id": "light.kitchen", "state": "on", "attributes": {"friendly_name": "Kitchen", "brightness": 128}}"#))
        XCTAssertEqual(light.headline, "On")
        XCTAssertEqual(light.caption, "Kitchen")
        XCTAssertEqual(light.isOn, true)
        XCTAssertEqual(light.symbol, "lightbulb.fill")
        XCTAssertEqual(light.gauges.first?.fraction ?? 0, 128.0 / 255, accuracy: 0.001)

        let temp = HomeAssistant.parse(try json(#"{"entity_id": "sensor.office", "state": "21.46", "attributes": {"unit_of_measurement": "°C", "device_class": "temperature"}}"#))
        XCTAssertEqual(temp.headline, "21°C")
        XCTAssertNil(temp.isOn)
        XCTAssertEqual(temp.symbol, "thermometer.medium")

        let script = HomeAssistant.parse(try json(#"{"entity_id": "script.movie_time", "state": "off", "attributes": {}}"#))
        XCTAssertNil(script.isOn, "Scripts run; they don't show on/off")

        XCTAssertEqual(HomeAssistant.service(for: "light")?.name, "toggle")
        XCTAssertEqual(HomeAssistant.service(for: "automation")?.name, "trigger")
        XCTAssertEqual(HomeAssistant.service(for: "lock", state: "locked")?.name, "unlock")
        XCTAssertNil(HomeAssistant.service(for: "sensor"))
        XCTAssertEqual(HomeAssistant.domain("binary_sensor.front_door"), "binary_sensor")
    }

    func testUnixSocketReplyParsing() {
        let plain = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[1,2]".utf8)
        let r = UnixSocketHTTP.parse(plain)
        XCTAssertEqual(r?.status, 200)
        XCTAssertEqual(r.map { String(decoding: $0.data, as: UTF8.self) }, "[1,2]")
        XCTAssertEqual(r?.headers["content-type"], "application/json")

        let chunked = Data("HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(UnixSocketHTTP.parse(chunked).map { String(decoding: $0.data, as: UTF8.self) }, "Wikipedia")
        XCTAssertNil(UnixSocketHTTP.parse(Data("garbage".utf8)))
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.count(950), "950")
        XCTAssertEqual(Fmt.count(1_500), "1.5k")
        XCTAssertEqual(Fmt.count(25_000), "25k")
        XCTAssertEqual(Fmt.count(2_500_000), "2.5M")
        XCTAssertEqual(Fmt.duration(90_000), "1d 1h")
        XCTAssertEqual(Fmt.duration(3_900), "1h 5m")
        XCTAssertEqual(Fmt.percent(0.123), "12%")
        XCTAssertEqual(Fmt.speed(1_500), "1.5 Gbps")
        XCTAssertNotNil(Fmt.isoDate("2030-01-02T03:04:05.123Z"))
        XCTAssertNotNil(Fmt.isoDate("2030-01-02"))
        XCTAssertEqual(Fmt.query("a b&c=d"), "a%20b%26c%3Dd")
    }

    func testJSONIsForgiving() throws {
        let j = try json(#"{"n": "42", "b": 1, "s": 7, "t": true}"#)
        XCTAssertEqual(j["n"].int, 42)
        XCTAssertEqual(j["b"].bool, true)
        XCTAssertEqual(j["s"].string, "7")
        XCTAssertNil(j["t"].string, "Booleans aren't strings")
        XCTAssertFalse(j["missing"]["deeper"].exists)
        XCTAssertTrue(j["missing"].array.isEmpty)
    }
}

// MARK: - Hot corner

final class HotCornerSettingTests: XCTestCase {
    func testToggleIsOptInAndSaved() throws {
        XCTAssertFalse(AppSettings().hotCornerToggles)
        let on = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hotCorner": true, "hotCornerToggles": true}"#.utf8))
        XCTAssertTrue(on.hotCorner)
        XCTAssertTrue(on.hotCornerToggles)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(back.hotCornerToggles)
    }
}

// MARK: - Desktop picture

final class DesktopPictureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mt-desktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func png(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testPlainPictureIsUsedAsIs() throws {
        let pic = try png("Beach.png")
        XCTAssertEqual(DesktopPicture.expand(pic).first, pic)
        XCTAssertTrue(DesktopPicture.isUsable(pic))
        XCTAssertFalse(DesktopPicture.isUsable(dir), "A folder isn't a picture")
    }

    func testShuffleFolderGivesAPicture() throws {
        let pic = try png("one.png")
        XCTAssertEqual(DesktopPicture.expand(dir).first?.lastPathComponent, pic.lastPathComponent)
    }

    func testDescriptionFilePointsAtArtwork() throws {
        let art = try png("Art.png")
        let madesktop = dir.appendingPathComponent("Thing.madesktop")
        let plist: [String: Any] = ["thumbnailPath": art.path, "name": "Thing"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: madesktop)
        XCTAssertEqual(DesktopPicture.expand(madesktop).first, art)
    }

    func testStorePicksMostRecentDesktopAndReadsEncodedConfiguration() throws {
        let old = try png("old.png"), new = try png("new.png")
        let config = try PropertyListSerialization.data(fromPropertyList: ["url": ["relative": new.absoluteString]], format: .binary, options: 0)
        let store: [String: Any] = [
            "AllSpacesAndDisplays": ["Desktop": ["LastSet": Date(timeIntervalSince1970: 100),
                                                 "Content": ["Choices": [["Files": [["relative": old.absoluteString]]]]]]],
            "Displays": ["ABC": ["Desktop": ["LastSet": Date(timeIntervalSince1970: 200),
                                             "Content": ["Choices": [["Configuration": config, "Provider": "com.apple.wallpaper.choice.image"]]]]]],
        ]
        XCTAssertEqual(DesktopPicture.candidates(fromStore: store).first?.lastPathComponent, new.lastPathComponent)
    }

    func testAerialsFoundByAssetIDVideoFirst() throws {
        let id = "8D04D2D9-A1B2-4C3D-8E9F-001122334455"
        let sub = dir.appendingPathComponent("Customer/4KSDR240FPS")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("\(id).mov"))
        _ = try png("asset-preview-\(id.lowercased()).png")
        let found = DesktopPicture.aerialFiles(ids: [id], roots: [dir.path])
        XCTAssertEqual(found.first?.pathExtension, "mov")
        XCTAssertEqual(found.count, 2)
    }

    func testSystemPicturesMatchByName() throws {
        _ = try png("Sequoia Light.png")
        _ = try png("Sonoma.png")
        XCTAssertEqual(DesktopPicture.systemPictures(matching: "sequoia", folders: [dir.path]).map(\.lastPathComponent), ["Sequoia Light.png"])
        XCTAssertTrue(DesktopPicture.systemPictures(matching: "ab", folders: [dir.path]).isEmpty, "Too short to match safely")
    }
}

final class BackgroundStyleTests: XCTestCase {
    func testRemovedDesktopBackgroundFallsBackToColor() throws {
        XCTAssertEqual(BackgroundStyle.allCases, [.color, .media, .live])
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(##"{"backgroundStyle": "desktop", "background": "#112233"}"##.utf8))
        XCTAssertEqual(s.backgroundStyle, .color)
    }
}

// MARK: - 1.12 pre-release hardening

final class HardeningTests: XCTestCase {
    func testLocalHostsAreRecognised() {
        for host in ["localhost", "nas", "192.168.1.10", "10.0.0.5", "172.20.1.1", "127.0.0.1", "100.101.102.103",
                     "169.254.3.4", "plex.local", "pihole.lan", "router.home.arpa", "box.internal", "mac.tail1234.ts.net",
                     "fd12:3456::1", "::1", "fe80::1"] {
            XCTAssertTrue(Integration.isLocalHost(host), host)
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "2001:db8::1", "plex.mydomain.net"] {
            XCTAssertFalse(Integration.isLocalHost(host), host)
        }
    }

    func testPlainHTTPToTheInternetIsFlagged() {
        XCTAssertTrue(Integration(kind: .sonarr, url: "http://sonarr.example.com").sendsSecretInsecurely)
        XCTAssertTrue(Integration(kind: .sonarr, url: "sonarr.example.com:8989").sendsSecretInsecurely, "no scheme means http")
        XCTAssertFalse(Integration(kind: .sonarr, url: "https://sonarr.example.com").sendsSecretInsecurely)
        XCTAssertFalse(Integration(kind: .sonarr, url: "http://192.168.1.10:8989").sendsSecretInsecurely)
        XCTAssertFalse(Integration(kind: .sonarr, url: "nas.lan:8989").sendsSecretInsecurely)
    }

    func testUsernameRequirement() {
        XCTAssertTrue(ServiceKind.proxmox.usernameRequired)
        XCTAssertTrue(ServiceKind.beszel.usernameRequired)
        XCTAssertTrue(ServiceKind.opnsense.usernameRequired)
        XCTAssertFalse(ServiceKind.glances.usernameRequired, "Glances only asks when password-protected")
        XCTAssertFalse(ServiceKind.plex.usernameRequired)
        for kind in ServiceKind.allCases where kind.usernameRequired { XCTAssertNotNil(kind.usernameLabel, kind.title) }
    }

    func testPathSegmentsCantChangeTheRequest() {
        XCTAssertEqual(Fmt.segment("light.kitchen"), "light.kitchen")
        XCTAssertEqual(Fmt.segment("abc123def"), "abc123def")
        XCTAssertFalse(Fmt.segment("../config?x=1#y").contains("/"))
        XCTAssertFalse(Fmt.segment("../config?x=1#y").contains("?"))
        XCTAssertFalse(Fmt.segment("../config?x=1#y").contains("#"))
        XCTAssertEqual(Fmt.segment("a b"), "a%20b")
    }

    func testDockerSocketRequestsAreChecked() {
        XCTAssertTrue(UnixSocketHTTP.isSafeRequest(method: "GET", target: "/containers/json?all=1"))
        XCTAssertTrue(UnixSocketHTTP.isSafeRequest(method: "POST", target: "/containers/abc/restart"))
        XCTAssertFalse(UnixSocketHTTP.isSafeRequest(method: "DELETE", target: "/containers/abc"))
        XCTAssertFalse(UnixSocketHTTP.isSafeRequest(method: "GET", target: "/x HTTP/1.0\r\nHost: y"))
        XCTAssertFalse(UnixSocketHTTP.isSafeRequest(method: "GET", target: "containers"))
    }

    func testSelfSignedTrustIsLimitedToTheServicesOwnHost() {
        var i = Integration(kind: .proxmox, url: "https://pve.lan:8006")
        i.allowSelfSigned = true
        XCTAssertTrue(ServiceClient.trustsSelfSigned(i, host: "pve.lan"))
        XCTAssertTrue(ServiceClient.trustsSelfSigned(i, host: "PVE.lan"))
        XCTAssertFalse(ServiceClient.trustsSelfSigned(i, host: "image.tmdb.org"))
        i.allowSelfSigned = false
        XCTAssertFalse(ServiceClient.trustsSelfSigned(i, host: "pve.lan"))
    }

    func testRedirectToAnotherHostDropsCredentials() {
        var request = URLRequest(url: URL(string: "https://elsewhere.example/poster.jpg")!)
        request.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        let away = ServiceClient.redirect(request, from: URL(string: "http://sonarr.lan:8989/api/v3/queue"))
        XCTAssertNil(away.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(away.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(away.url, request.url)

        var same = URLRequest(url: URL(string: "https://sonarr.lan/api/v3/queue")!)
        same.setValue("secret", forHTTPHeaderField: "X-Api-Key")
        let kept = ServiceClient.redirect(same, from: URL(string: "http://sonarr.lan/api/v3/queue"))
        XCTAssertEqual(kept.value(forHTTPHeaderField: "X-Api-Key"), "secret", "http → https on the same server keeps working")
    }

    func testNewsLinksMustBeWebAddresses() {
        XCTAssertNotNil(FeedDelegate.safeLink("https://www.bbc.co.uk/news/1"))
        XCTAssertNotNil(FeedDelegate.safeLink("  http://example.com/a  "))
        XCTAssertNil(FeedDelegate.safeLink("file:///Applications/Calculator.app"))
        XCTAssertNil(FeedDelegate.safeLink("x-apple.systempreferences:com.apple.preference.security"))
        XCTAssertNil(FeedDelegate.safeLink("javascript:alert(1)"))
        XCTAssertNil(FeedDelegate.safeLink(""))
    }

    func testWallpaperNamesStayInTheWallpapersFolder() {
        XCTAssertEqual(Wallpapers.importedCopy("1a2b3c4d-Beach.jpg")?.deletingLastPathComponent().standardizedFileURL,
                       Wallpapers.directory.standardizedFileURL)
        XCTAssertNil(Wallpapers.importedCopy("../layout.json"))
        XCTAssertNil(Wallpapers.importedCopy(".."))
        XCTAssertNil(Wallpapers.url(for: "../../Documents/x.png"))
        XCTAssertEqual(Wallpapers.url(for: "/Users/me/Pictures/x.png")?.path, "/Users/me/Pictures/x.png")
    }

    func testHandEditedSettingsAreClampedToTheSliders() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"tileScale": 9, "wallpaperDim": 1}"#.utf8))
        XCTAssertEqual(s.tileScale, 1.5)
        XCTAssertEqual(s.wallpaperDim, 0.7)
        let low = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"tileScale": 0}"#.utf8))
        XCTAssertEqual(low.tileScale, 0.8)
    }
}
