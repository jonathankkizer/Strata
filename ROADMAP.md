# Roadmap

The near-term backlog and known gaps. For the longer-term product vision
(v1–v4 scoping), see [`DESIGN.md`](DESIGN.md) § Scoping. Defects and polish items
from the September 2026 review are tracked in [`TODO.md`](TODO.md).

## Where things stand

Working today (Azure Blob Storage only):

- **Connect** by picking a storage account from a list (Azure Resource Manager),
  with a manual-entry fallback.
- **Browse** in a sortable List view or a Finder-style **Columns** (Miller) view,
  with a bottom path bar, an object inspector/preview pane, and full keyboard
  navigation. Columns swipe sideways as one strip and resize by dragging the divider
  between them (Option for all of them, double-click to fit the longest name).
- **Sort** by Name, Kind, Date Modified, Size, or Tier — from column headers, the
  right-click menu, or View ▸ Sort By.
- **Upload** (File ▸ Upload… or drag-and-drop, including folders) as streaming,
  bounded-memory transfers with a transfer queue, plus the differentiator:
  predicting the Event Grid `data.api` each write emits.
- **Download** (File ▸ Download ⌘D / Download To… ⇧⌘D, double-click, or by dragging
  a blob out to the Finder as a file promise), sharing the upload queue's progress,
  cancel, and retry, with Safari-style download-location preferences.
- **Quick Look** (Space or ⌘Y) of real blob contents, fetched into a versioned
  preview cache, with the panel following the selection as you arrow through a
  listing.
- **Copy and paste that mean something**: ⌘C puts a file promise on the pasteboard
  (so ⌘V in the Finder downloads the blob) alongside its path and URL, and ⌘V here
  uploads files copied from the Finder.
- **Go**: Back / Forward (⌘[ / ⌘]), Enclosing Folder (⌘↑), and Go to Folder… (⇧⌘G).
- **Delete** (File ▸ Delete… ⌘⌫), for objects and whole folders. The confirmation
  expands a folder first so it can say how many objects will really go, and asks the
  account whether the delete is reversible — Azure soft delete, S3 versioning, or
  neither — rather than warning "this cannot be undone" at someone whose bucket has
  kept every version for a year.
- **Favorites**: a Finder-style Favorites section above Containers in the sidebar.
  Add with ⌃⌘T or by dragging a folder onto it, reorder by dragging, rename in
  place, jump from the Go menu with ⌃⌘1…9 — and drop files onto a saved place to
  upload there. A favorite carries its account, so it can jump across accounts,
  reconnecting on the way.
- **Reconnect on launch** to the last account and folder, with a Settings toggle.
- **Welcome window** on first launch — app identity, what the `az` CLI sign-in is
  for, and saved places to jump straight into. Suppressed when there's an account
  to reconnect to; reopenable from Window ▸ Welcome to Strata (⇧⌘1).
- **Check for Updates…** — a weekly (opt-in) and on-demand check against the
  GitHub Releases API, with skip-this-version and a Settings ▸ Updates pane. Not
  Sparkle: it reports and links, it never installs.
- **Settings** (grouped, content-sized) and a notarization-ready release workflow.

## Next steps / gaps

### Read / write operations
These are the functional gaps; several Finder shortcuts are blocked on them.
- **Rename** (Return) — implemented as copy + delete (blob storage has no native
  rename). The delete half now exists.
- **Batch delete on S3.** Deletes go one key at a time on both clouds, which buys
  honest progress and per-key failures at the cost of a round trip each. S3's
  `DeleteObjects` would collapse a thousand keys into one request; Azure has no
  equivalent worth the complexity, so this would make the two paths diverge.
- **Metadata editing** — edit `x-ms-meta-*` and content type.
- **Find / filter** (⌘F) — filter the current listing.
- **Recursive folder download** — dragging a prefix out to the Finder is
  deliberately not offered until this exists, rather than promising a directory the
  app cannot produce.
- **Undo** — nothing registers an undo action today. The skill's guidance is to
  prefer undo over a confirmation sheet, and delete deliberately does not follow it:
  there is nothing to undo *to* in object storage, so the sheet reports what the
  account will actually do instead of promising a reversal Strata cannot perform.
  Rename, which is a copy followed by a delete, could genuinely be undone.

### Quick Look
- **Progress for a slow preview**: a Quick Look fetch is silent, so a large blob on a
  slow link looks like nothing is happening between Space and the panel appearing.
  Blobs over 64 MB are refused outright rather than fetched invisibly.
- **Cache eviction**: previews accumulate under `~/Library/Caches` and are only
  reclaimed by the system. A size cap or an age sweep would be tidier.

### Transfers
- **Pause / resume** — only cancel and retry exist. True pause needs
  `cancel(byProducingResumeData:)`, which `DownloadSession` is already structured
  for, plus block-level resumption on the upload side.

### Providers
**AWS S3** is being built in stages, so the core can absorb a second provider before
one arrives rather than being retrofitted around it. Done:

- **Core prepared.** `ProviderAccount` (cloud + name) is the unit of identity, with a
  migration for favorites and preferences saved when Azure was the only option.
  `ProviderFactory` builds providers, so `connect` no longer names a cloud.
