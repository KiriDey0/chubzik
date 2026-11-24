import AppKit
import SwiftUI
import CoreAudio

struct AudioOutput: Identifiable {
    let id: AudioDeviceID
    let name: String
}

enum OutputAudio {
    static func devices() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty, AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        var output = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        return ids.compactMap { id in
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &output, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var value: Unmanaged<CFString>?
            var bytes = UInt32(MemoryLayout.size(ofValue: value))
            guard AudioObjectGetPropertyData(id, &name, 0, nil, &bytes, &value) == noErr, let value else { return nil }
            return AudioOutput(id: id, name: value.takeRetainedValue() as String)
        }
    }

    static func select(_ output: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var id = output
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout.size(ofValue: id)), &id) == noErr
    }
}

struct PanelNotice: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let destination: PanelPage?
    let codexChat: String?
}

final class PanelModel: ObservableObject {
    @Published var page: PanelPage = .music
    @Published var media: MediaItem?
    @Published var artwork: NSImage?
    @Published var sources: [MediaItem] = []
    @Published var active = false
    @Published var isPinned = false
    @Published var reducedMotion = false
    let paging = PanelPaging()
    @Published var musicPreview = false
    var showsMusicPreview: Bool { page == .music && musicPreview }
    var visiblePage: PanelContent { showsMusicPreview ? .preview : .page(page) }
    var panelWidth: CGFloat { showsMusicPreview ? NotchGeometry.compactPanelWidth : NotchGeometry.fullPanelWidth }
    var panelHeight: CGFloat {
        let height = showsMusicPreview ? NotchGeometry.compactPanelHeight : NotchGeometry.fullPanelHeight
        return ceil(height * panelScale)
    }
    var calendarSample: [CalendarEntry]?
    let calendarFeed = CalendarFeed()
    @Published var panelScale = NotchGeometry.preferredPanelScale
    @Published var notchWidth: CGFloat = 134
    @Published var shelf = ShelfState()
    @Published var shelfSelection: Set<String> = []
    @Published var shelfFeedback = ""
    @Published var download: URL?
    @Published var hasNewDownload = false
    @Published var transfers: [String: String] = [:]
    @Published var notices: [PanelNotice] = []
    @Published var shelfCanUndo = false
    @Published var shelfFocusRequest = 0
    @Published var shelfSearchRequest = 0
    @Published var taskCanUndo = false
    @Published var taskFeedback = ""
    var isEditing = false
    @Published var calendarMonth = CalendarMonth(containing: .now).interval.start
    @Published var calendarDay = CalendarMonth.calendar.startOfDay(for: .now)
    @Published var tasks: [LocalTask] = []
    @Published var weather = LocalSettings.load(WeatherReading.self, from: "weather.json")
    @Published var countdown: Countdown?
    @Published var stopwatch = Stopwatch()
    @Published var clockFeedback: String?
    @Published var noteSaveFailed = false
    @Published var note = "" {
        didSet { if oldValue != note { onSaveNote?() } }
    }
    @Published var pendingCodex: [CodexPendingRequest] = []
    @Published var completedCodex: [CodexPendingRequest] = []
    @Published var latestCompletedCodex: CodexPendingRequest?
    @Published var quickChatIsRunning = false
    @Published var quickChatHasResult = false

    var onMedia: ((MediaItem.Track, String, Double?) -> Void)?
    var onSelectSource: ((String) -> Void)?
    var onOpenSource: ((MediaItem.Track) -> Void)?
    var onAddFiles: (([URL]) -> Void)?
    var onChooseFiles: (() -> Void)?
    var onPasteFiles: (() -> Void)?
    var onPinFiles: ((Set<String>, Bool) -> Void)?
    var onRemoveFiles: ((Set<String>) -> Void)?
    var onShelfAvailability: ((Set<String>, Set<String>, Set<String>) -> Void)?
    var onUndoFiles: (() -> Void)?
    var onRemoveTask: ((UUID) -> Void)?
    var onUndoTask: (() -> Void)?
    var onPreviewFile: ((URL) -> Void)?
    var onAskAboutImage: ((URL) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onQueue: ((URL) -> Void)?
    var onTimer: ((TimeInterval?, Countdown.Phase) -> Bool)?
    var onPauseTimer: (() -> Void)?
    var onStopwatch: ((Bool) -> Void)?
    var onSaveNote: (() -> Void)?
    var onOpenQuickChat: ((QuickChatArchive?) -> Void)?
    var onResumeQuickChat: (() -> Void)?
    var onOpenCodex: ((String?) -> Void)?
    var onReadCompletedCodex: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onSaveTasks: (([LocalTask]) -> Bool)?
    var onChangePage: ((PanelPage) -> Void)?
    var onExpandMusic: (() -> Void)?

    func notice(_ message: String, destination: PanelPage? = nil, codexChat: String? = nil) {
        notices.insert(PanelNotice(message: message, destination: destination, codexChat: codexChat), at: 0)
        if notices.count > 10 { notices.removeLast() }
    }
}

struct PlayerPanel: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var quickHistory: QuickChatHistory
    @State private var dropTarget = false
    @State private var newTask = ""
    @State private var city = ""
    @State private var weatherFeedback = ""
    @State private var linkFeedback = ""
    @State private var weatherLoading = false
    @State private var weatherChoices: [WeatherLocation] = []
    @State private var weatherChoicesFor = ""
    @State private var showsCompletedTasks = false
    @State private var shelfQuery = ""
    @State private var shelfSearchOpen = false
    @AppStorage("customTimerMinutes") private var customTimerMinutes = 7
    @State private var customTimerText = ""
    @State private var showsCustomTimer = false
    @FocusState private var editor: Editor?

