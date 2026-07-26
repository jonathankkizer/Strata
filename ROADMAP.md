# Roadmap

The near-term backlog and known gaps. For the longer-term product vision
(v1–v4 scoping), see [`DESIGN.md`](DESIGN.md) § Scoping.

## Where things stand

Working today (Azure Blob Storage only):

- **Connect** by picking a storage account from a list (Azure Resource Manager),
  with a manual-entry fallback.
- **Browse** in a sortable List view or a Finder-style **Columns** (Miller) view,
  with a bottom path bar, an object inspector/preview pane, and full keyboard
  navigation.
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
- **Delete** (⌘⌫) — with confirmation.
- **Rename** (Return) — implemented as copy + delete (blob storage has no native
  rename).
- **Metadata editing** — edit `x-ms-meta-*` and content type.
- **Find / filter** (⌘F) — filter the current listing.
- **Recursive folder download** — dragging a prefix out to the Finder is
  deliberately not offered until this exists, rather than promising a directory the
  app cannot produce.
- **Undo** — nothing registers an undo action today. Delete and rename will need it;
  the skill's guidance is to prefer undo over a confirmation sheet.

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
- **AWS S3 provider** — currently all stubs. The biggest functional gap; makes the
  two-cloud premise real. Needs SigV4 signing, ListBuckets / ListObjectsV2,
  PutObject + multipart upload, and an event-prediction analog.

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
- **Drag-and-drop upload in the Columns view** (wired for the List view today;
  dragging blobs *out* works in both).
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
