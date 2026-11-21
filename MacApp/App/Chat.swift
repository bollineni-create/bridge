import SwiftUI
import AppKit

// Qwen has no app of its own, so Bridge is its app: saved chats, streaming answers, and his live context from this Mac on every question.

struct ChatMsg: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String            // user | assistant
    var text: String
}

struct ChatThread: Codable, Identifiable {
    var id = UUID()
    var title = "New chat"
    var updated = Date()
    var msgs: [ChatMsg] = []
}

@MainActor
final class QwenChat: ObservableObject {
    @Published var threads: [ChatThread] = []
    @Published var current: UUID?
    @Published var busy = false
    @Published var useContext = true
    @Published var error = ""
    private var job: Task<Void, Never>?
    private let file = NSHomeDirectory() + "/Library/Application Support/Bridge/qwen-chats.json"
    static let system = "You are Qwen, the owner's assistant running privately on their own Mac inside the Bridge app. Be direct and concise; give finished answers, not plans. When live data from this Mac is supplied, use it and name the source and date. Never invent facts, figures or dates. If a request needs the web, a sign-in, a payment or an action on his Mac, say exactly what is needed and suggest handing it to Claude with the hand-off button."

    init() {
        if let d = FileManager.default.contents(atPath: file), let t = try? JSONDecoder().decode([ChatThread].self, from: d) { threads = t }
        current = threads.first?.id
    }

    var index: Int? { threads.firstIndex { $0.id == current } }
    var thread: ChatThread? { index.map { threads[$0] } }

    func save() {
        if let d = try? JSONEncoder().encode(threads) { try? d.write(to: URL(fileURLWithPath: file), options: .atomic) }
    }

    func newChat() {
        if let t = thread, t.msgs.isEmpty { return }
        let t = ChatThread()
        threads.insert(t, at: 0)
        current = t.id
    }

    func remove(_ id: UUID) {
        threads.removeAll { $0.id == id }
        if current == id { current = threads.first?.id }
        save()
    }

    func stop() { job?.cancel(); busy = false; save() }

    func send(_ raw: String, model: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if index == nil { newChat() }
        guard let i = index else { return }
        if threads[i].msgs.isEmpty { threads[i].title = String(text.prefix(48)) }
        threads[i].msgs.append(ChatMsg(role: "user", text: text))
        threads[i].msgs.append(ChatMsg(role: "assistant", text: ""))
        threads[i].updated = Date()
        let id = threads[i].id
        let history = threads[i].msgs.dropLast()
        busy = true
        error = ""
        let withContext = useContext
        job = Task {
            var sys = QwenChat.system + "\nNow: " + Date().formatted(date: .complete, time: .shortened) + "."
            if withContext {
                let ctx = await bg { runBridge(["gather", text]) }.1
                if !ctx.isEmpty, !ctx.hasPrefix("(nothing") { sys += "\n\nLIVE FROM THE OWNER'S MAC:\n" + ctx }
            }
            var messages: [[String: String]] = [["role": "system", "content": sys]]
            for m in history.suffix(24) { messages.append(["role": m.role, "content": m.text]) }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 900
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["model": model, "messages": messages, "stream": true, "think": false, "keep_alive": -1, "options": ["num_ctx": 32768, "temperature": 0.3]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    if let e = o["error"] as? String { self.error = e; break }
                    if let piece = (o["message"] as? [String: Any])?["content"] as? String, let j = self.threads.firstIndex(where: { $0.id == id }), let k = self.threads[j].msgs.indices.last {
                        self.threads[j].msgs[k].text += piece
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = "Qwen did not answer: \(error.localizedDescription). Is Ollama running? (Bridge > Health)" }
            }
            self.busy = false
            self.save()
        }
    }
}

