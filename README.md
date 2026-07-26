# Strata

A Mac-assed cloud blob storage client — a native macOS client for AWS S3 and
Azure Blob Storage (GCS and S3-compatible providers later). "Transmit for blob
storage." Built AppKit-first, treating Mac platform craft as a first-class
feature, with a differentiator no competing client offers: **it tells you, before
you upload, whether your blob will actually trigger the Azure pipeline waiting for
it** (Event Grid `data.api` prediction).

> `Strata` is a working name — easy to change (bundle id `com.kizersolutions.strata`,
> matching the existing Developer ID namespace so notarization uses the same team).

## Status

**Azure Blob Storage works end to end.** Connect by picking a storage account from
a list (Azure Resource Manager), browse in a sortable List view or a Finder-style
Columns (Miller) view with a bottom path bar and an object inspector/preview, and
move bytes both ways as streaming, queued transfers: upload (File ▸ Upload… or
drag-and-drop, including folders) — each showing the Event Grid `data.api` it will
emit — and download (⌘D, double-click, or by dragging a blob out to the Finder,
where it arrives as a file promise and fetches on drop). Space Quick Looks the real
contents of a blob. Copy a blob and paste it into the Finder to download it; paste
files in to upload them. Full keyboard navigation — including Back/Forward and Go to
Folder — and it reopens the account and folder you were last in. A unit-test suite
covers the prediction/parsing/sort/naming/history logic.

**AWS S3 is still stubbed** — the biggest functional gap. See
[`ROADMAP.md`](ROADMAP.md) for the near-term backlog and known gaps.

## Design principles

- **AppKit only.** No SwiftUI. Modern Swift 6 (strict concurrency, async/await)
  wrapped around AppKit — the framework Apple's own Mac apps use.
- **Programmatic UI.** No XIBs or Storyboards. Easier to diff, refactor, and edit.
- **macOS 26+.** Latest APIs, no back-compat conditionals.
- **Non-sandboxed, Developer ID–signed + notarized** distribution (Sparkle, not
  the App Store) — required to piggyback existing `aws`/`az` credentials.

See `DESIGN.md` for the full product and architecture writeup, and
[`ROADMAP.md`](ROADMAP.md) for the near-term backlog.

## Project layout

```
Strata.xcodeproj          Hand-written, file-system-synchronized (Xcode 16+):
                          drop a .swift file in Strata/ and it is picked up
                          automatically — no project-file edit needed.
Strata/
  App/                    Entry point (main.swift), AppDelegate, programmatic menu bar
  Browser/                Dual-pane browser window + content controllers
  Model/                  Provider-agnostic core: StorageProvider, StorageContainer,
                          StorageObject, Transfer, and BlobEvent (the event model)
  Providers/S3/           Amazon S3 provider (AWS SDK for Swift) — stub
  Providers/Azure/        Azure Blob provider (hand-rolled REST), auth strategy,
                          and the event-prediction service
  Transfer/               TransferQueue actor
  Preferences/            Classic toolbar-paned settings window
  Resources/              Assets.xcassets
```

## Build & run

```sh
# Build (Debug)
xcodebuild -project Strata.xcodeproj -scheme Strata -configuration Debug build

# Or open in Xcode and hit Run
open Strata.xcodeproj
```

### Signing note

This machine currently has **no code-signing identity**, so the project is
configured to build with **ad-hoc signing** (`CODE_SIGN_IDENTITY = "-"`,
non-sandboxed, hardened runtime off) — good enough to build and run locally.
Shipping requires a Developer ID certificate, then re-enabling hardened runtime
and running notarization/stapling. Those settings are called out in
`project.pbxproj` (`ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME`).

Release + notarization is automated in `.github/workflows/release.yml` (tag-triggered
on `v*`), adapted from the Lineage project. It imports a Developer ID cert, builds
Release with hardened runtime (`--options=runtime`), builds a DMG, notarizes via
`notarytool --wait`, staples, and publishes a GitHub Release. Required repo secrets:
`BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `SIGNING_IDENTITY`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## The differentiator, already modeled

`Model/BlobEvent.swift` + `Providers/Azure/EventPredictionService.swift` encode the
operation → `data.api` table from the design doc:

| Upload | REST call | emitted `data.api` |
|---|---|---|
| Small blob | `Put Blob` | `PutBlob` |
| Large blob | `Put Block` ×N + `Put Block List` | `PutBlockList` |
| Server-side copy | `Copy Blob` | `CopyBlob` |
| ADLS Gen2 (DFS) | `CreateFile` + `Flush` | `FlushWithClose` |
| SFTP endpoint | — | `SftpCreate` / `SftpCommit` |

An `UploadPlan` reports `predictedEventSummary` (e.g. "emits BlobCreated with api:
PutBlockList") from data-plane access alone — this is what surfaces per-transfer in
the queue and inspector. v2 adds reading real Event Grid subscription filters when
management RBAC is present.
