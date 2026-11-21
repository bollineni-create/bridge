#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The whole iPhone app: a one-time folder pick, then the native companion.
public struct PhoneShell: View {
    @StateObject private var store: Store
    @StateObject private var link: PhoneLink
    @State private var picking = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme

    public init() {
        let (s, l) = Store.phone()
        _store = StateObject(wrappedValue: s)
        _link = StateObject(wrappedValue: l)
    }

    public var body: some View {
        Group {
            if link.hasFolder {
                PhoneRoot()
            } else {
                setup
            }
        }
        .environmentObject(store)
        .environmentObject(link)
        .tint(P.accent)
        .onChange(of: phase) { _, p in if p == .active { link.refresh() } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { link.setFolder(url) }
        }
    }

    var setup: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Wordmark(size: 46, onDark: scheme == .dark)
            Text("Your board, your runners and what needs you, from your Mac.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 22) {
                feature("waveform", "Live runners", "See what Ultra, Pro and Qwen are doing right now.")
                feature("hand.raised.fill", "Only what needs you", "Approve, deny or finish with a swipe.")
                feature("text.bubble.fill", "Ask from anywhere", "Bridge routes it to the cheapest runner that can do it.")
            }
            .padding(.top, 40)
            Spacer(minLength: 24)
            Button { picking = true } label: {
                Text("Choose Folder").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            Text("iCloud Drive › AI › claude-bridge")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 12)
        }
        .padding(.horizontal, 32).padding(.bottom, 16)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2).foregroundStyle(P.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
