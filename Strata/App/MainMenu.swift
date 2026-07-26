import AppKit

/// Builds the app's menu bar programmatically. AppKit menu validation flows
/// through the responder chain, so most items target `nil` (first responder)
/// and use standard AppKit selectors; app-specific items target the delegate.
@MainActor
enum MainMenu {

    static func build(target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(target: target))
        mainMenu.addItem(fileMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
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
            menu.addItem(withTitle: "Connect to Azure Storage Account…", action: #selector(BrowserSplitViewController.connectAzureStorageAccount(_:)), keyEquivalent: "k")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Upload…", action: #selector(BrowserSplitViewController.uploadFiles(_:)), keyEquivalent: "u")
            // Safari's pairing: plain Download goes to the download folder, the
            // "To…" variant always asks. ⌘D is free here — there is nothing to
            // duplicate, which is what Finder spends it on.
            menu.addItem(withTitle: "Download", action: #selector(BrowserSplitViewController.downloadSelection(_:)), keyEquivalent: "d")
            let downloadTo = menu.addItem(withTitle: "Download To…", action: #selector(BrowserSplitViewController.downloadSelectionTo(_:)), keyEquivalent: "d")
            downloadTo.keyEquivalentModifierMask = [.command, .shift]
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
            let enclosing = menu.addItem(withTitle: "Enclosing Folder", action: #selector(BrowserSplitViewController.navigateToEnclosingFolder(_:)), keyEquivalent: String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1))
            enclosing.keyEquivalentModifierMask = [.command]
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

    private static func windowMenuItem() -> NSMenuItem {
        submenu("Window") { menu in
            menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
            NSApp.windowsMenu = menu
        }
    }

    private static func helpMenuItem() -> NSMenuItem {
        submenu("Help") { menu in
            menu.addItem(withTitle: "Strata Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
            NSApp.helpMenu = menu
        }
    }
}
