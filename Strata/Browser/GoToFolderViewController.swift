import AppKit

/// Finder's Go to Folder (⇧⌘G), for blob storage: type `container/prefix` and land
/// there. A sheet rather than a window, because it acts on one browser window.
@MainActor
final class GoToFolderViewController: NSViewController {

    private let onGo: (BrowserLocation) -> Void
    private let initialPath: String
    private let pathField = NSTextField()
    private let goButton = NSButton(title: "Go", target: nil, action: nil)

    init(initialPath: String, onGo: @escaping (BrowserLocation) -> Void) {
        self.initialPath = initialPath
        self.onGo = onGo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Go to the folder:")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        pathField.placeholderString = "container/folder"
        pathField.stringValue = initialPath
        pathField.font = .systemFont(ofSize: 13)
        pathField.delegate = self
        pathField.translatesAutoresizingMaskIntoConstraints = false
        // Return in the field is Go; Escape cancels via the standard sheet handling.
        pathField.target = self
        pathField.action = #selector(go(_:))

        let hint = NSTextField(labelWithString: "A container name, optionally followed by a folder path.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Escape

        goButton.bezelStyle = .rounded
        goButton.target = self
        goButton.action = #selector(go(_:))
        goButton.keyEquivalent = "\r"           // Return is the default button

        let buttons = NSStackView(views: [cancelButton, goButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let root = NSView()
        for subview in [title, pathField, hint, buttons] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            pathField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            hint.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),

            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 460, height: 160)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pathField)
        // Select the whole path so typing replaces it, but the current location is
        // still there to edit — the same behaviour as Finder's sheet.
        pathField.currentEditor()?.selectAll(nil)
        updateGoEnabled()
    }

    // MARK: - Actions

    @objc private func go(_ sender: Any?) {
        guard let location = BrowserLocation(path: pathField.stringValue) else {
            NSSound.beep()
            return
        }
        dismiss(nil)
        onGo(location)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
    }

    private func updateGoEnabled() {
        goButton.isEnabled = BrowserLocation(path: pathField.stringValue) != nil
    }
}

// MARK: - NSTextFieldDelegate

extension GoToFolderViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateGoEnabled()
    }
}
