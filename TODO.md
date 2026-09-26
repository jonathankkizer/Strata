# Review TODO

Findings from a full-codebase review on 2026-09-25 (v0.4.1, `main` at `4d89ff9`).
[`ROADMAP.md`](ROADMAP.md) holds the feature backlog; this file is the defect
and polish list from that review. Each item has enough context to pick up cold:
where the problem is, what a user sees, and the intended fix.

Line numbers are as of `4d89ff9` and will drift; search for the quoted symbol.
When an item is done, tick it and note the PR. Delete the file when it's empty.

Tiers are an order of work, not just severity. Tier 1 is small and contained
and protects data, so it goes first.

---

## Tier 1 — actions that hit the wrong object or lose data

All done in PR #34. Worth knowing for later work: a Data Lake (HNS) account
answers `400 InvalidUri` to a blob URL ending in `/` and keeps directories at the
slash-less name (verified live), and S3's `encoding-type=url` is form-style (a
space arrives as `+`, a literal `+` as `%2B`).

- [x] **I1. Azure blob URLs drop empty path segments and the trailing slash.**
  `AzureBlobRESTClient.blobURL(container:blobKey:)` (~line 361) splits the key with
  `omittingEmptySubsequences: true`, so `logs/` becomes `…/container/logs` and
  `a//b` becomes `a/b`. `DeletionPlan` (~line 91) always adds a folder's own key,
  so deleting folder `logs/` on a flat (non-HNS) account deletes a sibling *blob*
  named `logs` — and a 404 counts as success, so nothing looks wrong. The real
  `logs/` marker is never deleted either. Download, HEAD and Quick Look of
  `a//b`-style keys fetch the wrong blob. `AzureBlobProvider.objectURL` (~line 51)
  builds public URLs the same way.
  *Fix:* percent-encode the whole key as S3 does (`SigV4Signer`'s path encoding
  keeps empty segments and the trailing slash), and use it for every blob URL.
  *Test:* URL for `logs/`, `a//b`, `/lead`, `sp ace`, `ü`, `#`, `?`, `%`, `+`.

- [x] **I2. S3 list parsing trims whitespace from keys.**
  `S3XMLParsing` `didEndElement` (~line 133) trims `Key` and `Prefix`, so
  `"report.csv "` is shown, downloaded and deleted as `report.csv` (a different
  object, or a 204 no-op). Stop trimming `Key`/`Prefix`. Better: request
  `encoding-type=url` on ListObjectsV2 and percent-decode `Key`, `Prefix`,
  `StartAfter` — this also stops control characters in keys from breaking the XML
  parse. (Continuation tokens are not URL-encoded; leave them alone.)

- [x] **I3. Cancelling a multipart S3 upload never aborts it.**
  `S3RESTClient.putObjectMultipart` catch block (~line 309) runs
  `try? await abortMultipartUpload` in the task that was just cancelled; URLSession's
  async API fails immediately with -999 there, so the DELETE never leaves. Parts
  stay and bill. *Fix:* run the abort in an unstructured `Task {}` (not inheriting
  cancellation) and await it. Consider noting the `AbortIncompleteMultipartUpload`
  lifecycle rule somewhere user-visible.

- [x] **I4. S3 part size is capped at the multipart threshold.**
  `S3Provider` (~line 150) passes `plan.singleShotThreshold` (8 MiB) as the part
  size. S3 allows 10,000 parts, so anything over ~78 GiB fails at part 10,001 after
  uploading everything else. *Fix:* part size =
  `max(threshold, 5 MiB, ceil(size / 10_000))`, rounded up to a MiB; keep the
  threshold for the single-vs-multipart decision only.

- [x] **I5. S3 full-key listing drops nested folder markers.**
  The `!key.hasSuffix("/") || size > 0` filter in `S3XMLParsing` (~line 152) also
  applies when `listAllKeys` lists without a delimiter, so zero-byte markers like
  `logs/sub/` survive a folder delete and `logs/` reappears. *Fix:* apply the
  filter only when listing with a delimiter (browse), not for `listAllKeys`.

