# Product

<!-- impeccable:product-schema 1 -->

> Status: drafted from the v2.0 brief and the two source specs without an interview.
> Lines marked (inferred) have not been confirmed by the owner.

## Platform

macos

Native macOS only, Apple silicon only. Windows and Linux are dropped in v2.0. Minimum OS version is an open decision (inferred recommendation: macOS 26).

## Stack

Swift 6 for everything, including the trainer (confirmed by the owner 2026-11-24). SwiftUI for windows, AppKit for the floating bar and popups. The v1 Rust and gpui code stays on the `v1.0` branch.

## Users

People who write a lot on a Mac and would rather speak: messages, email, prompts to AI tools, notes, code comments. They are mid-task in another app when they use Glide, so their attention is on the text field they are filling, not on Glide.

## Product Purpose

Hold a key, speak, release, and the text appears where the cursor is. Glide runs speech recognition on the Mac and gets better at one person's names and jargon by learning from the corrections they make after dictating. Success is a falling edit rate: fewer dictations that need fixing.

## Positioning

Dictation that learns you, on your Mac. Corrections update a personal dictionary at once and train a small on-device adapter overnight. Audio and text stay on the machine. (inferred: v2.0 ships with no account, no cloud providers and no telemetry.)

## Operating Context

- A small bar floats at a screen edge at all times and becomes a live waveform while recording. It must never take keyboard focus from the app being typed in.
- A main window holds history, the dictionary and what Glide has learned. Settings is a separate standard window. An account control sits bottom left of the sidebar; it has nothing behind it in v2.0.
- First run needs Microphone and Accessibility permission and a roughly 450 MB model download.

## Capabilities and Constraints

- Push-to-talk on a global hotkey; double-tap latches hands-free; Escape cancels.
- Reads the focused text field through Accessibility for context; never reads or dictates into password fields.
- Inserts by simulated paste and restores the clipboard.
- Watches the field after insertion and stores the whole word-level diff of every edit, however large (confirmed). Each changed span is labelled on its own; only misheard spans train the recognizer.
- Recognizer: Parakeet TDT 0.6B v3 on Core ML for v2.0 (confirmed). Learning: dictionary and decode-time biasing first, nightly LoRA adapter with a regression gate later, a small edit model after that.
- Cached audio is sensitive: encrypted at rest, retention-capped, with a clear-all control.
- Source specs: "Voice Dictation Overlay: Clean-Room Functional Spec" and "Self-improving local dictation: STT models and on-device personalization".
- Undecided: minimum macOS version; whether cloud recognizers return as an option; whether command mode ships before the edit model.

## Brand Commitments

- Name: Glide. Publisher: Ghenti Labs.
- v1 identity: a lowercase g drawn from waveform pills, on a gradient app icon with alternate colors. The v2.0 mark is Caret: three voice bars meeting a text caret (confirmed). Tint is still open.
- v2.0 moves from v1's brutalist look to a clean, native Mac interface. All assets, sounds, colors and wording are Glide's own.
- No taglines or parenthetical asides in user-facing copy.

## Evidence on Hand

- v1 assets on the `v1.0` branch: `assets/logo/glide-logo.svg`, `assets/icons/AppIcon-*.png`, `assets/screenshots/`.
- No usage data, testimonials or benchmarks on Glide's own audio yet. Do not invent any.

## Product Principles

1. Out of the way. The bar and every popup yield to the app the user is typing in.
2. Local by default. Nothing leaves the Mac unless the user turns it on.
3. Learning is visible and reversible. Every learned word can be undone; every adapter can be rolled back.
4. Leave good text alone. When unsure, paste what was said.

## Accessibility & Inclusion

Honor Reduce Motion, Reduce Transparency and Increase Contrast. Every bar state has a non-color cue. VoiceOver labels on the bar and popups. Sound cues respect a mute setting.
