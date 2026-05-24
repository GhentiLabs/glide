# Glide - desktop build system
# Install: brew install just  (or: cargo install just)
# Usage:   just              (list all recipes)
#          just dev           (debug build + run for current OS)
#          just build         (release build + package for current OS)

ROOT := justfile_directory()
current_os := if os() == "macos" { "mac" } else { os() }

# List available recipes
default:
    @just --list

# ─── Primary Commands ─────────────────────────────────────────────────────────

# Debug build + auto-run (platform: mac, linux, windows)
dev platform=current_os:
    @just _dev-{{platform}}

# Release build + package artifacts (platform: mac, linux, windows)
build platform=current_os:
    @just _build-{{platform}}

# ─── macOS ────────────────────────────────────────────────────────────────────

[private]
_dev-mac:
    cargo run

[private]
_build-mac:
    {{ROOT}}/bundle.sh

# Debug app bundle, requiring a valid Apple code-signing identity.
dev-signed:
    {{ROOT}}/bundle.sh --debug --sign
    open {{ROOT}}/target/debug/Glide.app

# ─── Linux ────────────────────────────────────────────────────────────────────

[private]
_dev-linux:
    cargo run

[private]
_build-linux:
    cargo build --release

# ─── Windows ──────────────────────────────────────────────────────────────────

[private]
_dev-windows:
    cargo run

[private]
_build-windows:
    cargo build --release

# ─── Setup ────────────────────────────────────────────────────────────────────

# Check and install required tools
setup:
    {{ROOT}}/setup.sh

# ─── Quality ──────────────────────────────────────────────────────────────────

# Run all tests
test:
    cargo test

# Run clippy lints
lint:
    cargo clippy -- -D warnings

# Format all code
fmt:
    cargo fmt --all

# Check compilation without building
check:
    cargo check

# ─── Cleanup ──────────────────────────────────────────────────────────────────

# Remove all build artifacts
clean:
    cargo clean
