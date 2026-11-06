# Changelog

All notable changes to MacTiles. Each release's section becomes its GitHub release notes.

## [1.12.0] - 2026-11-05

A pre-release review of the whole app: bug fixes, security hardening and consistency.

### Fixed
- **Live tiles stay current while Start sits on the desktop.** With *Keep Start on the desktop* on, Start can stay on screen for hours, but weather, news, calendar events and the Desktop tile only refreshed when Start was hidden and shown again. They now refresh in the background every minute (each at its own pace), and when you open Start.
- **Plain-HTTP services on home DNS names** (like `http://nas.lan:8096`) and plain-HTTP news feeds could be blocked by macOS: the app's network settings combined two options in a way that made macOS ignore one of them. Only addresses you enter are contacted.
- **Changing the news feed or Photos folder** in Settings now takes effect right away (press Return after typing a feed), not the next time Start opens.
- **The last layout change is no longer lost on quit or update.** Changes were saved a moment after they happened; quitting, or the installer closing MacTiles during an upgrade, could drop the latest one.
- **Keychain hiccups don't leave a service signed out.** If the Keychain was locked or its prompt was dismissed, the service stayed signed out until MacTiles restarted; it's now asked again on the next update. If the Keychain refuses to save a key, the editor says so instead of failing silently.
- Clicking a tile whose app was deleted or moved beeps and leaves Start open, instead of closing Start and doing nothing.
- *Show Desktop* also closes an open Add/Edit tile panel.
- ComfyUI's live connection closes as soon as Start is hidden, instead of up to 90 seconds later.
- A news feed that fails isn't retried more than every 5 minutes.

### Security
- **News headlines only open web links.** A feed could otherwise make the News tile open a local file or launch an app through a custom link type.
- **Self-signed certificates are trusted only for the service's own server**, not for other sites it links to (posters) or redirects to.
- **Keys and tokens aren't forwarded on redirects to another server.**
- **Web tile icons are fetched only over http(s)**, and icon and manifest downloads are size-limited; a page can't point MacTiles at a local file.
- Values used in service addresses (Home Assistant entity IDs, Docker container IDs, Jellyfin item IDs) are percent-encoded, and requests to Docker's local socket are checked, so a value can't change the request.
- A hand-edited wallpaper file name can't reach outside MacTiles' Wallpapers folder.
- `layout.json` and its folder are now readable by your account only.
- The integration editor warns when a key or password would be sent over plain HTTP to an address that isn't on your local network.
- *Uninstall MacTiles… → Also delete my tiles, settings and saved service keys* now also removes MacTiles' Keychain items.
- Release workflow: the notary API key file is deleted when the job ends.

### Changed
- Settings values in a hand-edited `layout.json` are clamped to the same ranges as the Settings sliders (tile size, wallpaper dim).
- Keychain items are labelled with the service's name (*MacTiles: Plex*), so they're easy to find in Keychain Access.
- The right-click menu lists *Add Live Tile*, *Add Web Tile…*, *Add Service Tile…* in the same order everywhere.
- The web tile panel says a non-web link (`vnc://`, `smb://`…) opens in its own app, not your browser.
- The Weather tile and Settings credit Open-Meteo, as its data licence (CC BY 4.0) requires: in the tile's tooltip and right-click menu, and under Settings → Live tiles.

### Removed
- Leftover support for the app's pre-release name (Tessera): moving its old layout file and closing a running copy. The installer no longer closes other apps named Tessera.

### Project
- Ready to publish on GitHub: contributing guide, security policy (private vulnerability reporting), issue and pull-request templates, a *Privacy and third-party services* section in the README, and `Scripts/privacy-check.sh`, which looks for personal data and secrets before you push and runs in CI. `.gitignore` now blocks signing certificates and API key files.

## [1.11.0] - 2026-11-05

