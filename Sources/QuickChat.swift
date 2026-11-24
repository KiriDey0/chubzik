import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

struct QuickChatArchive: Codable, Identifiable {
    struct Entry: Codable {
        let question: String
        let answer: String
    }

    let id: UUID
    let updated: Date
    let entries: [Entry]
    var draftTitle: String? = nil

    var title: String { draftTitle ?? entries.first?.question.split(separator: "\n").first.map(String.init) ?? "Новый чат" }
}

final class QuickChatHistory: ObservableObject {
    struct SavedDraft: Codable, Equatable {
        let id: UUID
        let exchangeCount: Int
        let text: String
        let selectedText: String?
        let question: String?
        let partial: String?
        let questionHadImage: Bool
        let composerHadImage: Bool

        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedText == nil && question == nil && !composerHadImage
        }
        var title: String {
            QuickChatHistory.draftTitle(text: text, question: question, selectedText: selectedText)
        }

        var item: QuickChatArchive { QuickChatArchive(id: id, updated: .now, entries: [], draftTitle: title) }
    }

    private final class SentImages: NSObject {
        let byIndex: [Int: Data]

        init(_ byIndex: [Int: Data]) { self.byIndex = byIndex }
    }

    private static let name = "quick-chats.json"
    private static let draftName = "quick-chat-drafts.json"
    @Published private(set) var records: [QuickChatArchive]
    @Published private(set) var unsentDrafts: [QuickChatArchive] = []
    private var savedDrafts: [SavedDraft] = []
    private var recordsNeedSave = false
    private var draftsNeedSave = false

    init(persistent: Bool = true) {
        self.persistent = persistent
        records = persistent ? LocalSettings.load([QuickChatArchive].self, from: Self.name) ?? [] : []
        if persistent {
            let drafts = LocalSettings.load([SavedDraft].self, from: Self.draftName) ?? []
            savedDrafts = retained(drafts)
            unsentDrafts = savedDrafts.filter { $0.exchangeCount == 0 }.map(\.item)
        }
    }

    private let persistent: Bool

    static func draftTitle(text: String, question: String?, selectedText: String?) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = (source.isEmpty ? question ?? selectedText ?? "" : source).split(whereSeparator: \.isNewline).first
        return firstLine.map { "Черновик · " + String($0.prefix(48)) } ?? "Черновик"
    }

    private let sentImages: NSCache<NSUUID, SentImages> = {
        let cache = NSCache<NSUUID, SentImages>()
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func update(id: UUID, exchanges: [QuickChatExchange]) {
        let entries = exchanges.map { QuickChatArchive.Entry(question: $0.question.text, answer: $0.answer) }
        var images: [Int: Data] = [:]
        for (index, exchange) in exchanges.enumerated() { images[index] = exchange.question.image }
        if !images.isEmpty {
            sentImages.setObject(SentImages(images), forKey: id as NSUUID,
                                 cost: images.values.reduce(0) { $0 + $1.count })
        }
        records.removeAll { $0.id == id }
        records.insert(QuickChatArchive(id: id, updated: .now, entries: entries), at: 0)
        for entry in records.dropFirst(40) { sentImages.removeObject(forKey: entry.id as NSUUID) }
        records = Array(records.prefix(40))
        recordsNeedSave = persistent
    }

    func exchanges(in archive: QuickChatArchive) -> [QuickChatExchange] {
        let images = sentImages.object(forKey: archive.id as NSUUID)?.byIndex
        return archive.entries.enumerated().map { index, entry in
            QuickChatExchange(question: QuickChatQuestion(text: entry.question, image: images?[index]),
                              answer: entry.answer)
        }
    }

    func rememberUnsent(id: UUID, title: String) {
        forgetUnsent(id: id)
        unsentDrafts.insert(QuickChatArchive(id: id, updated: .now, entries: [], draftTitle: title), at: 0)
        unsentDrafts = Array(unsentDrafts.prefix(8))
    }

    func forgetUnsent(id: UUID) { unsentDrafts.removeAll { $0.id == id } }

    var resumeAfterLaunch: QuickChatArchive? {
        guard let draft = savedDrafts.first else { return nil }
        return records.first { $0.id == draft.id } ?? draft.item
    }

    func savedDraft(id: UUID) -> SavedDraft? { savedDrafts.first { $0.id == id } }

    func stageDraft(_ draft: SavedDraft) {
        guard persistent, savedDraft(id: draft.id) != draft else { return }
        var next = savedDrafts.filter { $0.id != draft.id }
        if !draft.isEmpty { next.insert(draft, at: 0) }
        next = retained(next)
        guard next != savedDrafts else { return }
        savedDrafts = next
        draftsNeedSave = true
    }

    func flush() -> Bool {
        // Keep the recoverable question on disk until its completed answer is in the archive.
        if recordsNeedSave {
            guard LocalSettings.save(records, as: Self.name) else { return false }
            recordsNeedSave = false
        }
        if draftsNeedSave {
            guard LocalSettings.save(savedDrafts, as: Self.draftName) else { return false }
            draftsNeedSave = false
        }
        return true
    }

    private func retained(_ drafts: [SavedDraft]) -> [SavedDraft] {
        let counts = Dictionary(records.map { ($0.id, $0.entries.count) }, uniquingKeysWith: { first, _ in first })
        var unsentCount = 0
        return drafts.filter { draft in
            guard !draft.isEmpty, counts[draft.id, default: 0] == draft.exchangeCount else { return false }
            if draft.exchangeCount > 0 { return true }
            guard unsentCount < 8 else { return false }
            unsentCount += 1
            return true
        }
    }
}