    private enum Editor: Hashable { case note, task, city, timer, shelfSearch }

    private func points(_ value: CGFloat) -> CGFloat { value * model.panelScale }

    private let accent = OrbitStyle.accent
    private let muted = OrbitStyle.muted
    private let tile = Color.white.opacity(0.067)

    @State private var shelfViewport = ShelfGridViewport()

    @ViewBuilder private func pageContent(_ page: PanelContent, isTurning: Bool) -> some View {
        switch page {
        case .preview: preview
        case .page(.music): music
        case .page(.shelf): shelf(isTurning: isTurning)
        case .page(let tool): tools(tool)
        }
    }

    var body: some View {
        if model.active {
            let contour = NotchContour(notchWidth: model.notchWidth, scale: model.panelScale)
            ZStack(alignment: .top) {
                if model.showsMusicPreview {
                    Button { model.onExpandMusic?() } label: {
                        contour.fill(.clear)
                            .contentShape(.interaction, contour)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Развернуть плеер")
                    .help("Развернуть плеер")
                }
                VStack(alignment: .leading, spacing: points(model.showsMusicPreview ? 9 : 13)) {
                    header
                    PanelPages(paging: model.paging, current: model.visiblePage, view: pageContent)
                }
                .padding(.horizontal, points(15))
                .padding(.top, contour.shoulderHeight + points(8))
                .padding(.bottom, points(11))
            }
            .frame(width: points(model.panelWidth), height: model.panelHeight, alignment: .top)
            .modifier(OrbitPointerLight())
            .background {
                GeometryReader { bounds in
                    let fade = min(1, points(20) / max(1, bounds.size.height))
                    ZStack {
                        OrbitStyle.glass()
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: fade * 0.17),
                            .init(color: .black.opacity(0.68), location: fade * 0.55),
                            .init(color: .clear, location: fade)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(contour)
            .overlay {
                contour.strokeBorderOverlay(dropTarget: dropTarget, accent: accent)
                    .allowsHitTesting(false)
            }
            .foregroundStyle(OrbitStyle.text)
            .preferredColorScheme(.dark)
            .tint(accent)
            .controlSize(.regular)
            .onDrop(of: [.fileURL], isTargeted: $dropTarget, perform: acceptFiles)
            .onChange(of: editor) { _, value in model.isEditing = value != nil }
            .onChange(of: model.page) { _, _ in editor = nil }
            .onDisappear { editor = nil; model.isEditing = false }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var preview: some View {
        HStack(spacing: points(10)) {
            if let item = model.media {
                sourceArtwork(size: 33, item: item)
                trackDetails(item, size: 13)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                transportControls(item, primarySize: 26, secondarySize: 22)
                    .fixedSize()
            } else {
                artwork(size: 33)
                    .allowsHitTesting(false)
                TimelineView(.everyMinute) { clock in
                    VStack(alignment: .leading, spacing: points(2)) {
                        Text(clock.date, format: .dateTime.hour().minute())
                            .font(.system(size: points(15), weight: .semibold)).monospacedDigit()
                        Text(clock.date, format: .dateTime.day().month(.wide))
                            .font(.system(size: points(11))).foregroundStyle(muted)
                    }
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                }
                .allowsHitTesting(false)
                Spacer(minLength: 0)
                Text("Ничего не играет")
                    .font(.system(size: points(10)))
                    .foregroundStyle(muted)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        ZStack {
            PanelTabBar(paging: model.paging, current: model.page, tileWidth: points(20), spacing: points(3),
                        accent: accent, muted: muted, attentionPage: model.hasNewDownload ? .shelf : nil) {
                model.onChangePage?($0)
            }
            HStack(spacing: points(3)) {
                Button { model.onTogglePin?() } label: {
                    headerTile(headerSymbol(model.isPinned ? "pin.fill" : "pin", highlighted: model.isPinned),
                               selected: model.isPinned)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPinned ? "Открепить панель" : "Закрепить панель")
                .accessibilityAddTraits(model.isPinned ? .isSelected : [])
                .help(model.isPinned ? "Открепить панель" : "Закрепить панель")
                if !model.pendingCodex.isEmpty || model.latestCompletedCodex != nil {
                    codexInbox
                }
                Spacer(minLength: 0)
                headerControls
            }
        }
    }

    private func headerSymbol(_ symbol: String, highlighted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: points(11), weight: .medium))
            .foregroundStyle(highlighted ? accent : muted)
    }

    private func headerTile<Content: View>(_ content: Content, selected: Bool = false) -> some View {
        content
            .frame(width: points(20), height: points(20))
            .background(.white.opacity(selected ? 0.085 : 0.055), in: RoundedRectangle(cornerRadius: points(5)))
            .contentShape(Rectangle())
    }

    private func headerMenu<Items: View>(_ symbol: String, highlighted: Bool = false,
                                         @ViewBuilder items: () -> Items) -> some View {
        headerTile(
            Menu(content: items) { headerSymbol(symbol, highlighted: highlighted) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        )
    }

    private var codexInbox: some View {
        let count = model.pendingCodex.count + model.completedCodex.count
        return headerTile(Menu {
            if let latest = model.latestCompletedCodex {
                Button { model.onOpenCodex?(latest.chat) } label: {
                    Label("Открыть последний ответ", systemImage: "arrow.up.right")
                }
            }
            if !model.pendingCodex.isEmpty {
                Section("Ждут действия") {
                    ForEach(model.pendingCodex) { request in
                        Button { model.onOpenCodex?(request.chat) } label: {
                            Label(request.label + " · Нужно подтверждение", systemImage: "exclamationmark.bubble")
                        }
                    }
                }
            }
            if !model.completedCodex.isEmpty {
                Section("Завершились") {
                    ForEach(model.completedCodex) { request in
                        Button { model.onOpenCodex?(request.chat) } label: {
                            Label(request.label + " · Готово", systemImage: "checkmark.circle")
                        }
                    }
                    Button("Прочитать все завершённые") { model.onReadCompletedCodex?() }
                }
            }
        } label: {
            headerSymbol("bubble.left.fill", highlighted: count > 0)
        } primaryAction: {
            if let latest = model.latestCompletedCodex { model.onOpenCodex?(latest.chat) }
            else { model.onOpenCodex?(model.pendingCodex.first?.chat) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize())
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 99 ? "99+" : count.formatted())
                    .font(.system(size: points(7.5), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, points(2))
                    .frame(minWidth: points(11), minHeight: points(11))
                    .background(Color(red: 0.32, green: 0.43, blue: 0.52), in: Capsule())
                    .overlay { Capsule().strokeBorder(Color(white: 0.11), lineWidth: points(0.7)) }
                    .offset(x: points(3), y: -points(3))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Входящие Codex")
        .accessibilityValue("Ждут действия: \(model.pendingCodex.count). Завершились: \(model.completedCodex.count).")
        .accessibilityHint("Удержать, чтобы открыть список")
        .help(model.latestCompletedCodex == nil ? "Входящие Codex · удержи для списка"
              : "Открыть последний ответ · удержи для списка")
    }

    private var headerControls: some View {
        HStack(spacing: points(3)) {
            headerMenu("bubble.left.and.bubble.right", highlighted: model.quickChatHasResult) {
                if model.quickChatIsRunning || model.quickChatHasResult {
                    Button(model.quickChatHasResult ? "Открыть ответ" : "Вернуться к ответу") {
                        model.onResumeQuickChat?()
                    }
                }
                Button("Новый чат") { model.onOpenQuickChat?(nil) }
                    .disabled(model.quickChatIsRunning)
                let records = quickHistory.unsentDrafts + quickHistory.records
                if !records.isEmpty {
                    Divider()
                    ForEach(records) { record in
                        Button { model.onOpenQuickChat?(record) } label: {
                            Text(String(record.title.prefix(58)))
                        }
                        .disabled(model.quickChatIsRunning)
                    }
                }
            }
            .accessibilityLabel("Диалоги Codex")
            .help("Диалоги Codex")
            Button { model.onOpenPreferences?() } label: {
                headerTile(headerSymbol("slider.horizontal.3"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
            .help("Настройки")
            if !model.showsMusicPreview {
                if model.page == .music {
                    outputMenu
                } else {
                    Color.clear.frame(width: points(20), height: points(20)).accessibilityHidden(true)
                }
            }
        }
    }

    private var outputMenu: some View {
        headerMenu("speaker.wave.2") {
            let outputs = OutputAudio.devices()
            if outputs.isEmpty { Text("Аудиовыходы недоступны") }
            ForEach(outputs) { output in
                Button(output.name) {
                    model.notice(OutputAudio.select(output.id) ? "Выход · " + output.name : "Не удалось сменить выход")
                }
            }
        }
        .accessibilityLabel("Аудиовыход")
        .help("Аудиовыход")
    }

    @ViewBuilder private var music: some View {
        if let item = model.media {
            VStack(alignment: .leading, spacing: points(9)) {
                HStack(spacing: points(11)) {
                    sourceArtwork(size: 48, item: item)
                    VStack(alignment: .leading, spacing: points(3)) {
                        trackDetails(item, size: 15, titleLines: 2)
                        if model.sources.count > 1 {
                            Menu(item.sourceName) {
                                ForEach(model.sources, id: \.selectionSource) { source in
                                    Button(source.sourceName) { model.onSelectSource?(source.selectionSource) }
                                }
                            }
                            .font(.system(size: points(9)))
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("Источник воспроизведения")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let duration = item.duration, duration.isFinite, duration > 0, item.elapsed != nil {
                    PlaybackTimeline(item: item, duration: duration, scale: model.panelScale) {
                        model.onMedia?(item.track, "seek", $0)
                    }
                    .id(item.track)
                }
                HStack(spacing: points(11)) {
                    if canSkip(item) { skipButton(-15, item: item) }
                    transportControls(item, primarySize: 28, secondarySize: 24)
                    if canSkip(item) { skipButton(15, item: item) }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: points(11)) {
                artwork(size: 44)
                VStack(alignment: .leading, spacing: points(3)) {
                    Text("Ничего не играет").font(.system(size: points(14), weight: .semibold))
                    Text("Включи музыку в «Ладе» или другом плеере")
                        .font(.system(size: points(10))).foregroundStyle(muted)
                }
            }
        }
    }

    private func canSkip(_ item: MediaItem) -> Bool {
        (item.capabilities?.contains("seek") ?? true) && item.elapsed != nil &&
        item.duration.map { $0.isFinite && $0 > 0 } == true
    }

    private func skipButton(_ seconds: Double, item: MediaItem) -> some View {
        Button {
            guard let position = item.position(), let duration = item.duration else { return }
            model.onMedia?(item.track, "seek", min(duration, max(0, position + seconds)))
        } label: {
            Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                .font(.system(size: points(14), weight: .medium))
                .frame(width: points(26), height: points(26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(muted)
        .accessibilityLabel(seconds < 0 ? "Назад на 15 секунд" : "Вперёд на 15 секунд")
    }

    private func sourceArtwork(size: CGFloat, item: MediaItem) -> some View {
        Button { model.onOpenSource?(item.track) } label: { artwork(size: size) }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть источник воспроизведения")
            .help("Открыть источник")
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: points(size * 0.23))
                .fill(tile)
            if let art = model.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: points(size * 0.40), weight: .medium))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: points(size), height: points(size))
        .clipShape(RoundedRectangle(cornerRadius: points(size * 0.23)))
    }

    private func trackDetails(_ item: MediaItem, size: CGFloat, titleLines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: points(3)) {
            Text(item.title).font(.system(size: points(size), weight: .semibold)).lineLimit(titleLines)
            Text(item.artist.isEmpty ? item.sourceName : item.artist)
                .font(.system(size: points(size == 13 ? 10 : 12))).foregroundStyle(muted).lineLimit(1)
        }
    }

    private func transportControls(_ item: MediaItem, primarySize: CGFloat, secondarySize: CGFloat) -> some View {
        HStack(spacing: points(8)) {
            transport("backward.end.fill", "Предыдущий", "previous", track: item.track, size: secondarySize,
                      allowed: item.capabilities?.contains("previous") ?? true)
            transport(item.playing ? "pause.fill" : "play.fill",
                      item.playing ? "Пауза" : "Играть", item.playing ? "pause" : "play",
                      track: item.track, size: primarySize, primary: true)
            transport("forward.end.fill", "Следующий", "next", track: item.track, size: secondarySize,
                      allowed: item.capabilities?.contains("next") ?? true)
        }
    }

    private func transport(_ icon: String, _ title: String, _ action: String,
                           track: MediaItem.Track, size: CGFloat, primary: Bool = false, allowed: Bool = true) -> some View {
        Button { model.onMedia?(track, action, nil) } label: {
            Image(systemName: icon)
                .font(.system(size: points(primary ? size * 0.43 : 11), weight: .semibold))
                .frame(width: points(size), height: points(size))
                .foregroundStyle(primary ? Color.black.opacity(0.85) : .white)
                .background(primary ? accent : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.32)
        .accessibilityLabel(title)
    }

    private func shelf(isTurning: Bool) -> some View {
        let paths = model.shelf.displayedPaths(matching: shelfQuery)
        let pinned = Set(model.shelf.pinnedPaths)
        return VStack(alignment: .leading, spacing: points(6)) {
            HStack(spacing: points(6)) {
                Text("Полка файлов").font(.system(size: points(13), weight: .semibold))
                Spacer()
                if shelfSearchOpen {
                    TextField("Имя файла", text: $shelfQuery)
                        .focused($editor, equals: .shelfSearch)
                        .frame(width: points(104))
                        .accessibilityLabel("Поиск файлов на полке")
                        .onSubmit {
                            openShelfSearchMatch(query: shelfQuery, paths: paths)
                        }
                }
                Button {
                    shelfSearchOpen.toggle()
                    if shelfSearchOpen { editor = .shelfSearch }
                    else { shelfQuery = ""; editor = nil }
                } label: {
                    Image(systemName: shelfSearchOpen ? "xmark" : "magnifyingglass")
                }
                .controlSize(.small)
                .help(shelfSearchOpen ? "Закрыть поиск" : "Найти файл (⌘F)")
                .accessibilityLabel(shelfSearchOpen ? "Закрыть поиск" : "Найти файл")
                Button { model.onChooseFiles?() } label: {
                    Label("Добавить файлы", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if let active = model.transfers.values.sorted().first {
                Label(active, systemImage: "arrow.down").foregroundStyle(muted).lineLimit(1)
            }
            if let file = model.download {
                HStack(spacing: points(5)) {
                    Label(file.lastPathComponent, systemImage: "arrow.down.to.line")
                        .lineLimit(1)
                        .help(file.lastPathComponent)
                    Spacer(minLength: 0)
                    Button("В Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .fixedSize()
                    Button("На полку") { model.onAddFiles?([file]) }.fixedSize()
                    if ["mp3", "m4a", "aac", "flac", "wav", "ogg", "aif", "aiff", "opus"].contains(file.pathExtension.lowercased()) {
                        Button("В «Лад»") { model.onQueue?(file) }
                            .fixedSize()
                            .help("В очередь «Лада»")
                    }
                }
                .controlSize(.small)
                .padding(points(7))
                .background(tile, in: RoundedRectangle(cornerRadius: points(8)))
            }
            if !model.shelfFeedback.isEmpty || model.shelfCanUndo {
                HStack(spacing: points(6)) {
                    Text(model.shelfFeedback).foregroundStyle(muted).lineLimit(1)
                    Spacer(minLength: 0)
                    if model.shelfCanUndo {
                        Button("Отменить") { model.onUndoFiles?() }.buttonStyle(.plain).foregroundStyle(accent)
                    }
                }
            }
            if model.shelf.paths.isEmpty {
                VStack(spacing: points(5)) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: points(16), weight: .medium))
                        .foregroundStyle(accent)
                    Text("Перетащи файлы сюда или на чёлку")
                        .foregroundStyle(dropTarget ? .white : muted)
                    Button("Вставить файлы") { model.onPasteFiles?() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tile, in: RoundedRectangle(cornerRadius: points(9)))
            } else {
                Group {
                    if isTurning {
                        ShelfGridPreview(paths: paths, selection: model.shelfSelection, pinned: pinned,
                                         scale: model.panelScale, viewport: shelfViewport)
                    } else {
                        ShelfFileGrid(paths: paths, availabilityPaths: model.shelf.paths, selection: $model.shelfSelection,
                                      pinned: pinned, scale: model.panelScale, viewport: shelfViewport,
                                      focusRequest: editor == .shelfSearch ? 0 : model.shelfFocusRequest,
                                      open: { model.onOpenFile?($0) }, preview: { model.onPreviewFile?($0) },
                                      askAboutImage: { model.onAskAboutImage?($0) },
                                      setPinned: { model.onPinFiles?($0, $1) }, remove: { model.onRemoveFiles?($0) },
                                      feedback: { model.shelfFeedback = $0 },
                                      didCheckAvailability: { model.onShelfAvailability?($0, $1, $2) })
                            .allowsHitTesting(!paths.isEmpty)
                            .accessibilityHidden(paths.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if paths.isEmpty {
                        Text("Файлы не найдены").foregroundStyle(muted)
                    }
                }
            }
        }
        .font(.system(size: points(11)))
        .onChange(of: model.shelfSearchRequest) { _, _ in
            shelfSearchOpen = true
            editor = .shelfSearch
        }
        .onChange(of: shelfQuery) { _, _ in
            model.shelfSelection.formIntersection(paths)
        }
    }

    private func openShelfSearchMatch(query: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        Task { @MainActor in
            let path = await Task.detached(priority: .userInitiated) {
                paths.first { FileManager.default.fileExists(atPath: $0) }
            }.value
            guard model.active, model.page == .shelf, shelfSearchOpen, shelfQuery == query,
                  model.shelf.displayedPaths(matching: query) == paths else { return }
            if let path { model.onOpenFile?(URL(fileURLWithPath: path)) }
            else { model.shelfFeedback = "Файлы недоступны" }
        }
    }

    private func tools(_ page: PanelPage) -> some View {
        VStack(alignment: .leading, spacing: points(9)) {
            switch page {
            case .quick: quickTools
            case .tasks: taskList
            case .calendar:
                CalendarPanel(scale: model.panelScale, accent: accent, tile: tile,
                              muted: muted, sample: model.calendarSample, feed: model.calendarFeed,
                              month: $model.calendarMonth, selection: $model.calendarDay)
            case .weather: weatherTools
            case .notices:
                if model.notices.isEmpty {
                    Text("Событий пока нет").foregroundStyle(muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: points(5)) {
                            ForEach(model.notices) { entry in
                                if let chat = entry.codexChat {
                                    Button { model.onOpenCodex?(chat) } label: { noticeRow(entry, actionable: true) }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(entry.message)
                                        .accessibilityValue(entry.date.formatted(date: .omitted, time: .shortened))
                                } else if let destination = entry.destination {
                                    Button { model.onChangePage?(destination) } label: {
                                        noticeRow(entry, actionable: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    noticeRow(entry, actionable: false)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            default: EmptyView()
            }
        }
        .font(.system(size: points(11)))
    }

    private func noticeRow(_ entry: PanelNotice, actionable: Bool) -> some View {
        HStack(spacing: points(8)) {
            Text(entry.date, format: .dateTime.hour().minute())
                .monospacedDigit().foregroundStyle(muted)
            Text(entry.message).lineLimit(2)
            Spacer(minLength: 0)
            if actionable { Image(systemName: "chevron.right").foregroundStyle(accent) }
        }
        .padding(points(7))
        .background(tile, in: RoundedRectangle(cornerRadius: points(6)))
    }

    private var taskList: some View {
        let active = model.tasks.filter { !$0.done }
        let completed = model.tasks.filter(\.done)
        return VStack(alignment: .leading, spacing: points(7)) {
            HStack {
                TextField("Новая задача", text: $newTask)
                    .focused($editor, equals: .task)
                    .onSubmit(addTask)
                Button("Добавить", action: addTask)
                    .disabled(newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.tasks.count >= 150)
            }
            if !model.tasks.isEmpty && active.isEmpty {
                Text("Активных задач нет").foregroundStyle(muted)
            }
            if !model.tasks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: points(4)) {
                        ForEach(active, content: taskRow)
                        if !completed.isEmpty {
                            DisclosureGroup("Выполнено · \(completed.count)", isExpanded: $showsCompletedTasks) {
                                ForEach(completed, content: taskRow)
                            }
                            .foregroundStyle(muted)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if model.taskCanUndo || !model.taskFeedback.isEmpty {
                HStack {
                    Text(model.taskFeedback.isEmpty ? "Задача удалена" : model.taskFeedback).foregroundStyle(muted)
                    Spacer()
                    if model.taskCanUndo {
                        Button("Отменить") { model.onUndoTask?() }.buttonStyle(.plain).foregroundStyle(accent)
                    }
                }
            }
        }
    }

    private func taskRow(_ task: LocalTask) -> some View {
        HStack {
            Button {
                var tasks = model.tasks
                guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
                tasks[index].done.toggle()
                _ = model.onSaveTasks?(tasks)
            } label: {
                Label(task.title, systemImage: task.done ? "checkmark.circle.fill" : "circle")
                    .strikethrough(task.done)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(task.title)
            .accessibilityHint(task.done ? "Вернуть в активные" : "Отметить выполненной")
            Spacer(minLength: 0)
            Button { model.onRemoveTask?(task.id) } label: {
                Image(systemName: "xmark").frame(width: points(22), height: points(20))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted)
            .accessibilityLabel("Удалить задачу")
        }
        .frame(minHeight: points(21))
    }

    private func addTask() {
        let title = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, model.tasks.count < 150 else { return }
        let tasks = model.tasks + [LocalTask(title: String(title.prefix(250)))]
        if model.onSaveTasks?(tasks) == true { newTask = "" }
    }

    private var weatherTools: some View {
        VStack(alignment: .leading, spacing: points(5)) {
            HStack(spacing: points(6)) {
                TextField("Город", text: $city)
                    .focused($editor, equals: .city)
                    .onSubmit { loadWeather() }
                Button(weatherLoading ? "Загружаю…" : "Обновить") { loadWeather() }
                    .disabled(weatherLoading || city.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
            .controlSize(.small)
            if !weatherChoices.isEmpty && city.trimmingCharacters(in: .whitespacesAndNewlines) == weatherChoicesFor {
                Menu("Выбрать город") {
                    ForEach(weatherChoices) { location in
                        Button(location.label) { loadWeather(location: location) }
                    }
                }
                .controlSize(.small)
                .disabled(weatherLoading)
            }
            if let weather = model.weather {
                TimelineView(.everyMinute) { clock in
                    weatherDetails(weather, now: clock.date)
                }
            } else {
                Text(weatherFeedback.isEmpty ? "Введи город для прогноза" : weatherFeedback)
                    .foregroundStyle(muted)
            }
        }
        .onAppear {
            if city.isEmpty { city = model.weather?.city ?? "" }
            refreshWeatherIfStale()
        }
        .onChange(of: model.page) { _, _ in refreshWeatherIfStale() }
    }

    private func weatherDetails(_ weather: WeatherReading, now: Date) -> some View {
        let condition = weatherCondition(weather.code, daylight: weather.isDay ?? true)
        let hours = weather.hourly?.filter { $0.time > now } ?? []
        let stale = now.timeIntervalSince(weather.recorded) >= 7200
        return VStack(alignment: .leading, spacing: points(5)) {
            ViewThatFits(in: .vertical) {
                VStack(spacing: points(5)) {
                    currentWeather(weather, condition: condition)
                    if !hours.isEmpty { hourlyForecast(hours, timezone: weather.timezone) }
                }
                .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: points(5)) {
                        currentWeather(weather, condition: condition)
                        if !hours.isEmpty { hourlyForecast(hours, timezone: weather.timezone) }
                    }
                }
            }
            HStack(spacing: points(5)) {
                if !weatherFeedback.isEmpty { Text(weatherFeedback).lineLimit(1) }
                else if stale {
                    Label("Данные устарели", systemImage: "clock.arrow.circlepath")
                        .lineLimit(1)
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                Text("Open-Meteo · " + weather.recorded.formatted(date: Calendar.current.isDateInToday(weather.recorded) ? .omitted : .abbreviated, time: .shortened))
                    .lineLimit(1)
            }
            .font(.system(size: points(8)))
            .foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func currentWeather(_ weather: WeatherReading, condition: (title: String?, icon: String)) -> some View {
        HStack(alignment: .center, spacing: points(7)) {
            Image(systemName: condition.icon)
                .font(.system(size: points(16))).foregroundStyle(accent)
                .frame(width: points(21))
                .accessibilityHidden(true)
            Text(degrees(weather.temperature))
                .font(.system(size: points(20), weight: .medium)).foregroundStyle(accent)
                .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(weather.city).fontWeight(.semibold).lineLimit(1)
                    .help(weather.location?.label ?? weather.city)
                Text(condition.title ?? "Сейчас").font(.system(size: points(9))).foregroundStyle(muted).lineLimit(1)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Ощущается как " + degrees(weather.feelsLike))
                let humidity = weather.humidity.map { "Влажность \($0)%" }
                let wind = weather.wind.map { "Ветер " + $0.formatted(.number.precision(.fractionLength(1))) + " м/с" }
                let details = [humidity, wind].compactMap { $0 }.joined(separator: "  ·  ")
                if !details.isEmpty { Text(details).lineLimit(1) }
            }
            .font(.system(size: points(9)))
            .foregroundStyle(muted)
        }
        .padding(points(6))
        .background(tile, in: RoundedRectangle(cornerRadius: points(8)))
    }

    private func hourlyForecast(_ hours: [WeatherReading.Hour], timezone: String?) -> some View {
        HStack(spacing: points(3)) {
            ForEach(hours) { hour in
                let format = Date.FormatStyle(
                    locale: Locale(identifier: "ru_RU"),
                    timeZone: timezone.flatMap(TimeZone.init(identifier:)) ?? .current).hour().minute()
                let condition = weatherCondition(hour.code, daylight: hour.isDay ?? true)
                VStack(spacing: points(1)) {
                    Text(hour.time, format: format).foregroundStyle(muted)
                    Image(systemName: condition.icon)
                        .foregroundStyle(accent)
                        .frame(height: points(12))
                        .accessibilityLabel(condition.title ?? "Прогноз")
                    Text(degrees(hour.temperature)).fontWeight(.semibold)
                    Label(hour.precipitation.map { "\($0)%" } ?? "–", systemImage: "drop")
                        .foregroundStyle(muted)
                        .accessibilityLabel(hour.precipitation.map { "Вероятность осадков \($0) процентов" } ?? "Вероятность осадков недоступна")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, points(3))
                .background(tile, in: RoundedRectangle(cornerRadius: points(6)))
            }
        }
        .font(.system(size: points(8)))
        .monospacedDigit()
    }

    private func degrees(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0))) + "°" } ?? "–"
    }

    private func weatherCondition(_ code: Int?, daylight: Bool = true) -> (title: String?, icon: String) {
        switch code ?? -1 {
        case 0: ("Ясно", daylight ? "sun.max" : "moon.stars")
        case 1, 2: ("Переменная облачность", daylight ? "cloud.sun" : "cloud.moon")
        case 3: ("Пасмурно", "cloud")
        case 45, 48: ("Туман", "cloud.fog")
        case 51...67, 80...82: ("Дождь", "cloud.rain")
        case 71...77, 85, 86: ("Снег", "cloud.snow")
        case 95...99: ("Гроза", "cloud.bolt.rain")
        default: (nil, "cloud.sun")
        }
    }

    private func refreshWeatherIfStale() {
        guard model.active, model.page == .weather, let recent = model.weather,
              Date().timeIntervalSince(recent.recorded) >= 7200,
              city == recent.city, weatherChoices.isEmpty else { return }
        loadWeather(location: recent.location)
    }

    private func loadWeather(location selected: WeatherLocation? = nil) {
        let name = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, !weatherLoading else { return }
        weatherLoading = true
        weatherFeedback = ""
        Task { @MainActor in
            defer { weatherLoading = false }
            do {
                let location: WeatherLocation
                if let remembered = selected ?? (model.weather?.city == name ? model.weather?.location : nil) {
                    location = remembered
                } else {
                    let found = try await WeatherPreview.search(String(name.prefix(100)))
                    guard city.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return }
                    guard !found.isEmpty else {
                        weatherChoices = []
                        weatherFeedback = "Город не найден"
                        return
                    }
                    let exact = found.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                    if let only = found.count == 1 ? found.first : (exact.count == 1 ? exact.first : nil) {
                        location = only
                    } else {
                        weatherChoices = exact.isEmpty ? found : exact
                        weatherChoicesFor = name
                        return
                    }
                }
                let weather = try await WeatherPreview.forecast(for: location)
                guard city.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return }
                city = weather.city
                weatherChoices = []
                model.weather = weather
                LocalSettings.save(weather, as: "weather.json")
            } catch {
                if city.trimmingCharacters(in: .whitespacesAndNewlines) == name {
                    weatherFeedback = "Не получилось получить прогноз"
                }
            }
        }
    }

    private var quickTools: some View {
        VStack(alignment: .leading, spacing: points(7)) {
            if model.countdown?.isPaused == false || model.stopwatch.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    timerControls(at: clock.date)
                }
            } else {
                timerControls(at: .now)
            }
            if showsCustomTimer && model.countdown == nil {
                HStack {
                    TextField("Минуты", text: $customTimerText)
                        .focused($editor, equals: .timer)
                        .onSubmit(startCustomTimer)
                        .frame(width: points(64))
                    Text("мин").foregroundStyle(muted)
                    Button("Старт", action: startCustomTimer)
                        .disabled(customDuration == nil)
                        .accessibilityLabel("Запустить свой таймер")
                }
                .controlSize(.small)
            }
            TextField("Быстрая заметка", text: $model.note, axis: .vertical)
                .focused($editor, equals: .note)
                .textFieldStyle(.plain)
                .lineLimit(2...3)
                .padding(points(8))
                .background(tile, in: RoundedRectangle(cornerRadius: points(8)))
            if model.noteSaveFailed {
                Text("Заметка пока не сохранена").foregroundStyle(muted).lineLimit(1)
            } else if let feedback = model.clockFeedback ?? (linkFeedback.isEmpty ? nil : linkFeedback) {
                Text(feedback).foregroundStyle(muted).lineLimit(1)
            }
        }
        .font(.system(size: points(11)))
    }

    private func timerControls(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: points(5)) {
            HStack(spacing: points(5)) {
                if let timer = model.countdown {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(timer.phase.title)
                            .font(.system(size: points(9))).foregroundStyle(muted)
                        Text(formatTime(timer.remaining(at: date).rounded(.up)))
                            .font(.system(size: points(17), weight: .semibold)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button(timer.isPaused ? "Продолжить" : "Пауза") { model.onPauseTimer?() }
                    Button("Стоп") { _ = model.onTimer?(nil, .timer) }
                } else {
                    Text("Таймер").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    ForEach([1, 5, 15], id: \.self) { minutes in
                        Button("\(minutes) мин") { _ = model.onTimer?(Double(minutes * 60), .timer) }
                    }
                    Button("25 + 5") { _ = model.onTimer?(1500, .focus) }
                        .help("Pomodoro · 25 минут фокуса, 5 минут перерыва")
                        .accessibilityLabel("Pomodoro, 25 и 5 минут")
                    Button("Свой…") {
                        showsCustomTimer.toggle()
                        if showsCustomTimer {
                            customTimerText = String(customTimerMinutes)
                            editor = .timer
                        }
                    }
                }
            }
            HStack(spacing: points(5)) {
                Text("Секундомер").fontWeight(.medium)
                Text(formatTime(model.stopwatch.seconds(at: .now(wallTime: date))))
                    .monospacedDigit().foregroundStyle(muted)
                Button(model.stopwatch.isRunning ? "Пауза" : "Старт") { model.onStopwatch?(false) }
                    .accessibilityLabel(model.stopwatch.isRunning ? "Пауза секундомера" : "Старт секундомера")
                if model.stopwatch.isPresent && !model.stopwatch.isRunning {
                    Button { model.onStopwatch?(true) } label: {
                        Image(systemName: "arrow.counterclockwise").accessibilityLabel("Сбросить секундомер")
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Очистить ссылку из буфера", action: cleanClipboardLink)
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("Дополнительные действия")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .controlSize(.small)
    }

    private var customDuration: Int? {
        guard let minutes = Int(customTimerText.trimmingCharacters(in: .whitespaces)),
              (1...1440).contains(minutes) else { return nil }
        return minutes
    }

    private func startCustomTimer() {
        guard let minutes = customDuration, model.countdown == nil,
              model.onTimer?(Double(minutes * 60), .timer) == true else { return }
        customTimerMinutes = minutes
        showsCustomTimer = false
        editor = nil
    }

    private func cleanClipboardLink() {
        let pasteboard = NSPasteboard.general
        guard let raw = pasteboard.string(forType: .string), let cleaned = CleanLink.clean(raw) else {
            linkFeedback = "В буфере нет ссылки"
            return
        }
        if cleaned != raw {
            pasteboard.clearContents()
            pasteboard.setString(cleaned, forType: .string)
        }
        linkFeedback = cleaned == raw ? "Ссылка уже чистая" : "Чистая ссылка скопирована"
    }

    private func acceptFiles(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !files.isEmpty else { return false }
        let group = DispatchGroup()
        var results = Array<URL?>(repeating: nil, count: files.count)
        for (index, provider) in files.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let file = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                DispatchQueue.main.async {
                    if let file, file.isFileURL { results[index] = file }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { model.onAddFiles?(results.compactMap { $0 }) }
        return true
    }
}

private struct NotchContour: Shape {
    let notchWidth: CGFloat
    let scale: CGFloat
    var shoulderHeight: CGFloat { 13 * scale }

    func path(in rect: CGRect) -> Path {
        Path(NotchSurface.path(in: rect, notchWidth: notchWidth, scale: scale))
    }

    func strokeBorderOverlay(dropTarget: Bool, accent: Color) -> some View {
        GeometryReader { bounds in
            let edge = min(1, 23 * scale / max(1, bounds.size.height))
            let color = dropTarget ? accent : Color.white.opacity(0.17)
            stroke(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: edge * 0.42),
                .init(color: color, location: edge),
                .init(color: color, location: 1)
            ], startPoint: .top, endPoint: .bottom),
            lineWidth: (dropTarget ? 2 : 1) * scale)
        }
    }
}

private struct PlaybackTimeline: View {
    let item: MediaItem
    let duration: Double
    let scale: CGFloat
    let seek: (Double) -> Void

    @State private var drag: Double?
    @State private var committed: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: item.playing ? 1 : 60)) { _ in
            let elapsed = drag ?? committed ?? item.position() ?? 0
            HStack(spacing: 7 * scale) {
                Text(formatTime(elapsed)).frame(minWidth: 25 * scale, alignment: .leading).monospacedDigit()
                Slider(value: Binding(get: { elapsed }, set: { drag = $0 }), in: 0...duration) { editing in
                    if !editing, let drag {
                        committed = drag
                        seek(drag)
                        self.drag = nil
                    }
                }
                .disabled(!(item.capabilities?.contains("seek") ?? true))
                .controlSize(.large)
                .accessibilityLabel("Позиция воспроизведения")
                Text(formatTime(duration)).frame(minWidth: 25 * scale, alignment: .trailing).monospacedDigit()
            }
            .font(.system(size: 10 * scale))
            .foregroundStyle(.secondary)
        }
        .onChange(of: item.positionAnchor) { _, _ in committed = nil }
        .task(id: committed) {
            guard committed != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            committed = nil
        }
    }
}

private func formatTime(_ duration: Double) -> String {
    guard duration.isFinite else { return "0:00" }
    let seconds = Int(min(999_999, max(0, duration.rounded(.down))))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
