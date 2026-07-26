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
- **Settings** (grouped, content-sized) and a notarization-ready release workflow.

## Next steps / gaps

### Navigation & keyboard
- **Back / Forward** (⌘[ / ⌘]) — needs a small navigation-history stack. The last
  core-navigation keyboard gap.
- **Go to Folder…** (⌘⇧G) — type a container/prefix path to jump directly.

### Read / write operations
These are the functional gaps; several Finder shortcuts are blocked on them.
- **Quick Look preview** (Space) of actual blob contents. The download path now
  exists, so this is unblocked: fetch to a cache directory and hand the file to
  `QLPreviewPanel`. Today the inspector shows the type icon, Finder-style.
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

### Polish & preferences
- **Drag-and-drop upload in the Columns view** (wired for the List view today;
  dragging blobs *out* works in both).
- **More Settings panes** (upload strategy, credentials, event-awareness) per
  `DESIGN.md` § Preferences.
- **Multiple simultaneous account connections** in the sidebar.
- **Reconnect on launch** to the last account, which is also what would make
  restoring the last browse location meaningful.
- **Accessibility**: the main controls carry labels, but no VoiceOver pass has been
  run over the full browse workflow.

### Distribution
- **Developer ID signing + notarization**: the tag-triggered release workflow is
  wired, but needs the repo secrets configured and a signing identity. Local builds
  are ad-hoc ("Sign to Run Locally").
