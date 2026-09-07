import SwiftUI

@main
struct PhotoArchiveReviewApp: App {
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
