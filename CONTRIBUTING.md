# Contributing to MacTiles

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with the **Bug report** template. The most useful details are:

- the MacTiles version (Settings shows it in the bottom-right corner) and your macOS version
- what you did, what you expected and what happened instead
- for a service tile, which service and version it is — but **never paste API keys, tokens, passwords or your public IP address**

Security problems go through [SECURITY.md](SECURITY.md) instead, not a public issue.

## Building

You need a Mac with Apple silicon, macOS 14 or later, and Xcode 15.3+ (or the Command Line Tools with Swift 5.10+).

```sh
make test       # unit tests
make run        # build and open MacTiles
make install    # build and copy to /Applications
```

## Pull requests

- Keep it light: no third-party dependencies, and nothing that polls while Start can't be seen.
- Add or update tests in `Tests/MacTilesTests` for parsing and logic changes. Parsers for services are pure functions so they can be tested with sample JSON — please use made-up data (`example.com`, `192.168.1.10`), not output copied from your own servers.
- Add a line to the top of [CHANGELOG.md](CHANGELOG.md) under an *Unreleased* heading.
- User-facing text is plain and short; match the tone of the existing Settings and menus.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