- [x] **I6. Azure query strings leave `+` unencoded.**
  `AzureBlobRESTClient` list requests (~lines 101-132) use `queryItems`, which
  leaves `+` bare; Azure decodes it as a space. Browsing `C++/` shows it empty; a
  `NextMarker` with `+` can break paging. *Fix:* build `percentEncodedQueryItems`
  with a strict encoder, as `putBlockList` already does for `blockid`.

- [x] **I7. Concurrent downloads with the same name overwrite each other.**
  Collision avoidance in `BrowserSplitViewController` (~line 513) only reserves
  names within one batch. Two separate Download actions that both produce
  `data.csv` pick the same URL and the second `replaceItemAt`s the first. *Fix:*
  also treat the `localURL` of every queued/active download in `TransferQueue` as
  taken.

- [x] **I8. One undecodable favorite wipes all favorites.**
  `FavoritesStore.load` (~line 97) decodes the whole array with `try?`; one bad
  entry yields `[]` and the next `commit()` overwrites the stored data. *Fix:*
  decode element by element, skipping bad entries, and never write back over data
  that failed to load.

- [x] **I9. Debug code shipped in 0.4.1.** A `// SMOKE` block in
  `AppDelegate.applicationShouldHandleReopen` (~lines 41-48) builds a throwaway
  connect sheet, reads `~/.aws/config`, creates an S3 provider and writes to
  stderr on every Dock click with no windows. Delete it.

## Tier 2 — reliability

R2–R6 done in PR #35: errors now go through `StorageErrorText` (one place, knows
the cloud), and the CLIs run through `CLIProcess` (discovery, PATH, timeout,
cancel). A refresh is shared by concurrent callers, so one caller's Stop doesn't
kill the CLI for the others; the 60 s timeout bounds it instead.

- [x] **R0. The delete sheet under-reports when a folder can't be listed.**
  `DeleteConfirmationViewController.expandFolders` turns a failed listing into
  "no children" (deliberately — the comment explains why), so the sheet says
  "1 object" for a folder of thousands. Nothing extra is deleted, but the count
  is wrong. Show "Couldn't list the contents of X" in the sheet instead. (PR #38:
  says so and disables Delete.)

