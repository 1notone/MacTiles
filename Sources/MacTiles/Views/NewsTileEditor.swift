import SwiftUI

struct NewsTileDraft: Identifiable, Equatable {
    let id = UUID()
    var tileID: UUID?       // nil = a new News tile
    var feed: String
    var name: String
}

/// A Metro-style panel over Start for choosing a News tile's source.
/// Accepts a feed address or a site's address (its feed is found for you).
@MainActor
struct NewsTileEditor: View {
    let draft: NewsTileDraft
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var hub: LiveHub
    @State private var feed = ""
    @State private var name = ""
    @State private var message = ""
    @State private var isError = false
    @State private var checking = false
    @State private var saveAnyway = false
    @FocusState private var focus: Field?

    enum Field { case feed, name }

    private var isEditing: Bool { draft.tileID != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 16) {
                Text(isEditing ? "Change news feed" : "Add a news tile")
                    .font(.system(size: 28, weight: .light))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Feed or website").font(.system(size: 12, weight: .semibold)).opacity(0.75)
                        Spacer()
                        Menu("Popular feeds") {
                            ForEach(NewsFeeds.popular, id: \.url) { preset in
                                Button(preset.name) { choose(preset.url, name: preset.name) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.system(size: 12))
                    }
                    input($feed, prompt: "feeds.bbci.co.uk/news/world/rss.xml or theverge.com", field: .feed)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name (optional)").font(.system(size: 12, weight: .semibold)).opacity(0.75)
                    input($name, prompt: "Shown on the tile; otherwise the feed's own name", field: .name)
                }
                Text(message.isEmpty ? "Any RSS or Atom feed works. Clicking the tile opens the headline it's showing." : message)
                    .font(.system(size: 12))
                    .foregroundStyle(isError ? Color(hex: "#FF8A80") : .white)
                    .opacity(isError ? 1 : 0.6)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", action: cancel)
                        .buttonStyle(MetroButtonStyle(filled: false))
                    Button(saveAnyway ? (isEditing ? "Save Anyway" : "Add Anyway") : (isEditing ? "Save" : "Add"), action: save)
                        .buttonStyle(MetroButtonStyle(filled: true))
                        .disabled(checking)
                }
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(width: 520)
            .background(Color(hex: "#1D1D1D"))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .onAppear {
            feed = draft.feed
            name = draft.name
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                focus = .feed
            }
        }
        .onChange(of: feed) { _, _ in
            saveAnyway = false
            if isError { message = ""; isError = false }
        }
        .onExitCommand(perform: cancel)
    }

    private func input(_ text: Binding<String>, prompt: String, field: Field) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundColor(.white.opacity(0.35)))
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(focus == field ? 0.16 : 0.09))
            .focused($focus, equals: field)
            .onSubmit(save)
    }

    private func choose(_ url: String, name preset: String) {
        feed = url
        if name.isEmpty || NewsFeeds.popular.contains(where: { $0.name == name }) { name = preset }
    }

    private func save() {
        guard !checking else { return }
        guard let url = WebLink.normalize(feed), WebLink.isFetchable(url) else {
            show("That doesn't look like a web address. Try something like theverge.com.", error: true)
            focus = .feed
            return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if saveAnyway { return commit(url.absoluteString, title: title) }
        checking = true
        show("Checking the feed…", error: false)
        Task { @MainActor in
            defer { checking = false }
            do {
                let result = try await FeedParser.fetch(url.absoluteString)
                commit(result.feedURL, title: title)
            } catch {
                show("Couldn't find a news feed at that address. Check it, or choose one from Popular feeds.", error: true)
                saveAnyway = true
            }
        }
    }

    private func commit(_ feedURL: String, title: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let id = draft.tileID {
                store.update(id) {
                    $0.url = feedURL
                    $0.title = title.isEmpty ? nil : title
                }
            } else {
                store.addNews(feed: feedURL, title: title.isEmpty ? nil : title)
            }
        }
        hub.liveSettingsChanged(active: launcher.tilesLive)
        launcher.newsDraft = nil
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }

    private func cancel() { launcher.newsDraft = nil }
}
