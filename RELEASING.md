# Releasing MacTiles

A release is a signed, notarized **installer package** (`.pkg`) and **disk image** (`.dmg`), published on GitHub with checksums. Apple only lets apps from other Macs open without warnings if they're signed with a Developer ID and notarized, which needs an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year).

Without a membership you can still run `make release`. You get an unsigned package and disk image that work on your own Mac, but other Macs will block them.

---

## Fewer password prompts for your own builds

Builds you make yourself (`make install`) are signed **ad-hoc** by default: a throwaway signature that's different every time. To macOS each new build is a different app, so it asks for your password again before MacTiles can read its service keys from the Keychain, and it may forget the Local Network permission.

Fix it once with a free personal signing certificate (no Apple Developer account needed):

```sh
make signing-cert
```

It creates **MacTiles Local Signing** in your login keychain and asks for your password once, to trust it for code signing. From then on `make install` (and `make app` / `make run`) sign with it automatically, and macOS treats every new build as the same app:

- The first time the newly signed build reads your service keys, macOS asks once: enter your password and click **Always Allow**. After that, updates don't ask.
- If macOS asks whether `codesign` may use the key "MacTiles Local Signing" during a build, click **Always Allow** too.
- If a service tile shows a strange connection error right after you switch, toggle MacTiles off and on in **System Settings → Privacy & Security → Local Network** once.

The certificate never leaves your Mac and is only for your own builds — `make release` still produces ad-hoc (or, with `APP_IDENTITY`, Developer ID) packages for other people. To remove it: Keychain Access → login → My Certificates → **MacTiles Local Signing** → Delete. To build ad-hoc for a moment anyway: `APP_IDENTITY=- make install`.

## Publishing on GitHub (first time)

Do this once, from the project folder on your Mac. Nothing here needs your real name or personal email.

**1. Keep your email out of commits.** Every commit records a name and email, and anyone can read them. On GitHub, open **Settings → Emails**, turn on **Keep my email addresses private** and **Block command line pushes that expose my email**, and copy your no-reply address (`12345678+yourname@users.noreply.github.com`). Then, in the project folder:

```sh
git init -b main
git config user.name  "your-github-username"
git config user.email "12345678+yourname@users.noreply.github.com"
```

(These apply to this project only.)

**2. Check for anything personal.**

```sh
./Scripts/privacy-check.sh
```

It looks for real-looking email addresses, home folders, private keys, tokens and certificate names in everything that would be committed, and checks the email above. Example values like `example.com` and `192.168.1.10` are fine. It also runs on every push in GitHub Actions.

**3. Create the repository.** On GitHub: **+ → New repository**, name it `MacTiles`, make it **Public**, and leave *Add a README*, *.gitignore* and *license* unticked (they're already here). Then:

```sh
git add .
git commit -m "MacTiles 1.12.0"
git remote add origin https://github.com/your-github-username/MacTiles.git
git push -u origin main
```

**4. Repository settings** (on GitHub, under **Settings**):
- **General**: add a description (*Windows 8-style Start screen and Live Tiles for macOS*) and topics (`macos`, `launcher`, `swiftui`, `windows-8`, `live-tiles`, `homelab`).
- **Code security**: turn on **Private vulnerability reporting** (used by [SECURITY.md](SECURITY.md)) and **Dependabot alerts**. Dependabot also keeps the GitHub Actions in the workflows up to date (`.github/dependabot.yml`).

**5. Publish the first release:**

```sh
git tag v1.12.0
git push origin v1.12.0
```

The *Release* workflow tests, builds and publishes `MacTiles-1.12.0.pkg`, `.dmg` and `SHA256SUMS.txt` on the repository's **Releases** page, with the CHANGELOG section as the notes. Without Apple signing secrets the files are unsigned, so people have to use **Open Anyway** once (the README explains this).

### Signing and your name

A Developer ID certificate for an **individual** Apple Developer account carries your legal name, and macOS shows it to anyone who inspects the app or installer ("Developer ID Application: *Your Name*"). If you'd rather stay anonymous, either publish unsigned releases, or enroll as an **organization** (it needs a legal entity and a D-U-N-S number; the certificate then shows the organization's name). Repository secrets themselves are never visible to the public.

---

## One-time setup

### 1. Create your Developer ID certificates

You need two certificates, one for the app and one for the installer:

1. Open **Xcode → Settings → Accounts**, sign in with your Apple ID, select your team, and click **Manage Certificates…**
2. Click **+** and add **Developer ID Application**.
3. Click **+** again and add **Developer ID Installer**.

Check that they're in your keychain:

