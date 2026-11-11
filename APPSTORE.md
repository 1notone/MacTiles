# meTiles on the Mac App Store

meTiles is the Mac App Store edition of MacTiles: the same code, built with `-DAPPSTORE` by
`make appstore`, sandboxed, and named meTiles (Apple's guidelines don't allow "Mac" as part of
an app's name). How to set up the account and upload a build is in
[RELEASING.md → Mac App Store (meTiles)](RELEASING.md#mac-app-store-metiles). This page has the
text for App Store Connect and what's different in this edition.

## What's different from MacTiles

| | meTiles (App Store) |
|---|---|
| Installing, updating, removing | Through the App Store; no "Move to Applications" or "Uninstall…" |
| Start at login | Off until you turn it on in Settings |
| Docker | Over the network (`http://host:2375`, or a docker-socket-proxy); not the socket on this Mac |
| Apps listed | `/Applications` and the system's apps (not `~/Applications`) |
| Quit / Force Quit on a running app's tile | Not available (the sandbox doesn't allow it) |
| Photos tile | Pictures works as is; another folder is chosen once in Settings |
| Desktop tile | Shows your wallpaper when it's a system picture or in Pictures |
| Settings | Kept in the app's sandbox folder. To bring your MacTiles layout across: Settings → **Import Layout…** (service keys need entering again) |

## App Store Connect

**Name:** meTiles
**Subtitle** (30 characters max): Live tile Start screen for Mac
**Category:** Utilities (secondary: Productivity)
**Price:** Free
**Privacy policy URL:** the link to PRIVACY.md in your GitHub repository
**Support URL:** your GitHub repository's Issues page
**App Privacy:** Data Not Collected
**Age rating:** 4+ (no objectionable content; it can open web links you add yourself)
**Export compliance:** uses only standard encryption (HTTPS) — already declared in the app (`ITSAppUsesNonExemptEncryption = NO`)

**Keywords** (100 characters max):
`launcher,start screen,tiles,live tiles,dashboard,homelab,app launcher,weather,widgets,plex,pihole`

**Promotional text:**
A full-screen Start screen of colourful, resizable tiles that come alive — weather, news, calendar, photos and your home server.

**Description:**

meTiles turns your Mac's apps into a full-screen Start screen of colourful tiles you can arrange, group and resize.

• Press ⌥ Space, or move to the bottom-left corner, to open Start; type to search every app.
• Live tiles: weather (by city or ZIP code), several news feeds, calendar, photos, clock, battery and system load.
• Web tiles for the sites you use most, with their own icons.
• Service tiles for your home lab: Plex, Jellyfin, Sonarr, Radarr, Overseerr, Pi-hole, AdGuard Home, Home Assistant, UniFi, OPNsense, Proxmox, TrueNAS, Unraid, Docker, Glances, Beszel and ComfyUI — now playing, downloads, DNS stats, CPU and more, right on the tile.
• Choose colours, glass or flat tiles, square or rounded corners, wallpapers, pictures, videos and animated backgrounds.
• Light and private: no account, no tracking, and passwords stay in your Keychain.

meTiles is open source (MIT). It's an independent project and isn't affiliated with Microsoft or with any of the services it connects to; their names are trademarks of their owners.

**What's New** (first release): First release on the Mac App Store.

## Notes for App Review

Paste into *App Review Information → Notes*:

> meTiles is a launcher: it shows your apps as tiles on a full-screen Start screen. Press Option-Space (or click the menu-bar icon) to open it.
>
> Network: weather comes from Open-Meteo and news from public RSS feeds. "Service tiles" connect only to servers the user adds in Settings → Integrations, usually on their home network and often over plain HTTP with self-signed certificates — that's why the app uses NSAllowsArbitraryLoads and asks for Local Network access. No sign-in is needed to review the app; service tiles are optional.
>
> The app doesn't start at login unless the user turns it on in Settings, and it doesn't collect any data.

**Screenshots:** at least one at 2880 × 1800 (or 2560 × 1600 / 1440 × 900 / 1280 × 800). Use made-up data, as for the README.