struct Bubble: View {
    let m: ChatMsg
    let busy: Bool
    var rendered: AttributedString {
        (try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text)
    }
    var body: some View {
        HStack(alignment: .top) {
            if m.role == "user" { Spacer(minLength: 80) }
            Group {
                if m.text.isEmpty && busy { ProgressView().controlSize(.small) } else { Text(rendered).textSelection(.enabled) }
            }
            .font(SW.a(14, 400))
            .foregroundStyle(m.role == "user" ? Color.white : Color.primary)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(m.role == "user" ? Color.accentColor : Ink.panel, in: Rectangle())
            if m.role != "user" { Spacer(minLength: 80) }
        }
    }
}

struct QwenView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var chat: QwenChat
    @State private var draft = ""
    @FocusState private var typing: Bool
    var model: String { store.snap?.settings["model"] ?? "qwen3.8:27b-mlx" }
    let starters = ["What's on my calendar this week?", "Summarize my unread messages", "Which reminders are due soon?", "Draft a reply to my latest email"]

    func send() { let t = draft; draft = ""; chat.send(t, model: model) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button { chat.newChat(); typing = true } label: { Label("New chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).keyboardShortcut("n", modifiers: .command)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(chat.threads) { t in
                            Button { chat.current = t.id } label: {
                                Text(t.title).font(SW.a(13.5, 400)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(chat.current == t.id ? Color.accentColor.opacity(0.16) : .clear, in: Rectangle())
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete chat", role: .destructive) { chat.remove(t.id) } }
                        }
                    }
                }
            }
            .padding(12).frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Qwen").font(SW.a(22, 800, width: 112))
                        Text("\(model) · runs on this Mac · free, private, no Claude usage").font(SW.a(13, 400)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Use my context", isOn: $chat.useContext).toggleStyle(.switch).controlSize(.small)
                        .help("Adds matching messages, mail, notes, reminders and calendar from this Mac to each question")
                    Menu {
                        Button("Claude · Ultra") { handOff("ultra") }
                        Button("Claude Pro") { handOff("pro") }
                    } label: { Label("Hand off", systemImage: "arrowshape.turn.up.right") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(chat.thread?.msgs.isEmpty ?? true)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            if let t = chat.thread, !t.msgs.isEmpty {
                                ForEach(t.msgs) { m in Bubble(m: m, busy: chat.busy).id(m.id) }
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill").font(SW.a(34, 400)).foregroundStyle(.teal)
                                    Text("Ask Qwen anything").font(SW.a(18, 600, width: 112))
                                    Text("It already has your calendar, reminders, messages, mail and notes from this Mac.").font(SW.a(13.5, 400)).foregroundStyle(.secondary)
                                    ForEach(starters, id: \.self) { s in
                                        Button(s) { draft = s; send() }.buttonStyle(QuietButton())
                                    }
                                }
                                .frame(maxWidth: .infinity).padding(.top, 70)
                            }
                            if !chat.error.isEmpty { Text(chat.error).font(SW.a(13.5, 400)).foregroundStyle(.red) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(20).frame(maxWidth: 860).frame(maxWidth: .infinity)
                    }
                    .onChange(of: chat.thread?.msgs.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: chat.current) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Qwen", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(SW.a(14, 400)).lineLimit(1...8).focused($typing)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Ink.panel, in: Rectangle())
                        .overlay(Rectangle().strokeBorder(Ink.line, lineWidth: 0.5))
                        .onSubmit(send)
                    Button { chat.busy ? chat.stop() : send() } label: {
                        Image(systemName: chat.busy ? "stop.circle.fill" : "arrow.up.circle.fill").font(SW.a(30, 400))
                    }
                    .buttonStyle(.plain).foregroundStyle(chat.busy ? Color.red : (draft.isEmpty ? Color.secondary : Color.accentColor))
                    .disabled(!chat.busy && draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: 860).frame(maxWidth: .infinity)
            }
            .background(Ink.bg)
        }
        .onAppear { typing = true }
    }

    func handOff(_ who: String) {
        guard let t = chat.thread else { return }
        let text = t.msgs.suffix(6).map { ($0.role == "user" ? "the owner: " : "Qwen: ") + $0.text }.joined(separator: "\n\n")
        store.cli(["ask", "Continue this from my Qwen chat and finish it:\n\n" + text, "--who", who])
    }
}
