.PHONY: build test app run install release pkg dmg clean

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

# Builds, copies to /Applications and launches (for development on this Mac).
install: app
	-osascript -e 'quit app "MacTiles"' 2>/dev/null
	@# A copy put there by the installer package belongs to the system: replacing it needs your password.
	@if [ -e /Applications/MacTiles.app ] && [ ! -w /Applications/MacTiles.app ]; then \
		echo "MacTiles in /Applications was installed by the installer package; enter your password to replace it."; \
		sudo rm -rf /Applications/MacTiles.app; \
	else \
		rm -rf /Applications/MacTiles.app; \
	fi
	ditto "$(APP)" /Applications/MacTiles.app
	open /Applications/MacTiles.app
	@echo "Installed to /Applications/MacTiles.app"

# Installer package + disk image + checksums in build/release/.
# Signs and notarizes when APP_IDENTITY, INSTALLER_IDENTITY and notary credentials are set (see RELEASING.md).
release: test
	./Scripts/release.sh $(VERSION)

pkg dmg: release

clean:
	rm -rf .build build "$(BUILD_ROOT)"
