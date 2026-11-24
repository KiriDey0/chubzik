import SwiftUI

enum PanelShortcut: String, CaseIterable, Identifiable {
    case off = "Выключено"
    case letterJ = "⌃⌥J"
    case space = "⌃⌥Пробел"

    var id: Self { self }
}

enum FileShortcut: String, CaseIterable, Identifiable {
    case off = "Выключено"
    case letterF = "⌃⌥F"
    case letterR = "⌃⌥R"
    case letterU = "⌃⌥U"
    case letterY = "⌃⌥Y"

    var id: Self { self }
}

enum FileSource { case downloads, codex }

enum ProjectFolderShortcut: String, CaseIterable, Identifiable {
    case off = "Выключено"
    case letterP = "⌃⌥P"
    case letterO = "⌃⌥O"
    var id: Self { self }
}

final class ChubzikPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var opensOnHover: Bool {
        didSet { defaults.set(opensOnHover, forKey: "opensOnHover") }
    }
    @Published var startPage: PanelPage {
        didSet { defaults.set(startPage.rawValue, forKey: "startPage") }
    }
    @Published private(set) var shortcut: PanelShortcut {
        didSet { defaults.set(shortcut.rawValue, forKey: "panelShortcut") }
    }
    @Published private(set) var quickChatEnabled: Bool {
        didSet { defaults.set(quickChatEnabled, forKey: "quickChatEnabled") }
    }
    @Published var quickChatShortcutUnavailable = false
    @Published var unavailablePanelShortcut: PanelShortcut?
    @Published private(set) var bringDownloadShortcut: FileShortcut {
        didSet { defaults.set(bringDownloadShortcut.rawValue, forKey: "bringDownloadShortcut") }
    }
    @Published private(set) var bringCodexFileShortcut: FileShortcut {
        didSet { defaults.set(bringCodexFileShortcut.rawValue, forKey: "bringCodexFileShortcut") }
    }
    @Published var unavailableDownloadShortcut: FileShortcut?
    @Published var unavailableCodexShortcut: FileShortcut?
    @Published private(set) var projectFolderShortcut: ProjectFolderShortcut {
        didSet { defaults.set(projectFolderShortcut.rawValue, forKey: "projectFolderShortcut") }
    }
    @Published var unavailableProjectFolderShortcut: ProjectFolderShortcut?
    @Published var clipboardPocketEnabled: Bool {
        didSet {
            defaults.set(clipboardPocketEnabled, forKey: "clipboardPocketEnabled")
            onClipboardPocketChange?(clipboardPocketEnabled)
        }
    }
    @Published var clipboardPocketShortcutUnavailable = false
    @Published var followsPointer: Bool {
        didSet {
            defaults.set(followsPointer, forKey: "gazeEnabled")
            onGazeChange?(followsPointer)
        }
    }
    @Published var followsCodexRequests: Bool {
        didSet {
            defaults.set(followsCodexRequests, forKey: "followsCodexRequests")
            onPursuitChange?(followsCodexRequests)
        }
    }
    @Published var completionMode: CompletionMode {
        didSet { defaults.set(completionMode.rawValue, forKey: "completionMode") }
    }
    @Published var returnsToPreviousLocation: Bool {
        didSet {
            defaults.set(returnsToPreviousLocation, forKey: "returnsToVideo")
            if !returnsToPreviousLocation { onReturnDisabled?() }
        }
    }
    @Published var readsSystemMedia: Bool {
        didSet {
            defaults.set(readsSystemMedia, forKey: "systemMedia")
            onSystemMediaChange?(readsSystemMedia)
        }
    }

    var onQuickChatShortcutChange: ((Bool) -> Bool)?
    var onShortcutChange: ((PanelShortcut) -> Bool)?
    var onFileShortcutChange: ((FileSource, FileShortcut) -> Bool)?
    var onGazeChange: ((Bool) -> Void)?
    var onPursuitChange: ((Bool) -> Void)?
    var onSystemMediaChange: ((Bool) -> Void)?
    var onReturnDisabled: (() -> Void)?
    var onProjectFolderShortcutChange: ((ProjectFolderShortcut) -> Bool)?
    var onClipboardPocketChange: ((Bool) -> Void)?

    func selectProjectFolderShortcut(_ value: ProjectFolderShortcut) {
        guard onProjectFolderShortcutChange?(value) != false else { return }
        projectFolderShortcut = value
    }

    func selectPanelShortcut(_ value: PanelShortcut) {
        guard onShortcutChange?(value) != false else { return }
        shortcut = value
    }

    func setQuickChatEnabled(_ enabled: Bool) {
        guard onQuickChatShortcutChange?(enabled) != false else { return }
        quickChatEnabled = enabled
    }

    func selectFileShortcut(_ value: FileShortcut, for source: FileSource) {
        guard onFileShortcutChange?(source, value) != false else { return }
        switch source {
        case .downloads: bringDownloadShortcut = value
        case .codex: bringCodexFileShortcut = value
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quickChatEnabled = defaults.object(forKey: "quickChatEnabled") as? Bool ?? true
        startPage = defaults.string(forKey: "startPage").flatMap(PanelPage.init(rawValue:)) ?? .music
        shortcut = defaults.string(forKey: "panelShortcut").flatMap(PanelShortcut.init(rawValue:)) ?? .off
        bringDownloadShortcut = defaults.string(forKey: "bringDownloadShortcut").flatMap(FileShortcut.init(rawValue:)) ?? .letterF
        bringCodexFileShortcut = defaults.string(forKey: "bringCodexFileShortcut").flatMap(FileShortcut.init(rawValue:)) ?? .letterR
        projectFolderShortcut = defaults.string(forKey: "projectFolderShortcut")
            .flatMap(ProjectFolderShortcut.init(rawValue:)) ?? .letterP
        clipboardPocketEnabled = defaults.bool(forKey: "clipboardPocketEnabled")
        opensOnHover = defaults.object(forKey: "opensOnHover") as? Bool ?? true
        followsPointer = defaults.object(forKey: "gazeEnabled") as? Bool ?? true
        followsCodexRequests = defaults.object(forKey: "followsCodexRequests") as? Bool ?? true
        completionMode = defaults.string(forKey: "completionMode").flatMap(CompletionMode.init(rawValue:)) ?? .soft
        returnsToPreviousLocation = defaults.object(forKey: "returnsToVideo") as? Bool ?? false
        readsSystemMedia = defaults.object(forKey: "systemMedia") as? Bool ?? true
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: ChubzikPreferences
    let onStartCursorChase: () -> Void

    @State private var page: Page = .general

    private enum Page: String, CaseIterable {
        case general = "Общие"
        case files = "Файлы"
        case chat = "Быстрый чат"

        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .files: "doc.on.doc"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(page == item ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(page == item ? .white.opacity(0.095) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 145)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text(page.rawValue)
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    switch page {
                    case .general: general
                    case .files: files
                    case .chat: chat
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(17)
            }
        }
        .frame(width: 545, height: 410)
        .background(Color(white: 0.045))
        .preferredColorScheme(.dark)
    }

    private var general: some View {
        Group {
            group("Панель") {
                option("Открывать при наведении", enabled: $preferences.opensOnHover)
                Divider().padding(.horizontal, 12)
                choice("Стартовый раздел", selection: $preferences.startPage, values: PanelPage.allCases)
                Divider().padding(.horizontal, 12)
                choice("Горячая клавиша панели",
                       selection: Binding(get: { preferences.shortcut }, set: preferences.selectPanelShortcut),
                       values: PanelShortcut.allCases)
                if let unavailable = preferences.unavailablePanelShortcut {
                    warning("Не удалось назначить \(unavailable.rawValue).")
                }
            }
            group("Чубзик") {
                HStack {
                    Text("Догонялки")
                    Spacer()
                    Button("Начать", action: onStartCursorChase)
                        .accessibilityLabel("Начать догонялки")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().padding(.horizontal, 12)
                option("Следить взглядом за курсором", enabled: $preferences.followsPointer)
                Divider().padding(.horizontal, 12)
                option("Подлетать при запросе Codex", enabled: $preferences.followsCodexRequests)
                Divider().padding(.horizontal, 12)
                choice("Когда ответ готов", selection: $preferences.completionMode, values: CompletionMode.allCases)
                warning(preferences.completionMode.detail)
                Divider().padding(.horizontal, 12)
                option("Возвращаться обратно", "После сообщения в том же диалоге Codex. Если Чубзик поставил видео на паузу, оно продолжится.",
                       enabled: $preferences.returnsToPreviousLocation)
                if preferences.completionMode != .soft, !BrowserVideoPlayback.hasAccess {
                    HStack {
                        Button("Разрешить управление видео через универсальный доступ") {
                            BrowserVideoPlayback.requestAccess()
                        }
                        Spacer()
                    }
                    .padding([.horizontal, .bottom], 12)
                }
                if preferences.completionMode != .soft, ArDiaVideoPlayback.isAvailable {
                    HStack {
                        Button("Подключить ArDia без CDP") { ArDiaAppleEventsPlayback.requestAccess() }
                        Spacer()
                    }
                    .padding([.horizontal, .bottom], 12)
                    warning("В ArDia включи View → Developer → Allow JavaScript from Apple Events.")
                }
            }
            group("Музыка") {
                option("Системный Now Playing", enabled: $preferences.readsSystemMedia)
            }
        }
    }

    private var chat: some View {
        Group {
            group("Вызов") {
                option("Открывать по ⌥ Space",
                       enabled: Binding(get: { preferences.quickChatEnabled }, set: preferences.setQuickChatEnabled))
                if preferences.quickChatShortcutUnavailable { warning("⌥ Space уже используется.") }
                Divider().padding(.horizontal, 12)
                value("Выделить область экрана", "⌘⇧W")
            }
            group("Подключение") {
                value("Модель", "GPT-6 Luna · High")
                Divider().padding(.horizontal, 12)
                value("Клиент", "Codex CLI")
                Divider().padding(.horizontal, 12)
                value("Аккаунт", "Текущий вход CLI")
            }
            group("История") { value("Хранение", "На этом Mac") }
        }
    }

    private var files: some View {
        group("Горячие клавиши") {
            choice("Принести последнюю загрузку",
                   selection: Binding(get: { preferences.bringDownloadShortcut },
                                      set: { preferences.selectFileShortcut($0, for: .downloads) }),
                   values: FileShortcut.allCases)
            if let unavailable = preferences.unavailableDownloadShortcut {
                warning("Не удалось назначить \(unavailable.rawValue).")
            }
            Divider().padding(.horizontal, 12)
            choice("Принести результат Codex",
                   selection: Binding(get: { preferences.bringCodexFileShortcut },
                                      set: { preferences.selectFileShortcut($0, for: .codex) }),
                   values: FileShortcut.allCases)
            if let unavailable = preferences.unavailableCodexShortcut {
                warning("Не удалось назначить \(unavailable.rawValue).")
            }
            Divider().padding(.horizontal, 12)
            choice("Открыть папку проекта Codex",
                   selection: Binding(get: { preferences.projectFolderShortcut }, set: preferences.selectProjectFolderShortcut),
                   values: ProjectFolderShortcut.allCases)
            if let unavailable = preferences.unavailableProjectFolderShortcut {
                warning("Не удалось назначить \(unavailable.rawValue).")
            }
            Divider().padding(.horizontal, 12)
            option("Карманы буфера по ⌃⌥V", "Хранить скопированное на Mac до 24 часов",
                   enabled: $preferences.clipboardPocketEnabled)
            if preferences.clipboardPocketShortcutUnavailable { warning("Не удалось назначить ⌃⌥V.") }
        }
    }

    private func value(_ title: String, _ detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func warning(_ title: String) -> some View {
        Text(title).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom], 12)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func choice<Value: Identifiable & RawRepresentable & Hashable>(
        _ title: String, selection: Binding<Value>, values: [Value]
    ) -> some View where Value.RawValue == String {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(values) { value in Text(value.rawValue).tag(value) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func option(_ title: String, _ detail: String? = nil, enabled: Binding<Bool>) -> some View {
        Toggle(isOn: enabled) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
