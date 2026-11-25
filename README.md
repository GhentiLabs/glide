# Glide

Dictation for the Mac that runs on the Mac and learns from your corrections. v2.0 is a ground-up Swift rebuild; the previous implementation lives on the [`v1.0`](https://github.com/GhentiLabs/glide/tree/v1.0) branch.

## Build

Needs macOS 26, Apple silicon, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate && open Glide.xcodeproj   # develop
cd Packages/GlideKit && swift test          # module tests
./scripts/release.sh                        # signed DMG in build/; set NOTARY_PROFILE to notarize
```

`swift run -c release glide-bench <folder>` (in `Packages/GlideKit`) scores the speech model on a folder of clips, each with a same-named `.txt` reference.
