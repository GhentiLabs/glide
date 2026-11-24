#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$ROOT/target/dist"
DMG_WORK_DIR="$ROOT/target/dmg"
STAGE_DIR="$DMG_WORK_DIR/stage"
ICONSET_DIR="$DMG_WORK_DIR/glide-dmg.iconset"
APP="$ROOT/target/release/Glide.app"
BACKGROUND="$ROOT/assets/dmg/dmg-background.png"
DMG_ICON_PNG="$ROOT/assets/dmg/glide-dmg.png"
DMG_ICON_ICNS="$DMG_WORK_DIR/glide-dmg.icns"
TEAM_ID="${GLIDE_APPLE_TEAM_ID:-${APPLE_TEAM_ID:-KSH6P6Y39N}}"
IDENTITY="${GLIDE_APPLE_CODESIGN_IDENTITY:-${APPLE_CODESIGN_IDENTITY:-}}"
NOTARY_PROFILE="${GLIDE_NOTARY_KEYCHAIN_PROFILE:-glide-notary}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        echo "$2" >&2
        exit 1
    fi
}

require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "release-dmg.sh must run on macOS." >&2
        exit 1
    fi
}

print_signing_setup_help() {
    cat >&2 <<EOF

Release DMG signing requires a Developer ID Application certificate installed in
your login Keychain. Apple Development certificates are not accepted for this
release path.

One-time setup:
  1. Enroll the Apple team in the Apple Developer Program.
  2. Open Xcode > Settings > Accounts, select the team, then Manage Certificates.
  3. Press + and create/download "Developer ID Application".
  4. Verify it is installed:
       security find-identity -v -p codesigning
  5. Store notarization credentials in Keychain:
       xcrun notarytool store-credentials ${NOTARY_PROFILE} --team-id ${TEAM_ID}

If the certificate is already installed under another team or name, set:
  GLIDE_APPLE_TEAM_ID=<team-id>
  GLIDE_APPLE_CODESIGN_IDENTITY=<identity hash or full identity name>
EOF
}

version() {
    awk -F'"' '/^version = / { print $2; exit }' "$ROOT/Cargo.toml"
}

find_developer_id_identity() {
    if [[ -n "$IDENTITY" ]]; then
        local identity_line
        identity_line="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -F "$IDENTITY" \
            | head -n 1 \
            || true)"

        if [[ "$IDENTITY" == Developer\ ID\ Application:* ]] \
            || [[ "$identity_line" == *"Developer ID Application"* ]]; then
            printf '%s\n' "$IDENTITY"
            return 0
        fi

        echo "GLIDE_APPLE_CODESIGN_IDENTITY must be a Developer ID Application identity." >&2
        echo "Do not use Apple Development certificates for notarized release DMGs." >&2
        print_signing_setup_help
        exit 1
    fi

    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v team="$TEAM_ID" '
            /Developer ID Application/ && (index($0, "(" team ")") || index($0, team)) {
                print $2
                exit
            }
        '
}

generate_volume_icon() {
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$DMG_ICON_PNG" \
            --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        local retina_size=$((size * 2))
        sips -z "$retina_size" "$retina_size" "$DMG_ICON_PNG" \
            --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$ICONSET_DIR" -o "$DMG_ICON_ICNS"
}

verify_release() {
    local dmg="$1"

    echo "Verifying signed app bundle..."
    codesign --verify --deep --strict --verbose=2 "$APP"

    echo "Verifying signed DMG..."
    codesign --verify --deep --strict --verbose=2 "$dmg"

    echo "Verifying stapled notarization ticket..."
    xcrun stapler validate "$dmg"

    echo "Running Gatekeeper assessment..."
    spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"

    echo "Verifying disk image..."
    hdiutil verify "$dmg"
}

main() {
    require_macos
    require_command cargo "Install Rust with rustup."
    require_command codesign "Install Xcode Command Line Tools."
    require_command create-dmg "Install create-dmg with: brew install create-dmg"
    require_command hdiutil "Install Xcode Command Line Tools."
    require_command iconutil "Install Xcode Command Line Tools."
    require_command security "Install Xcode Command Line Tools."
    require_command sips "Install Xcode Command Line Tools."
    require_command spctl "Install Xcode Command Line Tools."
    require_command xcrun "Install Xcode Command Line Tools."

    if [[ ! -f "$BACKGROUND" ]]; then
        echo "Missing DMG background: $BACKGROUND" >&2
        exit 1
    fi
    if [[ ! -f "$DMG_ICON_PNG" ]]; then
        echo "Missing DMG icon PNG: $DMG_ICON_PNG" >&2
        exit 1
    fi

    IDENTITY="$(find_developer_id_identity)"
    if [[ -z "$IDENTITY" ]]; then
        echo "No Developer ID Application identity found for Apple team $TEAM_ID." >&2
        echo "Install the certificate in Keychain or set GLIDE_APPLE_CODESIGN_IDENTITY." >&2
        print_signing_setup_help
        exit 1
    fi

    export GLIDE_APPLE_CODESIGN_IDENTITY="$IDENTITY"
    export GLIDE_APPLE_TEAM_ID="$TEAM_ID"

    local version dmg
    version="$(version)"
    dmg="$DIST_DIR/Glide-${version}.dmg"

    mkdir -p "$DIST_DIR" "$DMG_WORK_DIR"

    echo "Building and signing Glide.app with: $IDENTITY"
    "$ROOT/bundle.sh" --sign

    echo "Preparing DMG staging folder..."
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$APP" "$STAGE_DIR/"

    echo "Generating DMG volume icon..."
    generate_volume_icon

    echo "Creating signed and notarized DMG..."
    rm -f "$dmg"
    create-dmg \
        --volname "Glide ${version}" \
        --volicon "$DMG_ICON_ICNS" \
        --background "$BACKGROUND" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --text-size 12 \
        --icon-size 96 \
        --icon "Glide.app" 165 235 \
        --hide-extension "Glide.app" \
        --app-drop-link 495 235 \
        --no-internet-enable \
        --codesign "$IDENTITY" \
        --notarize "$NOTARY_PROFILE" \
        "$dmg" \
        "$STAGE_DIR"

    verify_release "$dmg"
    echo "Done: $dmg"
}

main "$@"
