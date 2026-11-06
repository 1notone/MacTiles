import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Packing

/// Packs tiles the way Windows 8.1 does: each group is a run of 4-unit-wide columns
/// ("bands"); tiles fill a band top-to-bottom, left-to-right, back-filling gaps with
/// small tiles, and spill into the next band when it's full.
enum Packer {
    struct Placed: Identifiable {
        let tile: Tile
        let x: Int
        let y: Int
        var id: UUID { tile.id }
    }

    struct Result {
        let items: [Placed]
        let width: Int
    }

    static let bandWidth = 4

    static func pack(_ tiles: [Tile], rows: Int) -> Result {
        var items: [Placed] = []
        var band = 0
        var grid = emptyGrid(rows)
        var right = 0

        for tile in tiles {
            let w = min(tile.size.units.w, bandWidth)
            let h = min(tile.size.units.h, rows)
            var spot: (x: Int, y: Int)? = nil
            while spot == nil {
                search: for y in 0...(rows - h) {
                    for x in 0...(bandWidth - w) where isFree(grid, x, y, w, h) {
                        spot = (x, y)
                        break search
                    }
                }
                if spot == nil {
                    band += 1
                    grid = emptyGrid(rows)
                }
            }
            let (x, y) = spot!
            for yy in y..<(y + h) { for xx in x..<(x + w) { grid[yy][xx] = true } }
            let gx = band * bandWidth + x
            items.append(Placed(tile: tile, x: gx, y: y))
            right = max(right, gx + w)
        }
        return Result(items: items, width: max(right, 2))
    }

    private static func emptyGrid(_ rows: Int) -> [[Bool]] {
        [[Bool]](repeating: [Bool](repeating: false, count: bandWidth), count: rows)
    }

    private static func isFree(_ g: [[Bool]], _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        for yy in y..<(y + h) {
            for xx in x..<(x + w) where g[yy][xx] { return false }
        }
        return true
    }
}

struct GroupLayout: Identifiable {
    let group: TileGroup
    let pack: Packer.Result
    let columnOffset: Int
    var id: UUID { group.id }

    static func build(_ groups: [TileGroup], rows: Int) -> [GroupLayout] {
        var offset = 0
        return groups.map { group in
            let pack = Packer.pack(group.tiles, rows: rows)
            let layout = GroupLayout(group: group, pack: pack, columnOffset: offset)
            offset += pack.width + 1
            return layout
        }
    }
}

// MARK: - Start screen

@MainActor
struct StartTilesView: View {
    let metrics: Metrics
    @EnvironmentObject private var store: LayoutStore

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: metrics.groupSpacing) {
                ForEach(GroupLayout.build(store.groups, rows: metrics.rows)) { layout in
                    GroupView(layout: layout, metrics: metrics)
                }
                NewGroupZone(metrics: metrics)
            }
            .padding(.leading, metrics.leftMargin)
            .padding(.trailing, 80)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .contextMenu { BackgroundMenu() }   // empty space between and beyond groups
    }
}

@MainActor
struct GroupView: View {
    let layout: GroupLayout
    let metrics: Metrics

    @EnvironmentObject private var store: LayoutStore
    @State private var editing = false
    @State private var draft = ""
    @State private var targeted = false
    @State private var hoveringHeader = false
    @FocusState private var nameFocused: Bool

    private var isDraggingThis: Bool { store.draggingGroupID == layout.group.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .frame(height: Metrics.groupTitleHeight - 10, alignment: .leading)
                // Drag a group by its name to move it left or right.
                .onDrag {
                    store.draggingGroupID = layout.group.id
                    store.draggingID = nil
                    return NSItemProvider(object: ("group:" + layout.group.id.uuidString) as NSString)
                } preview: {
                    GroupDragPreview(name: layout.group.displayName, count: layout.group.tiles.count)
                }
            ZStack(alignment: .topLeading) {
                ForEach(layout.pack.items) { placed in
                    TileView(tile: placed.tile, metrics: metrics, column: layout.columnOffset + placed.x)
                        .offset(x: CGFloat(placed.x) * metrics.step, y: CGFloat(placed.y) * metrics.step)
                }
            }
            .frame(width: metrics.span(layout.pack.width), height: metrics.span(metrics.rows), alignment: .topLeading)
            .background(Color.white.opacity(targeted ? 0.05 : 0))
            .contentShape(Rectangle())
            .onDrop(of: [.text, .fileURL, .url], isTargeted: $targeted) { providers in
                store.acceptDrop(providers, at: .endOf(layout.group.id))
            }
        }
        .opacity(isDraggingThis ? 0.45 : 1)
        .scaleEffect(isDraggingThis ? 0.97 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.15), value: isDraggingThis)
        .onChange(of: targeted) { _, isOn in
            if isOn, let dragging = store.draggingGroupID, dragging != layout.group.id {
                store.liveMoveGroup(dragging, to: layout.group.id)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if editing {
            TextField("Name group", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 240)
                .focused($nameFocused)
                .onSubmit(commit)
                .onAppear { nameFocused = true }
                .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
        } else {
            let name = layout.group.name
            Text(name.isEmpty ? "Name group" : name)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(name.isEmpty ? (hoveringHeader ? 0.45 : 0.12) : 0.9))
                .contentShape(Rectangle())
                .onHover { hoveringHeader = $0 }
                .onTapGesture(count: 2) { beginEditing() }
                .help("Drag to move this group · double-click to rename")
                .contextMenu {
                    Button("Rename Group") { beginEditing() }
                    Divider()
                    Button("Move Group Left") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.shiftGroup(layout.group.id, by: -1) }
                    }
                    .disabled(store.groups.first?.id == layout.group.id)
                    Button("Move Group Right") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.shiftGroup(layout.group.id, by: 1) }
                    }
                    .disabled(store.groups.last?.id == layout.group.id)
                    Divider()
                    Button("Remove Group") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.removeGroup(layout.group.id) }
                    }
                }
        }
    }

    private func beginEditing() {
        draft = layout.group.name
        editing = true
    }

    private func commit() {
        guard editing else { return }
        store.rename(layout.group.id, to: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        editing = false
    }
}

/// What follows the pointer while a group is dragged.
struct GroupDragPreview: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
            Text(name).font(.system(size: 15, weight: .medium))
            Text("\(count) tile\(count == 1 ? "" : "s")").font(.system(size: 12)).opacity(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.22))
    }
}

/// Drop a tile (or an app from Finder) past the last group to start a new group.
@MainActor
struct NewGroupZone: View {
    let metrics: Metrics
    @EnvironmentObject private var store: LayoutStore
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: Metrics.groupTitleHeight - 10)
            Rectangle()
                .strokeBorder(Color.white.opacity(targeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .frame(width: metrics.span(4), height: metrics.span(metrics.rows))
                .contentShape(Rectangle())
                .onDrop(of: [.text, .fileURL, .url], isTargeted: $targeted) { providers in
                    store.acceptDrop(providers, at: .newGroup)
                }
        }
    }
}

// MARK: - Entrance animation

/// Tiles fly in from the right in a column-staggered cascade each time Start opens.
@MainActor
struct Entrance: ViewModifier {
    let token: Int
    let column: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : 70)
            .onAppear { play() }
            .onChange(of: token) { _, _ in
                shown = false
                play()
            }
    }

    private func play() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shown = true
            return
        }
        let delay = min(0.45, Double(column) * 0.02)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(delay)) { shown = true }
        }
    }
}
