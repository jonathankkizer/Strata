import AppKit

// Programmatic AppKit entry point: no storyboard, no @NSApplicationMain, no XIB.
// Top-level code in main.swift runs on the main actor under the Swift 6 language
// mode, so these MainActor-isolated NSApplication calls are safe here.
let application = NSApplication.shared
let strataDelegate = AppDelegate()
application.delegate = strataDelegate
application.setActivationPolicy(.regular)
application.run()
