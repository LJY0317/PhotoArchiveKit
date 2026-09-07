import AppKit
import SwiftUI

final class PhotoArchiveReviewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PhotoArchiveReviewApp: App {
    @NSApplicationDelegateAdaptor(PhotoArchiveReviewAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PhotoArchiveKit") {
            ReviewRootView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("다시 불러오기") {
                    NotificationCenter.default.post(name: .photoArchiveReloadReview, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let photoArchiveReloadReview = Notification.Name("PhotoArchiveReloadReview")
}