- **Event prediction generalised.** `UploadPlan` takes an `UploadTarget` and yields a
  provider-neutral `PredictedWriteEvent`. The S3 analog is real: `PutObject` emits
  `s3:ObjectCreated:Put` and a multipart upload emits
  `s3:ObjectCreated:CompleteMultipartUpload`, so a notification filtered to `:Put`
  silently misses large uploads — the same failure Azure's `data.api` prediction
  exists to catch.
- **Credentials.** `AWSCLICredentialProvider` shells out to `aws configure
  export-credentials`, which runs the whole standard chain (SSO, assume-role,
  credential_process, static keys). This is why the AWS SDK isn't a dependency: its
  main draw was that chain. `AWSConfigFile` parses `~/.aws/config` for profile names
  to populate a picker — names and hints only, never secrets.
- **Transport.** `SigV4Signer` (pinned to AWS's published `aws4_testsuite` vectors),
  `S3Endpoint` (virtual-hosted and path-style, custom hosts for MinIO/R2/Backblaze),
  and `S3RESTClient` — ListBuckets, ListObjectsV2 with continuation paging,
  HeadObject, GetObject via the shared `DownloadSession`, PutObject, and the multipart
  trio with abort-on-failure so abandoned parts don't accrue storage charges.

- **Wired up and reachable.** `S3Provider` sits on the REST client, the connect sheet
  has a provider switcher (Azure accounts from Resource Manager, S3 profiles from
  `~/.aws/config`), and the sidebar says "Buckets" rather than "Containers" when
  connected to S3. Per-bucket regions are learned lazily: the profile's region is tried
  first, and a bucket living elsewhere is found by taking S3's correction and retrying
  once, then remembered for the session — so no `GetBucketLocation` round trip before
  every first use.

Still to do:

- ~~**Delete through the provider protocol.**~~ **Done** — `StorageProvider` has
  `delete`, `listAllKeys` and `deletionRecovery`, implemented on both clouds. Rename
  is still open.
- **`GetBucketLocation` uses a regional endpoint.** `S3RESTClient.bucketRegion` signs
  for the configured region, and live S3 now answers a cross-region call with an error
  carrying no `x-amz-bucket-region`, so it resolves to `wrongRegion(correctRegion: nil)`
  — the live test `Resolves a bucket's real region` fails on this. No user impact:
  nothing in the app calls it, because `S3Provider` learns regions from the failures of
  real operations instead. The fix is to address the global `s3.amazonaws.com` endpoint,
  which is what the AWS CLI does for this one call.
- **S3-specific inspector detail** — storage class transitions, restore state for
  Glacier objects.
- ~~**Live verification.**~~ **Done** — `StrataTests/S3IntegrationTests.swift` runs
  against real S3, covering listing, paging, awkward keys, metadata, download with
  progress, PutObject round-trip, multipart, delete, region resolution, and path-style
  addressing. Skipped unless `STRATA_S3_BUCKET`, `STRATA_S3_BUCKET_EU` and
  `STRATA_S3_BUCKET_DOTTED` are set, so CI stays green without credentials. Note that
  `xcodebuild` only forwards variables prefixed `TEST_RUNNER_` into an app-hosted test
  process.

  It found three real bugs that fixtures could not have (see the commit), which is the
  argument for keeping it. What it still does **not** cover: an SSO or assume-role
  profile (the account tested uses long-lived keys, so the refresh path is unexercised),
  and S3-compatible endpoints — MinIO/LocalStack would exercise `S3Endpoint.customHost`,
  which no test currently reaches over the wire.

### Event-awareness (the differentiator — v2)
- Match the predicted `data.api` against the account's **actual Event Grid
  subscriptions** (management API), so the app can say not just *what* event a write
  emits, but whether a subscription is actually listening for it.

### Favorites
- **Stale favorites are not detected.** Blob storage has no real folders — a "folder"
  exists only while it holds blobs — so a saved place can quietly stop existing.
  Validating on launch would mean one request per favorite to prevent a case the
  empty state already handles, so they are left alone deliberately.

### Polish & preferences
- **More Settings panes** (upload strategy, credentials, event-awareness) per
  `DESIGN.md` § Preferences.
- **Multiple simultaneous account connections** in the sidebar.
- **Accessibility**: the main controls carry labels, but no VoiceOver pass has been
  run over the full browse workflow. This is the clearest remaining rubric gap and
  needs a human at a Mac — it cannot be verified headlessly.

### Distribution
- **Developer ID signing + notarization**: the tag-triggered release workflow derives
  its version from the tag and runs the tests before touching the certificate. All
  that is left is running `scripts/setup-release-secrets.sh` from a Mac that holds
  the Developer ID `.p12`. Local builds remain ad-hoc ("Sign to Run Locally").
- **Updates**: the check is implemented (GitHub Releases API, no Sparkle), but it
  cannot succeed yet and knows it. Two things are outstanding, both outside the
  code: no release has been tagged, and while the repository is **private** the
  `releases/latest` endpoint answers 404 to an unauthenticated caller — which is
  why `.noReleaseFound` is a first-class, non-alarming result rather than an
  error. Making the repository public resolves both the check and the
  authenticated-download problem for release assets (and stops private macOS
  Actions minutes billing at the 10× multiplier).
