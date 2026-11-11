# Privacy policy

This policy covers **MacTiles** (the free release on GitHub) and **meTiles** (the same app on the Mac App Store).

## The short version

The app collects nothing. There are no accounts, no analytics, no advertising, no tracking and no servers of ours. Nothing you do in the app is sent to the developers.

## What stays on your Mac

- Your tiles, groups and settings, in the app's own folder on your Mac.
- Copies of wallpapers you choose and icons of websites you pin, in the same folder.
- Passwords, tokens and API keys for services you connect, in your macOS Keychain.

## What the app connects to, and only when you use the feature

| Connection | When | What it receives |
|---|---|---|
| [Open-Meteo](https://open-meteo.com) (weather) | Weather tile, and when you look up a city or ZIP / postal code | The city or postal code you type, then that place's coordinates |
| News feeds you choose (default: BBC News) | News tiles | An ordinary request for the feed |
| Websites you pin as web tiles | When the tile is added or its icon refreshed | An ordinary request for the page and its icon |
| Google's favicon service | Only if a pinned site's own icon can't be found | That site's domain name |
| Services you connect (Plex, Pi-hole, Home Assistant…) | While their tiles are on screen | Requests signed with the key or password you entered, sent only to the address you entered |

These are requests from your Mac straight to those services; their own privacy policies apply to them.

## Permissions macOS may ask for

- **Calendars** — only if you turn on events for the Calendar tile; events are read on your Mac and never sent anywhere.
- **Local Network** — to reach the services you connect on your home network.
- **Pictures** and any folder you choose — read only, for the Photos tile and wallpapers.

## Contact

Questions about privacy: open an issue at the project's GitHub repository, or report privately as described in [SECURITY.md](SECURITY.md).