```sh
security find-identity -v | grep "Developer ID"
#  1) ABC123… "Developer ID Application: Jane Doe (TEAMID1234)"
#  2) DEF456… "Developer ID Installer: Jane Doe (TEAMID1234)"
```

### 2. Save notarization credentials

Create an **app-specific password** at [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords, then save it in your keychain under a profile name:

```sh
xcrun notarytool store-credentials MacTiles \
  --apple-id you@example.com --team-id TEAMID1234 --password abcd-efgh-ijkl-mnop
```

### 3. Put it in your shell profile (optional)

```sh
# ~/.zshrc
export APP_IDENTITY="Developer ID Application: Jane Doe (TEAMID1234)"
export INSTALLER_IDENTITY="Developer ID Installer: Jane Doe (TEAMID1234)"
export NOTARY_PROFILE=MacTiles
```

---

## Making a release on your Mac

1. Update `CHANGELOG.md` with a `## [x.y.z] - date` section.
2. Set the version in `Resources/Info.plist` (`CFBundleShortVersionString`). The build number is filled in automatically from the git commit count.
3. Run:

   ```sh
   make release            # or: ./Scripts/release.sh 1.0.0
   ```

This runs the tests, then:

| Step | Result |
|---|---|
| Build & sign the app (hardened runtime) | `~/Library/Caches/MacTiles-build/MacTiles.app` |
| Notarize & staple the app | Opens without warnings, even offline |
| Build, sign, notarize & staple the installer | `build/release/MacTiles-1.0.0.pkg` |
| Build, sign, notarize & staple the disk image | `build/release/MacTiles-1.0.0.dmg` |
| Checksums | `build/release/SHA256SUMS.txt` |

Compiling and signing happen in `~/Library/Caches/MacTiles-build`, outside the project. If the project is in iCloud Drive (or Desktop & Documents syncing is on), iCloud adds Finder metadata to its files and `codesign` rejects them with *"resource fork, Finder information, or similar detritus not allowed"*. Only the finished files are copied into `build/release/`. Set `MACTILES_BUILD_ROOT` to build somewhere else.

Notarization usually takes 1–5 minutes per file. If Apple rejects a file, the script prints Apple's log explaining why.

Check the result the way a user's Mac will:

```sh
spctl --assess --type install -vv build/release/MacTiles-1.0.0.pkg   # → accepted, source=Notarized Developer ID
```

---

## Releasing from GitHub Actions

Push a version tag and `.github/workflows/release.yml` tests, builds, signs, notarizes and publishes a GitHub release. It uses that version's CHANGELOG section as the release notes:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

You can also run the workflow by hand (*Actions → Release → Run workflow*); that creates a **draft** release.

### Repository secrets

Add these under *Settings → Secrets and variables → Actions*. Without them the workflow still publishes, but the files are unsigned.

| Secret | What it is | How to get it |
|---|---|---|
| `DEVELOPER_ID_APP_P12` | Developer ID Application certificate + private key, base64 | Keychain Access → right-click the certificate → Export… as `.p12`, then `base64 -i app.p12 \| pbcopy` |
| `DEVELOPER_ID_INSTALLER_P12` | Developer ID Installer certificate + private key, base64 | Same, for the Installer certificate |
| `P12_PASSWORD` | The password you set when exporting (use the same one for both) | |
| `APPLE_API_KEY_P8` | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`) | [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api) → Integrations → Team Keys → **+**, role *Developer* |
| `APPLE_API_KEY_ID` | That key's ID | Shown next to the key |
| `APPLE_API_ISSUER` | Issuer ID | Shown above the key list |

---

## What the installer does

- Shows a welcome page, the MIT license and a short "you're ready" page.
- Refuses to install on Intel Macs or macOS older than 14, with a clear message.
- Closes a running MacTiles before replacing it. Tiles and settings in `~/Library/Application Support/MacTiles` are untouched.
- Always installs to `/Applications/MacTiles.app`. It is marked non-relocatable, so it never "upgrades" a stray copy in a build folder instead.
- Opens MacTiles for the person who is logged in when the install finishes. On first launch, MacTiles adds itself to Login Items.

Package identifier: `io.github.mactiles.MacTiles.pkg`, app bundle identifier: `io.github.mactiles.MacTiles`.

## Uninstalling

Use **Settings → Uninstall MacTiles…**, or by hand:

```sh
osascript -e 'quit app "MacTiles"'
rm -rf /Applications/MacTiles.app ~/Library/Application\ Support/MacTiles
defaults delete io.github.mactiles.MacTiles
sudo pkgutil --forget io.github.mactiles.MacTiles.pkg   # only if installed with the .pkg
```

Then remove MacTiles from **System Settings → General → Login Items** if it's still listed.
