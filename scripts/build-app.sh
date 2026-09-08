#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_NAME="PhotoArchiveKit"
APP_DIR="$PROJECT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE_NAME="photoarchive-review"

cd "$PROJECT_DIR"
CONFIGURATION="${PHOTOARCHIVE_BUILD_CONFIGURATION:-release}"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE_NAME" >&2

BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)
SOURCE_EXECUTABLE="$BIN_DIR/$EXECUTABLE_NAME"

# The old development bundle name is no longer a separate product.
rm -rf "$PROJECT_DIR/.build/PhotoArchiveKit Review.app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$SOURCE_EXECUTABLE" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleDisplayName</key>
    <string>PhotoArchiveKit</string>
    <key>CFBundleExecutable</key>
    <string>photoarchive-review</string>
    <key>CFBundleIdentifier</key>
    <string>io.photoarchivekit.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PhotoArchiveKit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
printf '%s\n' "$APP_DIR"
