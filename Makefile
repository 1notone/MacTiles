.PHONY: build test app run install release pkg dmg clean signing-cert appstore

# Version for `make release`; defaults to the one in Resources/Info.plist.
# Builds happen outside the project (see Scripts/paths.sh) so iCloud-synced folders don't break code signing.
BUILD_ROOT ?= $(or $(MACTILES_BUILD_ROOT),$(HOME)/Library/Caches/MacTiles-build)
SCRATCH := $(BUILD_ROOT)/swiftpm
APP := $(BUILD_ROOT)/MacTiles.app
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null)

build:
	swift build -c release --arch arm64 --scratch-path "$(SCRATCH)"

test:
	swift test --scratch-path "$(SCRATCH)"

app:
	./Scripts/build-app.sh

run: app
	open "$(APP)"

# One time: a free personal code-signing certificate, so the Keychain (and Local Network
# permission) recognise each new build as the same app. See RELEASING.md → "Fewer password prompts".
signing-cert:
	./Scripts/make-signing-cert.sh

# Builds, copies to /Applications and launches (for development on this Mac).
install: app
	-osascript -e 'quit app "MacTiles"' 2>/dev/null
	@# Quitting takes a moment; wait (up to 5 s) so the new copy isn't opened while the old one is closing.
	@for i in $$(seq 1 25); do pgrep -xq MacTiles || break; sleep 0.2; done
	@# A copy put there by the installer package belongs to the system: replacing it needs your password.
	@if [ -e /Applications/MacTiles.app ] && [ ! -w /Applications/MacTiles.app ]; then \
		echo "MacTiles in /Applications was installed by the installer package; enter your password to replace it."; \
		sudo rm -rf /Applications/MacTiles.app; \
	else \
		rm -rf /Applications/MacTiles.app; \
	fi
	ditto "$(APP)" /Applications/MacTiles.app
	@open /Applications/MacTiles.app || { sleep 2; open /Applications/MacTiles.app; }
	@echo "Installed to /Applications/MacTiles.app"

# Installer package + disk image + checksums in build/release/.
# Signs and notarizes when APP_IDENTITY, INSTALLER_IDENTITY and notary credentials are set (see RELEASING.md).
release: test
	./Scripts/release.sh $(VERSION)

pkg dmg: release

# meTiles, the Mac App Store edition: build/appstore/meTiles-<version>.pkg for Transporter.
# Needs your App Store certificates and AppStore/meTiles.provisionprofile (see RELEASING.md).
appstore: test
	./Scripts/appstore.sh $(VERSION)

clean:
	rm -rf .build build "$(BUILD_ROOT)"
