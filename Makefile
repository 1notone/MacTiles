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
	rm -rf /Applications/MacTiles.app
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
