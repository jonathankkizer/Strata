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
- **Settings** (grouped, content-sized) and a notarization-ready release workflow.

## Next steps / gaps

### Navigation & keyboard
- **Back / Forward** (⌘[ / ⌘]) — needs a small navigation-history stack. The last
  core-navigation keyboard gap.
- **Go to Folder…** (⌘⇧G) — type a container/prefix path to jump directly.

### Read / write operations
These are the functional gaps; several Finder shortcuts are blocked on them.
- **Download** — drag a blob out to Finder / double-click to download. Unlocks the
  items below.
- **Quick Look preview** (Space) of actual blob contents in the inspector — needs
  the download path (today the inspector shows the type icon, Finder-style).
- **Delete** (⌘⌫) — with confirmation.
- **Rename** (Return) — implemented as copy + delete (blob storage has no native
  rename).
- **Metadata editing** — edit `x-ms-meta-*` and content type.
- **Find / filter** (⌘F) — filter the current listing.

### Sorting
- **Persist** the sort field and direction across launches (currently per-session).

### Providers
- **AWS S3 provider** — currently all stubs. The biggest functional gap; makes the
  two-cloud premise real. Needs SigV4 signing, ListBuckets / ListObjectsV2,
  PutObject + multipart upload, and an event-prediction analog.

### Event-awareness (the differentiator — v2)
- Match the predicted `data.api` against the account's **actual Event Grid
  subscriptions** (management API), so the app can say not just *what* event a write
  emits, but whether a subscription is actually listening for it.

### Polish & preferences
- **Drag-and-drop upload in the Columns view** (wired for the List view today).
- **More Settings panes** (upload strategy, credentials, event-awareness) per
  `DESIGN.md` § Preferences.
- **Multiple simultaneous account connections** in the sidebar.

### Distribution
- **Developer ID signing + notarization**: the tag-triggered release workflow is
  wired, but needs the repo secrets configured and a signing identity. Local builds
  are ad-hoc ("Sign to Run Locally").
