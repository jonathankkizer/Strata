import AppKit

/// Builds the app's menu bar programmatically. AppKit menu validation flows
/// through the responder chain, so most items target `nil` (first responder)
/// and use standard AppKit selectors; app-specific items target the delegate.
@MainActor
enum MainMenu {

    static func build(target: AppDelegate, favoritesMenuDelegate: any NSMenuDelegate) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(target: target))
        mainMenu.addItem(fileMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(goMenuItem(favoritesMenuDelegate: favoritesMenuDelegate))
        mainMenu.addItem(windowMenuItem(target: target))
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    private static func appMenuItem(target: AppDelegate) -> NSMenuItem {
        submenu("Strata") { menu in
            menu.addItem(withTitle: "About Strata", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            // Directly under About, which is where every Mac app that checks for its
            // own updates puts this (and where Sparkle's own menu item goes).
            let checkForUpdates = menu.addItem(
                withTitle: "Check for Updates\u{2026}",
                action: #selector(AppDelegate.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            checkForUpdates.target = target
            menu.addItem(.separator())
            let settings = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
            settings.target = target
            menu.addItem(.separator())
            // Standard App-menu Services submenu; AppKit populates it from the
            // system's registered services for whatever is on the pasteboard.
            let services = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
            let servicesMenu = NSMenu(title: "Services")
            services.submenu = servicesMenu
            NSApp.servicesMenu = servicesMenu
            menu.addItem(.separator())
            menu.addItem(withTitle: "Hide Strata", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Strata", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
    }

    private static func fileMenuItem(target: AppDelegate) -> NSMenuItem {
        submenu("File") { menu in
            let newWindow = menu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newBrowserWindow(_:)), keyEquivalent: "n")
            newWindow.target = target
            let newTab = menu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newBrowserTab(_:)), keyEquivalent: "t")
            newTab.target = target
            menu.addItem(.separator())
            // Finder convention: ⌘O opens (descends into) the selected folder.
            menu.addItem(withTitle: "Open", action: #selector(BrowserSplitViewController.openSelection(_:)), keyEquivalent: "o")
            // Finder's Quick Look shortcut. Space does the same thing from the
            // browse surfaces; the menu item is what makes it discoverable.
            menu.addItem(withTitle: "Quick Look", action: #selector(BrowserSplitViewController.toggleQuickLook(_:)), keyEquivalent: "y")
            menu.addItem(.separator())
            // Targets nil so it routes through the responder chain to the key
            // window's BrowserSplitViewController. Cmd+K mirrors Finder's
            // "Connect to Server".
            // Finder's command, shortcut, and placement for saving a place.
            let addToSidebar = menu.addItem(withTitle: "Add to Sidebar", action: #selector(BrowserSplitViewController.addToSidebar(_:)), keyEquivalent: "t")
            addToSidebar.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(.separator())
            menu.addItem(withTitle: "Upload…", action: #selector(BrowserSplitViewController.uploadFiles(_:)), keyEquivalent: "u")
            // Safari's pairing: plain Download goes to the download folder, the
            // "To…" variant always asks. ⌘D is free here — there is nothing to
            // duplicate, which is what Finder spends it on.
            menu.addItem(withTitle: "Download", action: #selector(BrowserSplitViewController.downloadSelection(_:)), keyEquivalent: "d")
            let downloadTo = menu.addItem(withTitle: "Download To…", action: #selector(BrowserSplitViewController.downloadSelectionTo(_:)), keyEquivalent: "d")
            downloadTo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            // Finder's shortcut for Move to Trash, on the command that is as close as
            // object storage gets. Named "Delete…" rather than "Move to Trash" because
            // there is no Trash to move it to, and the ellipsis promises the
            // confirmation sheet that says whether it can be undone.
            let delete = menu.addItem(withTitle: "Delete…", action: #selector(BrowserSplitViewController.deleteSelection(_:)), keyEquivalent: "\u{8}")
            delete.keyEquivalentModifierMask = [.command]
            menu.addItem(.separator())
            menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }
    }

    private static func editMenuItem() -> NSMenuItem {
        submenu("Edit") { menu in
            menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }
    }

    private static func viewMenuItem() -> NSMenuItem {
        submenu("View") { menu in
            // Finder convention: ⌘1 / ⌘2 switch view layout.
            menu.addItem(withTitle: "as List", action: #selector(BrowserSplitViewController.showAsList(_:)), keyEquivalent: "1")
            menu.addItem(withTitle: "as Columns", action: #selector(BrowserSplitViewController.showAsColumns(_:)), keyEquivalent: "2")
            menu.addItem(.separator())
            // Finder convention: Sort By, with ⌃⌥⌘1…5 for the fields.
            let sortBy = menu.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "")
            sortBy.submenu = SortMenu.makeMenu(shortcuts: true)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Refresh", action: #selector(BrowserSplitViewController.refreshListing(_:)), keyEquivalent: "r")
            // Cmd+I: the Finder "Get Info" convention for a metadata inspector.
            menu.addItem(withTitle: "Show Inspector", action: #selector(BrowserSplitViewController.toggleObjectInspector(_:)), keyEquivalent: "i")
            menu.addItem(.separator())
            // Finder convention: ⌃⌘S toggles the sidebar.
            let toggleSidebar = menu.addItem(withTitle: "Hide Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            toggleSidebar.keyEquivalentModifierMask = [.command, .control]
            let toggleToolbar = menu.addItem(withTitle: "Hide Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
            toggleToolbar.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(withTitle: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
                .keyEquivalentModifierMask = [.command, .control]
        }
    }

    /// Finder's Go menu: history, then hierarchy, then jumping somewhere by name.
    /// Enclosing Folder and Connect live here rather than in View and File because
    /// this is where a Mac user looks for them.
    private static func goMenuItem(favoritesMenuDelegate: any NSMenuDelegate) -> NSMenuItem {
        submenu("Go") { menu in
            // Saved places are appended by the delegate each time the menu opens.
            menu.delegate = favoritesMenuDelegate
            let back = menu.addItem(withTitle: "Back", action: #selector(BrowserSplitViewController.goBack(_:)), keyEquivalent: "[")
            back.keyEquivalentModifierMask = [.command]
            let forward = menu.addItem(withTitle: "Forward", action: #selector(BrowserSplitViewController.goForward(_:)), keyEquivalent: "]")
            forward.keyEquivalentModifierMask = [.command]
            let enclosing = menu.addItem(
                withTitle: "Enclosing Folder",
                action: #selector(BrowserSplitViewController.navigateToEnclosingFolder(_:)),
                keyEquivalent: String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1)
            )
            enclosing.keyEquivalentModifierMask = [.command]
            menu.addItem(.separator())
            let goTo = menu.addItem(withTitle: "Go to Folder…", action: #selector(BrowserSplitViewController.goToFolder(_:)), keyEquivalent: "g")
            goTo.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            // ⌘K mirrors Finder's "Connect to Server…".
            menu.addItem(withTitle: "Connect to Storage Account…", action: #selector(BrowserSplitViewController.connectStorageAccount(_:)), keyEquivalent: "k")
        }
    }

    private static func windowMenuItem(target: AppDelegate) -> NSMenuItem {
        submenu("Window") { menu in
            menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            // Xcode's placement and shortcut for getting the launcher back once it has
            // been dismissed — otherwise turning off "show on launch" hides it forever.
            let welcome = menu.addItem(
                withTitle: "Welcome to Strata",
                action: #selector(AppDelegate.showWelcomeWindow(_:)),
                keyEquivalent: "1"
            )
            welcome.keyEquivalentModifierMask = [.command, .shift]
            welcome.target = target
            // Safari's shortcut for its Downloads list.
            let transfers = menu.addItem(
                withTitle: "Transfers",
                action: #selector(AppDelegate.showTransfers(_:)),
                keyEquivalent: "l"
            )
            transfers.keyEquivalentModifierMask = [.command, .option]
            transfers.target = target
            menu.addItem(.separator())
            menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
            NSApp.windowsMenu = menu
        }
    }

    private static func helpMenuItem() -> NSMenuItem {
        submenu("Help") { menu in
            // There's no Help Book; the README is the manual. Without this the item
            // says "Help isn't available for Strata."
            menu.addItem(withTitle: "Strata Help", action: #selector(AppDelegate.showStrataHelp(_:)), keyEquivalent: "?")
            NSApp.helpMenu = menu
        }
    }
}
