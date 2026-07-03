# A Mac-Assed Cloud Blob Storage Client

*Combined design document: the product/architecture writeup plus the Azure integration brief (authentication and Event Grid event-awareness) folded in.*

## The pitch

A native macOS client for working with cloud blob storage — AWS S3, Azure Blob Storage, and eventually GCS — that treats Mac platform craft as a first-class feature rather than an afterthought. "Transmit for blob storage" is the elevator pitch. The target user is the developer, data engineer, or analytics engineer who works across cloud providers daily and is poorly served by a combination of the AWS Console, Azure Portal, Cyberduck, and Transmit (which doesn't support Azure at all and treats S3 as a bolted-on FTP protocol).

## Why this gap exists

The existing landscape, briefly:

- **Cyberduck** — venerable, broad protocol support, Java-based under the hood, dated UI. Not Mac-assed.
- **Transmit (Panic)** — gold standard for Mac craft, but FTP/SFTP-first. S3 is bolted on. Azure Blob is absent. GCS is third-class. The cloud storage abstractions leak constantly because the underlying mental model is "remote filesystem." Its SFTP-first design also causes a subtle, serious problem for event-driven pipelines (see *Event-awareness* below): SFTP-endpoint uploads emit storage events that standard Event Grid filters ignore, so downstream automation silently fails to fire.
- **ExpanDrive / Mountain Duck / CloudMounter** — mount-cloud-as-drive utilities. Functional but optimized for filesystem mounting rather than being a real client for cloud storage as cloud storage. No surfacing of storage classes, versioning, lifecycle policies, presigned URLs, etc. As mounts, they're also the worst offenders for opaque, event-breaking upload behavior.
- **S3 Files** — actually native, Mac-assed sensibility, Shortcuts integration. But S3-protocol only. No Azure Blob, no native GCS.
- **AWS/Azure/GCP web consoles** — universally hated. Slow, inconsistent, missing keyboard navigation, no cross-provider workflows.

The gap is "Transmit-grade Mac craft applied to cloud blob storage as a primary concept, with first-class multi-cloud support." Nobody has shipped this. The reason: it requires the overlap of (a) genuine Mac UI craft and (b) deep familiarity with how data/infra people actually use cloud storage. Those skill sets rarely coincide.

## What "Mac-assed" means for this app

Non-negotiable platform behaviors. These are not "nice to haves" — they are the entire reason this app exists rather than another Electron wrapper.

### Framework choices

- **AppKit only.** No SwiftUI. AppKit is the framework Apple's senior macOS engineers actually use, and the apps universally cited as Mac-assed (Transmit, BBEdit, Acorn, OmniFocus, Tower, Xcode itself) are AppKit. SwiftUI on the Mac is still incomplete and retrofitted from iOS; AppKit was designed for the Mac from the start.
- **Modern Swift wrapped around AppKit.** Swift 6, strict concurrency, async/await throughout. AppKit's verbosity becomes a feature here — the LLM can crank out boilerplate (data sources, cell views) while architecture decisions stay human.
- **Programmatic UI, no XIBs or Storyboards.** Auto Layout in code, NSStackView for composition. Easier to diff, easier to refactor, easier for LLMs to edit.
- **Target macOS 26+.** Latest APIs everywhere, no conditional code. Hobby project — no enterprise back-compat requirements.

### Platform integration

- Proper menu bar with full standard menus: File, Edit, View, Window, Help, plus app-specific menus. Menu item validation through the responder chain. Keyboard shortcuts on every reasonable action.
- Real NSToolbar with customizable items. Not the iOS-port toolbar style.
- Window state restoration on relaunch — windows reopen where they were, in the same tab configuration, with the same panes.
- Multiple windows, multiple tabs per window. Tab merging via the standard Window menu commands.
- Drag-and-drop with rich pasteboard types. Drag objects out as URLs, file promises, or actual files depending on destination.
- Quick Look integration. Space bar previews files without downloading (range requests where possible).
- Services menu integration. "Upload to S3..." from any app's Services menu.
- AppleScript dictionary. Real scripting support, not a fake "Shortcuts only" gesture.
- Shortcuts app integration with proper App Intents.
- Spotlight integration for recent buckets/objects (eventually).
- Dark mode that works correctly across all accent colors.
- VoiceOver and full keyboard accessibility.

### Preferences

- Classic Mac preference window pattern: NSToolbar across the top with icon+label items, one per pane. Window resizes smoothly between panes. Title updates to match selected pane. Window is non-resizable, centered, remembers last selected pane. Cmd+, opens from anywhere.
- **Explicitly not the SwiftUI Settings scene API.** System Settings.app in Ventura+ is the cautionary tale for un-Mac-assed Mac UI.

### File browser experience

- Dual-pane mode (toggleable). Drag between panes within a provider or across providers.
- Tabs for multiple locations.
- NSOutlineView for hierarchical bucket/prefix navigation.
- NSTableView with configurable columns: key, size, storage class, last modified, content-type, etc.
- Column show/hide, reorder, sort.
- Fast keyboard navigation. Type-ahead. Arrow keys, Return to enter, Cmd+Up to go up a level.
- Inspector pane (Cmd+Opt+I) showing full object metadata.
- Robust transfer queue: pause, resume, retry, bandwidth visibility, progress per file and aggregate.

## Architecture

### Provider abstraction

Provider-agnostic core model with concrete implementations per cloud. Designed for two providers from day one (S3 + Azure Blob) rather than retrofitted, because S3-only abstractions inevitably leak through every layer and have to be ripped out painfully later.

Core types:

- **Provider** — top-level account/credential context. AWS profile, Azure storage account, eventually GCP project. Display name, auth mechanism, list of containers.
- **Container** — bucket (S3) / container (Azure) / bucket (GCS). Region/location, access settings, provider-specific config exposed in an inspector.
- **Object** — key/blob name, size, last modified, storage class/tier, content-type, metadata dictionary, version info.
- **Transfer** — unit of work in the queue. Source object, destination location, progress, state. Transfer engine handles same-provider copy (server-side where possible), cross-provider copy (stream through local), and upload/download. **Every write operation also declares the storage event it will emit** — see *Event-awareness*.

Generic concepts are modeled abstractly (storage tier, versioning, server-side encryption, lifecycle). Provider-specific features (S3 bucket policies, Azure SAS tokens, S3 object tags vs. Azure blob index tags) get provider-specific inspector panes that only appear for the relevant provider — no forced false abstractions.

### Azure-specific semantic differences to accommodate

- Three blob types: block, append, page. S3 has one.
- Hierarchical namespace (ADLS Gen2) vs. flat. Browser must handle both. This also changes which storage event an upload emits (see *Event-awareness*).
- Access tiers are blob-level *and* account-level (default + override). S3 storage class is per-object.
- Soft delete, versioning, and snapshots are three distinct concepts in Azure.
- Lease semantics for write coordination. No S3 equivalent.
- Auth on the wire: SigV4 (S3) vs. Shared Key / Azure AD bearer / SAS (Azure).

### SDK choices

- **AWS:** AWS SDK for Swift (GA late 2023, solid). Implements the standard credential provider chain, which does most of the credential-reuse work for free.
- **Azure:** No official Swift SDK exists. Write a thin REST client over URLSession with a Shared Key signing helper, plus MSAL (or CLI-minted tokens) for Azure AD bearer auth. Focused, weekend-scale, no dependency risk. **This is an advantage, not just a cost:** hand-rolling the client is what makes deterministic event prediction possible, because the app controls exactly which REST operation each upload uses.
- **Future GCP:** Same pattern as Azure — direct REST client, no third-party SDK dependency.

### Authentication & credential management

The single most important UX win: respect credentials the user already has configured. No "paste your access key here" when `aws sso login` or an existing `az login` session would suffice. Typing a secret should be the fallback, not the default.

Auth is a small strategy layer with ordered sources, a token cache keyed by (account, tenant), and Keychain persistence for anything durable. Ephemeral tokens minted from a CLI need no storage.

**AWS** — lean on the AWS SDK for Swift's provider chain:
- Read `~/.aws/credentials` and `~/.aws/config`; surface all named profiles in a picker
- SSO profiles with `aws sso login` — detect expired sessions and prompt to refresh (SSO token cache lives under `~/.aws/sso/cache/`)
- Assume-role profiles with MFA prompts
- Direct access key + secret (the simple case)

**Azure** — hand-rolled, in priority order:

1. **Azure CLI session piggyback (best default when the CLI is present).** Reuse the existing `az login` session by shelling out to mint a data-plane token on demand — the same mechanism the official `AzureCliCredential` uses internally:
   ```
   az account get-access-token --resource https://storage.azure.com/ --output json
   ```
   - **Resource/scope:** `https://storage.azure.com/` — identical across all public and sovereign clouds, valid for any storage account. (Scope form: `https://storage.azure.com/.default`.)
   - **Return payload:** JSON with `accessToken`, `expiresOn`, `expires_on` (epoch), `subscription`, `tenant`. Cache and refresh ~5 min before expiry.
   - **Using the token:** set `Authorization: Bearer <accessToken>` **and** `x-ms-version: 2017-11-09` or higher. Without a recent `x-ms-version`, the service rejects bearer auth ("Authentication scheme Bearer is not supported in this version").
   - **Multi-subscription / multi-tenant:** pass `--subscription <id>` / `--tenant <id>`; enumerate with `az account list` / `az account show` and let the user pick. Token is tenant-scoped; the account's tenant must match.
2. **Native interactive login via MSAL for Apple platforms.** Microsoft ships MSAL for Swift/Obj-C. Gives an in-app `az login`–equivalent (interactive browser or device-code) with **no CLI dependency** — the right path for users without the CLI. This is a separate login, complementary to option 1, not a substitute.
3. **Service principal** (client ID + secret + tenant) via client-credentials grant against `https://storage.azure.com/`. Common in CI/CD, and likely already present in Suvida's Azure Functions / Logic Apps config.
4. **Storage account access key** — simplest, still widely used. Direct Shared Key signing, no Entra involved.
5. **SAS token** — for scoped/shared access. Prefer user-delegation SAS (Entra-secured) over account-key SAS where possible.

**Critical RBAC gotcha — surface this in the UI.** Bearer/Entra auth against blob data requires a *data-plane* role: `Storage Blob Data Reader` (read/list), `Storage Blob Data Contributor` (read/write/delete), or `Storage Blob Data Owner` (full, incl. ADLS Gen2 ACLs). Management-plane roles (`Owner`, `Contributor`, `Reader`) do **not** grant blob data access — a user can have full portal control and still get 403s on the data plane. This is one of the most confusing Azure storage failures. Detect the "authenticated token but 403 on data plane" condition and show a specific message ("Your identity is authenticated but lacks a Storage Blob Data role on this account") rather than a generic auth error.

**Practical macOS concerns for shelling out to `az` / `aws`:**
- **GUI apps don't inherit the shell PATH.** A Finder-launched app won't find `az` on `$PATH`. Resolve the binary explicitly: probe `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`; optionally read the login shell config; expose a "Path to Azure CLI" override in Preferences.
- **`az` is a Python script with ~1–2s cold start.** Cache tokens aggressively; never invoke it on the hot path of every request.
- All durable secrets (keys, SPN secrets, SAS) go in the **Keychain**, never plaintext.

This need to read `~/.azure` / `~/.aws` and invoke CLIs directly drives the distribution decision below.

### Event-awareness (Azure)

Uploading a blob is not the same as triggering the pipeline meant to react to it. Some tools land files that *never fire* the expected Event Grid subscriber (Azure Functions, Logic Apps, Synapse/ADF storage-event triggers, custom webhooks). Turning this from a silent failure into a first-class, visible feature is a genuine differentiator no competing client offers.

**Why events silently fail to fire.** A `Microsoft.Storage.BlobCreated` event carries a `data.api` field naming the REST operation that created the blob, and downstream subscriptions routinely filter on it. Microsoft's own recommended practice encourages this: to ensure `BlobCreated` fires only when a block blob is fully committed, filter for `CopyBlob`, `PutBlob`, `PutBlockList`, or `FlushWithClose`. So a typical subscription filters `data.api StringIn (PutBlob, PutBlockList)` — and any client writing via a different operation produces events that don't match, so the subscriber never fires. Two traps:

1. **SFTP-endpoint uploads** emit `SftpCreate` (an initial empty blob when the file is opened) and `SftpCommit` (when contents are written) — not `PutBlob`/`PutBlockList`. An SFTP-first tool (e.g. Transmit pointed at Azure's SFTP endpoint) therefore emits events standard filters ignore. Bonus footgun: a naive subscriber reacting to `SftpCreate` fires on an empty file.
2. **Hierarchical namespace (ADLS Gen2) endpoint choice.** On HNS accounts, native DFS-path writes emit `CreateFile` / `FlushWithClose` (with a `contentOffset` field), while flat blob-API uploads emit `PutBlob` / `PutBlockList`. Which endpoint you hit (`blob.core.windows.net` vs `dfs.core.windows.net`) changes the event; a filter tuned for one shape won't fire for the other.

**Operation → emitted `data.api` value:**

| App operation | REST call | `data.api` on the event |
|---|---|---|
| Upload small blob (single shot) | `Put Blob` | `PutBlob` |
| Upload large blob (staged) | `Put Block` × N + `Put Block List` | `PutBlockList` (on commit) |
| Server-side copy / "move" | `Copy Blob` | `CopyBlob` |
| ADLS Gen2 native write (DFS endpoint) | `CreateFile` + `Flush` | `CreateFile` / `FlushWithClose` |
| SFTP endpoint write | — | `SftpCreate` then `SftpCommit` |

`BlobCreated` fires only after full commit for `PutBlob`, `PutBlockList`, `CopyBlob`, and `FlushWithClose` — which is exactly why pipelines filter for those, and why the client should prefer them.

**Design principles that fall out:**

1. **Treat "which operation writes the blob" as a deliberate, visible decision.** Default: single `PutBlob` below a configurable size threshold; staged `PutBlock` + `PutBlockList` above it. Both emit the `api` values standard subscriptions filter for. Make the threshold visible in Preferences.
2. **Never route uploads through SFTP when the goal is to trigger standard pipelines.** Use the Blob REST API (or the DFS API deliberately on HNS accounts). If SFTP is ever supported, label it clearly as event-incompatible with standard filters.
3. **Be HNS-aware and endpoint-explicit.** Detect hierarchical namespace; surface it in the account inspector ("Hierarchical namespace: enabled"); choose blob-vs-DFS endpoint deliberately and let the user see/override which uploads use, because that choice changes the emitted event.
4. **Every write operation declares the event it will emit** — the lookup table above, wired into the transfer model from day one.

**The differentiating feature — predict-and-verify the event:**

- *Deterministic prediction (needs only data-plane access — always available).* Because the emitted `data.api` is fully determined by the operation the app chooses, the app shows, per pending transfer, exactly which event will fire — e.g. "emits `BlobCreated` with `api: PutBlockList`." A data engineer reading that instantly knows whether it matches their subscription filter. This alone catches the SFTP failure at design time. **Ships in v1.**
- *Subscription matching (bonus — lights up with management RBAC).* With the Event Grid management API and `EventGrid/eventSubscriptions/read` on the storage account's system topic, the app reads actual subscription filters and warns before upload: "⚠️ This upload emits `api: SftpCommit`, but subscription `sub-process-uploads` filters for `PutBlob, PutBlockList` — it won't fire." Degrade gracefully: deterministic prediction always works with data-plane access only; subscription matching appears only when the extra management RBAC is present (many users have the storage key but not management rights). **v2.**

**Mac-assed surfacing:**
- Transfer queue: a column/badge on each transfer showing the `api` value it will emit.
- Inspector "Event Grid" section on a selected blob or pending transfer, Finder-Get-Info-styled, showing event type, `api`, and (when readable) a green check or amber warning about filter match.
- Preferences: per-account or per-container upload strategy ("always use PutBlockList for this account"), in the classic animated preference-pane style.
- Notifications: native notification on upload completion, and optionally on confirmed event acceptance if a verification path is wired up.

### Distribution & sandboxing

Reading `~/.azure` / `~/.aws` and invoking `az` / `aws` is incompatible with the App Sandbox, which cannot freely execute Homebrew binaries or read those paths. **Recommendation: do not sandbox. Distribute directly, Developer ID–signed and notarized, outside the Mac App Store** — the same path as Transmit's non-MAS build, TablePlus, and many pro dev tools. Notarization for Gatekeeper is still required and is fine; it's the sandbox specifically that's incompatible with credential-piggybacking. Decide this early: it affects entitlements, the update mechanism (Sparkle rather than MAS), and crash reporting.

## Scoping

### v1 — Mac-assed dual-cloud browser

The bar for shipping. Has to be defensible on its own as a better S3+Azure client than what exists.

- S3 and Azure Blob, both first-class providers
- Dual-pane browser with cross-provider drag-and-drop
- Tabs, multiple windows
- Robust transfer queue (pause/resume/retry, visible progress)
- Credential auto-detection from `~/.aws/credentials`, `~/.azure/`, plus SSO/CLI flows; Azure CLI session piggyback; the RBAC-aware error handling
- **Event-awareness: deterministic event prediction** (per-transfer "this will emit `api: X`"), Blob-REST-API uploads chosen to emit pipeline-friendly operations, HNS/endpoint awareness
- Read-only object metadata inspector
- Quick Look previews
- Proper Mac shell: menus, toolbar, window restoration, classic preference window, keyboard nav
- Developer ID–signed + notarized, non-sandboxed distribution

### v2 — S3/Azure parity with the web consoles, but better

The point where this becomes meaningfully better than the AWS Console + Azure Portal at their own job.

- Object metadata *editing* (content-type, cache-control, custom metadata)
- Storage class / access tier management, including Glacier/Archive restore workflows
- Versioning UI: see all versions, restore, delete specific versions
- Server-side encryption settings visible and configurable
- Presigned URL / SAS token generation (Services menu + right-click action)
- Object tags (S3) and blob index tags (Azure)
- Bucket/container-level configuration: lifecycle rules, CORS, public access settings
- **Event-awareness: subscription matching** — read Event Grid subscriptions and warn pre-upload when an event won't match a filter

### v3 — GCS and S3-compatible providers

Abstraction was designed for this from day one; now ship it.

- Google Cloud Storage as a first-class peer
- S3-compatible providers: R2, B2, Wasabi, MinIO, DigitalOcean Spaces
- Unified credential model across all providers

### v4 — Data engineering affordances

The differentiator for the actual target user.

- Parquet / CSV / JSON preview without full download (range requests + real parser)
- Schema inspection for parquet
- Object size and count rollups per prefix (the thing AWS Console refuses to show)
- Cost estimation per bucket/prefix based on storage class and size
- Diff view between two buckets or prefixes
- S3 Select / equivalent query interface

### Explicit non-goals

- **Mount-as-drive.** ExpanDrive and Mountain Duck own this. Different product, different mental model. Being an explicit *client* rather than a *mount* is also what makes event-awareness possible at all — mounts translate filesystem semantics into opaque blob operations. Don't compete here.
- **Folder sync.** A whole sub-product. Defer indefinitely.
- **Cross-platform.** Mac-only is the entire premise. iOS companion is conceivable but out of scope.
- **Enterprise admin features.** IAM policy editor, org-wide policies, etc. Out of scope.

## Risks and known hard parts

- **AppKit + modern Swift skill ramp.** LLMs are weaker on AppKit than on web frameworks. Training data skews older (Objective-C, Swift 3/4 era, IBOutlets). Mitigation: read NetNewsWire source (open-source, modern AppKit Swift) before starting; be explicit in prompts about Swift 6, async/await, programmatic UI; modernize LLM output rather than trusting it.
- **Notarization, hardened runtime, code signing.** Not glamorous, time-consuming, LLM assistance is weakest here. Budget real time. (Sandboxing is resolved by the non-sandboxed distribution decision, but signing/notarization/stapling still apply.)
- **Cross-provider transfer engine.** Streaming uploads/downloads with multipart, retries, bandwidth control, concurrent transfers — the hard part of the app. Get the abstractions right early.
- **Auth edge cases.** SSO session expiration, MFA prompts, role assumption chains, regional endpoints, FIPS endpoints, the data-plane-vs-management RBAC trap on Azure. Each is small but they compound.
- **Azure token-cache internals.** Reuse the CLI via `az account get-access-token` rather than parsing `~/.azure/` token-cache files directly — that file format is not a stable contract.
- **The Mac-assed bar is high and unforgiving.** A toolbar with the wrong style, a sidebar that doesn't collapse correctly, a preference pane that snaps instead of animating — Mac users notice in 30 seconds. The trained eye comes from studying Apple's own apps and Apple's own sample code, not from generated output.

## North star

When in doubt: what would Panic do?

Build the app you actually want to use at work. Dogfood it daily. Ship v1 when it can replace the AWS Console + Azure Portal for your day-to-day Suvida data platform work — including the thing no other tool does: telling you, before you upload, whether your blob will actually trigger the pipeline waiting for it. Everything after that is upside.

---

### Appendix — validated Azure facts underpinning this document

- Storage AAD token resource is `https://storage.azure.com/`, identical across clouds; bearer calls require `x-ms-version: 2017-11-09`+.
- Blob data-plane access requires `Storage Blob Data *` RBAC roles; management roles (Owner/Contributor/Reader) alone are insufficient.
- `BlobCreated` fires on commit for `CopyBlob` / `PutBlob` / `PutBlockList` / `FlushWithClose`; `data.api` records the operation and is filterable.
- SFTP uploads emit `SftpCreate` + `SftpCommit`; HNS native writes emit `CreateFile` / `FlushWithClose` — both differ from flat blob-API `PutBlob` / `PutBlockList` and can miss filters tuned for the other.
- Reusing the Azure CLI session via `az account get-access-token` is the same approach `AzureCliCredential` uses internally; there is no official Azure SDK for Swift, so the Azure client is hand-rolled over the REST API.
