#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$ROOT/target/dist"
WINDOWS_TARGET="${GLIDE_WINDOWS_TARGET:-x86_64-pc-windows-msvc}"
LINUX_TARGETS="${GLIDE_LINUX_TARGETS:-x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu}"

host_os() {
    case "$(uname -s)" in
        Darwin) printf 'macos\n' ;;
        Linux) printf 'linux\n' ;;
        MINGW*|MSYS*|CYGWIN*) printf 'windows\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

host_target() {
    rustc -vV | awk '/^host: / { host = $2 } END { print host }'
}

require_command() {
    local command="$1"
    local install_hint="$2"
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required command: $command" >&2
        echo "$install_hint" >&2
        exit 1
    fi
}

binary_extension() {
    case "$1" in
        *windows*) printf '.exe\n' ;;
        *) printf '\n' ;;
    esac
}

copy_release_binary() {
    local target="$1"
    local label="$2"
    local release_dir="$ROOT/target/release"
    if [[ "$target" != "native" ]]; then
        release_dir="$ROOT/target/$target/release"
    fi

    local extension source dest
    extension="$(binary_extension "$label")"
    source="$release_dir/Glide${extension}"
    dest="$DIST_DIR/Glide-${label}${extension}"

    if [[ ! -f "$source" ]]; then
        echo "Expected build artifact missing: $source" >&2
        exit 1
    fi

    mkdir -p "$DIST_DIR"
    cp "$source" "$dest"
    echo "Copied: $dest"
}

build_native() {
    local target
    target="$(host_target)"
    echo "Building native release for $target..."
    cargo build --release
    copy_release_binary native "native-$target"
}

build_windows() {
    case "$(host_os)" in
        windows)
            build_native
            ;;
        macos)
            require_command cargo-xwin "Install with: cargo install cargo-xwin"
            echo "Cross-compiling Windows release for $WINDOWS_TARGET..."
            cargo xwin build --release --target "$WINDOWS_TARGET"
            copy_release_binary "$WINDOWS_TARGET" "$WINDOWS_TARGET"
            ;;
        *)
            echo "Windows builds are supported natively on Windows or via cargo-xwin on macOS." >&2
            exit 1
            ;;
    esac
}

build_linux_native() {
    build_native
}

build_linux_cross_target() {
    local target="$1"
    require_command cross "Install with: cargo install cross"

    echo "Cross-compiling Linux release for $target..."
    if [[ "$target" == aarch64-* ]]; then
        env \
            PKG_CONFIG_ALLOW_CROSS=1 \
            PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
            cross build --release --target "$target"
    else
        cross build --release --target "$target"
    fi

    copy_release_binary "$target" "$target"
}

build_linux() {
    case "$(host_os)" in
        linux)
            build_linux_native
            ;;
        macos)
            for target in $LINUX_TARGETS; do
                build_linux_cross_target "$target"
            done
            ;;
        *)
            echo "Linux builds are supported natively on Linux or via cross on macOS." >&2
            exit 1
            ;;
    esac
}

build_all() {
    if [[ "$(host_os)" != "macos" ]]; then
        echo "The all target is intended for macOS-hosted cross compilation." >&2
        exit 1
    fi

    build_windows
    build_linux
}

usage() {
    cat <<'USAGE'
Usage: ./build-platforms.sh <native|windows|linux|all>

Environment overrides:
  GLIDE_WINDOWS_TARGET   Defaults to x86_64-pc-windows-msvc
  GLIDE_LINUX_TARGETS    Defaults to "x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu"
USAGE
}

main() {
    cd "$ROOT"
    case "${1:-}" in
        native) build_native ;;
        windows) build_windows ;;
        linux) build_linux ;;
        all) build_all ;;
        -h|--help|help) usage ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