- [x] **R1. No retries or backoff anywhere.** (PR #36 — per-request retries; resuming is split out as R1b below.) Nothing handles 429/503,
  `SlowDown`, `ServerBusy`, `Retry-After`, a network drop or sleep/wake. One
  failed part aborts a 50 GB upload, and Retry starts from byte 0. *Fix:* a shared
  retry policy (jittered exponential backoff, honour `Retry-After`, max ~5
  attempts) for idempotent requests and individual parts/blocks; keep completed
  block IDs / part ETags on the `TransferItem` so Retry resumes. Downloads: resume
  data from `DownloadSession` (already structured for it).

- [x] **R1b. Retry after a failed transfer starts again from zero.** (PR #41) Per-request
  retries (R1) ride out blips, but once a transfer does fail, pressing Retry
  re-sends every part. Keep completed block IDs / part ETags (and the S3 upload
  ID) on the `TransferItem` so Retry resumes; for downloads, use
  `cancel(byProducingResumeData:)` in `DownloadSession`.

- [x] **R2. CLI errors are unreadable.** `AzureCLIError` / `AWSCLIError` aren't
  `LocalizedError`, and `BrowserSplitViewController.connect`'s generic catch
  (~line 777) shows "Strata.AzureCLIError error 0" for a missing CLI or an expired
  login — the most common first-run failure. The connect picker
  (`ConnectAccountViewController` ~line 416) says "You can still enter a name
  below", which will fail the same way. *Fix:* `LocalizedError` with
  `recoverySuggestion` (install command; `az login`; `aws sso login --profile x`),
  map them in the connect path and the picker.

- [x] **R3. CLI discovery misses common installs; the override is unwired.**
  `AzureAuth` / `AWSAuth` search only `/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/bin`. pipx (`~/.local/bin`), MacPorts (`/opt/local/bin`), nix, asdf, conda
  fail when launched from Finder. `explicitBinaryPath` exists but nothing passes
  it (`ProviderFactory` ~lines 17, 23). Also `credential_process` helpers
  (aws-vault, granted, 1Password) run with the minimal GUI PATH. *Fix:* more search
  paths, a login-shell fallback (`$SHELL -lc 'command -v az'`, cached), a Settings
  field for the path, and pass a sensible PATH into the subprocess environment.

- [x] **R4. CLI subprocesses: no timeout, no cancel, duplicated refreshes.**
  Actor reentrancy across `await mint()` / `fetch()` in
  `AzureCLITokenProvider` / `AWSCLICredentialProvider` means every concurrent
  caller spawns its own `az`/`aws` when the cache expires (8 at once during a
  delete). A hung CLI hangs the transfer and Cancel doesn't kill it. *Fix:* share a
  single in-flight `Task` per refresh; `withTaskCancellationHandler` + a timeout
  that calls `process.terminate()`.

- [x] **R5. Token `invalidate()` is never called.** After a 401 / `ExpiredToken`
  the cached token is reused until its refresh margin; static AWS keys are cached
  for the provider's lifetime. *Fix:* on `.unauthorized`, invalidate and retry the
  request once.

- [x] **R6. Clock skew reported as a permissions problem.** `RequestTimeTooSkewed`
  (403) falls through to `dataPlaneForbidden` in `S3RESTClient.error(...)`
  (~lines 519-538), sending the user to IAM. Give it its own error and message.
  Check Azure's equivalent (`AuthenticationFailed` with a time detail).

- [ ] **R7. Large listings are all-or-nothing.** *Mostly done in PR #37:* the
  List view streams pages (merged, not re-sorted) and cancels superseded loads.
  Still open: Columns still load each column whole; no count while loading; the
  Azure 1,000-page cap is still silent. Nothing shows until every page
  has loaded; the full array is then sorted on the main actor; superseded loads
  keep running (ignored by the token, never cancelled); Azure silently stops at
  1,000 pages (`AzureBlobRESTClient` ~lines 109, 139). *Fix:* keep and cancel the
  load `Task` on navigation; stream pages into the view (append, sort at the end or
  off-main); show a count while loading; surface truncation.

## Tier 3 — everyday feel

- [x] **U1. ⌘R in List wipes the view.** (PR #37) `ObjectListViewController.reload()`
  (~line 299) empties `items` before loading, losing selection, scroll position
  and inspector. Keep rows while loading; restore selected keys and top visible
  row afterwards.

- [x] **U2. Sort change / ⌘R in Columns collapses the open path.** (PR #37)
  `ColumnBrowserViewController.applySort` (~line 1133) and the reload path
  (~line 1076) re-select via `selectRow`, which fires `handleSelection` (~line 963):
  columns to the right are removed and re-fetched and history is pushed. If the
  selected folder was deleted, a different folder is highlighted while the next
  column still shows the old contents. *Fix:* a suppress flag around programmatic
  re-selection (like `isAutoExpanding`); explicit deselect + cull when the key is
  gone.

- [ ] **U3. Right-clicking a folder in Columns navigates into it.**
  `menuNeedsUpdate` (~line 438) selects the clicked row, and in Columns selecting a
  folder opens it. The Finder's model is that a right-click doesn't change the
  selection and the menu acts on the clicked row. Doing that means the
  responder-chain commands (Download, Quick Look, Delete, Get Info) have to
  target the clicked row while a context menu's action runs, and nothing else.
  *Needs a real Mac:* it depends on when AppKit resets `clickedRow` relative to
  `menuDidClose` and the action, and getting it wrong points Delete at the wrong
  object. Tried and reverted in PR #37 for that reason. Suppressing the selection
  callback instead leaves one folder highlighted beside another's contents.

- [x] **U4. Descending sort breaks the comparator contract.** (PR #37)
  `BrowseSort.areInOrder` (~line 45) returns `!ordered` for descending, which is
  true for equal elements. Swap operands instead, and tie-break on name so equal
  sizes/dates have a stable order.

- [x] **U5. Error states are dead ends.** (PR #38 — list and picker get Try Again;
  column errors got a tooltip in PR #35. A column still has no retry button.) List errors
  (`ObjectListViewController` ~lines 350-376) have no Try Again / Reconnect
  button; column errors (~lines 1048, 1145) are one truncated line with no
  tooltip; the connect picker's error says "try again" with no button
  (`ConnectAccountViewController` ~line 413). Add the buttons and tooltips.

- [ ] **U6. Can't drop files onto an empty folder or an error page.** *Dropping
  onto an empty folder done in PR #38;* drops onto folder rows and spring-loading
  are still open.
  `showEmptyState` hides the scroll view, and the table is the only drop target.
  Register the empty-state view (or the root) for `.fileURL` and forward to
  `onDropFiles`. Related: drops only land on the current folder
  (`setDropRow(-1, .on)`, ~line 591) — accept drops on folder rows, add
  spring-loading.

- [ ] **U7. Quick Look feedback.** *The spurious beep is fixed in PR #38;* showing
  progress for a slow fetch is still open. Nothing visible happens while a large blob
  downloads; Space again restarts the fetch; arrowing with the panel open beeps on
  every step because a cancelled fetch beeps before the stale-token check
  (`QuickLookController` ~lines 75-90). Return silently on cancellation/stale;
  show progress (open the panel with a placeholder, or a spinner in the row).

- [x] **U8. Find / filter (⌘F).** (PR #42) `NSSearchToolbarItem` bound to ⌘F (Edit ▸
  Find) filtering the current listing, both views.

- [x] **U9. Transfers are only reachable from a toolbar popover.** (PR #40) Add Window ▸
  Transfers (⌥⌘L, Safari's), a Dock badge + Dock progress, a user notification
  when a transfer finishes while inactive (DESIGN.md promises it), and a tooltip or
  wrapping on the failure line in `TransferRowView` (~line 159).

- [ ] **U10. Columns view is single-select and not a drop target.**
  `allowsMultipleSelection = false` (~line 223). Allow multi-select (cull columns
  to the right when count ≠ 1); per-column `validateDrop`/`acceptDrop`.

- [x] **U11. Connect sheet can connect to the wrong account.** (PR #38)
  `resolvedAccountName()` (~line 453) prefers the selected row over a typed name.
  Clear the row selection when the manual field is edited, and vice versa.

- [ ] **U12. Window and tab restoration.** `isRestorable = true` with no
  restoration class or encoded state; three tabs across two accounts come back as
  one window. Encode account + location per window; restore via
  `NSWindowRestoration`.

## Tier 4 — finish

- [ ] **F1. Sheets and alerts.** *Escape fixed in PR #38;* the silent manual update
  check and the consent prompt's timing are still open. Escape doesn't cancel the delete sheet when the
  delete is irreversible (`DeleteConfirmationViewController` ~line 186 — override
  `cancelOperation`). Escape doesn't hit "Not Now"/"Later" in
  `UpdateAlertController` (~lines 33, 54). Manual Check for Updates shows nothing
  for up to 10s. The update consent prompt (`UpdateCoordinator` ~lines 42-47,
  100-105) can appear over the Connect sheet or while inactive — guard it like the
  scheduled check.
- [x] **F2. Help.** (PR #38) ⌘? says "Help isn't available". Point it at the README /
  GitHub page with `NSWorkspace.open`.
- [ ] **F3. Toolbar and tabs.** *Tab bar + fixed in PR #38.* No Back/Forward item group (Finder has it by
  default); no Download/Delete items; tooltips repeat labels. Tab bar has no + (no
  `newWindowForTab(_:)`).
- [ ] **F4. Finder parity in the browser.** *PR #39 did: title-case sidebar
  headers, the favorite tooltip, the Kind column (Finder words, sorted the same way,
  MIME in the tooltip), relative dates, expansion tooltips on names, and ⌘↑
  selecting the folder you came from.* Still open: hard-coded sidebar fonts;
  re-clicking the selected container (needs care: a click that *changes* the
  selection also sends the action, so it would navigate twice); favorite selection
  lost on rename; the column header menu; context-menu validation; inspector
  metadata-key constraints.
  - Sidebar headers uppercased and fonts hard-coded at 13pt
    (`ContainerSidebarViewController` ~lines 222, 386, 396) — use the title as is,
    let `rowSizeStyle` choose the font.
  - Favorite tooltip prints a raw struct: `"\(favorite.account)"` (~line 426) →
    `qualifiedName`.
  - Clicking the already-selected container doesn't return to its root (~lines
    233-245) — add a single-click action.
  - Favorite selection lost on rename/reorder (`rebuildGroups` ~line 162).
  - List column "Content Type" shows raw MIME while the Sort menu says "Kind" —
    show `UTType.localizedDescription` under "Kind".
  - Dates: `doesRelativeDateFormatting` ("Today at 3:04 PM").
  - No header menu to show/hide columns.
  - `allowsExpansionToolTips` on name labels (list and columns).
  - ⌘↑ in List should select the folder you came from (`pendingSelectKey`).
  - Context menus don't validate like the main menu (Show/Hide Inspector title,
    Copy URL enabled on folders, Delete… enabled on empty-space click).
  - Inspector metadata key labels: required width + required compression
    resistance → broken constraints for long keys (`InspectorViewController`
    ~line 463).
- [ ] **F5. Settings.** Remove the minimize button; animate pane switches with the
  top edge pinned; ~~explicit pane order~~ (PR #35); refresh controls in `viewWillAppear` (the
  Welcome window's checkbox leaves Settings stale).
- [ ] **F6. Welcome window.** Return always means Connect even with a favorite
  selected; the "Reconnect to X" button is built once and goes stale.
- [ ] **F7. About panel.** *Copyright set in PR #38;* Credits.rtf still open. Empty `NSHumanReadableCopyright`; add Credits.rtf with
  the GitHub link.
- [ ] **F8. Copy pass.** Literal backticks around `az login`
  (`BrowserSplitViewController` ~lines 788-790); straight vs curly apostrophes
  (`UpdateAlertController` ~lines 71, 93); "while the repository is private"
  (~line 84); "This copy is Strata 0.4.1." (`PreferencesWindowController`
  ~line 425); ~~"asks the az CLI for a fresh token" ignores AWS~~ (PR #35); the
  self-justifying Settings caption (~lines 287-288) and "Nothing is stored here."
  (`WelcomeWindowController` ~line 133). Run proposed wording past the author.
- [ ] **F9. Localization.** Zero `String(localized:)`. Wrap user-facing strings,
  add a String Catalog, use plural variants instead of hand-rolled plurals.
- [x] **F10. Swift 6 isolation warnings.** (PR #38) `panel.dataSource`/`delegate` assigned
  from nonisolated `beginPreviewPanelControl`/`end…`
  (`BrowserSplitViewController` ~lines 807-813).
- [x] **F11. Preview cache never evicts.** (PR #39 — 512 MB, least recently used first,
  pruned at launch.) Add an LRU size cap, prune on launch.
- [x] **F12. Folder upload through a symlink** (PR #39) uses the target's path for the key
  (`UploadPlanning` ~lines 38-42); derive from the unresolved enumerator URL.
- [x] **F13. Docs drift.** (PR #39) README says S3 is stubbed. DESIGN.md promises Services
  "Upload to…", AppleScript, App Intents, completion notifications, a CLI-path
  setting and a visible upload threshold — none exist. Update README; mark DESIGN
  items as roadmap.

## Notes for whoever picks this up

- Two live S3 tests fail on `main` for reasons outside the code: "Resolves a
  bucket's real region" (the known `GetBucketLocation` issue in ROADMAP.md) and
  "Reads real sizes and modification dates", which expects the objects seeded in
  August to be under 30 days old. Loosen or reseed.
- The Azure live suite runs against a Data Lake account; its assertions accept
  both account shapes since PR #34.

- The host is headless: AppKit UI can't be observed here (see the project
  memory). UI items need a check on a real Mac; say so in the PR.
- Data-path items (Tier 1, R1, R4, R5) have live integration suites:
  `StrataTests/S3IntegrationTests.swift` and the Azure delete suite. `xcodebuild`
  only forwards env vars prefixed `TEST_RUNNER_` into the app-hosted tests.
- Any launch-time modal must be skipped under tests (`UpdateCoordinator.isRunningTests`)
  or CI hangs.