final class QuickChatModel: ObservableObject {
    enum Phase: Equatable {
        case composing, capturing, connecting, thinking, streaming, done, stopped, signIn
        case error(String)

        var isRunning: Bool { self == .connecting || self == .thinking || self == .streaming || self == .signIn }
    }

    @Published var draft = ""
    @Published var selectedText: String?
    @Published var attachment: Data?
    @Published var importingImage = false
    @Published var attachmentError: String?
    @Published var saveFailed = false
    @Published var isTransferring = false
    @Published var transferError: String?
    @Published var needsComposerImage = false
    @Published var exchanges: [QuickChatExchange] = []
    @Published var current: QuickChatQuestion?
    @Published var needsImageForRetry = false
    @Published var partial = ""
    @Published var phase: Phase = .composing
    @Published var details = false
    @Published var preview: Data?
    @Published var focus = 0

    var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isTranscript: Bool { !exchanges.isEmpty || current != nil }
    var hasTransferContent: Bool { isTranscript || !text.isEmpty || selectedText != nil || attachment != nil }
    var canTransfer: Bool {
        hasTransferContent && !phase.isRunning && phase != .capturing && !importingImage && !isTransferring
    }
    var canSend: Bool {
        !text.isEmpty && !importingImage && !needsComposerImage && !phase.isRunning && phase != .capturing && !isTransferring
    }
    var canSelectScreen: Bool { !importingImage && !phase.isRunning && phase != .capturing && preview == nil && !isTransferring }
    var hasNextAttachment: Bool { phase.isRunning && (attachment != nil || importingImage) }
    var attachmentNotice: String? {
        attachmentError ?? (needsComposerImage ? "Прикрепи изображение заново" : nil)
    }
    var desiredHeight: CGFloat {
        if preview != nil { return 322 }
        let contextHeight: CGFloat = selectedText == nil || phase.isRunning ? 0 : 34
        let errorHeight: CGFloat = (attachmentNotice == nil ? 0 : 44) + (saveFailed ? 26 : 0) + (transferError == nil ? 0 : 30)
        if !isTranscript {
            return (attachment == nil ? 52 : 117) + contextHeight + errorHeight
        }
        let base: CGFloat
        switch phase {
        case .connecting, .thinking, .signIn: base = exchanges.isEmpty ? 155 : 249
        case .error, .stopped:
            base = partial.isEmpty ? (exchanges.isEmpty ? 169 : 270) : (exchanges.isEmpty ? 269 : 348)
        default: base = exchanges.count > 1 || (!exchanges.isEmpty && current != nil) ? 348 : 269
        }
        let attachmentHeight: CGFloat = hasNextAttachment ? 34 : attachment == nil ? 0 : 65
        return base + attachmentHeight + (details ? 36 : 0) + contextHeight + errorHeight
    }
}

