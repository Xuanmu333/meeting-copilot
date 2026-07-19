import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: MeetingViewModel
    @State private var chineseIntent = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                documentsPanel
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        transcriptCard
                        replyCard
                        chineseCard
                    }
                    .padding(24)
                }
            }

            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Meeting Copilot", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "quote.bubble.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Copilot")
                    .font(.headline)
                Text("Webex English reply assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isListening {
                Label("Listening", systemImage: "waveform")
                    .foregroundStyle(.red)
            }
            Button(model.isListening ? "End meeting" : "Start meeting") {
                Task { await model.toggleMeeting() }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isListening ? .red : .blue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var documentsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MEETING FILES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.importDocuments()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add meeting files")
            }

            if model.documents.isEmpty {
                ContentUnavailableView(
                    "No meeting files",
                    systemImage: "doc.badge.plus",
                    description: Text("Add files that the assistant may use.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.documents) { document in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(document.name)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                model.remove(document)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Button("Add files…") {
                model.importDocuments()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var transcriptCard: some View {
        card(title: "What they just said", icon: "waveform") {
            Text(model.transcript.isEmpty
                 ? "Start the meeting and play Webex audio. The live English transcript will appear here."
                 : model.transcript)
                .font(.title3)
                .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)

            if !model.chineseTranslation.isEmpty {
                Divider()
                Label("中文理解", systemImage: "character.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.chineseTranslation)
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Generate reply") {
                    Task { await model.generateReply(style: .standard) }
                }
                .disabled(model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating)
            }
        }
    }

    private var replyCard: some View {
        card(title: "Suggested reply", icon: "text.bubble") {
            if model.isGenerating {
                ProgressView("Preparing a reply…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(model.suggestedReply.isEmpty
                     ? "Your short, spoken-English reply will appear here."
                     : model.suggestedReply)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .lineSpacing(7)
                    .foregroundStyle(model.suggestedReply.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }

            if !model.replySource.isEmpty {
                Label(model.replySource, systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                ForEach([ReplyStyle.shorter, .natural, .cautious], id: \.self) { style in
                    Button(style.rawValue) {
                        Task { await model.generateReply(style: style) }
                    }
                    .disabled(model.suggestedReply.isEmpty || model.isGenerating)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.suggestedReply, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.suggestedReply.isEmpty)
            }
        }
    }

    private var chineseCard: some View {
        card(title: "Say it in Chinese", icon: "character.bubble") {
            TextField("例如：时间还不能确认，要先问技术团队。", text: $chineseIntent, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Turn your intent into simple spoken English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Convert to English") {
                    let value = chineseIntent
                    chineseIntent = ""
                    Task { await model.convertChineseIntent(value) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chineseIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(model.isListening ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Audio is processed live and is not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(20)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: MeetingViewModel
    @State private var key = ""

    var body: some View {
        Form {
            Section("DeepSeek") {
                SecureField("API key", text: $key)
                Text("Stored only in your macOS Keychain. It is never written to project files or logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save key") {
                        model.saveAPIKey(key)
                        key = ""
                    }
                    Button("Remove key", role: .destructive) {
                        model.removeAPIKey()
                    }
                    Spacer()
                    Text(model.hasAPIKey ? "Key configured" : "No key configured")
                        .foregroundStyle(model.hasAPIKey ? .green : .secondary)
                }
            }
            Section("Model") {
                TextField("Model", text: $model.modelName)
                Text("Use a model available to your DeepSeek API account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
