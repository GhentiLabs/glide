# Glide - macOS build system
# Install: brew install just  (or: cargo install just)
# Usage:   just              (list all recipes)
#          just dev           (debug build + run)
#          just build         (release build + .app bundle)
#          just dmg           (signed + notarized release DMG)

ROOT := justfile_directory()

# List available recipes
default:
    @just --list

# ─── Primary Commands ─────────────────────────────────────────────────────────

# Debug build + run
dev:
    cargo run

# Release build + .app bundle
build:
    "{{ROOT}}/bundle.sh"

# Signed and notarized macOS DMG
dmg:
    "{{ROOT}}/release-dmg.sh"

# Native release binary for the current OS
build-native:
    "{{ROOT}}/build-platforms.sh" native

# Windows release binary; native on Windows, cargo-xwin from macOS
build-windows:
    "{{ROOT}}/build-platforms.sh" windows

# Linux release binaries; native on Linux, cross from macOS
build-linux:
    "{{ROOT}}/build-platforms.sh" linux

# Windows x64 and Linux x64/ARM release binaries from macOS
build-cross:
    "{{ROOT}}/build-platforms.sh" all

# Debug app bundle, requiring a valid Apple code-signing identity.
dev-signed: _stop-dev-signed
    rm -f "{{ROOT}}/target/debug/Glide" "{{ROOT}}/target/debug/Glide.app/Contents/MacOS/Glide"
    "{{ROOT}}/bundle.sh" --debug --sign
    open "{{ROOT}}/target/debug/Glide.app"

[private]
_stop-dev-signed:
    # [G] keeps pgrep/pkill from matching this recipe's shell command.
    -pkill -TERM -f "{{ROOT}}/target/debug/[G]lide.app/Contents/MacOS/Glide"
    @for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
        pgrep -f "{{ROOT}}/target/debug/[G]lide.app/Contents/MacOS/Glide" >/dev/null || exit 0; \
        sleep 0.1; \
    done; \
    pkill -KILL -f "{{ROOT}}/target/debug/[G]lide.app/Contents/MacOS/Glide" || true

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

# Benchmark a speech-to-text provider against a WAV file.
bench-stt audio provider="openai" model="whisper-1" runs="3" warmups="1":
    cargo run --bin glide-bench -- stt --audio "{{audio}}" --provider "{{provider}}" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Benchmark an LLM cleanup provider against text or @file input.
bench-llm text provider="openai" model="gpt-5.4-nano" runs="3" warmups="1":
    cargo run --bin glide-bench -- llm --text "{{text}}" --provider "{{provider}}" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Benchmark Glide's dictation flow without pasting by default.
bench-flow audio runs="3" warmups="1":
    cargo run --bin glide-bench -- flow --audio "{{audio}}" --runs "{{runs}}" --warmups "{{warmups}}" --no-paste

# Benchmark Glide's dictation flow with the short recorded fixture.
bench-flow-short runs="3" warmups="1":
    cargo run --bin glide-bench -- flow --audio "{{ROOT}}/fixtures/benchmark/dictation-short.wav" --runs "{{runs}}" --warmups "{{warmups}}" --no-paste

# Benchmark Glide's dictation flow with the long recorded fixture.
bench-flow-long runs="3" warmups="1":
    cargo run --bin glide-bench -- flow --audio "{{ROOT}}/fixtures/benchmark/dictation-long.wav" --runs "{{runs}}" --warmups "{{warmups}}" --no-paste

# Benchmark an STT provider with the short recorded fixture.
bench-stt-short provider="parakeet" model="parakeet-tdt-0.6b-v3-int8" runs="3" warmups="1":
    cargo run --bin glide-bench -- stt --audio "{{ROOT}}/fixtures/benchmark/dictation-short.wav" --provider "{{provider}}" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Benchmark Fireworks Whisper Turbo with the short recorded fixture.
bench-stt-fireworks model="whisper-v3-turbo" runs="3" warmups="1":
    cargo run --bin glide-bench -- stt --audio "{{ROOT}}/fixtures/benchmark/dictation-short.wav" --provider "fireworks" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Benchmark ElevenLabs Scribe with the short recorded fixture.
bench-stt-elevenlabs model="scribe_v2" runs="3" warmups="1":
    cargo run --bin glide-bench -- stt --audio "{{ROOT}}/fixtures/benchmark/dictation-short.wav" --provider "elevenlabs" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Benchmark a Fireworks serverless/API LLM against text or @file input.
bench-llm-fireworks text model="accounts/fireworks/models/gpt-oss-20b" runs="3" warmups="1":
    cargo run --bin glide-bench -- llm --text "{{text}}" --provider "fireworks" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Benchmark an STT provider with the long recorded fixture.
bench-stt-long provider="parakeet" model="parakeet-tdt-0.6b-v3-int8" runs="3" warmups="1":
    cargo run --bin glide-bench -- stt --audio "{{ROOT}}/fixtures/benchmark/dictation-long.wav" --provider "{{provider}}" --model "{{model}}" --runs "{{runs}}" --warmups "{{warmups}}"

# Compare two benchmark JSON reports and fail above a percent threshold.
bench-compare baseline candidate threshold="20":
    cargo run --bin glide-bench -- compare --baseline "{{baseline}}" --candidate "{{candidate}}" --fail-threshold "{{threshold}}"

# Run the live prompt eval suite against the default remote LLM candidates.
prompt-eval-core runs="1" timeout_secs="60":
    cargo run --bin glide-bench -- prompt-eval --suite "{{ROOT}}/fixtures/prompt_eval/core.jsonl" --candidate "openai:gpt-5.4-nano" --candidate "groq:meta-llama/llama-4-scout-17b-16e-instruct" --candidate "cerebras:gpt-oss-120b" --candidate "fireworks:accounts/fireworks/models/gpt-oss-20b" --runs "{{runs}}" --timeout-secs "{{timeout_secs}}"

# ─── Cleanup ──────────────────────────────────────────────────────────────────

# Remove all build artifacts
clean:
    cargo clean
