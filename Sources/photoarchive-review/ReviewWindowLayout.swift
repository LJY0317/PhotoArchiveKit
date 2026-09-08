import SwiftUI

struct ReviewWindowLayout<Sidebar: View, Detail: View, Actions: View>: View {
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        // A safe-area inset does not reduce an embedded NSScrollView's frame.
        // Give the action bar a separate layout slot so it cannot cover either
        // scroller, regardless of SwiftUI/AppKit safe-area propagation.
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar()
            } detail: {
                detail()
            }
            actions()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
