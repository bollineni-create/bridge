#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The whole iPhone app: a one-time folder pick, then the companion.
public struct PhoneShell: View {
    @StateObject private var store: Store
    @StateObject private var link: PhoneLink
    @State private var picking = false
    @Environment(\.scenePhase) private var phase

    public init() {
        let (s, l) = Store.phone()
        _store = StateObject(wrappedValue: s)
        _link = StateObject(wrappedValue: l)
    }

    public var body: some View {
        Group {
            if link.hasFolder {
                CompanionRoot().environmentObject(store)
            } else {
                setup
            }
        }
        .background(D.paper.ignoresSafeArea())
        .onChange(of: phase) { _, p in if p == .active { link.refresh() } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { link.setFolder(url) }
        }
    }

    var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 44).padding(.bottom, 20)
            Rule(heavy: true)
            Text("Your board, your runners and what needs you, from the Mac.")
                .font(D.heading(24)).tracking(-0.8).foregroundStyle(D.ink).padding(.top, 20)
            VStack(alignment: .leading, spacing: 10) {
                step("1", "Tap Choose folder.")
                step("2", "Go to iCloud Drive › AI and pick claude-bridge.")
                step("3", "That's it. Bridge reads the board from there and sends your taps back to your Mac.")
            }.padding(.top, 24)
            Spacer()
            Button { picking = true } label: { Text("Choose folder").frame(maxWidth: .infinity) }
                .buttonStyle(SquareButton(solid: true))
        }
        .padding(28)
    }

    func step(_ n: String, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).font(D.heading(16)).foregroundStyle(D.red).frame(width: 18, alignment: .leading)
            Text(t).font(D.a(16)).foregroundStyle(D.body)
        }
    }
}
#endif
