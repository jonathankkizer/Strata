import AppKit

/// Confirms a delete, then carries it out.
///
/// The sheet does three things a plain "are you sure?" cannot. It expands the folders in
/// the selection first, so the count it shows is the number of objects that will really
/// go rather than the number of rows the user clicked. It asks the account whether a
/// delete here can be undone — Azure soft delete, S3 versioning, or neither — and says
/// so, instead of warning "this cannot be undone" at someone whose bucket has kept every
/// version for a year. And it stays up for the delete itself, because a folder can take
/// a while and a progress bar that can be stopped beats a beachball.
@MainActor
final class DeleteConfirmationViewController: NSViewController {

    /// How the sheet ended. `deleted` carries whatever failed, which is empty on a clean
    /// run — a partly-failed folder delete still deleted things, so the browser has to
    /// refresh either way.
    enum Outcome {
        case cancelled
        case deleted(failures: [DeletionFailure])
    }

    private let selection: [StorageObject]
    private let container: StorageContainer
    private let provider: any StorageProvider
    private let onFinish: (Outcome) -> Void

    private var plan: DeletionPlan?
    private var recovery: DeletionRecovery = .unknown
    private var deletion: Task<Void, Never>?

    // Chrome
    private let symbol = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let recoveryLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    init(
        selection: [StorageObject],
        container: StorageContainer,
        provider: any StorageProvider,
        onFinish: @escaping (Outcome) -> Void
    ) {
        self.selection = selection
        self.container = container
        self.provider = provider
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    override func loadView() {
        symbol.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.stringValue = DeletionPlan.make(selection: selection).title

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = selection.contains(where: \.isPrefix) ? "Counting\u{2026}" : ""

        recoveryLabel.font = .systemFont(ofSize: 11)
        recoveryLabel.textColor = .secondaryLabelColor
        recoveryLabel.lineBreakMode = .byWordWrapping
        recoveryLabel.maximumNumberOfLines = 2
        recoveryLabel.stringValue = ""

        progress.style = .bar
        progress.isIndeterminate = false
        progress.isHidden = true

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSheet(_:))
        cancelButton.keyEquivalent = "\u{1b}"   // Escape

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(confirmDelete(_:))
        deleteButton.hasDestructiveAction = true
        // Nothing may be deleted until the count is in: a folder's real size is the whole
        // point of asking.
        deleteButton.isEnabled = !selection.contains(where: \.isPrefix)

        let buttons = NSStackView(views: [cancelButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let text = NSStackView(views: [titleLabel, detailLabel, recoveryLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(8, after: detailLabel)

        let root = NSView()
        for subview in [symbol, text, progress, buttons] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            symbol.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            symbol.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            symbol.widthAnchor.constraint(equalToConstant: 40),

            text.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            text.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            progress.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 14),
            progress.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 440, height: 172)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        prepare()
    }

    // MARK: - Preparation

    /// Expands the folders and asks the account about retention, concurrently — neither
    /// answer depends on the other, and the sheet is already on screen waiting for both.
    private func prepare() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            async let recoveryAnswer = provider.deletionRecovery(in: container)
            let expanded = await expandFolders()

            self.recovery = await recoveryAnswer
            let plan = DeletionPlan.make(selection: selection, expandedKeys: expanded)
            self.plan = plan

            self.titleLabel.stringValue = plan.title
            self.detailLabel.stringValue = plan.detail
            self.recoveryLabel.stringValue = self.recovery.summary
            self.applyRecoveryStyling()

            // Nothing to delete is not an error — an empty folder that turned out to be
            // only a prefix with nothing under it simply has no keys.
            self.deleteButton.isEnabled = !plan.isEmpty
            self.progress.maxValue = Double(max(plan.keys.count, 1))
        }
    }

    /// Lists every key under each selected folder. A folder that can't be listed is left
    /// with no children rather than failing the whole sheet: the objects the user could
    /// see are still deletable, and the failure surfaces when the delete runs.
    private func expandFolders() async -> [String: [StorageObject]] {
        var expanded: [String: [StorageObject]] = [:]
        for folder in selection where folder.isPrefix {
            expanded[folder.key] = (try? await provider.listAllKeys(under: folder.key, in: container)) ?? []
        }
        return expanded
    }

    /// The safest button is the default one — but which button that is depends on what
    /// the account actually does. Where the delete is reversible, Return deletes; where
    /// it is final (or Strata couldn't find out), Return cancels and deleting takes a
    /// deliberate click.
    private func applyRecoveryStyling() {
        if recovery.isRecoverable {
            deleteButton.keyEquivalent = "\r"
            cancelButton.keyEquivalent = "\u{1b}"
            symbol.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            symbol.contentTintColor = .secondaryLabelColor
        } else {
            cancelButton.keyEquivalent = "\r"
            deleteButton.keyEquivalent = ""
            symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            symbol.contentTintColor = .systemOrange
        }
    }

    // MARK: - Actions

    @objc private func confirmDelete(_ sender: Any?) {
        guard let plan, !plan.isEmpty else { return }

        // Into the running state: the sheet stays up, Delete becomes Stop.
        deleteButton.isEnabled = false
        deleteButton.keyEquivalent = ""
        cancelButton.title = "Stop"
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.action = #selector(stopDelete(_:))
        recoveryLabel.stringValue = ""
        progress.isHidden = false
        progress.doubleValue = 0

        let run = DeletionRun(provider: provider, container: container, plan: plan)
        let total = plan.keys.count

        // Progress arrives off the main actor, so it is hopped back explicitly rather
        // than captured — the closure outlives this scope and crosses isolation.
        let report: @Sendable (Int) -> Void = { [weak self] finished in
            Task { @MainActor in
                self?.progress.doubleValue = Double(finished)
                self?.detailLabel.stringValue = "Deleting \(min(finished, total)) of \(total)\u{2026}"
            }
        }

        deletion = Task { @MainActor [weak self] in
            let failures = await run.run(onProgress: report)
            self?.finish(.deleted(failures: failures))
        }
    }

    @objc private func stopDelete(_ sender: Any?) {
        // Cancelled between keys, so nothing is abandoned mid-request. What has already
        // been deleted stays deleted, which is why this still reports as a deletion.
        deletion?.cancel()
    }

    @objc private func cancelSheet(_ sender: Any?) {
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        dismiss(nil)
        onFinish(outcome)
    }
}
