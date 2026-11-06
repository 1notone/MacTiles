# Shared build locations. Sourced by the other scripts.
#
# Everything is built outside the project folder, in ~/Library/Caches/MacTiles-build.
# If the project lives in iCloud Drive (including Desktop & Documents syncing), iCloud
# tags files with Finder metadata, and `codesign` refuses to sign them ("resource fork,
# Finder information, or similar detritus not allowed"). Only the finished .pkg/.dmg
# are copied back into build/release/. Override with MACTILES_BUILD_ROOT.

BUILD_ROOT="${MACTILES_BUILD_ROOT:-$HOME/Library/Caches/MacTiles-build}"
SCRATCH="$BUILD_ROOT/swiftpm"        # SwiftPM's .build
APP="$BUILD_ROOT/MacTiles.app"       # the built, signed app
mkdir -p "$BUILD_ROOT"