### Added
- **ComfyUI** integration (new *AI* group): a *Generation* tile with live job progress (step by step, from ComfyUI's WebSocket), how many jobs are queued, VRAM and RAM use, the GPU name and ComfyUI version, and your latest images. With the ComfyUI-Crystools custom node installed it also shows GPU load, GPU temperature and CPU. Right-click to interrupt the current job or clear the queue. Updates every 2 seconds while Start is on screen; no API key needed.
- **Beszel** integration (Servers): a *Systems* tile showing how many systems are up, average CPU / memory / disk, the busiest system and each system's numbers — or pick one system in the tile editor for its full stats (CPU, memory, disk, GPU, temperature, network, load, uptime, agent version). Signs in with your Beszel email and password (user or superuser).

### Changed
- Service tiles are checked every second for anything due (each widget still keeps its own pace), so fast widgets like ComfyUI feel live.

## [1.10.2] - 2026-11-04

### Removed
- The **Desktop** option under Settings → Background. If you had it selected, Start goes back to your background color; Color, Picture or Video, and Live are unchanged. The Desktop live tile is still available.

## [1.10.1] - 2026-11-04

### Fixed
- **Desktop background shows your real wallpaper.** macOS only reports plain picture files reliably; Apple's built-in (Sonoma, Sequoia…), dynamic and aerial wallpapers, and photo shuffles came back as a placeholder, a description file or a folder, so Start showed the wrong picture or none. MacTiles now also reads the wallpaper settings macOS keeps for System Settings and finds the actual artwork. Aerials play as moving video behind your tiles (pausing like other animated wallpapers), with a still if the video hasn't been downloaded. Anything else falls back to a Quick Look preview.
- The Desktop live tile uses the same lookup.

### Added
- Settings → Background → Desktop shows a preview of the wallpaper MacTiles found, with Refresh and Wallpaper Settings… buttons. The background updates when you change your wallpaper and come back to Start.

## [1.10.0] - 2026-11-04

### Added
- **Hot corner as a toggle** (Settings → Opening Start → *Corner also closes Start and shows the desktop when Start is open*). With it on, moving the pointer into the bottom-left corner opens Start, and doing it again while Start is open puts Start away and shows the desktop. It fires once per visit, so the pointer has to leave the corner before it acts again.

### Fixed
- The hot corner now also notices the pointer while Start is in front (previously it only watched other apps).

## [1.9.2] - 2026-11-04

### Added
- **OPNsense interface traffic.** The Firewall Health tile now leads with live WAN download speed (upload underneath) and a sparkline of the last few minutes. Wide tiles list each interface with ↓/↑ speeds; large tiles add gateways, memory, firewall states and more. Speeds appear on first look and refresh every 10 seconds while Start is on screen.

### Fixed
- An OPNsense key without every privilege no longer leaves the tile nearly empty: each part (traffic, gateways, memory, states, uptime) is fetched on its own, and the tile shows whatever the key can read.

## [1.9.1] - 2026-11-04

### Added
- **OPNsense** integration (Network & Home): a *Firewall Health* tile with gateways online (each with latency and packet loss), firewall states against the limit, memory, load, uptime and version. Connect it with an API key and secret from System → Access → Users. Self-signed certificates are allowed by default, as OPNsense usually has one.

## [1.9.0] - 2026-11-04

### Added
- **Service tiles** — homelab integrations like Homarr's widgets, as a new kind of tile. MacTiles talks to each service directly (no Homarr needed):
  - Media: **Plex**, **Jellyfin** and **Emby** (now playing with progress, or recently added with posters), **Sonarr** and **Radarr** (upcoming, queue, missing), **Overseerr / Jellyseerr** (pending and recent requests).
  - Network & home: **Pi-hole** (v6, and v5) and **AdGuard Home** (queries and % blocked; pause blocking for 1 minute to "until I resume", or resume, from the tile's menu), **Home Assistant** (any entity — click a light, switch, fan, cover or media player to toggle it, a script, scene, button or automation to run it), **UniFi Network** (clients, devices, latency, speed, gateway load).
  - Servers: **Proxmox VE**, **TrueNAS**, **Unraid** and **Glances** (CPU, memory, storage, uptime), and **Docker** (containers, with start / stop / restart) — on this Mac via Docker Desktop, OrbStack, Colima or Rancher Desktop, or a remote Docker API.
- **Settings → Integrations**: add, edit, test and remove service connections. Passwords, tokens and API keys are kept in the Keychain, not in layout.json. Self-signed certificates are accepted only where you allow them.
- **Add Service Tile…** in the right-click menu, the ⋯ menu and the menu-bar icon: pick a service, what to show and (for Home Assistant) an entity.
- Service tiles flip through posters and items like live tiles, show their numbers in all four sizes, poll only while Start is on screen, and keep their last data (with a small warning sign) if a service stops answering.

### Changed
- MacTiles now asks for Local Network access (the first time it talks to a service on your network) and allows plain-HTTP connections, which homelab services usually use.

## [1.8.1] - 2026-11-02

### Added
- Right-click the tile of a running app (the ones with the dot) — or the app in All apps — to **Quit** it. The app quits normally, so it can still ask you to save documents.
- **Force Quit…** is there too, for apps that aren't responding, with a confirmation first because unsaved changes are lost.

## [1.8.0] - 2026-11-02

### Added
- **Running indicator**: a small glowing dot on the tile of any app that's running (bottom-right on larger tiles, bottom-center on small ones), like the Dock. It appears and disappears as apps open and quit, and running apps get the same dot in All apps. Turn it off in Settings → Start screen.

## [1.7.2] - 2026-11-01

### Changed
- Removed the diagonal light streak from glass tiles; the gloss, rim, depth, pointer glint and hover shimmer stay.

## [1.7.1] - 2026-11-01

### Improved
- Glass tiles are glossier and shinier:
  - a curved gloss reflection across the top of each pane and a diagonal light streak,
  - a polished rim that catches the light at the top-left corner, with a second inner edge for thickness,
  - the tint deepens toward the bottom, with a little shade pooling there, so panes look thick,
  - a highlight that follows your pointer across the tile, and a quick shimmer when you hover (skipped with Reduce Motion).

## [1.7.0] - 2026-11-01

### Added
- **Tile finish** (Settings → Start screen): **Flat** (the classic Metro look) or **Glass** — translucent, frosted tiles that let your wallpaper show through, with a light sheen and a bright top edge. A **Glass tint** slider runs from clear to strongly colored.
- **Tile shadow**: None, Subtle, Medium or Strong, so tiles lift off the background. The shadow deepens slightly when you hover over a tile.

## [1.6.1] - 2026-11-01

### Improved
- Web tiles now find and use the website's own icon far more reliably, and pick the sharpest one available:
  - follows redirects (apple.com → www.apple.com) before looking for icons,
  - reads the site's web app manifest, where many sites keep their 192–512 px icons,
  - tries apple-touch-icon, declared favicons and the standard /favicon.ico, keeping the largest,
  - falls back to a public favicon service (which receives only the site's domain) when a site blocks direct requests.
- Icons saved by 1.6.0 are fetched again once, so existing web tiles get sharper icons too.
- Sites without an icon aren't re-checked on every redraw (retried after 30 minutes, or right away with Refresh Icon).

## [1.6.0] - 2026-11-01

### Added
- **Web tiles**: pin any web address to Start. Clicking the tile opens it in your default browser.
  - Add one from the right-click menu, the ••• menu or the menu-bar icon (**Add Web Tile…**). If you've copied an address, it's filled in for you.
  - Or drag a link — or the address from your browser's address bar — onto Start.
  - Tiles show the site's icon and page title (or a name you choose), and work in every size, color and shape.
  - Right-click a web tile to edit it, copy its link, or refresh its icon.
  - Icons and titles are kept on your Mac, so tiles look right offline.

## [1.5.0] - 2026-11-01

### Added
- **Wallpapers** for the Start screen (Settings → Start screen → Background):
  - **Color** — the solid colors you had before.
  - **Picture or Video** — any picture, an animated GIF (or animated PNG/HEIC/WebP), or a video (MP4, MOV, M4V) that loops silently. MacTiles keeps its own copy, so you can move or delete the original. A Dim slider keeps tiles readable.
  - **Live** — four animated wallpapers drawn by MacTiles (Aurora, Ribbons, Bokeh, Squares), tinted with any color you pick.
  - **Desktop** — your Mac's current desktop picture, like Windows 8.1's "show my desktop background on Start".
- Animated wallpapers pause when Start is hidden or covered, in Low Power Mode, and when Reduce Motion is on.
- **Change Wallpaper…** in the right-click menu.

## [1.4.0] - 2026-10-31

### Added
- **Move tile groups**: drag a group by its name to the left or right. The other groups slide aside as you drag, and the group's tiles move with it. You can also right-click a group name → Move Group Left / Move Group Right.

## [1.3.0] - 2026-10-31

### Added
- **Tile shape** setting (Settings → Start screen): **Square** (classic Windows 8), **Soft** (12 pt squircle corners) or **Round** (20 pt corners with wider gaps, like macOS widgets). Corners use Apple's continuous squircle curve, scale with tile size, and tiles animate when you switch.

## [1.2.0] - 2026-10-28

### Fixed
- Apps opened from MacTiles now get keyboard focus, whether you click a tile or type and press Return. MacTiles stays on the desktop behind them. (Since macOS 14, an app must explicitly hand focus to the app it opens.) The same applies to news links, Show in Finder and Show Desktop.

### Added
- Right-click any empty part of the launcher for a menu with **MacTiles Settings…**, Add Live Tile, All Apps and Show Desktop.

## [1.1.0] - 2026-10-28

### Changed
- The Start screen no longer shows a "Start" title.
- The search box is gone. Whenever MacTiles has focus, just start typing: what you type appears large at the top-left with a cursor, and the results replace the tiles. Delete erases a letter, ⌥Delete a word and ⌘Delete everything; Return opens the top result.

### Added
- Any background color: Settings has a color wheel (with a brightness slider for any shade) and a hex-code field, alongside the presets. Start updates live while you pick.

## [1.0.0] - 2026-10-28

### Added
- **macOS Installer package** (`MacTiles-1.0.0.pkg`): installs to Applications, closes and replaces a running copy, keeps your tiles, and opens MacTiles when it finishes. Turns away Intel Macs and macOS versions older than 14 with a clear message.
- Signed, notarized and stapled release builds (Developer ID, hardened runtime), plus a drag-to-Applications disk image and SHA-256 checksums.
- **Uninstall MacTiles…** in Settings: removes the login item, optionally your tiles and settings, and moves the app to the Trash.
- Build number shown in Settings.
- Automated tests and a tag-triggered release pipeline.

### Fixed
- Building from a folder synced by iCloud Drive (such as Documents) no longer fails code signing with "resource fork, Finder information, or similar detritus not allowed".

## [0.2.1] - 2026-10-28

### Fixed
- Newly installed, updated or deleted apps now show up in All apps and search within a few seconds, without relaunching MacTiles.

## [0.2.0] - 2026-10-27

### Changed
- Renamed from Tessera to **MacTiles**. Your existing layout is carried over automatically.
- Start now stays on the desktop behind your apps, like Windows 8, instead of disappearing after you launch something. The Dock icon works as a Start button.

### Added
- Opens at login after it's installed in Applications.
- Offers to move itself into Applications on first launch.
- Settings to keep Start on the desktop and to show the Dock icon.

## [0.1.0] - 2026-10-27

- First version (as Tessera): Windows 8-style Start screen, tile groups, All apps, type-to-search, and Clock, Calendar, Weather, System, Battery, Photos, News and Desktop live tiles.