struct QuickChatView: View {
    @ObservedObject var model: QuickChatModel
    let send: () -> Void
    let stop: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void
    let removeAttachment: () -> Void
    let transfer: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let image = model.preview {
                preview(image)
            } else if model.isTranscript {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        transferButton
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 5)
                    transcript
                    if model.saveFailed { saveNotice }
                    if let error = model.transferError { transferNotice(error) }
                    if let error = model.attachmentNotice { notice(error) }
                    if model.hasNextAttachment {
                        HStack {
                            Label(model.importingImage ? "Загружаю изображение…" : "Изображение в следующем сообщении",
                                  systemImage: "photo")
                            Spacer()
                            removeAttachmentButton()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(OrbitStyle.muted)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                    } else if !model.phase.isRunning {
                        Divider().overlay(.white.opacity(0.06)).padding(.horizontal, 11)
                        composer
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if model.saveFailed { saveNotice }
                    if let error = model.transferError { transferNotice(error) }
                    if let error = model.attachmentNotice { notice(error) }
                    composer
                }
            }
        }
        .foregroundStyle(OrbitStyle.text)
        .modifier(OrbitPointerLight())
        .background { OrbitStyle.glass(radius: 16) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.17), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.focus, initial: true) { _, _ in focused = model.preview == nil }
        .onExitCommand(perform: dismiss)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = model.selectedText {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                    Text(text).lineLimit(1)
                        .accessibilityLabel("Выделенный текст: " + text)
                    Spacer(minLength: 0)
                    Button { model.selectedText = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Убрать выделенный текст")
                    if !model.isTranscript { transferButton }
                }
                .font(.system(size: 11))
                .foregroundStyle(OrbitStyle.muted)
                .frame(height: 26)
            }
            if let attachment = model.attachment {
                HStack(alignment: .top) {
                    photo(attachment, width: 92, height: 55)
                        .overlay(alignment: .topTrailing) {
                            removeAttachmentButton().padding(3)
                        }
                    if !model.isTranscript && model.selectedText == nil {
                        Spacer(minLength: 0)
                        transferButton
                    }
                }
            }
            HStack(spacing: 8) {
                if model.importingImage {
                    ProgressView().controlSize(.small).accessibilityLabel("Загружаю изображение")
                    if model.attachment == nil { removeAttachmentButton() }
                }
                TextField(model.isTranscript ? "Уточнить…" : "Спроси что угодно", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .disabled(model.isTransferring)
                    .accessibilityLabel(model.isTranscript ? "Уточнение" : "Вопрос")
                    .onSubmit(send)
                iconButton("arrow.up", name: "Отправить", isPrimary: model.canSend, action: send)
                    .disabled(!model.canSend)
                if !model.isTranscript && model.attachment == nil && model.selectedText == nil && model.hasTransferContent {
                    transferButton
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var transferButton: some View {
        if model.isTransferring {
            ProgressView().controlSize(.small).accessibilityLabel("Переношу в Codex")
                .frame(width: 28, height: 28)
        } else {
            iconButton("arrow.up.right", name: "Продолжить в Codex", action: transfer)
                .disabled(!model.canTransfer)
        }
    }

    private func removeAttachmentButton() -> some View {
        Button(action: removeAttachment) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(.black.opacity(0.76), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.importingImage ? "Отменить загрузку изображения" : "Убрать изображение")
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(model.exchanges.enumerated()), id: \.offset) { index, exchange in
                        bubble(exchange.question)
                        if index == model.exchanges.count - 1 && model.current == nil {
                            progress("Ход ответа", icon: "chevron.right")
                        }
                        answer(exchange.answer)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(exchange.answer, forType: .string)
                        } label: {
                            Image(systemName: "document.on.document").font(.system(size: 11))
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(OrbitStyle.muted)
                        .accessibilityLabel("Копировать ответ")
                    }
                    if let current = model.current {
                        bubble(current)
                        currentReply
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.exchanges.count, initial: true) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.partial.count) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.phase) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var currentReply: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .connecting: progress("Подключаюсь к Codex…", icon: "circle.dotted")
            case .thinking: progress(model.current?.image == nil ? "Готовлю ответ…" : "Разбираю снимок…", icon: "circle.dotted")
            case .streaming:
                if model.details { progress("Ход ответа", icon: "chevron.right") }
                answer(model.partial)
            case .signIn: progress("Жду входа в Codex…", icon: "person.crop.circle")
            case .stopped: recovery("Остановлено", icon: "stop")
            case let .error(message): recovery(message, icon: "exclamationmark.circle")
            default: EmptyView()
            }
            if model.phase.isRunning {
                HStack {
                    Spacer()
                    iconButton("minus", name: "Свернуть чат", action: dismiss)
                    iconButton("stop.fill", name: "Остановить", isPrimary: true, action: stop)
                }
            }
        }
    }

    private func progress(_ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.details.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10))
                    Text(text).font(.system(size: 11, weight: .medium))
                    if icon != "chevron.right" {
                        Image(systemName: model.details ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }
                }
                .foregroundStyle(OrbitStyle.muted)
            }
            .buttonStyle(.plain)
            if model.details {
                if model.current?.image != nil || model.exchanges.last?.question.image != nil {
                    Label("Снимок прикреплён", systemImage: "photo")
                }
                if model.phase != .connecting && model.phase != .signIn {
                    Label("Запрос отправлен", systemImage: "checkmark")
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(OrbitStyle.muted)
    }

    private func bubble(_ question: QuickChatQuestion) -> some View {
        HStack {
            Spacer(minLength: 30)
            HStack(alignment: .center, spacing: 8) {
                Text(question.text)
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let image = question.image {
                    photo(image, width: 56, height: 34)
                        .contextMenu {
                            Button("Прикрепить к уточнению") {
                                model.attachment = image
                                model.focus += 1
                            }
                            .disabled(!model.canSelectScreen)
                        }
                }
            }
            .padding(8)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func answer(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recovery(_ message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.partial.isEmpty { answer(model.partial) }
            Label(message, systemImage: icon).font(.system(size: 11)).foregroundStyle(OrbitStyle.muted)
            Button(action: retry) {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(model.importingImage || (model.needsImageForRetry && model.attachment == nil))
        }
    }

    private var saveNotice: some View {
        Label("Чат пока не сохранён", systemImage: "exclamationmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(OrbitStyle.muted)
            .padding(.horizontal, 11)
            .frame(height: 26)
    }

    private func transferNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(OrbitStyle.muted)
            .padding(.horizontal, 11)
            .frame(height: 30)
    }

    private func notice(_ message: String) -> some View {
        HStack(spacing: 6) {
            Label(message, systemImage: "exclamationmark.circle")
            if model.needsComposerImage && !model.importingImage {
                Spacer(minLength: 0)
                Button(action: removeAttachment) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Убрать вложение")
                    .help("Убрать вложение")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(OrbitStyle.muted)
        .padding([.top, .horizontal], 11)
    }

    private func photo(_ data: Data, width: CGFloat, height: CGFloat) -> some View {
        Button {
            model.preview = data
        } label: {
            Group {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo")
                }
            }
            .frame(width: width, height: height)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.14)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Открыть снимок")
    }

    private func preview(_ data: Data) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            iconButton("xmark", name: "Закрыть снимок") {
                model.preview = nil
                model.focus += 1
            }
            if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ icon: String, name: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPrimary ? OrbitStyle.ink : OrbitStyle.muted)
                .frame(width: 28, height: 28)
                .background(isPrimary ? OrbitStyle.accent : .white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .help(name)
    }
}

final class QuickChatController {
    enum Reaction { case focus, capture, attachment, thinking, writing, done, stopped, error }
    private let backend = QuickChatCodex()
    let model = QuickChatModel()
    let history: QuickChatHistory
    private let fixture: Bool
    private var panel: OverlayPanel?
    private var previousApp: NSRunningApplication?
    private var catchers: [OverlayPanel] = []
    private var captureForeground: pid_t?
    private var subscriptions: Set<AnyCancellable> = []
    private var captureTask: Task<Void, Never>?
    private var imageImport: Task<Void, Never>?
    private var loginRetry: DispatchWorkItem?
    private var pressMonitor: Any?
    private var tracking: Timer?
    private var hotspot = CGPoint.zero
    private var panelID = UUID()
    private var archiveID = UUID()
    private var hasConversation = false
    private var turnID = UUID()
    private var phaseBeforeCapture: QuickChatModel.Phase = .composing
    private struct Draft {
        let text: String
        let selectedText: String?
        let attachment: Data?
        let unfinishedQuestion: QuickChatQuestion?
        let partial: String
        let phase: QuickChatModel.Phase
        let needsImageForRetry: Bool
        let needsComposerImage: Bool
        let attachmentError: String?
        var isEmpty: Bool {
            text.isEmpty && selectedText == nil && attachment == nil && unfinishedQuestion == nil && !needsComposerImage
        }
    }
    private var drafts: [UUID: Draft] = [:]
    private var draftObservations: Set<AnyCancellable> = []
    private var draftSave: DispatchWorkItem?
    private var requestAccount: CodexChatAccount?
    private var recoveryCount = 0
    private var fixtureTask: DispatchWorkItem?
    private var fixtureSentPartial = false
    private var transferPicker: NSOpenPanel?
    private var transferClient: QuickChatCodex?
    private var lastTransferFolder: URL?

    var onReaction: ((Reaction) -> Void)?
    var onCaptureVisibility: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onPointerMoved: ((CGPoint) -> Void)?
    var onBackgroundResult: ((Bool) -> Void)?
    var isOpen: Bool { panel != nil }
    var frame: CGRect? { panel?.frame }
    var isCapturing: Bool { !catchers.isEmpty || model.phase == .capturing }

    init(history: QuickChatHistory, fixture: Bool) {
        self.history = history
        self.fixture = fixture
        model.$draft.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.scheduleDraftSave()
        }.store(in: &draftObservations)
        model.$selectedText.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.scheduleDraftSave()
        }.store(in: &draftObservations)
        model.$attachment.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] hasImage in
            if hasImage { self?.model.needsComposerImage = false }
            self?.scheduleDraftSave()
        }.store(in: &draftObservations)
    }

    func show(at point: CGPoint, archive: QuickChatArchive? = nil, startNew: Bool = false,
              imageURL: URL? = nil, selectedText: String? = nil) {
        let archive = archive ?? (!hasConversation && !startNew ? history.resumeAfterLaunch : nil)
        let switching = !hasConversation || (archive.map { $0.id != archiveID } ?? startNew)
        guard !switching || (!model.phase.isRunning && !model.isTransferring) else { return }
        if switching {
            hide(notify: false)
            saveDraft()
            let draft = Draft(text: model.draft, selectedText: model.selectedText, attachment: model.attachment,
                              unfinishedQuestion: model.current, partial: model.partial, phase: model.phase,
                              needsImageForRetry: model.needsImageForRetry, needsComposerImage: model.needsComposerImage,
                              attachmentError: model.attachmentError)
            if hasConversation, !draft.isEmpty {
                drafts[archiveID] = draft
                if model.exchanges.isEmpty {
                    let title = QuickChatHistory.draftTitle(text: draft.text, question: draft.unfinishedQuestion?.text,
                                                           selectedText: draft.selectedText)
                    history.rememberUnsent(id: archiveID, title: title)
                }
                let visibleDrafts = Set((history.records + history.unsentDrafts).map(\.id))
                drafts = drafts.filter { visibleDrafts.contains($0.key) }
            }
            archiveID = archive?.id ?? UUID()
            let restored = drafts.removeValue(forKey: archiveID)
            let saved = restored == nil ? history.savedDraft(id: archiveID) : nil
            history.forgetUnsent(id: archiveID)
            hasConversation = true
            panelID = UUID()
            imageImport?.cancel()
            imageImport = nil
            model.exchanges = archive.map { history.exchanges(in: $0) } ?? []
            model.current = restored?.unfinishedQuestion ?? saved?.question.map { QuickChatQuestion(text: $0, image: nil) }
            model.draft = restored?.text ?? saved?.text ?? ""
            model.selectedText = restored == nil ? saved?.selectedText : restored?.selectedText
            model.attachment = restored?.attachment
            model.importingImage = false
            model.attachmentError = restored?.attachmentError
            model.transferError = nil
            model.needsComposerImage = restored?.needsComposerImage ?? (saved?.composerHadImage == true)
            model.preview = nil
            model.partial = restored?.partial ?? saved?.partial ?? ""
            model.details = false
            model.needsImageForRetry = restored?.needsImageForRetry ?? (saved?.questionHadImage == true)
            if let restored {
                model.phase = restored.phase
            } else if model.current != nil {
                model.phase = model.needsImageForRetry
                    ? .error("Запрос прерван. Прикрепи изображение заново")
                    : .error("Запрос прерван перезапуском Чубзика")
            } else {
                model.phase = model.exchanges.isEmpty ? .composing : .done
            }
        }
        if let selectedText { model.selectedText = selectedText }
        hotspot = point
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        }
        if let panel {
            layout()
            panel.makeKeyAndOrderFront(nil)
            if !model.phase.isRunning { model.focus += 1 }
            if let imageURL { _ = addShelfImage(imageURL) }
            return
        }
        let window = OverlayPanel(frame: .zero, keyboard: true)
        window.becomesKeyOnlyIfNeeded = false
        window.title = "Быстрый чат Чубзика"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: QuickChatView(model: model,
            send: { [weak self] in self?.send() },
            stop: { [weak self] in self?.stop() },
            retry: { [weak self] in self?.retry() },
            dismiss: { [weak self] in self?.escape() },
            removeAttachment: { [weak self] in self?.removeAttachment() },
            transfer: { [weak self] in self?.continueInCodex() }))
        host.sizingOptions = []
        window.contentView = host
        panel = window
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.layout() }.store(in: &subscriptions)
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            let selecting = !self.catchers.isEmpty && self.catchers.contains { $0 === event.window || $0.isKeyWindow }
            guard selecting || event.window === self.panel || self.panel?.isKeyWindow == true else { return event }
            if event.keyCode == 53 {
                self.escape()
                return nil
            }
            if event.keyCode == 13,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
                if !event.isARepeat { self.toggleCapture() }
                return nil
            }
            return self.catchers.isEmpty ? event : nil
        }
        layout()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        model.focus += 1
        if fixture {
            NSLog("quick-chat visible=%@ key=%@ frame=%@", String(window.isVisible), String(window.isKeyWindow), NSStringFromRect(window.frame))
        }
        onReaction?(.focus)
        trackPointer(from: point)
        if let imageURL { _ = addShelfImage(imageURL) }
    }

    func addShelfImage(_ url: URL) -> Bool {
        importImage { QuickChatImage.read(url) }
    }

    func addClipboardImage(_ bytes: Data) -> Bool {
        importImage { QuickChatImage.read(bytes) }
    }

    private func importImage(_ read: @escaping @Sendable () -> Data?) -> Bool {
        guard isOpen, !isCapturing, !model.isTransferring else { return false }
        imageImport?.cancel()
        model.preview = nil
        hotspot = NSEvent.mouseLocation
        model.importingImage = true
        model.attachmentError = nil
        restoreComposerFocus()
        let id = panelID
        imageImport = Task { @MainActor [weak self] in
            if self?.fixture == true, CommandLine.arguments.contains("--fixture-quick-chat-slow-import") {
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { return }
            }
            let worker = Task.detached(priority: .userInitiated, operation: read)
            let image = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.panelID == id else { return }
            self.imageImport = nil
            self.model.importingImage = false
            if let image {
                self.model.attachment = image
                self.onReaction?(.attachment)
            } else {
                self.showAttachmentError("Не удалось открыть изображение")
                self.onReaction?(.error)
            }
        }
        return true
    }

    private func removeAttachment() {
        imageImport?.cancel()
        imageImport = nil
        model.importingImage = false
        model.attachment = nil
        model.attachmentError = nil
        model.needsComposerImage = false
        scheduleDraftSave()
        if !model.phase.isRunning { model.focus += 1 }
    }

    private func trackPointer(from point: CGPoint) {
        var last = point
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self, !self.isCapturing, !self.model.isTransferring else { return }
            let location = NSEvent.mouseLocation
            guard hypot(location.x - last.x, location.y - last.y) >= 1 else { return }
            last = location
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.followPointer(location) }
            self.onPointerMoved?(location)
        }
        timer.tolerance = 0.001
        tracking = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func toggleCapture() {
        if isCapturing {
            cancelCapture(restoreFocus: true)
        } else if isOpen, model.canSelectScreen {
            restoreComposerFocus()
            captureForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            makeCatchers()
        }
    }

    func escape() {
        if let transferPicker { transferPicker.cancel(nil); return }
        if isCapturing {
            cancelCapture(restoreFocus: true)
        } else if model.preview != nil {
            model.preview = nil
            model.focus += 1
        } else {
            hide()
        }
    }

    func hide(notify: Bool = true) {
        guard isOpen else { return }
        let chooser = transferPicker
        transferPicker = nil
        chooser?.cancel(nil)
        transferClient?.close()
        transferClient = nil
        model.isTransferring = false
        cancelCapture()
        onCaptureVisibility?(true)
        if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
        pressMonitor = nil
        tracking?.invalidate()
        tracking = nil
        subscriptions.removeAll()
        panel?.orderOut(nil)
        panel = nil
        model.preview = nil
        saveDraft()
        if notify {
            if NSApp.isActive, previousApp?.isTerminated == false { previousApp?.activate() }
            previousApp = nil
            onClose?()
        }
    }

    func shutDown() {
        hide(notify: false)
        draftSave?.cancel()
        fixtureTask?.cancel()
        loginRetry?.cancel()
        imageImport?.cancel()
        backend.close()
    }

    func prepareToQuit() -> Bool { saveDraft() }

    private func scheduleDraftSave(after delay: TimeInterval = 0.6) {
        guard draftSave == nil else { return }
        let pending = DispatchWorkItem { [weak self] in self?.saveDraft() }
        draftSave = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: pending)
    }

    @discardableResult private func saveDraft() -> Bool {
        draftSave?.cancel()
        draftSave = nil
        guard hasConversation else { return true }
        history.stageDraft(.init(id: archiveID, exchangeCount: model.exchanges.count, text: model.draft,
                                 selectedText: model.selectedText,
                                 question: model.current?.text, partial: model.partial.isEmpty ? nil : model.partial,
                                 questionHadImage: model.current?.image != nil || model.needsImageForRetry,
                                 composerHadImage: model.attachment != nil || model.needsComposerImage))
        let saveFailed = !history.flush()
        if model.saveFailed != saveFailed { model.saveFailed = saveFailed }
        if saveFailed { scheduleDraftSave(after: 5) }
        return !saveFailed
    }

    private func layout() {
        guard let panel, let screen = screen(at: hotspot) else { return }
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(area.width, model.preview == nil ? (model.isTranscript ? 318 : 304) : 428)
        let height = min(area.height, model.desiredHeight)
        let x = hotspot.x + 43 + width <= area.maxX ? hotspot.x + 43 : hotspot.x - 43 - width
        let y = hotspot.y - height + 24
        let next = CGRect(x: max(area.minX, min(area.maxX - width, x)),
                          y: max(area.minY, min(area.maxY - height, y)), width: width, height: height)
        if panel.frame != next { panel.setFrame(next, display: true) }
    }

    func followPointer(_ point: CGPoint) {
        guard let frame, !isCapturing, model.preview == nil, !model.isTransferring else { return }
        guard QuickChatAnchor.follows(point, from: hotspot, panel: frame) else { return }
        hotspot = point
        layout()
    }

    func refreshDisplays() {
        cancelCapture()
        layout()
    }

    func applicationActivated(_ app: NSRunningApplication) {
        let id = app.processIdentifier
        if id != getpid(), id != captureForeground { cancelCapture() }
    }

    func cancelCapture(restoreFocus: Bool = false) {
        guard isCapturing else { return }
        captureForeground = nil
        captureTask?.cancel()
        captureTask = nil
        if model.phase == .capturing { model.phase = phaseBeforeCapture }
        removeCatchers()
        selectionAppearance(visible: true)
        if restoreFocus { restoreComposerFocus() }
    }

    private func makeCatchers() {
        guard let panel else { return }
        for screen in NSScreen.screens {
            let overlay = OverlayPanel(frame: screen.frame, keyboard: true)
            overlay.title = "Выбор области"
            overlay.becomesKeyOnlyIfNeeded = true
            overlay.acceptsMouseMovedEvents = true
            overlay.level = NSWindow.Level(rawValue: panel.level.rawValue - 2)
            let target = QuickChatSelectionView(screenFrame: screen.frame)
            target.started = { [weak overlay] in
                overlay?.makeKey()
            }
            target.preview = { [weak self, weak overlay] isVisible in
                guard let self, let overlay, self.catchers.contains(where: { $0 === overlay }) else { return }
                self.selectionAppearance(visible: !isVisible)
            }
            target.completed = { [weak self, weak overlay] region in
                guard let self, let overlay, self.catchers.contains(where: { $0 === overlay }) else { return }
                self.finishSelection(region, on: screen)
            }
            target.dismiss = { [weak self] in self?.escape() }
            overlay.contentView = target
            overlay.orderFrontRegardless()
            catchers.append(overlay)
        }
        if !catchers.isEmpty { NSCursor.crosshair.set() }
    }

    private func removeCatchers() {
        guard !catchers.isEmpty else { return }
        let dismissed = catchers
        catchers.removeAll()
        for overlay in dismissed {
            (overlay.contentView as? QuickChatSelectionView)?.cancelSelection()
            overlay.orderOut(nil)
        }
        NSCursor.arrow.set()
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func selectionAppearance(visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        guard let panel, panel.alphaValue != alpha else { return }
        panel.alphaValue = alpha
        onCaptureVisibility?(visible)
    }

    private func restoreComposerFocus() {
        guard !model.phase.isRunning, let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        model.focus += 1
    }

    private func continueInCodex() {
        guard model.canTransfer, let panel else { return }
        model.transferError = nil
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(toOpen: URL(string: "codex://threads/new")!) else {
            model.transferError = "Приложение Codex не найдено"
            return
        }
        let bundledCLI = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let executable = FileManager.default.isExecutableFile(atPath: bundledCLI.path) ? bundledCLI : nil
        let context = QuickChatTransfer(exchanges: model.exchanges, unfinished: model.current, partial: model.partial,
                                        draft: model.text, selectedText: model.selectedText, attachment: model.attachment)
        let picker = NSOpenPanel()
        picker.title = "Папка для диалога Codex"
        picker.prompt = "Продолжить"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = false
        picker.directoryURL = lastTransferFolder
        picker.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        transferPicker = picker
        model.isTransferring = true
        NSApp.activate()
        picker.begin { [weak self, weak picker] response in
            guard let self, let picker, self.transferPicker === picker else { return }
            self.transferPicker = nil
            guard response == .OK, let folder = picker.url else {
                self.model.isTransferring = false
                self.restoreComposerFocus()
                return
            }
            self.lastTransferFolder = folder
            if !context.hasContext {
                self.openCodexTransfer(context.link(folder: folder), created: false)
            } else {
                self.createCodexTransfer(context, folder: folder, executable: executable)
            }
        }
    }

    private func createCodexTransfer(_ context: QuickChatTransfer, folder: URL, executable: URL?) {
        let client = QuickChatCodex(executable: executable)
        transferClient = client
        client.transfer(context, to: folder) { [weak self, weak client] result in
            guard let self, let client, self.transferClient === client else { return }
            self.transferClient = nil
            switch result {
            case .success(let thread):
                self.openCodexTransfer(context.link(to: thread), created: true)
            case .failure:
                self.model.isTransferring = false
                self.model.transferError = "Не удалось перенести диалог в Codex"
                self.restoreComposerFocus()
            }
        }
    }

    private func openCodexTransfer(_ link: URL?, created: Bool) {
        model.isTransferring = false
        guard let link, NSWorkspace.shared.open(link) else {
            model.transferError = created ? "Чат создан. Открой его в приложении Codex" : "Не удалось открыть Codex"
            restoreComposerFocus()
            return
        }
        hide(notify: false)
        previousApp = nil
        onClose?()
    }

    private func finishSelection(_ region: CGRect?, on display: NSScreen? = nil) {
        if let region, let display,
           let number = display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let window = panel, model.canSelectScreen {
            capture(QuickChatRegion.captureRect(region, on: display.frame), displayID: number.uint32Value, in: window)
        } else {
            captureForeground = nil
            selectionAppearance(visible: true)
            restoreComposerFocus()
        }
    }

    private func capture(_ region: CGRect, displayID: CGDirectDisplayID, in window: OverlayPanel) {
        phaseBeforeCapture = model.phase
        model.attachmentError = nil
        model.phase = .capturing
        removeCatchers()
        selectionAppearance(visible: false)
        onReaction?(.capture)
        let scan = panelID
        captureTask = Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            defer {
                if self.panelID == scan, self.isOpen, !Task.isCancelled {
                    self.captureForeground = nil
                    self.selectionAppearance(visible: true)
                    self.restoreComposerFocus()
                    self.captureTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(85))
                try Task.checkCancellation()
                let image: Data
                if self.fixture {
                    image = try Self.fixtureImage(region.size)
                } else {
                    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                        throw ChatCaptureError.permission
                    }
                    image = try await Self.captureDisplay(displayID, region: region)
                }
                guard self.panelID == scan, window === self.panel, !Task.isCancelled else { return }
                self.model.attachment = image
                self.model.phase = self.phaseBeforeCapture
                self.onReaction?(.attachment)
            } catch {
                guard self.panelID == scan, self.isOpen, !Task.isCancelled else { return }
                self.model.phase = self.phaseBeforeCapture
                self.showAttachmentError(error as? ChatCaptureError == .permission
                                         ? "Доступ к записи экрана выключен" : "Не удалось снять экран")
                self.onReaction?(.error)
            }
        }
    }

    private func showAttachmentError(_ message: String) {
        model.attachmentError = model.attachment == nil ? message : message + ". Предыдущее вложение осталось."
    }

    private enum ChatCaptureError: Error { case permission, unavailable }

    private static func captureDisplay(_ id: CGDirectDisplayID, region: CGRect) async throws -> Data {
        let windows = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = windows.displays.first(where: { $0.displayID == id }) else { throw ChatCaptureError.unavailable }
        let selfApps = windows.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: selfApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), 3000 / max(region.width, region.height))
        config.sourceRect = region
        config.width = max(1, Int((region.width * scale).rounded()))
        config.height = max(1, Int((region.height * scale).rounded()))
        config.showsCursor = false
        let result = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let bytes = QuickChatImage.jpeg(result)
        else { throw ChatCaptureError.unavailable }
        return bytes
    }

    private static func fixtureImage(_ size: CGSize) throws -> Data {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.13, alpha: 1).setFill()
            rect.fill()
            NSColor(srgbRed: 0.52, green: 0.75, blue: 0.67, alpha: 1).setFill()
            rect.insetBy(dx: rect.width / 8, dy: rect.height / 5).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [:]) else { throw ChatCaptureError.unavailable }
        return data
    }

    private func send() {
        guard model.canSend, !isCapturing else { return }
        let text = model.selectedText.map { "\(model.text)\n\nВыделенный текст:\n\($0)" } ?? model.text
        model.current = QuickChatQuestion(text: text, image: model.attachment)
        model.needsImageForRetry = false
        model.needsComposerImage = false
        model.draft = ""
        model.selectedText = nil
        model.attachment = nil
        model.attachmentError = nil
        model.details = false
        retry()
    }

    private func retry() {
        guard var question = model.current, !model.phase.isRunning, !isCapturing, !model.importingImage,
              !model.isTransferring else { return }
        if model.needsImageForRetry {
            guard let image = model.attachment else { return }
            question = QuickChatQuestion(text: question.text, image: image)
            model.current = question
            model.needsImageForRetry = false
            model.attachment = nil
            model.attachmentError = nil
        }
        recoveryCount = 0
        requestAccount = nil
        launch(question)
    }

    private func stop() {
        turnID = UUID()
        loginRetry?.cancel()
        loginRetry = nil
        fixtureTask?.cancel()
        fixtureTask = nil
        backend.cancel()
        model.phase = .stopped
        saveDraft()
        model.focus += 1
        onReaction?(.stopped)
    }

    private func launch(_ question: QuickChatQuestion) {
        let id = UUID()
        turnID = id
        model.partial = ""
        model.phase = .connecting
        saveDraft()
        onReaction?(.thinking)
        if fixture {
            receive(.sent, question: question)
            let sendPartial = CommandLine.arguments.contains("--fixture-quick-chat-partial") && !fixtureSentPartial
            if sendPartial {
                fixtureSentPartial = true
                receive(.text("Часть ответа уже пришла."), question: question)
            }
            let task = DispatchWorkItem { [weak self] in
                guard self?.turnID == id else { return }
                if sendPartial {
                    self?.receive(.failed(.requestFailed), question: question)
                } else {
                    self?.receive(.finished(question.image == nil ? "Это тестовый ответ." : "На тестовом снимке виден зелёный прямоугольник."), question: question)
                }
            }
            fixtureTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + (sendPartial ? 1.3 : 0.7), execute: task)
            return
        }
        backend.ask(question, previous: model.exchanges, expectedAccount: requestAccount) { [weak self] in
            guard self?.turnID == id else { return }
            self?.receive($0, question: question)
        }
    }

    private func receive(_ event: QuickChatCodex.Event, question: QuickChatQuestion) {
        switch event {
        case let .account(identity):
            if requestAccount == nil { requestAccount = identity }
        case .sent:
            if model.phase == .connecting { model.phase = .thinking }
        case let .text(value):
            if model.phase != .streaming { onReaction?(.writing) }
            model.partial = value
            model.phase = .streaming
            scheduleDraftSave()
        case let .finished(answer):
            model.exchanges.append(QuickChatExchange(question: question, answer: answer))
            model.current = nil
            model.partial = ""
            model.phase = .done
            model.details = false
            model.focus += 1
            history.update(id: archiveID, exchanges: model.exchanges)
            saveDraft()
            onReaction?(.done)
            if !isOpen { onBackgroundResult?(true) }
        case .failed(.signIn):
            if !model.partial.isEmpty {
                publishError("Вход в Codex обновился")
                return
            }
            let delays: [TimeInterval] = [3, 6, 9]
            guard recoveryCount < delays.count else {
                publishError("Войди в Codex и повтори запрос")
                return
            }
            model.phase = .signIn
            let delay = delays[recoveryCount]
            recoveryCount += 1
            let id = turnID
            let wait = DispatchWorkItem { [weak self] in
                guard self?.turnID == id else { return }
                self?.launch(question)
            }
            loginRetry = wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: wait)
        case let .failed(error):
            switch error {
            case .accountChanged: publishError("Аккаунт Codex сменился")
            case .unavailable: publishError("Codex CLI недоступен")
            case .timedOut: publishError("Codex не успел ответить")
            default: publishError("Ответ не загрузился")
            }
        }
    }

    private func publishError(_ message: String) {
        model.phase = .error(message)
        saveDraft()
        model.focus += 1
        onReaction?(.error)
        if !isOpen { onBackgroundResult?(false) }
    }
}

private final class QuickChatSelectionView: NSView {
    var started: (() -> Void)?
    var preview: ((Bool) -> Void)?
    var completed: ((CGRect?) -> Void)?
    var dismiss: (() -> Void)?
    private let screenFrame: CGRect
    private var origin: CGPoint?
    private var dragged = false
    private var selection: CGRect?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) {
        origin = screenPoint(for: event)
        started?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        dragged = true
        let old = selection
        selection = QuickChatRegion.selection(from: origin, to: screenPoint(for: event), on: screenFrame)
        if (old == nil) != (selection == nil) { preview?(selection != nil) }
        if old != selection { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin else { return }
        let result = dragged ? QuickChatRegion.selection(from: origin, to: screenPoint(for: event), on: screenFrame) : nil
        cancelSelection()
        completed?(result)
    }

    func cancelSelection() {
        origin = nil
        dragged = false
        selection = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { dismiss?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.006).setFill()
        dirtyRect.fill()
        guard let selection else { return }
        let rect = selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(rect)
        shade.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.38).setFill()
        shade.fill()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        NSColor(white: 1, alpha: 0.91).setStroke()
        outline.stroke()
    }
}
