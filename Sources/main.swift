import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import IOKit.pwr_mgt
import SwiftUI
import ImageIO
import QuickLookUI
import EventKit

final class IslandController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private enum ScrollAxis { case undecided, horizontal, vertical }
    private enum CompletionKind { case codex, quickChat }
    private enum CompletionHandoff { case opening, destination(pid_t) }
    private struct CompletionNotice {
        let kind: CompletionKind
        var chats: Set<String> = []
        var unknown = false

        var singleChat: String? { !unknown && chats.count == 1 ? chats.first : nil }
        var grouped: Bool { chats.count > 1 }

        mutating func merge(_ other: Self) {
            chats.formUnion(other.chats)
            unknown = unknown || other.unknown
        }

        func removing(_ chat: String) -> Self? {
            var notice = self
            notice.chats.remove(chat)
            return notice.chats.isEmpty && !notice.unknown ? nil : notice
        }
    }
    private enum CompletionVideo {
        case browser(BrowserVideoPlayback.Target)
        case arDia(ArDiaVideoPlayback.Target)
        case arDiaAutomation(ArDiaAppleEventsPlayback.Target)

        var point: CGPoint {
            switch self {
            case .browser(let target): target.point
            case .arDia(let target): target.point
            case .arDiaAutomation(let target): target.point
            }
        }
        var isPictureInPicture: Bool {
            switch self {
            case .browser(let target): target.isPictureInPicture
            case .arDia(let target): target.isPictureInPicture
            case .arDiaAutomation(let target): target.isPictureInPicture
            }
        }
    }
    private struct CompletionReturn {
        let chat: String
        let video: CompletionVideo?
        let originalApp: pid_t?
        var location: CompletionReturnLocation? = nil
        var tab: ArDiaAppleEventsPlayback.TabLocation? = nil
        var requestedChat = false
        var codexApp: pid_t?
    }
    private struct CompletionReturnAttempt: Equatable {
        let id = UUID()
        let codex: pid_t
    }
    private let model = PanelModel()
    private let media = SystemMedia()
    private let preferences: ChubzikPreferences = {
        if CommandLine.arguments.contains("--fixture"),
           let suite = ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_DEFAULTS"],
           let defaults = UserDefaults(suiteName: suite) {
            return ChubzikPreferences(defaults: defaults)
        }
        return ChubzikPreferences()
    }()
    private var preferencesWindow: NSWindow?
    private lazy var quickHistory = QuickChatHistory(persistent: !fixture || fixtureQuickChatPersistence)
    private lazy var quickChat = QuickChatController(history: quickHistory, fixture: fixture)
    private var quickChatPhase: AnyCancellable?
    private lazy var quickShortcut = GlobalPanelShortcut(id: 2) { [weak self] in self?.toggleQuickChat() }
    private var chatBlink: DispatchWorkItem?
    private lazy var panelShortcut = GlobalPanelShortcut { [weak self] in self?.togglePanelFromKeyboard() }
    private lazy var escapeShortcut = GlobalPanelShortcut(id: 3) { [weak self] in self?.cancelMascotInteraction() }
    private var cursorChase: CursorChase?
    private var cursorChaseTimer: Timer?
    private var cursorChaseApp: pid_t?
    private var completionNudge: CompletionNudge?
    private var completionNudgeTimer: Timer?
    private var completionPending: CompletionNotice?
    private var completionCurrent: CompletionNotice?
    private var completionPreparing: UUID?
    private var completionVideo: CompletionVideo?
    private var completionReturn: CompletionReturn?
    private var completionReturnExpiry: DispatchWorkItem?
    private var completionReturnAttempt: CompletionReturnAttempt?
    private var returnPreparation: UUID?
    private var completionMode: CompletionMode = .soft
    private var fixtureCompletionMode: CompletionMode?
    private var completionIdentity: UUID?
    private var completionForeground: pid_t?
    private var completionHandoff: CompletionHandoff?
    private var completionRequestedHandoff = false
    private var completionCheckingPlayback = false
    private var completionPauseReserved = false
    private var completionDidOpen = false
    private var completionComposerSearch: Task<Void, Never>?
    private var completionComposer: CodexComposer.Window?
    private var completionComposerCheck = 0.0
    private var completionCancelled = false
    private let browserVideo = BrowserVideoPlayback()
    private let arDiaVideo = ArDiaVideoPlayback()
    private let arDiaAutomation = ArDiaAppleEventsPlayback()
    private var completionBatch: DispatchWorkItem?
    private var completionTugs = 0
    private var completionWarpFailed = false
    private var completionSignal: CompletionNotice?
    private var deferredCodexSignal: (notice: CompletionNotice, persistent: Bool)?
    private var completionSignalWindow: OverlayPanel?
    private var completionSignalButton: NSButton?
    private var completionSignalExpiry: DispatchWorkItem?
    private weak var cursorChaseMenuItem: NSMenuItem?
    private var fileChooser: NSOpenPanel?
    private var previewWindow: NSWindow?
    private var removedShelfItems: [(index: Int, path: String)] = []
    private var removedShelfPins: [(index: Int, path: String)] = []
    private var removedShelfReferences: [String: Data] = [:]
    private let shelfReferenceQueue = DispatchQueue(label: "local.kirill.chubzik.shelf-references", qos: .utility)
    private var checkingShelfReferences = false
    private var pendingShelfReferences = Set<String>()
    private var removedTask: (index: Int, task: LocalTask)?
    private var shelfUndoDeadline: DispatchWorkItem?
    private var taskUndoDeadline: DispatchWorkItem?
    private let gazeDisabledByArgument = CommandLine.arguments.contains("--no-gaze")
    private let workspace = NSWorkspace.shared
    private let fixture = CommandLine.arguments.contains("--fixture")
    private let fixtureQuickChatPersistence = CommandLine.arguments.contains("--fixture-quick-chat-persistence")
        && ProcessInfo.processInfo.environment["CHUBZIK_DATA_DIR"] != nil
    private let center = NotificationCenter.default
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var terminationSignal: DispatchSourceSignal?
    private var geometry: NotchGeometry?
    private var hasPhysicalNotch = false
    private var mascotWindow: OverlayPanel?
    private var mascot: MascotView?
    private var coverWindow: OverlayPanel?
    private var cover: CoverView?
    private var notchDropWindow: OverlayPanel?
    private var notchDropFeedback: DispatchWorkItem?
    private var shelfDelivery: ShelfDelivery?
    private var fileHandoff: FileHandoff?
    private var fileHandoffExpiry: DispatchWorkItem?
    private var filePickerSelection: Task<Void, Never>?
    private var recentDownloads: [String] = []
    private var recentCodexFiles = CodexResultFiles.History()
    private lazy var downloadFileShortcut = GlobalPanelShortcut(id: 6) { [weak self] in self?.bringFile(from: .downloads) }
    private lazy var codexFileShortcut = GlobalPanelShortcut(id: 7) { [weak self] in self?.bringFile(from: .codex) }
    private lazy var projectFolderShortcut = GlobalPanelShortcut(id: 8) { [weak self] in self?.openCurrentProjectFolder() }
    private lazy var clipboardShortcut = GlobalPanelShortcut(id: 9) { [weak self] in self?.openClipboardPocket() }
    private let clipboardPocket = ClipboardPocket()
    private var lastFileContextClick: (point: CGPoint, pid: pid_t, at: TimeInterval)?
    private var filesReceivedDuringLaunch: [URL] = []
    private var isReadyToReceiveFiles = false
    private var suppressNotchReveal = false
    private var activityWindow: OverlayPanel?
    private var activityLabel: NSTextField?
    private var activityTick: DispatchWorkItem?
    private var meetingWindow: OverlayPanel?
    private var meetingButton: MeetingButton?
    private var meetingRefresh: DispatchWorkItem?
    private var meetingAlerts: [MeetingAlert] = []
    private var joinedMeetings: [MeetingAlert.JoinKey: Date] = [:]
    private var fixtureMeetings: [CalendarEntry] = []
    private var displaysSleeping = false
    private var player: OverlayPanel?
    private var systemItem: MediaItem?
    private var direct: [String: MediaItem] = [:]
    private var preferredSource: String?
    private var playingSources: [String] = []
    private var imageJob: URLSessionDataTask?
    private var imageGeneration = 0
    private var imageIdentity: String?
    private var imageData: Data?
    private var reveal: DispatchWorkItem?
    private var hidePanel: DispatchWorkItem?
    private var pointerExitStarted: TimeInterval?
    private var hideDeadline: TimeInterval?
    private var closePanel: DispatchWorkItem?
    private var closesFromPointer = false
    private let panelMotion = NotchPanelMotion()
    private var pointerHasEnteredPanel = false
    private var panelDismissedAt: TimeInterval?
    private var menuTrackingDepth = 0
    private var scrollAxis: ScrollAxis = .undecided
    private var scrollMovement = CGSize.zero
    private var lastScrollSample: TimeInterval?
    private var scrollVelocity: CGFloat = 0
    private var queuedPage: PanelPage?
    private var removeCover: DispatchWorkItem?
    private var returnHome: DispatchWorkItem?
    private var curiosity: DispatchWorkItem?
    private var chaseReminder: DispatchWorkItem?
    private var flight: Timer?
    private var reducedMotion = false
    private var timerAlarm: DispatchWorkItem?
    private var countdownSaveRetry: DispatchWorkItem?
    private let countdownSaveError = "Не удалось сохранить таймер"
    private let stopwatchSaveError = "Не удалось сохранить секундомер"
    private var fixtureTimerOffset: TimeInterval = 0
    private var timerDate: Date { Date().addingTimeInterval(fixtureTimerOffset) }
    private var stopwatchTime: Stopwatch.Instant { .now(wallTime: timerDate) }
    private var noteSave: DispatchWorkItem?
    private var noteNeedsSave = false
    private var awakeDeadline: DispatchWorkItem?
    private var awakeID: IOPMAssertionID?
    private var press: CGPoint?
    private var pressOrigin: CGPoint?
    private var dragStarted = false
    private var needsReturn = false
    private var sourcesReady: Set<String> = []
    private var pendingQueue: [URL] = []
    private var queueTimeout: DispatchWorkItem?
    private var downloadPreviewTimeout: DispatchWorkItem?
    private var lastMouseUpdate = -Double.infinity
    private var lastMouseMovement = 0.0
    private var lastGaze = CGPoint.zero
    private var lastFullscreenProbe = 0.0
    private var fullscreen = false
    private var pursuing = false
    private var hiddenByUser = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.shelf = LocalSettings.load(ShelfState.self, from: "shelf.json") ?? ShelfState()
        rememberShelfReferences()
        model.note = LocalSettings.load(String.self, from: "note.json") ?? ""
        model.tasks = LocalSettings.load([LocalTask].self, from: "tasks.json") ?? []
        model.countdown = LocalSettings.load(Countdown.self, from: "timer.json")
        var stopwatch = LocalSettings.load(Stopwatch.self, from: "stopwatch.json") ?? Stopwatch()
        if stopwatch.migrateClock(at: stopwatchTime) { LocalSettings.save(stopwatch, as: "stopwatch.json") }
        model.stopwatch = stopwatch
        if !fixture {
            recentDownloads = LocalSettings.load([String].self, from: "recent-download-files.json") ?? []
            recentCodexFiles = LocalSettings.load(CodexResultFiles.History.self, from: "recent-codex-files.json") ?? .init()
            model.completedCodex = LocalSettings.load([CodexPendingRequest].self, from: "codex-inbox.json") ?? []
            model.latestCompletedCodex = LocalSettings.load(CodexPendingRequest.self, from: "codex-latest.json")
                ?? model.completedCodex.first
        }
        if !fixture || CommandLine.arguments.contains("--fixture-services") {
            NSApp.servicesProvider = self
            NSUpdateDynamicServices()
        }
        lastMouseMovement = ProcessInfo.processInfo.systemUptime
        configureActions()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination
        makeWindows()
        updateMotionPreference()
        makeMenu()
        refreshGeometry()
        scheduleTimer()
        scheduleMeetingAlert()

        observe(center, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.refreshGeometry() }
        observe(workspace.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            self?.updateMotionPreference()
        }
        observe(center, NSMenu.didBeginTrackingNotification) { [weak self] _ in
            self?.menuTrackingDepth += 1
            self?.cancelPanelHide()
        }
        observe(center, NSMenu.didEndTrackingNotification) { [weak self] _ in
            guard let self else { return }
            self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
            DispatchQueue.main.async { [weak self] in self?.updatePointerExit(NSEvent.mouseLocation) }
        }
        observe(workspace.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            self.quickChat.cancelCapture()
            self.clipboardPocket.close()
            self.cancelFilePickerSelection()
            if self.fileHandoff?.isDragging != true { self.dismissFileHandoff() }
            let openingCodex = self.completionHandoff != nil
                && (self.completionNudge?.awaitsComposer == true || self.completionComposer?.isCurrent() == true)
            self.interruptPointerControl(endChase: self.cursorChase != nil,
                                         endCompletion: self.completionCurrent != nil && !openingCodex)
            if self.model.active, !self.panelContains(NSEvent.mouseLocation) {
                self.closePanelUnlessPinned()
            }
            self.changedSpace()
        }
        observe(workspace.notificationCenter, NSWorkspace.didActivateApplicationNotification) { [weak self] notice in
            self?.applicationActivated(notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        observe(workspace.notificationCenter, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier { self?.sourceClosed(id) }
        }
        observe(workspace.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.refreshTimer()
            self?.scheduleMeetingAlert()
            self?.changedSpace()
        }
        observe(workspace.notificationCenter, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            self?.displaysSleeping = true
            self?.clipboardPocket.close()
            self?.cancelFilePickerSelection()
            self?.dismissFileHandoff()
            self?.clearCompletionReturn()
            self?.stopShelfDelivery()
            self?.scheduleMeetingAlert()
            self?.stopCursorChase(animated: false)
            self?.stopCompletionNudge()
            self?.curiosity?.cancel()
            self?.chaseReminder?.cancel()
            if self?.flight != nil { self?.returnMascot(animated: false) }
            self?.activityTick?.cancel()
            self?.activityWindow?.orderOut(nil)
            self?.quickChat.hide()
            self?.closePanelUnlessPinned()
        }
        observe(workspace.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.clipboardPocket.close()
            self?.cancelFilePickerSelection()
            self?.quickChat.cancelCapture()
            self?.dismissFileHandoff()
            self?.clearCompletionReturn()
            self?.stopShelfDelivery()
            self?.stopCursorChase(animated: false)
            self?.stopCompletionNudge()
        }
        observe(workspace.notificationCenter, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.displaysSleeping = false
            self?.refreshTimer()
            self?.scheduleMeetingAlert()
            self?.changedSpace()
        }
        observe(center, .EKEventStoreChanged) { [weak self] _ in self?.scheduleMeetingAlert() }
        observe(center, .NSSystemClockDidChange) { [weak self] _ in
            self?.refreshTimer()
            self?.scheduleMeetingAlert()
        }

        observe(DistributedNotificationCenter.default(), IslandEvents.inbound) { [weak self] notice in
            if let event = IslandEvents.decode(notice), let self,
               !self.fixture || !["ready", "media", "bye"].contains(event.type) {
                self.handle(event)
            }
        }
        installPointerMonitoring()
        updatePanelShortcut(fixture && CommandLine.arguments.contains("--fixture-panel-shortcut") ? .letterJ : preferences.shortcut)
        updateQuickShortcut(preferences.quickChatEnabled)
        if !fixture || CommandLine.arguments.contains("--fixture-file-hotkeys") { updateFileShortcuts() }
        if !fixture || CommandLine.arguments.contains("--fixture-file-hotkeys") {
            updateProjectFolderShortcut(preferences.projectFolderShortcut)
            updateClipboardPocket(preferences.clipboardPocketEnabled)
        }
        if fixture && CommandLine.arguments.contains("--quick-chat") {
            DispatchQueue.main.async { [weak self] in self?.showQuickChat() }
        }
        media.changed = { [weak self] item in
            self?.systemItem = item
            self?.refreshMedia()
        }
        media.healthChanged = { message in NSLog("Чубзик: %@", message) }
        if fixture { installFixture() }
        else if preferences.readsSystemMedia { media.start() }
        if !fixture { IslandEvents.post(IslandEvent(type: "hello"), to: IslandEvents.outbound) }
        isReadyToReceiveFiles = true
        if !filesReceivedDuringLaunch.isEmpty {
            putFilesOnShelf(filesReceivedDuringLaunch)
            filesReceivedDuringLaunch.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if isReadyToReceiveFiles { putFilesOnShelf(urls) }
        else { filesReceivedDuringLaunch.append(contentsOf: urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let noteSaved = saveNote()
        let chatSaved = quickChat.prepareToQuit()
        if noteSaved && chatSaved { return .terminateNow }
        let alert = NSAlert()
        if !noteSaved && !chatSaved {
            alert.messageText = "Заметка и быстрый чат пока не сохранены"
        } else {
            alert.messageText = chatSaved ? "Заметка пока не сохранена" : "Быстрый чат пока не сохранён"
        }
        alert.informativeText = "Продолжи работу, чтобы Чубзик смог повторить сохранение."
        alert.addButton(withTitle: "Продолжить работу")
        alert.addButton(withTitle: "Выйти без сохранения")
        sender.activate()
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        if !noteSaved { scheduleNoteSave(after: 5) }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardPocket.flush(wait: true)
        if countdownSaveRetry != nil { saveCountdown(model.countdown) }
        cancelFilePickerSelection()
        dismissFileHandoff()
        stopShelfDelivery()
        stopCompletionNudge()
        stopCursorChase(animated: false)
        if !fixture { IslandEvents.post(IslandEvent(type: "disconnect"), to: IslandEvents.outbound) }
        noteSave?.cancel()
        quickChat.shutDown()
        media.stop()
        endAwake()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func observe(_ source: NotificationCenter, _ name: Notification.Name, handler: @escaping (Notification) -> Void) {
        let token = source.addObserver(forName: name, object: nil, queue: .main, using: handler)
        observers.append((source, token))
    }

    private func scheduleNoteSave(after delay: TimeInterval) {
        noteSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.noteSave = nil
            if !self.saveNote() { self.scheduleNoteSave(after: 5) }
        }
        noteSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: save)
    }

    private func saveNote() -> Bool {
        guard noteNeedsSave else { return true }
        guard LocalSettings.save(model.note, as: "note.json") else {
            if !model.noteSaveFailed { model.noteSaveFailed = true }
            return false
        }
        noteNeedsSave = false
        if model.noteSaveFailed { model.noteSaveFailed = false }
        return true
    }

    private func configureActions() {
        model.calendarFeed.onAccessRequested = { [weak self] in self?.scheduleMeetingAlert() }
        model.onMedia = { [weak self] track, action, position in self?.sendMedia(track, action, position: position) }
        model.onSelectSource = { [weak self] source in
            self?.preferredSource = source
            self?.refreshMedia()
        }
        model.onOpenSource = { [weak self] track in self?.openMediaSource(track) }
        model.onAddFiles = { [weak self] urls in self?.addFiles(urls) }
        model.onPasteFiles = { [weak self] in self?.pasteShelfFiles() }
        model.onPinFiles = { [weak self] paths, pinned in self?.pinShelfFiles(paths, pinned: pinned) }
        model.onChooseFiles = { [weak self] in self?.chooseShelfFiles() }
        model.onRemoveFiles = { [weak self] paths in self?.removeShelfFiles(paths) }
        model.onShelfAvailability = { [weak self] scanned, reachable, revised in
            guard let self, self.model.active, self.model.page == .shelf, self.model.paging.turn == nil else { return }
            let tracked = self.model.shelf.recordedPaths
            let moved = scanned.subtracting(reachable).intersection(tracked)
            self.refreshShelfReferences(for: moved.union(reachable.subtracting(tracked)).union(revised))
        }
        model.onUndoFiles = { [weak self] in self?.undoShelfRemoval() }
        model.onPreviewFile = { [weak self] file in self?.showFilePreview(file) }
        model.onAskAboutImage = { [weak self] file in self?.askAboutShelfImage(file) }
        model.onOpenFile = { [weak self] file in
            if NSWorkspace.shared.open(file) { self?.closePanelUnlessPinned() }
            else { self?.model.shelfFeedback = "Не удалось открыть файл" }
        }
        model.onRemoveTask = { [weak self] id in self?.removeTask(id) }
        model.onUndoTask = { [weak self] in self?.undoTaskRemoval() }
        model.onQueue = { [weak self] file in self?.queueFile(file) }
        model.onTimer = { [weak self] duration, phase in
            guard let self else { return false }
            return self.setCountdown(duration.map { Countdown(end: self.timerDate.addingTimeInterval($0), phase: phase) })
        }
        model.onPauseTimer = { [weak self] in
            guard let self, let countdown = self.model.countdown else { return }
            if let next = countdown.togglingPause(at: self.timerDate) { self.setCountdown(next) }
            else { self.refreshTimer() }
        }
        model.onStopwatch = { [weak self] reset in
            guard let self else { return }
            var stopwatch = reset ? Stopwatch() : self.model.stopwatch
            if !reset { stopwatch.toggle(at: self.stopwatchTime) }
            guard LocalSettings.save(stopwatch, as: "stopwatch.json") else {
                self.model.clockFeedback = self.stopwatchSaveError
                return
            }
            self.model.stopwatch = stopwatch
            if self.model.clockFeedback == self.stopwatchSaveError { self.model.clockFeedback = nil }
            self.updateActivity()
        }
        model.onSaveNote = { [weak self] in
            guard let self else { return }
            self.noteNeedsSave = true
            self.scheduleNoteSave(after: 0.35)
        }
        model.onSaveTasks = { [weak self] tasks in self?.persistTasks(tasks) ?? false }
        model.onChangePage = { [weak self] page in
            guard let self else { return }
            self.requestPage(page)
            if page == .shelf { self.focusShelf() }
        }
        model.onExpandMusic = { [weak self] in self?.setPanel(true) }
        model.onOpenQuickChat = { [weak self] record in
            // Let the menu release keyboard focus before the chat takes it.
            DispatchQueue.main.async { [weak self] in
                self?.showQuickChat(record, startNew: record == nil)
            }
        }
        model.onResumeQuickChat = { [weak self] in self?.showQuickChat() }
        quickChat.onPointerMoved = { [weak self] in self?.followQuickChatPointer($0, animated: false) }
        quickChat.onReaction = { [weak self] reaction in self?.showChatExpression(reaction) }
        quickChatPhase = quickChat.model.$phase.map(\.isRunning).removeDuplicates().sink { [weak self] running in
            self?.model.quickChatIsRunning = running
        }
        quickChat.onCaptureVisibility = { [weak self] isVisible in self?.mascotWindow?.alphaValue = isVisible ? 1 : 0 }
        quickChat.onClose = { [weak self] in
            guard let self else { return }
            self.chatBlink?.cancel()
            self.chatBlink = nil
            self.mascot?.setChatExpression(.neutral)
            self.mascotWindow?.ignoresMouseEvents = false
            self.returnMascot(animated: true)
            self.updateVisibility()
            self.scheduleCuriosity()
            self.startCompletionNudgeIfReady()
        }
        quickChat.onBackgroundResult = { [weak self] succeeded in
            guard let self else { return }
            self.model.quickChatHasResult = true
            self.signalCompletion(.quickChat, useNudge: succeeded)
        }
        preferences.onQuickChatShortcutChange = { [weak self] enabled in self?.updateQuickShortcut(enabled) ?? false }
        model.onOpenCodex = { [weak self] chat in self?.openCodex(chat) }
        model.onReadCompletedCodex = { [weak self] in
            self?.readAllCompletedCodex()
        }
        model.onTogglePin = { [weak self] in self?.togglePanelPin() }
        model.onOpenPreferences = { [weak self] in self?.showPreferences() }
        preferences.onShortcutChange = { [weak self] shortcut in self?.updatePanelShortcut(shortcut) ?? false }
        preferences.onFileShortcutChange = { [weak self] source, shortcut in
            guard let self, self.updateFileShortcut(shortcut, for: source) else { return false }
            if source == .downloads {
                if self.preferences.unavailableCodexShortcut == self.preferences.bringCodexFileShortcut {
                    self.updateFileShortcut(self.preferences.bringCodexFileShortcut, for: .codex)
                }
            } else if self.preferences.unavailableDownloadShortcut == self.preferences.bringDownloadShortcut {
                self.updateFileShortcut(self.preferences.bringDownloadShortcut, for: .downloads)
            }
            return true
        }
        preferences.onReturnDisabled = { [weak self] in self?.clearCompletionReturn() }
        preferences.onProjectFolderShortcutChange = { [weak self] shortcut in self?.updateProjectFolderShortcut(shortcut) ?? false }
        preferences.onClipboardPocketChange = { [weak self] in self?.updateClipboardPocket($0) }
        clipboardPocket.onAsk = { [weak self] in self?.askAboutClipboardEntry($0) }
        clipboardPocket.onShelf = { [weak self] in self?.shelveClipboardEntry($0) }
        preferences.onGazeChange = { [weak self] enabled in
            if !enabled {
                self?.lastGaze = .zero
                self?.mascot?.look(.zero)
            }
        }
        preferences.onPursuitChange = { [weak self] enabled in
            guard let self, !enabled, self.pursuing else { return }
            self.stopPursuitMotion()
        }
        preferences.onSystemMediaChange = { [weak self] enabled in
            guard let self, !self.fixture else { return }
            if enabled {
                self.media.start()
            } else {
                self.media.stop()
                self.systemItem = nil
                self.refreshMedia()
            }
        }
    }

    private func makeWindows() {
        let characterFrame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let character = MascotView(frame: characterFrame)
        let mascotWindow = OverlayPanel(frame: characterFrame)
        mascotWindow.title = "Чубзик"
        mascotWindow.contentView = character
        character.onPress = { [weak self] point in self?.takeMascot(point) }
        character.onDrag = { [weak self] point in self?.dragMascot(point) }
        character.onRelease = { [weak self] _ in self?.dropMascot() }
        character.onDrop = { [weak self] urls in self?.dropFilesAtNotch(urls) ?? false }
        character.onDragTarget = { [weak self] in self?.notchDragEntered() }
        character.contextMenu = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            self.addMenuItem("Догонялки", #selector(self.toggleCursorChase), to: menu)
            return menu
        }
        mascot = character
        self.mascotWindow = mascotWindow

        let albumFrame = CGRect(x: 0, y: 0, width: 26, height: 26)
        let cover = CoverView(frame: albumFrame)
        cover.onClick = { [weak self] in self?.openMediaSource() }
        cover.onDrop = { [weak self] urls in self?.dropFilesAtNotch(urls) ?? false }
        cover.onDragTarget = { [weak self] in self?.notchDragEntered() }
        let coverWindow = OverlayPanel(frame: albumFrame)
        coverWindow.title = "Обложка"
        coverWindow.contentView = cover
        self.cover = cover
        self.coverWindow = coverWindow

        let notchTarget = NotchDropView(frame: .zero)
        notchTarget.onClick = { [weak self] in self?.setPanel(true) }
        notchTarget.onDragTarget = { [weak self] in self?.notchDragEntered() }
        notchTarget.onDrop = { [weak self] urls in self?.dropFilesAtNotch(urls) ?? false }
        let notchWindow = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        notchWindow.title = "Сброс файлов на чёлку"
        notchWindow.contentView = notchTarget
        notchDropWindow = notchWindow

        let activityFrame = CGRect(x: 0, y: 0, width: 50, height: 22)
        let activityWindow = OverlayPanel(frame: activityFrame)
        activityWindow.title = "Таймер у чёлки"
        activityWindow.ignoresMouseEvents = true
        let activityView = NSView(frame: activityFrame)
        activityView.wantsLayer = true
        activityView.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.14, alpha: 0.95).cgColor
        activityView.layer?.cornerRadius = 8
        let activityLabel = NSTextField(labelWithString: "")
        activityLabel.frame = CGRect(x: 0, y: 3, width: 50, height: 15)
        activityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        activityLabel.textColor = NSColor(white: 0.96, alpha: 1)
        activityLabel.alignment = .center
        activityView.addSubview(activityLabel)
        activityWindow.contentView = activityView
        self.activityWindow = activityWindow
        self.activityLabel = activityLabel

        let meetingFrame = CGRect(x: 0, y: 0, width: 63, height: 22)
        let meetingWindow = OverlayPanel(frame: meetingFrame)
        meetingWindow.title = "Встреча у чёлки"
        let meetingButton = MeetingButton(frame: meetingFrame)
        meetingButton.title = "Войти"
        meetingButton.font = .systemFont(ofSize: 11, weight: .semibold)
        meetingButton.isBordered = false
        meetingButton.focusRingType = .none
        meetingButton.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        meetingButton.imagePosition = .imageLeading
        meetingButton.contentTintColor = .white
        meetingButton.wantsLayer = true
        meetingButton.layer?.cornerRadius = 7
        meetingButton.layer?.backgroundColor = NSColor(srgbRed: 0.17, green: 0.19, blue: 0.24, alpha: 0.96).cgColor
        meetingButton.target = self
        meetingButton.action = #selector(joinMeeting)
        meetingWindow.contentView = meetingButton
        self.meetingWindow = meetingWindow
        self.meetingButton = meetingButton

        let signalFrame = CGRect(x: 0, y: 0, width: 118, height: 22)
        let signalWindow = OverlayPanel(frame: signalFrame)
        signalWindow.title = "Ответ у чёлки"
        let signalButton = MeetingButton(frame: signalFrame)
        signalButton.isBordered = false
        signalButton.focusRingType = .none
        signalButton.font = .systemFont(ofSize: 10.5, weight: .semibold)
        signalButton.imagePosition = .imageLeading
        signalButton.contentTintColor = .white
        signalButton.wantsLayer = true
        signalButton.layer?.cornerRadius = 7
        signalButton.layer?.backgroundColor = NSColor(srgbRed: 0.17, green: 0.19, blue: 0.24, alpha: 0.96).cgColor
        signalButton.target = self
        signalButton.action = #selector(openCompletionSignal)
        signalWindow.contentView = signalButton
        completionSignalWindow = signalWindow
        completionSignalButton = signalButton

        let panel = OverlayPanel(frame: CGRect(x: 0, y: 0, width: NotchGeometry.fullPanelWidth, height: 116), keyboard: true)
        panel.title = "Островок"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        let hosting = NSHostingView(rootView: PlayerPanel(model: model, quickHistory: quickHistory))
        hosting.wantsLayer = true
        hosting.sizingOptions = []
        panel.contentView = hosting
        player = panel
    }

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Чубзик")
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.toolTip = "Чубзик"
        let menu = NSMenu()
        addMenuItem("Показать островок", #selector(showPanel), to: menu)
        addMenuItem("Открыть полку", #selector(showShelf), to: menu)
        addMenuItem("Принести последнюю загрузку", #selector(bringDownload), to: menu)
        addMenuItem("Принести результат Codex", #selector(bringCodexFile), to: menu)
        addMenuItem("Открыть папку проекта Codex", #selector(openCurrentProjectFolder), to: menu)
        addMenuItem("Карманы буфера", #selector(openClipboardPocket), to: menu)
        addMenuItem("Быстрый чат", #selector(openQuickChat), to: menu)
        cursorChaseMenuItem = addMenuItem("Догонялки", #selector(toggleCursorChase), to: menu)
        addMenuItem("Спрятать или показать чубзика", #selector(toggleHidden), to: menu)
        addMenuItem("Настройки…", #selector(showPreferences), to: menu, key: ",")
        menu.addItem(.separator())
        addMenuItem("Keep Awake на 30 минут", #selector(startAwake), to: menu)
        addMenuItem("Разрешить сон", #selector(stopAwake), to: menu)
        menu.addItem(.separator())
        let demo = NSMenu()
        addMenuItem("Любопытный взгляд", #selector(demoCurious), to: demo)
        addMenuItem("Файл на полке", #selector(demoFile), to: demo)
        addMenuItem("Таймер закончился", #selector(demoTimer), to: demo)
        demo.addItem(.separator())
        addMenuItem("Как будто Codex начал работу", #selector(demoWorking), to: demo)
        addMenuItem("Как будто Codex закончил", #selector(demoDone), to: demo)
        addMenuItem("Как будто Codex ждёт ответа", #selector(demoAsk), to: demo)
        addMenuItem("Вернуть чубзика домой", #selector(demoClear), to: demo)
        let demos = NSMenuItem(title: "Проверить чубзика", action: nil, keyEquivalent: "")
        demos.submenu = demo
        menu.addItem(demos)
        menu.addItem(.separator())
        addMenuItem("Выйти", #selector(quit), to: menu, key: "q")
        item.menu = menu
        statusItem = item
    }

    @discardableResult private func addMenuItem(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === cursorChaseMenuItem else { return true }
        return cursorChase != nil || canStartCursorChase
    }

    @objc private func showPanel() { setPanel(true) }
    @objc private func showShelf() {
        changePage(.shelf)
        setPanel(true, restorePageOnOpen: false)
        focusShelf()
    }

    private func focusShelf() {
        guard model.page == .shelf else { return }
        model.shelfFocusRequest += 1
        player?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func demoWorking() { handle(IslandEvent(type: "work")) }
    @objc private func demoDone() { handle(IslandEvent(type: "done")) }
    @objc private func demoAsk() { handle(IslandEvent(type: "ask")) }
    @objc private func demoClear() {
        stopCompletionNudge()
        resolveCodexRequest(nil)
        stopPursuitMotion()
    }
    @objc private func demoCurious() { mascot?.react(.curious(1)) }
    @objc private func demoFile() { mascot?.react(.file) }
    @objc private func demoTimer() { mascot?.react(.timer) }
    @objc private func toggleHidden() {
        hiddenByUser.toggle()
        if hiddenByUser {
            clipboardPocket.close()
            cancelFilePickerSelection()
            dismissFileHandoff()
            clearCompletionReturn()
            stopShelfDelivery()
            stopCursorChase(animated: false)
            stopCompletionNudge()
            stopPursuitMotion()
            setPanel(false)
            curiosity?.cancel()
        }
        updateVisibility()
        if !hiddenByUser { scheduleCuriosity() }
    }

    @discardableResult private func updatePanelShortcut(_ shortcut: PanelShortcut) -> Bool {
        let registered = panelShortcut.set(shortcut)
        preferences.unavailablePanelShortcut = registered ? nil : shortcut
        return registered
    }

    private func updateFileShortcuts() {
        updateFileShortcut(preferences.bringDownloadShortcut, for: .downloads)
        updateFileShortcut(preferences.bringCodexFileShortcut, for: .codex)
    }

    @discardableResult private func updateFileShortcut(_ shortcut: FileShortcut, for source: FileSource) -> Bool {
        let registration = source == .downloads ? downloadFileShortcut : codexFileShortcut
        let registered = registration.setFileShortcut(shortcut)
        switch source {
        case .downloads: preferences.unavailableDownloadShortcut = registered ? nil : shortcut
        case .codex: preferences.unavailableCodexShortcut = registered ? nil : shortcut
        }
        return registered
    }

    @objc private func bringDownload() {
        DispatchQueue.main.async { [weak self] in self?.bringFile(from: .downloads) }
    }

    @objc private func bringCodexFile() {
        DispatchQueue.main.async { [weak self] in self?.bringFile(from: .codex) }
    }

    @discardableResult private func updateProjectFolderShortcut(_ shortcut: ProjectFolderShortcut) -> Bool {
        let registered = projectFolderShortcut.setProjectFolder(shortcut)
        preferences.unavailableProjectFolderShortcut = registered ? nil : shortcut
        return registered
    }

    @objc private func openCurrentProjectFolder() {
        guard let app = workspace.frontmostApplication, app.bundleIdentifier.map(isCodex) == true else {
            reportFileAction("Открой нужный диалог Codex")
            return
        }
        let pid = app.processIdentifier
        Task { @MainActor [weak self] in
            let lookup = await Task.detached(priority: .userInitiated) {
                guard let title = CodexComposer.focusedTitle(pid: pid) else { return nil as (String, URL)? }
                return CodexProjectFolder.find(title: title).map { (title, $0) }
            }.value
            guard let self, self.workspace.frontmostApplication?.processIdentifier == pid else { return }
            guard let (title, folder) = lookup, CodexComposer.focusedTitle(pid: pid) == title else {
                self.reportFileAction("Не удалось определить папку диалога")
                return
            }
            guard let finder = self.workspace.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                self.reportFileAction("Не удалось открыть Finder")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                let application = try await self.workspace.open([folder], withApplicationAt: finder, configuration: configuration)
                if self.workspace.frontmostApplication?.processIdentifier == pid,
                   CodexComposer.focusedTitle(pid: pid) == title {
                    application.activate()
                }
            } catch {
                if self.workspace.frontmostApplication?.processIdentifier == pid {
                    self.reportFileAction("Не удалось открыть папку диалога")
                }
            }
        }
    }

    private func reportFileAction(_ text: String) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              fileHandoff?.isDragging != true else { return }
        dismissFileHandoff()
        let message = FileHandoff(files: [], cursor: NSEvent.mouseLocation, display: screen.visibleFrame, emptyMessage: text)
        fileHandoff = message
        message.show()
        updateEscapeShortcut()
        expireFileMessage()
    }

    private func updateClipboardPocket(_ enabled: Bool) {
        clipboardPocket.setEnabled(enabled)
        preferences.clipboardPocketShortcutUnavailable = !clipboardShortcut.setClipboardPocket(enabled)
    }

    @objc private func openClipboardPocket() {
        guard !displaysSleeping, fileChooser == nil, fileHandoff?.isDragging != true,
              !quickChat.isCapturing else { return }
        guard preferences.clipboardPocketEnabled else {
            reportFileAction("Включи карманы буфера в настройках «Файлы»")
            return
        }
        dismissFileHandoff()
        clipboardPocket.show(at: NSEvent.mouseLocation)
    }

    private func askAboutClipboardEntry(_ entry: PocketEntry) {
        if let photo = entry.photo {
            if !quickChat.isOpen { showQuickChat() }
            _ = quickChat.addClipboardImage(photo.data)
        } else if let image = entry.fileURLs.first(where: QuickChatImage.supports) {
            askAboutShelfImage(image)
        } else if let text = entry.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showQuickChat(selectedText: String(text.prefix(16_000)))
        }
    }

    private func shelveClipboardEntry(_ entry: PocketEntry) {
        let files = entry.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty { putFilesOnShelf(files); return }
        guard let photo = entry.photo else { reportFileAction("Файл больше недоступен"); return }
        let directory = LocalSettings.directory.appendingPathComponent("Shelf Images", isDirectory: true)
        let date = entry.copied.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let file = directory.appendingPathComponent("Буфер \(date) \(entry.id.uuidString.prefix(8))")
            .appendingPathExtension(photo.type.preferredFilenameExtension ?? "image")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) { try photo.data.write(to: file, options: .atomic) }
            putFilesOnShelf([file])
        } catch { reportFileAction("Не удалось положить изображение на полку") }
    }

    private func bringFile(from source: FileSource) {
        guard !displaysSleeping, !completionMouseDown, fileChooser == nil,
              filePickerSelection == nil, fileHandoff?.isDragging != true else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        dismissFileHandoff()
        let files = source == .downloads ? recentDownloads.compactMap(CodexResultFiles.localFile)
            : recentCodexFiles.latestAvailableFiles()
        let empty = source == .downloads ? "Нет доступных загрузок" : "Нет файлов в результатах Codex"
        let destination = files.isEmpty || !CGPreflightPostEventAccess() ? nil : FilePickerDestination.current()
        if let destination, files.count == 1, let file = files.first {
            selectInFilePicker(file, destination: destination)
            return
        }
        showFileHandoff(files, at: point, on: screen, empty: empty, destination: destination)
    }

    private func selectInFilePicker(_ file: URL, destination: FilePickerDestination) {
        dismissFileHandoff()
        cancelFilePickerSelection()
        filePickerSelection = Task { @MainActor [weak self] in
            let selected = await destination.select(file)
            guard let self, !Task.isCancelled else { return }
            self.filePickerSelection = nil
            self.updateEscapeShortcut()
            guard !selected, destination.isCurrent else { return }
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                self.showFileHandoff([file], at: point, on: screen, empty: "Файл больше недоступен", destination: nil)
            }
        }
        updateEscapeShortcut()
    }

    private func cancelFilePickerSelection() {
        guard let selection = filePickerSelection else { return }
        selection.cancel()
        filePickerSelection = nil
        updateEscapeShortcut()
    }

    private func showFileHandoff(_ files: [URL], at point: CGPoint, on screen: NSScreen, empty: String,
                                 destination: FilePickerDestination?) {
        let delivery = FileHandoff(files: files, cursor: point, display: screen.visibleFrame, emptyMessage: empty,
                                   inPicker: destination != nil)
        fileHandoff = delivery
        if let destination {
            delivery.onPick = { [weak self] file in self?.selectInFilePicker(file, destination: destination) }
        }
        delivery.finished = { [weak self, weak delivery] in
            guard let self, let delivery, self.fileHandoff === delivery else { return }
            self.dismissFileHandoff()
        }
        delivery.becameEmpty = { [weak self, weak delivery] in
            guard let self, let delivery, self.fileHandoff === delivery else { return }
            self.expireFileMessage()
        }
        delivery.selectionChanged = { [weak self] in self?.updateEscapeShortcut() }
        updateEscapeShortcut()
        guard !files.isEmpty else {
            delivery.show()
            expireFileMessage()
            return
        }
        guard !reducedMotion, !hiddenByUser, !quickChat.isOpen, cursorChase == nil, shelfDelivery == nil,
              completionCurrent == nil, !pursuing, press == nil, let geometry, let mascotWindow, let mascot else {
            delivery.show()
            return
        }
        stopFlight()
        returnHome?.cancel()
        returnHome = nil
        curiosity?.cancel()
        curiosity = nil
        reveal?.cancel()
        reveal = nil
        closePanelUnlessPinned()
        let home = CGPoint(x: geometry.mascot.midX, y: geometry.mascot.midY)
        let start = screen.frame.contains(home) ? home : CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 14)
        mascotWindow.setFrameOrigin(CGPoint(x: start.x - mascotWindow.frame.width / 2,
                                             y: start.y - mascotWindow.frame.height / 2))
        mascotWindow.ignoresMouseEvents = true
        delivery.fly(mascotWindow: mascotWindow, mascot: mascot, home: home, start: start, display: screen.frame) { [weak self] in
            guard let self else { return }
            self.mascotWindow?.ignoresMouseEvents = false
            self.returnMascot(animated: false)
            self.updateVisibility()
            self.scheduleCuriosity()
            self.startCompletionNudgeIfReady()
        }
        updateVisibility()
    }

    private func updateEscapeShortcut() {
        let cardIsCancellable = fileHandoff.map { !$0.isDragging } ?? false
        _ = escapeShortcut.setEscape(filePickerSelection == nil && (cursorChase != nil || completionNudge != nil || cardIsCancellable))
    }

    private func cancelMascotInteraction() {
        if cursorChase != nil { stopCursorChase() }
        if completionCurrent != nil { cancelCompletionGesture() }
        if fileHandoff?.isDragging != true { dismissFileHandoff() }
    }

    private func dismissFileHandoff() {
        guard let delivery = fileHandoff else { return }
        fileHandoff = nil
        fileHandoffExpiry?.cancel()
        fileHandoffExpiry = nil
        updateEscapeShortcut()
        delivery.dismiss()
    }

    private func expireFileMessage() {
        fileHandoffExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.dismissFileHandoff() }
        fileHandoffExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: expiry)
    }

    private func dismissFileHandoffOnOutsideClick() {
        guard let delivery = fileHandoff, !delivery.isDragging,
              !delivery.window.isVisible || !delivery.window.frame.contains(NSEvent.mouseLocation) else { return }
        dismissFileHandoff()
    }

    private func togglePanelFromKeyboard() {
        guard fileChooser == nil else { return }
        if model.active {
            beginPanelClose(fromPointer: false)
        } else {
            setPanel(true)
            player?.makeKeyAndOrderFront(nil)
            focusShelf()
        }
    }

    @objc private func openQuickChat() { showQuickChat() }

    private var canStartCursorChase: Bool {
        mascotWindow != nil && geometry != nil && fileChooser == nil && !quickChat.isOpen && completionNudge == nil &&
            filePickerSelection == nil && shelfDelivery == nil && fileHandoff?.isFlying != true
    }

    @objc private func toggleCursorChase() {
        if cursorChase != nil {
            stopCursorChase()
            return
        }
        guard canStartCursorChase, let mascotWindow else { return }
        guard escapeShortcut.setEscape(true) else {
            let alert = NSAlert()
            alert.messageText = "Догонялки недоступны"
            alert.informativeText = "Не удалось назначить Esc для выхода из игры."
            NSApp.activate()
            alert.runModal()
            return
        }
        preferencesWindow?.close()
        closePanelUnlessPinned()
        if pursuing { stopPursuitMotion() }
        stopFlight()
        returnHome?.cancel()
        returnHome = nil
        curiosity?.cancel()
        curiosity = nil
        press = nil
        pressOrigin = nil
        dragStarted = false
        needsReturn = false
        mascot?.hold(false)
        mascot?.clearBlush()
        mascotWindow.ignoresMouseEvents = true

        cursorChase = CursorChase(at: CGPoint(x: mascotWindow.frame.midX, y: mascotWindow.frame.midY),
                                  now: ProcessInfo.processInfo.systemUptime)
        let front = workspace.frontmostApplication?.processIdentifier
        cursorChaseApp = front == getpid() ? nil : front
        cursorChaseMenuItem?.title = "Закончить догонялки"
        updateVisibility()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.advanceCursorChase()
        }
        timer.tolerance = 0.002
        cursorChaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceCursorChase() {
        guard var chase = cursorChase, let mascotWindow else { return }
        let cursor = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let primary = screens.first, let screen = screens.first(where: { $0.frame.contains(cursor) }) else {
            stopCursorChase(animated: false)
            return
        }
        let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
        let frame = chase.step(cursor: cursor, now: ProcessInfo.processInfo.systemUptime,
                               bounds: screen.frame.insetBy(dx: 18, dy: 18),
                               mouseDown: buttonDown, reduceMotion: reducedMotion)
        cursorChase = chase
        if let target = frame.cursor {
            if let owner = cursorChaseApp, workspace.frontmostApplication?.processIdentifier != owner {
                interruptPointerControl(endChase: true, endCompletion: false)
                return
            }
            if CGWarpMouseCursorPosition(CGPoint(x: target.x, y: primary.frame.maxY - target.y)) != .success {
                stopCursorChase()
                return
            }
        }
        let size = mascotWindow.frame.size
        let origin = CGPoint(x: frame.mascot.x - size.width / 2, y: frame.mascot.y - size.height / 2)
        if origin != mascotWindow.frame.origin { mascotWindow.setFrameOrigin(origin) }
        let look = frame.cursor ?? cursor
        mascot?.look(CGPoint(x: min(3.25, max(-3.25, (look.x - frame.mascot.x) / 20)),
                             y: min(2.5, max(-3, (look.y - frame.mascot.y) / 22))))
        mascot?.extendPaw(frame.paw)
        switch frame.cue {
        case .crouch(let direction): mascot?.react(.chaseCrouch(direction))
        case .feint(let direction): mascot?.react(.chaseFeint(direction))
        case .jump(let direction, let duration): mascot?.react(.chaseJump(direction, duration: duration))
        case .catchCursor: mascot?.react(.chaseCatch)
        case .miss: mascot?.react(.chaseMiss)
        case .land: mascot?.react(.landing)
        case nil: break
        }
    }

    private func stopCursorChase(animated: Bool = true) {
        guard cursorChase != nil else { return }
        cursorChase = nil
        cursorChaseApp = nil
        cursorChaseTimer?.invalidate()
        cursorChaseTimer = nil
        updateEscapeShortcut()
        mascot?.extendPaw(nil)
        cursorChaseMenuItem?.title = "Догонялки"
        mascotWindow?.ignoresMouseEvents = false
        returnMascot(animated: animated && !hiddenByUser && !fullscreen)
        updateVisibility()
        lastMouseMovement = ProcessInfo.processInfo.systemUptime
        scheduleCuriosity()
        startCompletionNudgeIfReady()
    }

    private func signalCompletion(_ kind: CompletionKind, chat: String? = nil, useNudge: Bool = true) {
        guard !hiddenByUser, !displaysSleeping else { return }
        let notice = CompletionNotice(kind: kind, chats: Set([chat].compactMap { $0 }),
                                      unknown: kind == .codex && chat == nil)
        if !useNudge {
            showCompletionSignal(notice)
            return
        }
        if var current = completionCurrent, current.kind == kind, !completionDidOpen {
            current.merge(notice)
            completionCurrent = current
            if current.singleChat == nil { completionNudge?.redirectToCursor() }
            if current.grouped {
                showCompletionSignal(current, persistent: true)
            }
            return
        }
        if var pending = completionPending, pending.kind == kind {
            pending.merge(notice)
            completionPending = pending
        } else if completionPending == nil || kind == .quickChat {
            if let pending = completionPending { showCompletionSignal(pending, persistent: pending.grouped) }
            completionPending = notice
        } else {
            showCompletionSignal(notice)
        }
        guard completionBatch == nil else { return }
        let batch = DispatchWorkItem { [weak self] in
            self?.completionBatch = nil
            self?.startCompletionNudgeIfReady()
        }
        completionBatch = batch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: batch)
    }

    private func withdrawCompletion(for chat: String) {
        if let pending = completionPending, pending.kind == .codex, pending.chats.contains(chat) {
            completionPending = pending.removing(chat)
        }
        withdrawCompletionSignal(for: chat)
        guard let current = completionCurrent, current.kind == .codex, current.chats.contains(chat) else { return }
        if let remaining = current.removing(chat) {
            completionCurrent = remaining
        } else {
            stopCompletionNudge(clearPending: false)
            scheduleCuriosity()
            startCompletionNudgeIfReady()
        }
    }

    private var canStartCompletionGesture: Bool {
        !hiddenByUser && !displaysSleeping && !quickChat.isOpen && cursorChase == nil &&
            press == nil && fileChooser == nil && !completionMouseDown && menuTrackingDepth == 0 &&
            !model.isEditing && preferencesWindow?.isVisible != true && previewWindow?.isVisible != true
    }

    private var completionMouseDown: Bool {
        NSEvent.pressedMouseButtons != 0 ||
            CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) ||
            CGEventSource.buttonState(.combinedSessionState, button: .center)
    }

    private func startCompletionNudgeIfReady() {
        guard completionBatch == nil, let notice = completionPending, completionCurrent == nil,
              completionNudge == nil, shelfDelivery == nil, fileHandoff?.isFlying != true,
              !hiddenByUser, !displaysSleeping, geometry != nil else { return }
        completionPending = nil
        guard canStartCompletionGesture,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else {
            showCompletionSignal(notice)
            return
        }
        completionCurrent = notice
        completionMode = fixtureCompletionMode ?? preferences.completionMode
        completionRequestedHandoff = false
        completionPauseReserved = false
        completionDidOpen = false
        completionCancelled = false
        let id = UUID()
        completionIdentity = id
        completionForeground = workspace.frontmostApplication?.processIdentifier
        completionPreparing = id
        let display = screen.frame
        guard completionMode != .soft, notice.singleChat != nil else {
            beginCompletionGesture(id, on: display, video: nil)
            return
        }
        if fixture && !CommandLine.arguments.contains("--fixture-live-video") {
            if CommandLine.arguments.contains("--fixture-nudge-uncertain") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.startCompletionAfterProbe(id, on: display, result: .unavailable)
                }
            } else {
                startCompletionAfterProbe(id, on: display, result: .inactive)
            }
            return
        }
        probeCompletionVideo(on: display, while: { [weak self] in self?.completionPreparing == id }) { [weak self] result in
            self?.startCompletionAfterProbe(id, on: display, result: result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in
            self?.startCompletionAfterProbe(id, on: display, result: .unavailable)
        }
    }

    private func probeCompletionVideo(on display: CGRect, while isCurrent: @escaping () -> Bool,
                                      completion: @escaping (VideoProbe<CompletionVideo>) -> Void) {
        func probeArDia(_ finished: @escaping (VideoProbe<CompletionVideo>) -> Void) {
            arDiaAutomation.find(on: display, mediaTabID: direct[ArDiaVideoPlayback.bundleID]?.id) { [weak self] result in
                guard let self, isCurrent() else { return }
                if case .unavailable = result {
                    self.arDiaVideo.find(on: display) { result in
                        if isCurrent() { finished(result.map(CompletionVideo.arDia)) }
                    }
                } else {
                    if self.fixture, case .playing = result { NSLog("completion found ArDia video via Apple Events") }
                    if self.fixture, case .uncertain = result { NSLog("completion found ambiguous ArDia playback via Apple Events") }
                    finished(result.map(CompletionVideo.arDiaAutomation))
                }
            }
        }

        func probeAccessibility(useArDiaFallback: Bool, includeArDia: Bool = true) {
            browserVideo.find(on: display, includeArDia: includeArDia) { result in
                guard isCurrent() else { return }
                switch result {
                case .playing, .uncertain: completion(result.map(CompletionVideo.browser))
                case .inactive, .unavailable:
                    if useArDiaFallback, let top = NSScreen.screens.first?.frame.maxY,
                       ArDiaVideoPlayback.pictureInPicturePoint(top: top) != nil {
                        probeArDia { arDiaResult in
                            if case .inactive = arDiaResult { completion(result.map(CompletionVideo.browser)) }
                            else { completion(arDiaResult) }
                        }
                    } else {
                        completion(result.map(CompletionVideo.browser))
                    }
                }
            }
        }

        let arDiaPiP = NSScreen.screens.first.flatMap { ArDiaVideoPlayback.pictureInPicturePoint(top: $0.frame.maxY) }
        if arDiaVideo.isFrontmost || (arDiaPiP != nil && !BrowserVideoPlayback.isFrontmostBrowser) {
            probeArDia { result in
                switch result {
                case .unavailable: probeAccessibility(useArDiaFallback: false)
                case .inactive: probeAccessibility(useArDiaFallback: false, includeArDia: false)
                case .playing, .uncertain: completion(result)
                }
            }
        } else {
            probeAccessibility(useArDiaFallback: true)
        }
    }

    private func startCompletionAfterProbe(_ id: UUID, on display: CGRect, result: VideoProbe<CompletionVideo>) {
        switch result {
        case .playing(let video): beginCompletionGesture(id, on: display, video: video)
        case .inactive: beginCompletionGesture(id, on: display, video: nil)
        case .unavailable, .uncertain: beginCompletionGesture(id, on: display, video: nil, canGuide: false)
        }
    }

    private func beginCompletionGesture(_ id: UUID, on display: CGRect, video: CompletionVideo?, canGuide: Bool = true) {
        guard completionPreparing == id, let notice = completionCurrent else { return }
        completionPreparing = nil
        guard canStartCompletionGesture, let window = mascotWindow, display.contains(NSEvent.mouseLocation) else {
            completionCurrent = nil
            completionIdentity = nil
            showCompletionSignal(notice)
            startCompletionNudgeIfReady()
            return
        }
        stopFlight()
        returnHome?.cancel()
        returnHome = nil
        needsReturn = false
        reveal?.cancel()
        reveal = nil
        curiosity?.cancel()
        curiosity = nil
        window.ignoresMouseEvents = true
        completionTugs = 0
        completionWarpFailed = false
        completionVideo = notice.singleChat == nil ? nil : video
        let fixtureVideo = fixture && notice.singleChat != nil && completionMode != .soft
            && CommandLine.arguments.contains("--fixture-nudge-video")
        let pausePoint = completionVideo?.point ?? (fixtureVideo ? CGPoint(x: display.midX - 80, y: display.midY) : nil)
        if notice.grouped || completionMode == .medium || (completionMode == .high && !canGuide) {
            showCompletionSignal(notice, persistent: true)
        }
        completionNudge = CompletionNudge(at: CGPoint(x: window.frame.midX, y: window.frame.midY),
                                          now: ProcessInfo.processInfo.systemUptime, display: display,
                                          video: pausePoint, guidesToAnswer: canGuide && completionMode == .high && notice.singleChat != nil,
                                          overhead: !fixture && Int.random(in: 0..<4) == 0)
        updateEscapeShortcut()
        updateVisibility()
        if fixture { NSLog("completion started %@", completionMode.rawValue) }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.advanceCompletionNudge()
        }
        timer.tolerance = 0.002
        completionNudgeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceCompletionNudge() {
        guard var nudge = completionNudge, let window = mascotWindow, let home = geometry?.mascot else {
            cancelCompletionGesture()
            return
        }
        if CGEventSource.keyState(.combinedSessionState, key: 53) {
            cancelCompletionGesture()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let composer = completionComposer, now - completionComposerCheck >= 0.12 {
            completionComposerCheck = now
            if !composer.isCurrent() {
                cancelCompletionGesture()
                return
            }
        }
        let cursor = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first,
              let display = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) else {
            cancelCompletionGesture()
            return
        }
        let frame = nudge.step(cursor: cursor, home: CGPoint(x: home.midX, y: home.midY), display: display.frame,
                               now: now, mouseDown: completionMouseDown,
                               reduceMotion: reducedMotion)
        completionNudge = nudge
        if (frame.cursor != nil || frame.action != nil), let front = workspace.frontmostApplication,
           !allowsCompletion(in: front) {
            interruptPointerControl(endChase: false, endCompletion: true)
            return
        }
        let movement = CGPoint(x: frame.mascot.x - window.frame.midX, y: frame.mascot.y - window.frame.midY)
        let origin = CGPoint(x: frame.mascot.x - window.frame.width / 2, y: frame.mascot.y - window.frame.height / 2)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
        if let target = frame.cursor,
           CGWarpMouseCursorPosition(CGPoint(x: target.x, y: primary.frame.maxY - target.y)) != .success {
            completionWarpFailed = true
            cancelCompletionGesture()
            return
        }
        mascot?.extendPaw(frame.paw, tug: frame.tug)
        let look = frame.cursor ?? cursor
        if let paw = frame.paw {
            let tip = paw.tip
            mascot?.look(CGPoint(x: tip.x / 5.7, y: tip.y / 6.8))
        } else {
            let isMoving = hypot(movement.x, movement.y) > 0.5
            let dx = isMoving ? movement.x / 4 : (look.x - frame.mascot.x) / 24
            let dy = isMoving ? movement.y / 4 : (look.y - frame.mascot.y) / 24
            mascot?.look(CGPoint(x: min(3.25, max(-3.25, dx)), y: min(2.5, max(-2.5, dy))))
        }
        if frame.cancelled {
            if completionDidOpen {
                cancelCompletionGesture()
                return
            }
            completionCancelled = true
            if let notice = completionCurrent { showCompletionSignal(notice, persistent: completionMode == .medium || notice.grouped) }
        }
        if !completionCancelled, let action = frame.action {
            switch action {
            case .pause:
                if let video = completionVideo {
                    pauseCompletionVideo(video)
                }
                if fixture, completionVideo == nil {
                    NSLog("completion touched video")
                }
            case .openAnswer:
                beginCodexHandoff(on: display.frame)
            }
        }
        if frame.tug {
            completionTugs += 1
            if fixture { NSLog("completion tug") }
        }
        if frame.finished {
            if let notice = completionCurrent, !completionDidOpen,
               notice.kind == .quickChat || completionMode != .soft || notice.grouped || completionTugs < 2 || completionWarpFailed {
                showCompletionSignal(notice, persistent: completionMode == .medium || notice.grouped)
            }
            stopCompletionNudge(clearPending: false)
            lastMouseMovement = ProcessInfo.processInfo.systemUptime
            scheduleCuriosity()
            startCompletionNudgeIfReady()
        }
    }

    private func beginCodexHandoff(on display: CGRect) {
        guard completionNudge?.awaitsComposer == true, !completionRequestedHandoff, !completionCancelled,
              !completionMouseDown, let chat = completionCurrent?.singleChat, let id = completionIdentity else { return }
        guard workspace.frontmostApplication?.processIdentifier == completionForeground else {
            completionNudge?.redirectToCursor()
            return
        }
        completionRequestedHandoff = true
        if fixture && !CommandLine.arguments.contains("--fixture-live-video") {
            openCodexHandoff(chat, on: display)
            return
        }

        completionCheckingPlayback = true
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.completionIdentity == id && self.completionCheckingPlayback && !self.completionCancelled &&
                self.completionNudge?.awaitsComposer == true && self.completionCurrent?.singleChat == chat
        }
        let canSwitch = { [weak self] in
            guard let self, isCurrent(), self.canStartCompletionGesture,
                  self.workspace.frontmostApplication?.processIdentifier == self.completionForeground else { return false }
            return display.contains(NSEvent.mouseLocation)
        }
        let finish = { [weak self] (canOpen: Bool) in
            guard let self, isCurrent() else { return }
            let shouldOpen = canOpen && canSwitch()
            self.completionCheckingPlayback = false
            if shouldOpen {
                self.openCodexHandoff(chat, on: display)
            } else {
                self.completionNudge?.redirectToCursor()
            }
        }
        probeCompletionVideo(on: display, while: isCurrent) { [weak self] result in
            guard let self, canSwitch() else { finish(false); return }
            switch result {
            case .inactive: finish(true)
            case .unavailable, .uncertain: finish(false)
            case .playing(let video):
                // The second probe may find a different player after the first one stops.
                guard !self.completionPauseReserved else { finish(false); return }
                self.pauseVideo(video, shouldPress: canSwitch) { [weak self] result in
                    guard let self else { return }
                    if result == .paused, self.completionIdentity == id, !self.completionCancelled,
                       self.model.completedCodex.contains(where: { $0.chat == chat }) {
                        self.rememberVideoPause(video, for: chat)
                    }
                    guard canSwitch() else { finish(false); return }
                    if self.fixture {
                        NSLog("completion video stopped=%@ result=%@", String(result.hasStopped), result.rawValue)
                    }
                    // Give the player's pause handlers time to run, then check the whole playback context again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        guard let self, canSwitch() else { finish(false); return }
                        self.probeCompletionVideo(on: display, while: isCurrent) { confirmation in
                            if case .inactive = confirmation { finish(true) }
                            else { finish(false) }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.70) { finish(false) }
    }

    private func openCodexHandoff(_ chat: String, on display: CGRect) {
        let identity = completionIdentity
        prepareCompletionReturn(for: chat, while: { [weak self] in
            guard let self else { return false }
            return self.completionIdentity == identity && self.completionNudge?.awaitsComposer == true
                && self.completionCurrent?.singleChat == chat && !self.completionMouseDown
        }) { [weak self] in
            self?.launchCodexHandoff(chat, on: display)
        }
    }

    private func launchCodexHandoff(_ chat: String, on display: CGRect) {
        completionNudge?.restartComposerWait(now: ProcessInfo.processInfo.systemUptime)
        completionHandoff = .opening
        guard openCodex(chat, verifyRead: false) else {
            if completionReturn?.chat == chat { clearCompletionReturn() }
            completionHandoff = nil
            completionNudge?.guide(to: nil, from: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                                   reduceMotion: reducedMotion)
            return
        }
        if fixture {
            completionDidOpen = true
            acknowledgeCodex(chat)
            let point = CommandLine.arguments.contains("--fixture-completion-composer")
                ? CGPoint(x: display.midX, y: display.minY + 110) : nil
            completionNudge?.guide(to: point, from: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                                   reduceMotion: reducedMotion)
            return
        }
        let identity = completionIdentity
        completionComposerSearch = Task { @MainActor [weak self] in
            guard let self else { return }
            var window = await self.waitForCodexWindow(chat, timeout: 1.40)
            if let first = window, first.pid != self.completionForeground {
                // A fullscreen Space can report the Codex window before its transition settles.
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled, self.completionIdentity == identity,
                      self.completionNudge?.awaitsComposer == true else { return }
                self.completionNudge?.restartComposerWait(now: ProcessInfo.processInfo.systemUptime)
                window = await self.waitForCodexWindow(chat, timeout: 0.45)
            }
            guard !Task.isCancelled, self.completionIdentity == identity,
                  self.completionNudge?.awaitsComposer == true, !self.completionMouseDown else { return }
            guard let window, let top = NSScreen.screens.first?.frame.maxY, window.isCurrent() else {
                self.completionNudge?.guide(to: nil, from: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                                            reduceMotion: self.reducedMotion)
                return
            }
            self.completionDidOpen = true
            self.acknowledgeCodex(chat)
            let job = Task.detached(priority: .userInitiated) { await CodexComposer.locate(in: window, top: top) }
            let destination = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled, self.completionIdentity == identity,
                  self.completionNudge?.awaitsComposer == true, !self.completionMouseDown else { return }
            let point = destination.flatMap { display.contains($0) && window.isCurrent() ? $0 : nil }
            self.completionComposer = point == nil ? nil : window
            self.completionComposerCheck = ProcessInfo.processInfo.systemUptime
            self.completionNudge?.guide(to: point, from: NSEvent.mouseLocation,
                                        now: self.completionComposerCheck, reduceMotion: self.reducedMotion)
        }
    }

    @MainActor private func waitForCodexWindow(_ chat: String, timeout: TimeInterval) async -> CodexComposer.Window? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let search = Task.detached(priority: .userInitiated) { CodexHook.uniqueThreadTitle(chat) }
        let title = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
        guard let title else { return nil }
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if let app = workspace.frontmostApplication, let bundle = app.bundleIdentifier, isCodex(bundle) {
                let pid = app.processIdentifier
                if let window = await Task.detached(priority: .userInitiated, operation: {
                    CodexComposer.confirmedWindow(pid: pid, title: title)
                }).value, window.isCurrent() { return window }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private func pauseCompletionVideo(_ video: CompletionVideo) {
        guard let chat = completionCurrent?.singleChat else { return }
        let id = completionIdentity
        var reserved = false
        let shouldPress = { [weak self] in
            guard let self, self.completionIdentity == id, self.completionCurrent?.singleChat == chat, !self.completionCancelled,
                  self.canStartCompletionGesture, !self.completionRequestedHandoff,
                  !self.completionPauseReserved,
                  self.workspace.frontmostApplication?.processIdentifier == self.completionForeground else { return false }
            self.completionPauseReserved = true
            reserved = true
            return true
        }
        let finished = { [weak self] (result: VideoPause) in
            guard let self, self.completionIdentity == id, !self.completionCancelled else { return }
            if reserved && !result.mayHavePaused { self.completionPauseReserved = false }
            if result == .paused, self.model.completedCodex.contains(where: { $0.chat == chat }) {
                self.rememberVideoPause(video, for: chat)
            }
            if self.fixture { NSLog("completion video stopped=%@ result=%@", String(result.hasStopped), result.rawValue) }
        }
        pauseVideo(video, shouldPress: shouldPress, completion: finished)
    }

    private func pauseVideo(_ video: CompletionVideo, shouldPress: @escaping () -> Bool,
                            completion: @escaping (VideoPause) -> Void) {
        let keep = preferences.returnsToPreviousLocation && completionCurrent?.kind == .codex && completionCurrent?.singleChat != nil
        switch video {
        case .browser(let target): browserVideo.pause(target, shouldPress: shouldPress, completion: completion)
        case .arDia(let target):
            arDiaVideo.pause(target, retainForResume: keep, shouldPress: shouldPress, completion: completion)
        case .arDiaAutomation(let target):
            arDiaAutomation.pause(target, retainForResume: keep, shouldPress: shouldPress, completion: completion)
        }
    }

    private func rememberVideoPause(_ video: CompletionVideo, for chat: String) {
        guard preferences.returnsToPreviousLocation, completionCurrent?.kind == .codex else { return }
        rememberCompletionReturn(CompletionReturn(chat: chat, video: video, originalApp: completionForeground))
    }

    private func rememberCompletionReturn(_ ticket: CompletionReturn) {
        clearCompletionReturn()
        completionReturn = ticket
        let expiry = DispatchWorkItem { [weak self] in self?.clearCompletionReturn() }
        completionReturnExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 480, execute: expiry)
    }

    private func clearCompletionReturn() {
        returnPreparation = nil
        completionReturnExpiry?.cancel()
        completionReturnExpiry = nil
        completionReturn = nil
        completionReturnAttempt = nil
    }

    private func prepareCompletionReturn(for chat: String, while isCurrent: @escaping () -> Bool,
                                         open: @escaping () -> Void) {
        guard isCurrent() else { return }
        guard preferences.returnsToPreviousLocation,
              let app = workspace.frontmostApplication, let bundle = app.bundleIdentifier,
              app.processIdentifier != getpid(), !isCodex(bundle) else {
            open()
            return
        }
        let pid = app.processIdentifier
        if let ticket = completionReturn, ticket.chat == chat, ticket.originalApp == pid, ticket.video != nil {
            open()
            return
        }
        clearCompletionReturn()
        let id = UUID()
        returnPreparation = id
        let location = CompletionReturnLocation.capture(pid: pid)
        let finish: (ArDiaAppleEventsPlayback.TabLocation?) -> Void = { [weak self] tab in
            guard let self, self.returnPreparation == id else { return }
            self.returnPreparation = nil
            guard isCurrent(), self.workspace.frontmostApplication?.processIdentifier == pid else { return }
            if self.preferences.returnsToPreviousLocation, location != nil || tab != nil {
                self.rememberCompletionReturn(CompletionReturn(chat: chat, video: nil, originalApp: pid,
                                                               location: location, tab: tab))
            }
            open()
        }
        if bundle == ArDiaVideoPlayback.bundleID {
            arDiaAutomation.currentTab(pid: pid, completion: finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(nil) }
        } else {
            finish(nil)
        }
    }

    private func returnAfterSubmitting(chat: String) {
        // Hook events from other threads can arrive while the foreground submission is being verified.
        guard preferences.returnsToPreviousLocation, let ticket = completionReturn, ticket.chat == chat,
              let app = workspace.frontmostApplication, app.bundleIdentifier.map(isCodex) == true,
              ticket.codexApp == app.processIdentifier || (ticket.codexApp == nil && ticket.requestedChat) else { return }
        let codex = app.processIdentifier
        clearCompletionReturn()
        let attempt = CompletionReturnAttempt(codex: codex)
        completionReturnAttempt = attempt
        if completionCurrent?.singleChat == chat { stopCompletionNudge(clearPending: false) }
        let stillInCodex = { [weak self] in
            guard let self else { return false }
            return self.completionReturnAttempt == attempt && self.preferences.returnsToPreviousLocation && !self.hiddenByUser && !self.displaysSleeping &&
                self.workspace.frontmostApplication?.processIdentifier == codex
        }
        Task { @MainActor [weak self] in
            let lookup = Task.detached(priority: .userInitiated) { CodexHook.uniqueThreadTitle(chat) }
            try? await Task.sleep(for: .milliseconds(220))
            let title = await lookup.value
            guard let self, self.completionReturnAttempt == attempt else { return }
            guard stillInCodex(), let title, let window = CodexComposer.confirmedWindow(pid: codex, title: title) else {
                self.clearCompletionReturn()
                if self.fixture {
                    NSLog("%@", ticket.video == nil ? "return-to-location restored=false" : "return-to-video resumed=false")
                }
                return
            }
            let shouldResume = { stillInCodex() && window.isCurrent() }
            let finished: (Bool) -> Void = { [weak self] started in
                guard let self, self.completionReturnAttempt == attempt else { return }
                defer { self.clearCompletionReturn() }
                if started, ticket.video?.isPictureInPicture == true, let pid = ticket.originalApp, pid != codex, shouldResume() {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                if started, !self.reducedMotion { self.mascot?.react(.landing) }
                if self.fixture {
                    let label = ticket.video == nil ? "return-to-location restored" : "return-to-video resumed"
                    NSLog("%@=%@", label, String(started))
                }
            }
            switch ticket.video {
            case .browser(let target): self.browserVideo.resume(target, shouldResume: shouldResume, completion: finished)
            case .arDia(let target): self.arDiaVideo.resume(target, shouldResume: shouldResume, completion: finished)
            case .arDiaAutomation(let target):
                self.arDiaAutomation.resume(target, shouldResume: shouldResume, completion: finished)
            case nil:
                let restoreWindow: () -> Bool = {
                    if let location = ticket.location { return location.restore() }
                    guard let pid = ticket.originalApp else { return false }
                    return NSRunningApplication(processIdentifier: pid)?.activate() == true
                }
                if let tab = ticket.tab {
                    self.arDiaAutomation.restoreTab(tab, shouldRestore: {
                        shouldResume() && (ticket.location?.isAvailable() ?? true)
                    }) { restored in
                        let stillThere = shouldResume()
                        let didRestore = restored && (stillThere ? restoreWindow()
                            : self.workspace.frontmostApplication?.processIdentifier == ticket.originalApp)
                        finished(didRestore)
                    }
                } else if let location = ticket.location, shouldResume() {
                    finished(location.restore())
                } else {
                    finished(false)
                }
            }
        }
    }

    private func allowsCompletion(in app: NSRunningApplication) -> Bool {
        switch completionHandoff {
        case .destination(let pid): return app.processIdentifier == pid
        case .opening:
            if app.bundleIdentifier.map(isCodex) == true {
                completionHandoff = .destination(app.processIdentifier)
                return true
            }
            return app.processIdentifier == completionForeground
        case nil: return app.processIdentifier == completionForeground
        }
    }

    private func interruptPointerControl(endChase: Bool, endCompletion: Bool) {
        guard endChase || endCompletion else { return }
        let pending = completionPending
        completionPending = nil
        completionBatch?.cancel()
        completionBatch = nil
        if endChase { stopCursorChase(animated: false) }
        if endCompletion { cancelCompletionGesture() }
        if let pending { showCompletionSignal(pending, persistent: pending.grouped) }
    }

    private func cancelCompletionGesture() {
        guard let notice = completionCurrent else { return }
        let didOpen = completionDidOpen
        stopCompletionNudge(clearPending: false)
        if !didOpen { showCompletionSignal(notice, persistent: completionMode == .medium || notice.grouped) }
        if fixture { NSLog("completion cancelled") }
        startCompletionNudgeIfReady()
    }

    private func stopCompletionNudge(clearPending: Bool = true) {
        if clearPending {
            completionPending = nil
            completionBatch?.cancel()
            completionBatch = nil
            deferredCodexSignal = nil
            clearCompletionSignal()
        }
        completionPreparing = nil
        completionIdentity = nil
        completionForeground = nil
        completionHandoff = nil
        completionCheckingPlayback = false
        completionComposerSearch?.cancel()
        completionComposerSearch = nil
        completionComposer = nil
        completionCurrent = nil
        completionVideo = nil
        guard completionNudge != nil else { return }
        completionNudge = nil
        completionNudgeTimer?.invalidate()
        completionNudgeTimer = nil
        updateEscapeShortcut()
        mascot?.extendPaw(nil)
        mascotWindow?.ignoresMouseEvents = false
        returnMascot(animated: false)
        updateVisibility()
    }

    private func showCompletionSignal(_ incoming: CompletionNotice, persistent: Bool = false) {
        var notice = incoming
        var stays = persistent
        if notice.kind == .codex {
            let old = deferredCodexSignal?.notice ?? (completionSignal?.kind == .codex ? completionSignal : nil)
            if let old {
                notice.merge(old)
                stays = stays || (deferredCodexSignal?.persistent ?? (completionSignalExpiry == nil))
            }
            notice.chats.formIntersection(Set(model.completedCodex.compactMap(\.chat)))
            guard notice.unknown || !notice.chats.isEmpty else { return }
            stays = stays || notice.grouped
            if completionSignal?.kind == .quickChat {
                deferredCodexSignal = (notice, stays)
                return
            }
        } else if let old = completionSignal, old.kind == .codex {
            deferredCodexSignal = (old, completionSignalExpiry == nil)
        }
        displayCompletionSignal(notice, persistent: stays)
    }

    private func displayCompletionSignal(_ notice: CompletionNotice, persistent: Bool) {
        guard !hiddenByUser, !displaysSleeping, let geometry, let window = completionSignalWindow,
              let button = completionSignalButton else { return }
        completionSignal = notice
        let failed = notice.kind == .quickChat && quickChat.model.phase != .done
        let title = notice.grouped ? "Codex · \(notice.chats.count) готово" : failed ? "Открыть чат" : "К ответу"
        button.title = title
        button.image = NSImage(systemSymbolName: failed ? "exclamationmark.circle" : "checkmark.circle",
                               accessibilityDescription: nil)
        button.toolTip = notice.grouped ? "Показать завершённые диалоги Codex" : "Открыть готовый ответ"
        button.setAccessibilityLabel(title + " — " + (button.toolTip ?? ""))
        let display = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.frame
        if let display, display != geometry.screen {
            window.setFrameOrigin(CGPoint(x: display.midX - window.frame.width / 2,
                                         y: display.maxY - window.frame.height - 8))
        } else {
            window.setFrameOrigin(CGPoint(x: geometry.cover.minX - window.frame.width - 5,
                                         y: geometry.cover.midY - window.frame.height / 2))
        }
        window.orderFrontRegardless()
        completionSignalExpiry?.cancel()
        completionSignalExpiry = nil
        if !persistent {
            let expiry = DispatchWorkItem { [weak self] in self?.clearCompletionSignal() }
            completionSignalExpiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: expiry)
        }
    }

    private func clearCompletionSignal() {
        let restoreCodex = completionSignal?.kind == .quickChat
        completionSignalExpiry?.cancel()
        completionSignalExpiry = nil
        completionSignal = nil
        completionSignalWindow?.orderOut(nil)
        if restoreCodex, let deferred = deferredCodexSignal {
            deferredCodexSignal = nil
            showCompletionSignal(deferred.notice, persistent: deferred.persistent)
        }
    }

    private func withdrawCompletionSignal(for chat: String) {
        if let deferred = deferredCodexSignal, deferred.notice.chats.contains(chat) {
            deferredCodexSignal = deferred.notice.removing(chat).map { ($0, deferred.persistent) }
        }
        guard let notice = completionSignal, notice.kind == .codex, notice.chats.contains(chat) else { return }
        if let remaining = notice.removing(chat) {
            displayCompletionSignal(remaining, persistent: completionSignalExpiry == nil)
        } else {
            clearCompletionSignal()
        }
    }

    @objc private func openCompletionSignal() {
        guard let notice = completionSignal else { return }
        if notice.grouped, let button = completionSignalButton {
            cancelCompletionGesture()
            completionSignalExpiry?.cancel()
            let menu = NSMenu()
            for entry in model.completedCodex where entry.chat.map(notice.chats.contains) == true {
                let item = NSMenuItem(title: entry.label, action: #selector(openCompletedChat(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.chat
                menu.addItem(item)
            }
            if menu.items.isEmpty { clearCompletionSignal() }
            else { menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -3), in: button) }
            return
        }
        cancelCompletionGesture()
        switch notice.kind {
        case .codex:
            if notice.chats.isEmpty { clearCompletionSignal() }
            if let chat = notice.singleChat { openFromCompletionSignal(chat) }
            else { openCodex(notice.chats.first) }
        case .quickChat: showQuickChat()
        }
    }

    @objc private func openCompletedChat(_ item: NSMenuItem) {
        guard let chat = item.representedObject as? String else { return }
        openFromCompletionSignal(chat)
    }

    private func openFromCompletionSignal(_ chat: String) {
        guard (fixtureCompletionMode ?? preferences.completionMode) != .soft else {
            openCodex(chat)
            return
        }
        prepareCompletionReturn(for: chat, while: { [weak self] in
            self?.model.completedCodex.contains(where: { $0.chat == chat }) == true
        }) { [weak self] in
            guard let self else { return }
            if !self.openCodex(chat), self.completionReturn?.chat == chat { self.clearCompletionReturn() }
        }
    }

    @discardableResult private func updateQuickShortcut(_ enabled: Bool) -> Bool {
        if fixture && !CommandLine.arguments.contains("--fixture-hotkey") { return true }
        let registered = quickShortcut.setQuickChat(enabled)
        preferences.quickChatShortcutUnavailable = !registered
        return registered
    }

    private func toggleQuickChat() {
        if quickChat.isOpen { quickChat.escape() }
        else { showQuickChat() }
    }

    private func askAboutShelfImage(_ file: URL) {
        if quickChat.isOpen {
            if !quickChat.addShelfImage(file) { model.shelfFeedback = "Чат сейчас занят" }
        } else {
            showQuickChat(imageURL: file)
        }
    }

    private func showQuickChat(_ archive: QuickChatArchive? = nil, startNew: Bool = false,
                               imageURL: URL? = nil, selectedText: String? = nil) {
        guard fileChooser == nil, fileHandoff?.isDragging != true else { return }
        guard !(startNew || archive != nil) || !quickChat.model.phase.isRunning else { return }
        dismissFileHandoff()
        stopShelfDelivery()
        stopCursorChase(animated: false)
        if let notice = completionCurrent, notice.kind == .codex { showCompletionSignal(notice) }
        if completionPending?.kind == .quickChat {
            completionPending = nil
            completionBatch?.cancel()
            completionBatch = nil
        }
        stopCompletionNudge(clearPending: false)
        closePanelUnlessPinned()
        chaseReminder?.cancel()
        curiosity?.cancel()
        curiosity = nil
        returnHome?.cancel()
        returnHome = nil
        reveal?.cancel()
        reveal = nil
        if pursuing { stopPursuitMotion() }
        let point = NSEvent.mouseLocation
        quickChat.show(at: point, archive: archive, startNew: startNew, imageURL: imageURL, selectedText: selectedText)
        model.quickChatHasResult = false
        if completionSignal?.kind == .quickChat { clearCompletionSignal() }
        if !hiddenByUser {
            mascotWindow?.ignoresMouseEvents = true
            mascotWindow?.orderFrontRegardless()
            followQuickChatPointer(point, animated: true)
        }
    }

    @objc(askChubzik:userData:error:)
    func askChubzik(_ pasteboard: NSPasteboard, userData: String?,
                    error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            error?.pointee = "Выдели текст, чтобы спросить Чубзика"
            return
        }
        guard fileChooser == nil else {
            error?.pointee = "Сначала закрой выбор файлов"
            return
        }
        showQuickChat(selectedText: String(text.prefix(16_000)))
    }

    private func putFilesOnShelf(_ incoming: [URL]) {
        let urls = incoming.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let pickup = shelfPickupPoint()
        let previous = Set(model.shelf.paths)
        if saveShelfFiles(urls) {
            guard let index = model.shelf.paths.firstIndex(where: { !previous.contains($0) }) else { return }
            startShelfDelivery(from: pickup, path: model.shelf.paths[index])
        }
    }

    private func shelfPickupPoint() -> CGPoint {
        defer { lastFileContextClick = nil }
        if let click = lastFileContextClick, click.pid == workspace.frontmostApplication?.processIdentifier,
           ProcessInfo.processInfo.systemUptime - click.at < 8 { return click.point }
        return NSEvent.mouseLocation
    }

    private func startShelfDelivery(from point: CGPoint, path: String) {
        guard !hiddenByUser, !displaysSleeping, !quickChat.isOpen, cursorChase == nil, completionCurrent == nil,
              !pursuing, press == nil, fileHandoff?.isFlying != true, let geometry, let mascotWindow, let mascot else { return }
        if reducedMotion {
            mascot.react(.file)
            return
        }
        stopShelfDelivery()
        stopFlight()
        returnHome?.cancel()
        returnHome = nil
        reveal?.cancel()
        reveal = nil
        curiosity?.cancel()
        curiosity = nil
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame ?? geometry.screen
        let edge = screen.insetBy(dx: 26, dy: 26)
        let pickup = CGPoint(x: min(edge.maxX, max(edge.minX, point.x)), y: min(edge.maxY, max(edge.minY, point.y)))
        let drop = CGPoint(x: geometry.cutout.midX, y: geometry.cutout.minY - 14)
        let home = CGPoint(x: geometry.mascot.midX, y: geometry.mascot.midY)
        let delivery = ShelfDelivery(mascotWindow: mascotWindow, mascot: mascot, icon: workspace.icon(forFile: path))
        shelfDelivery = delivery
        mascotWindow.ignoresMouseEvents = true
        updateVisibility()
        delivery.start(pickup: pickup, drop: drop, home: home) { [weak self] in
            self?.stopShelfDelivery()
            self?.scheduleCuriosity()
            self?.startCompletionNudgeIfReady()
        }
    }

    private func stopShelfDelivery() {
        guard let shelfDelivery else { return }
        shelfDelivery.stop()
        self.shelfDelivery = nil
        mascotWindow?.ignoresMouseEvents = false
        returnMascot(animated: false)
        updateVisibility()
    }

    private func showChatExpression(_ reaction: QuickChatController.Reaction) {
        guard quickChat.isOpen else { return }
        let expression: MascotView.ChatExpression
        switch reaction {
        case .focus, .attachment: expression = .focus
        case .capture: expression = .capture
        case .thinking: expression = .thinking
        case .writing: expression = .writing
        case .done: expression = .done
        case .stopped: expression = .stopped
        case .error: expression = .error
        }
        mascot?.setChatExpression(expression)
        chatBlink?.cancel()
        chatBlink = nil
        if reaction == .thinking { scheduleChatBlink() }
    }

    private func scheduleChatBlink() {
        guard !reducedMotion else { return }
        let next = DispatchWorkItem { [weak self] in
            guard let self, self.quickChat.isOpen, self.quickChat.model.phase.isRunning else { return }
            self.mascot?.react(.blink)
            self.scheduleChatBlink()
        }
        chatBlink = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8, execute: next)
    }

    private func followQuickChatPointer(_ point: CGPoint, animated: Bool) {
        guard quickChat.isOpen, !hiddenByUser, !quickChat.isCapturing, let mascotWindow,
              let display = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let area = display.visibleFrame.insetBy(dx: 5, dy: 5)
        let placeLeft = (quickChat.frame?.midX ?? point.x + 1) < point.x
        let x = point.x + (placeLeft ? -37 : 10)
        let y = point.y + 8
        var target = CGRect(x: min(max(x, area.minX), area.maxX - 32),
                            y: min(max(y, area.minY), area.maxY - 32), width: 32, height: 32)
        if let chat = quickChat.frame, chat.intersects(target) {
            target.origin.y = min(area.maxY - 32, point.y + 20)
            if chat.intersects(target) {
                target.origin.x = placeLeft ? max(chat.maxX, area.minX) : min(chat.minX - 32, area.maxX - 32)
            }
        }
        let dx = point.x - mascotWindow.frame.midX
        let dy = point.y - mascotWindow.frame.midY
        if preferences.followsPointer {
            mascot?.look(CGPoint(x: min(3, max(-3, dx / 11)), y: min(2.5, max(-2.5, dy / 11))))
        }
        guard animated || !reducedMotion else { return }
        let distance = hypot(target.minX - mascotWindow.frame.minX, target.minY - mascotWindow.frame.minY)
        if animated || (distance > 9 && flight == nil) {
            moveMascot(to: target, animated: true, reaction: animated ? .landing : nil, inQuickChat: true)
        }
    }

    @objc private func showPreferences() {
        stopCursorChase()
        quickChat.hide()
        closePanelUnlessPinned()
        if preferencesWindow == nil {
            let view = PreferencesView(preferences: preferences) { [weak self] in
                self?.toggleCursorChase()
            }
            let content = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: content)
            window.title = "Настройки Чубзика"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.center()
            preferencesWindow = window
        }
        NSApp.activate()
        preferencesWindow?.deminiaturize(nil)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshGeometry() {
        dismissFileHandoff()
        stopShelfDelivery()
        stopCursorChase(animated: false)
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let cutout: CGRect
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            cutout = CGRect(x: left.maxX, y: frame.maxY - screen.safeAreaInsets.top,
                            width: max(80, right.minX - left.maxX), height: screen.safeAreaInsets.top)
        } else {
            cutout = CGRect(x: frame.midX - 67, y: frame.maxY - 30, width: 134, height: 30)
        }
        if quickChat.isOpen { quickChat.refreshDisplays() }
        stopFlight()
        let layout = NotchGeometry(screen: frame, cutout: cutout)
        geometry = layout
        hasPhysicalNotch = screen.safeAreaInsets.top > 0
        placeNotchDropTarget()
        model.notchWidth = cutout.width
        model.panelScale = geometry!.panelScale
        if !dragStarted && !pursuing && !quickChat.isOpen && completionNudge == nil {
            mascotWindow?.setFrame(geometry!.mascot, display: false)
        }
        coverWindow?.setFrame(geometry!.cover, display: false)
        positionActivity(showMeeting: meetingWindow?.isVisible == true)
        resizePlayer()
        changedSpace()
        if fixture {
            NSLog("geometry screen=%@ cutout=%@ mascot=%@ player=%@", NSStringFromRect(frame), NSStringFromRect(cutout),
                  NSStringFromRect(geometry!.mascot), NSStringFromRect(geometry!.player))
        }
    }

    private func changedSpace() {
        let previousFullscreen = fullscreen
        fullscreen = detectFullscreen()
        if fixture { NSLog("space fullscreen=%@ front=%@", String(fullscreen), workspace.frontmostApplication?.localizedName ?? "–") }
        lastFullscreenProbe = ProcessInfo.processInfo.systemUptime
        if fullscreen && !previousFullscreen && model.active && !panelContains(NSEvent.mouseLocation) { closePanelUnlessPinned() }
        if fullscreen && pursuing && completionNudge == nil {
            returnMascot(animated: false)
        } else if previousFullscreen && pursuing {
            scheduleChaseReminder()
        }
        updateVisibility()
        scheduleCuriosity()
    }

    private func placeNotchDropTarget() {
        guard let geometry, let notchDropWindow else { return }
        if model.active && !hasPhysicalNotch {
            notchDropWindow.orderOut(nil)
            return
        }
        let region = model.active ? geometry.cutout : geometry.dropTarget(hasPhysicalNotch: hasPhysicalNotch)
        notchDropWindow.setFrame(region, display: true)
        if !notchDropWindow.isVisible { notchDropWindow.orderFrontRegardless() }
    }

    private func detectFullscreen() -> Bool {
        guard let geometry, let front = workspace.frontmostApplication, front.processIdentifier != getpid(),
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return false }
        let flippedY = primary.frame.maxY - geometry.screen.maxY
        let frames = infos.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { return nil }
            return bounds
        }
        if frames.contains(where: { bounds in
            return abs(bounds.minY - flippedY) < 2 && abs(bounds.minX - geometry.screen.minX) < 2 &&
                bounds.width >= geometry.screen.width - 2 && bounds.height >= geometry.screen.height - 2
        }) { return true }
        // On a notched Mac, a Space may reserve the top menu-bar strip even in fullscreen.
        let fillsUnderNotch = frames.contains { bounds in
            abs(bounds.minX - geometry.screen.minX) < 2 && bounds.width >= geometry.screen.width - 2 &&
                bounds.minY > flippedY && bounds.minY - flippedY < 48 &&
                abs(bounds.maxY - (flippedY + geometry.screen.height)) < 2
        }
        guard fillsUnderNotch, AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.10)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXFullScreen" as CFString, &value) == .success &&
            value as? Bool == true
    }

    private func installPointerMonitoring() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if event.type == .mouseMoved {
                self?.pointerMoved()
            } else if let self {
                self.cancelFilePickerSelection()
                self.dismissFileHandoffOnOutsideClick()
                self.clipboardPocket.closeIfOutside(NSEvent.mouseLocation)
                if event.type == .rightMouseDown, let pid = self.workspace.frontmostApplication?.processIdentifier {
                    self.lastFileContextClick = (NSEvent.mouseLocation, pid, ProcessInfo.processInfo.systemUptime)
                }
                self.cancelCompletionGesture()
                if self.model.active, !self.model.isPinned, self.menuTrackingDepth == 0,
                   !self.panelContains(NSEvent.mouseLocation) {
                    self.beginPanelClose(fromPointer: false)
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                                                   .otherMouseDown, .leftMouseUp, .keyDown, .scrollWheel]) { [weak self] event in
            if event.type == .mouseMoved { self?.pointerMoved() }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                self?.cancelFilePickerSelection()
                self?.dismissFileHandoffOnOutsideClick()
                self?.clipboardPocket.closeIfOutside(NSEvent.mouseLocation)
                self?.cancelCompletionGesture()
            }
            if event.type == .scrollWheel, self?.navigateWithScroll(event) == true { return nil }
            if event.type == .leftMouseUp {
                // Let the control finish handling its release before closing the panel.
                DispatchQueue.main.async { self?.updatePointerExit(NSEvent.mouseLocation) }
            }
            if event.type == .keyDown, let self {
                let escape = event.keyCode == 53
                if self.model.active, self.model.page == .shelf, event.window === self.player,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "v" where !(self.player?.firstResponder is NSTextView):
                        self.pasteShelfFiles()
                        return nil
                    case "f":
                        self.model.shelfSearchRequest += 1
                        return nil
                    default: break
                    }
                }
                if escape, self.cursorChase != nil || self.completionCurrent != nil ||
                    self.fileHandoff.map({ !$0.isDragging }) == true {
                    self.cancelMascotInteraction()
                    return nil
                }
                if let preferencesWindow = self.preferencesWindow, event.window === preferencesWindow,
                   escape || (event.keyCode == 13 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command) {
                    preferencesWindow.performClose(nil)
                    return nil
                }
                if escape, let preview = self.previewWindow, event.window === preview {
                    preview.performClose(nil)
                    return nil
                }
                if escape, self.model.active, event.window === self.player, self.menuTrackingDepth == 0 {
                    self.beginPanelClose(fromPointer: false)
                    return nil
                }
            }
            return event
        }
    }

    private func navigateWithScroll(_ event: NSEvent) -> Bool {
        let ending = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        guard model.active, event.hasPreciseScrollingDeltas, menuTrackingDepth == 0,
              event.window === player || (ending && scrollAxis == .horizontal) else { return false }
        if event.momentumPhase != [] { return scrollAxis == .horizontal }
        if event.phase.contains(.began) {
            scrollAxis = .undecided
            scrollMovement = .zero
            scrollVelocity = 0
            lastScrollSample = nil
            if !model.paging.isSettling { model.paging.reset() }
        }
        if ending {
            guard scrollAxis == .horizontal else { return false }
            settleSwipe(at: event.timestamp, cancelled: event.phase.contains(.cancelled))
            return true
        }
        guard event.phase.contains(.began) || event.phase.contains(.changed) else { return false }
        guard scrollAxis != .vertical else { return false }

        scrollMovement.width += event.scrollingDeltaX
        scrollMovement.height += event.scrollingDeltaY
        if event.scrollingDeltaX != 0 {
            if let lastScrollSample {
                let elapsed = event.timestamp - lastScrollSample
                scrollVelocity = elapsed > 0 && elapsed < 0.12 ? event.scrollingDeltaX / elapsed : 0
            }
            lastScrollSample = event.timestamp
        }
        if scrollAxis == .undecided {
            let horizontal = abs(scrollMovement.width)
            let vertical = abs(scrollMovement.height)
            if vertical >= 10, vertical > horizontal { scrollAxis = .vertical; return false }
            guard horizontal >= 9, horizontal > vertical * 1.4 else { return false }
            scrollAxis = .horizontal
        }
        if !model.reducedMotion, !model.paging.isSettling {
            let direction: CGFloat = scrollMovement.width < 0 ? 1 : -1
            let neighbor = adjacentPage(in: Int(direction))
            let width = (player?.frame.width ?? 1) - 30 * model.panelScale
            let progress = PanelSwipe.progress(distance: scrollMovement.width, width: width, hasNeighbor: neighbor != nil)
            model.paging.track(from: model.visiblePage, to: neighbor.map { .page($0) },
                               direction: direction, progress: progress)
        }
        return true
    }

    private func adjacentPage(in direction: Int) -> PanelPage? {
        let pages = PanelPage.allCases
        let current = queuedPage ?? model.page
        guard let index = pages.firstIndex(of: current), pages.indices.contains(index + direction) else { return nil }
        return pages[index + direction]
    }

    private func settleSwipe(at time: TimeInterval, cancelled: Bool) {
        let distance = scrollMovement.width
        let age = lastScrollSample.map { time - $0 } ?? .infinity
        if !cancelled, PanelSwipe.commits(distance: distance, velocity: scrollVelocity, sampleAge: age),
           let destination = adjacentPage(in: distance < 0 ? 1 : -1) {
            requestPage(destination, continuingSwipe: true)
        } else if model.paging.turn != nil, !model.paging.isSettling {
            model.paging.settle(commit: false) { [weak self] in self?.runQueuedPage() }
        }
        scrollMovement = .zero
        lastScrollSample = nil
    }

    private func pointerMoved() {
        guard let geometry, !hiddenByUser || model.active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        guard !quickChat.isOpen, cursorChase == nil, completionNudge == nil else { return }
        if model.active { updatePointerExit(point) }
        guard shelfDelivery == nil, fileHandoff?.isFlying != true else { return }
        let overDrop = notchDropWindow?.frame.contains(point) == true
        if geometry.hover.contains(point) || overDrop {
            if preferences.opensOnHover, preferencesWindow?.isVisible != true, fileChooser == nil,
               previewWindow?.isVisible != true,
               !hiddenByUser, !model.active, !suppressNotchReveal, reveal == nil, press == nil,
               NSEvent.pressedMouseButtons & 1 == 0,
               mascotWindow?.frame.contains(point) != true {
                if !fullscreen, now - lastFullscreenProbe > 1.5 {
                    fullscreen = detectFullscreen()
                    lastFullscreenProbe = now
                }
                let item = DispatchWorkItem { [weak self] in
                    self?.reveal = nil
                    let point = NSEvent.mouseLocation
                    if NSEvent.pressedMouseButtons & 1 == 0,
                       self?.geometry?.hover.contains(point) == true || self?.notchDropWindow?.frame.contains(point) == true {
                        self?.setPanel(true, fromHover: true)
                    }
                }
                reveal = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: item)
            }
        } else {
            suppressNotchReveal = false
            reveal?.cancel()
            reveal = nil
        }

        let updateBody = now - lastMouseUpdate > 0.065
        if updateBody {
            lastMouseUpdate = now
            lastMouseMovement = now
            if curiosity == nil, !reducedMotion { scheduleCuriosity() }
        }
        guard !fullscreen || model.active, press == nil, returnHome == nil else { return }
        if preferences.followsPointer, !gazeDisabledByArgument, !reducedMotion, let frame = mascotWindow?.frame {
            let dx = point.x - frame.midX
            let dy = point.y - frame.midY
            let reach = min(1, max(0, (geometry.gazeRadius - hypot(dx, dy)) / 90))
            lastGaze = CGPoint(x: min(3.25, max(-3.25, dx / 34)) * reach,
                               y: min(2.5, max(-3, dy / 37)) * reach)
            mascot?.look(lastGaze)
        }
        if pursuing, updateBody { pursue(point, jump: false) }
    }

    private func panelContains(_ point: CGPoint) -> Bool {
        geometry?.hover.contains(point) == true || player?.frame.contains(point) == true
    }

    private func updatePointerExit(_ point: CGPoint) {
        guard model.active, !model.isPinned, menuTrackingDepth == 0, let geometry, let player else { return }
        if model.isEditing || player.firstResponder is NSTextView {
            cancelPanelHide()
            return
        }
        if panelContains(point) {
            pointerHasEnteredPanel = true
            cancelPanelHide()
            if closesFromPointer { reopenPanel() }
            return
        }
        guard pointerHasEnteredPanel, closePanel == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let started = pointerExitStarted ?? now
        pointerExitStarted = started
        let deadline = started + PanelExitGrace.delay(at: point, panel: player.frame, notch: geometry.hover)
        if deadline <= now {
            beginPanelClose(fromPointer: true)
            return
        }
        if let scheduled = hideDeadline, abs(scheduled - deadline) < 0.018 { return }
        hidePanel?.cancel()
        hideDeadline = deadline
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hidePanel = nil
            self.hideDeadline = nil
            guard self.menuTrackingDepth == 0, !self.model.isEditing,
                  !(self.player?.firstResponder is NSTextView) else { return }
            if self.panelContains(NSEvent.mouseLocation) { self.cancelPanelHide() }
            else { self.beginPanelClose(fromPointer: true) }
        }
        hidePanel = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (deadline - now), execute: item)
    }

    private func cancelPanelHide() {
        hidePanel?.cancel()
        hidePanel = nil
        hideDeadline = nil
        pointerExitStarted = nil
    }

    private func beginPanelClose(fromPointer: Bool) {
        guard model.active, closePanel == nil else { return }
        cancelPanelHide()
        guard !reducedMotion, let view = player?.contentView else {
            setPanel(false)
            return
        }
        closesFromPointer = fromPointer
        player?.ignoresMouseEvents = true
        panelMotion.close(view, notchWidth: model.notchWidth, scale: model.panelScale)
        let item = DispatchWorkItem { [weak self] in self?.setPanel(false) }
        closePanel = item
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchPanelMotion.closingDuration, execute: item)
    }

    private func cancelPanelClose() {
        closePanel?.cancel()
        closePanel = nil
        closesFromPointer = false
        player?.ignoresMouseEvents = false
    }

    private func reopenPanel() {
        guard closePanel != nil else { return }
        cancelPanelClose()
        if !reducedMotion, let view = player?.contentView {
            panelMotion.open(view, notchWidth: model.notchWidth, scale: model.panelScale)
        }
    }

    private func requestPage(_ page: PanelPage, continuingSwipe: Bool = false) {
        if model.paging.isSettling {
            queuedPage = page
            return
        }
        guard page != model.page else {
            if model.showsMusicPreview { setPanel(true) }
            return
        }
        guard model.active, !model.reducedMotion else { changePage(page); return }
        let pages = PanelPage.allCases
        let from = pages.firstIndex(of: model.page) ?? 0
        let to = pages.firstIndex(of: page) ?? from
        let continueTurn = continuingSwipe && model.paging.turn?.destination == .page(page)
        if !continueTurn {
            model.paging.track(from: model.visiblePage, to: .page(page), direction: to > from ? 1 : -1, progress: 0)
        }
        commitPage(page)
        model.paging.settle(commit: true, startAfterLayout: !continueTurn) { [weak self] in self?.runQueuedPage() }
    }

    private func runQueuedPage() {
        guard let queuedPage else { return }
        self.queuedPage = nil
        requestPage(queuedPage)
    }

    private func changePage(_ page: PanelPage) {
        model.paging.reset()
        queuedPage = nil
        commitPage(page)
    }

    private func commitPage(_ page: PanelPage) {
        if page == .shelf, model.active {
            showDownloadPreview()
            refreshShelfReferences(for: Set(model.shelf.paths))
        }
        guard model.page != page else { return }
        model.isEditing = false
        if page == .music { model.musicPreview = false }
        model.page = page
        player?.makeFirstResponder(nil)
        resizePlayer(animateGrowth: true)
        if fixture { NSLog("section=%@", page.rawValue) }
    }

    private func resizePlayer(animateGrowth: Bool = false) {
        guard let geometry, let player else { return }
        let current = player.frame
        let next = geometry.panel(width: model.panelWidth, height: model.panelHeight)
        guard current != next else { return }
        panelMotion.reset()
        player.setFrame(next, display: false)
        if animateGrowth, model.active, !reducedMotion,
           current.size.width <= next.width, current.size.height < next.height,
           let view = player.contentView {
            view.layoutSubtreeIfNeeded()
            panelMotion.open(view, notchWidth: model.notchWidth, scale: model.panelScale, from: current.size)
        }
    }

    private func setPanel(_ show: Bool, fromHover: Bool = false, restorePageOnOpen: Bool = true) {
        if show { stopCursorChase() }
        reveal?.cancel()
        reveal = nil
        cancelPanelHide()
        let desired = show && (!fromHover || (preferences.opensOnHover && !hiddenByUser))
        if desired {
            reopenPanel()
            if !model.active && restorePageOnOpen {
                changePage(PanelOpening.page(last: model.page, preferred: preferences.startPage,
                                             dismissedAt: panelDismissedAt, now: ProcessInfo.processInfo.systemUptime))
            }
            if model.page == .shelf {
                showDownloadPreview()
                if !model.active { refreshShelfReferences(for: Set(model.shelf.paths)) }
            }
            let preview = fromHover
            if model.musicPreview != preview {
                model.musicPreview = preview
                resizePlayer(animateGrowth: true)
            }
        } else {
            model.isPinned = false
            cancelPanelClose()
            panelMotion.reset()
        }
        guard desired != model.active else { return }
        pointerHasEnteredPanel = desired && (fromHover || panelContains(NSEvent.mouseLocation))
        model.active = desired
        placeNotchDropTarget()
        if fixture { NSLog("panel visible=%@ fullscreen=%@", String(desired), String(fullscreen)) }
        if desired {
            player?.orderFrontRegardless()
            if !reducedMotion, let view = player?.contentView {
                panelMotion.open(view, notchWidth: model.notchWidth, scale: model.panelScale)
            }
        } else {
            panelDismissedAt = ProcessInfo.processInfo.systemUptime
            model.isEditing = false
            scrollAxis = .undecided
            scrollMovement = .zero
            lastScrollSample = nil
            model.paging.reset()
            queuedPage = nil
            player?.makeFirstResponder(nil)
            player?.orderOut(nil)
        }
        updateVisibility()
    }

    private func togglePanelPin() {
        guard model.active else { return }
        model.isPinned.toggle()
        if model.isPinned {
            cancelPanelHide()
            reopenPanel()
            player?.makeKey()
        } else {
            updatePointerExit(NSEvent.mouseLocation)
        }
    }

    private func closePanelUnlessPinned() {
        if !model.isPinned { setPanel(false) }
    }

    private func updateMotionPreference() {
        let requested = workspace.accessibilityDisplayShouldReduceMotion ||
            (fixture && CommandLine.arguments.contains("--reduce-motion"))
        guard requested != reducedMotion else { return }
        reducedMotion = requested
        model.reducedMotion = requested
        mascot?.reducedMotion = requested
        if requested {
            let wasFlying = fileHandoff?.isFlying == true
            if wasFlying { dismissFileHandoff() }
            stopShelfDelivery()
            model.paging.reset()
            queuedPage = nil
            if closePanel != nil { setPanel(false) }
            else { panelMotion.reset() }
            curiosity?.cancel()
            curiosity = nil
            chaseReminder?.cancel()
            if flight != nil { returnMascot(animated: false) }
        } else if pursuing {
            scheduleChaseReminder()
        } else {
            scheduleCuriosity()
        }
    }

    private func updateVisibility() {
        updateMeetingVisibility()
        let visible = !hiddenByUser && (!fullscreen || model.active || quickChat.isOpen)
        if (!hiddenByUser && !displaysSleeping) || notchDropFeedback != nil || cursorChase != nil || completionNudge != nil || shelfDelivery != nil ||
            fileHandoff?.isFlying == true {
            if mascotWindow?.isVisible != true { mascotWindow?.orderFrontRegardless() }
        } else if mascotWindow?.isVisible == true {
            mascotWindow?.orderOut(nil)
        }
        if visible && hasCover {
            if coverWindow?.isVisible != true { coverWindow?.orderFrontRegardless() }
        } else if coverWindow?.isVisible == true {
            coverWindow?.orderOut(nil)
        }
        if visible, !displaysSleeping, activityWindow?.isVisible != true,
           model.countdown != nil || model.stopwatch.isPresent || !model.transfers.isEmpty {
            updateActivity()
        } else if !visible || displaysSleeping {
            activityTick?.cancel()
            activityTick = nil
            activityWindow?.orderOut(nil)
        }
    }

    private func updateActivity() {
        activityTick?.cancel()
        activityTick = nil
        guard !hiddenByUser, !displaysSleeping, (!fullscreen || model.active) else {
            activityWindow?.orderOut(nil)
            return
        }
        let value: String
        let title: String
        let ticks: Bool
        if let countdown = model.countdown, !countdown.isPaused || !model.stopwatch.isRunning {
            value = ActivityClock.compact(countdown.remaining(at: timerDate).rounded(.up))
            title = countdown.isPaused ? countdown.phase.title + " на паузе" : countdown.phase.title
            ticks = !countdown.isPaused
        } else if model.stopwatch.isPresent {
            value = ActivityClock.compact(model.stopwatch.seconds(at: stopwatchTime).rounded(.down))
            title = model.stopwatch.isRunning ? "Секундомер" : "Секундомер на паузе"
            ticks = model.stopwatch.isRunning
        } else if !model.transfers.isEmpty {
            value = "↓ " + String(model.transfers.count)
            title = "Загрузки"
            ticks = false
        } else {
            activityWindow?.orderOut(nil)
            return
        }
        activityLabel?.stringValue = value
        activityLabel?.setAccessibilityLabel(title)
        if activityWindow?.isVisible != true { activityWindow?.orderFrontRegardless() }
        guard ticks else { return }
        let tick = DispatchWorkItem { [weak self] in self?.updateActivity() }
        activityTick = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
    }

    private func positionActivity(showMeeting: Bool) {
        guard let home = geometry?.mascot else { return }
        let x = home.maxX + 5
        let y = home.midY - 11
        let meetingOrigin = CGPoint(x: x, y: y)
        if let meetingWindow, meetingWindow.frame.origin != meetingOrigin {
            meetingWindow.setFrameOrigin(meetingOrigin)
        }
        let shift = showMeeting ? (meetingWindow?.frame.width ?? 0) + 5 : 0
        let activityFrame = CGRect(x: x + shift, y: y, width: 50, height: 22)
        if let activityWindow, activityWindow.frame != activityFrame {
            activityWindow.setFrame(activityFrame, display: false)
        }
    }

    private func scheduleMeetingAlert() {
        meetingRefresh?.cancel()
        meetingRefresh = nil
        guard !displaysSleeping else { updateMeetingVisibility(); return }
        let now = Date()
        joinedMeetings = joinedMeetings.filter { $0.value > now }
        let interval = DateInterval(start: now.addingTimeInterval(-MeetingAlert.leadTime),
                                    end: now.addingTimeInterval(24 * 3600))
        let entries = fixture ? fixtureMeetings : model.calendarFeed.events(in: interval)
        let plan = MeetingAlert.plan(for: entries, at: now, excluding: Set(joinedMeetings.keys))
        meetingAlerts = plan.current
        updateMeetingVisibility()
        guard let next = plan.nextChange ?? (!fixture && model.calendarFeed.hasAccess ? now.addingTimeInterval(1800) : nil)
        else { return }
        let update = DispatchWorkItem { [weak self] in self?.scheduleMeetingAlert() }
        meetingRefresh = update
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0.05, next.timeIntervalSinceNow), execute: update)
    }

    private func updateMeetingVisibility() {
        guard let meetingWindow, let meetingButton else { return }
        let visible = !meetingAlerts.isEmpty && !displaysSleeping && !hiddenByUser
            && (hasPhysicalNotch || !fullscreen || model.active)
        if visible, let first = meetingAlerts.first {
            let multiple = meetingAlerts.count > 1
            let width: CGFloat = multiple ? 91 : 63
            if meetingWindow.frame.width != width {
                var frame = meetingWindow.frame
                frame.size.width = width
                meetingWindow.setFrame(frame, display: true)
            }
            meetingButton.title = multiple ? "Встречи · \(meetingAlerts.count)" : "Войти"
            meetingButton.toolTip = multiple ? "Выбрать встречу" : first.menuTitle
            meetingButton.setAccessibilityLabel(multiple ? "Встречи: \(meetingAlerts.count)"
                : "Войти во встречу «\(first.entry.title)»")
            positionActivity(showMeeting: true)
            if !meetingWindow.isVisible { meetingWindow.orderFrontRegardless() }
        } else if meetingWindow.isVisible {
            meetingWindow.orderOut(nil)
            positionActivity(showMeeting: false)
        }
    }

    @objc private func joinMeeting() {
        let selected = meetingAlerts
        guard let button = meetingButton, let first = selected.first else { return }
        if selected.count == 1 {
            openMeeting(id: first.entry.id)
        } else {
            let menu = NSMenu()
            for alert in selected {
                let item = addMenuItem(alert.menuTitle, #selector(joinMeetingFromMenu(_:)), to: menu)
                item.representedObject = alert.entry.id
            }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -3), in: button)
        }
    }

    @objc private func joinMeetingFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { openMeeting(id: id) }
    }

    private func openMeeting(id: String) {
        scheduleMeetingAlert()
        guard let alert = meetingAlerts.first(where: { $0.entry.id == id }) else { return }
        let link = alert.link
        if fixture {
            NSLog("fixture meeting opened %@", link.absoluteString)
        } else if !workspace.open(link) {
            model.notice("Не удалось открыть ссылку на встречу", destination: .calendar)
            showPanel()
            requestPage(.notices)
            return
        }
        joinedMeetings[alert.joinKey] = alert.expires
        scheduleMeetingAlert()
    }

    private var hasCover = false

    private func refreshMedia() {
        var items = direct
        if let systemItem {
            let canonical = systemItem.selectionSource
            if var directItem = items[canonical] {
                if directItem.artworkURL == nil && directItem.title == systemItem.title {
                    directItem.artwork = systemItem.artwork
                    items[canonical] = directItem
                }
            } else {
                items[canonical] = systemItem
            }
        }
        let active = items.values.sorted { $0.selectionSource < $1.selectionSource }
        model.sources = active
        let previouslyPlaying = Set(playingSources)
        let started = active.filter { $0.playing && !previouslyPlaying.contains($0.selectionSource) }
            .sorted { $0.timestamp > $1.timestamp }
        playingSources.removeAll { items[$0]?.playing != true }
        playingSources.insert(contentsOf: started.map(\.selectionSource), at: 0)
        let preferred = preferredSource.flatMap { items[$0] }
        if preferred == nil { preferredSource = nil }
        let previous = model.media
        let selected = preferred
            ?? playingSources.first.flatMap { items[$0] }
            ?? previous.flatMap { items[$0.selectionSource] }
            ?? active.max(by: { $0.timestamp < $1.timestamp })
        if let selected {
            if previous != selected { model.media = selected }
        } else if previous != nil {
            model.media = nil
        }
        let item = model.media
        let identity = item.map { $0.source + "/" + $0.id + "/" + ($0.artworkURL?.absoluteString ?? "") }
        if identity != imageIdentity || imageData != item?.artwork {
            imageIdentity = identity
            imageData = item?.artwork
            loadArtwork(for: item)
        }

        if item?.playing == true {
            removeCover?.cancel()
            removeCover = nil
            if previous?.playing != true { mascot?.react(.curious(-1)) }
            hasCover = true
            updateVisibility()
        } else if hasCover, removeCover == nil {
            let remove = DispatchWorkItem { [weak self] in
                self?.removeCover = nil
                self?.hasCover = false
                self?.updateVisibility()
            }
            removeCover = remove
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: remove)
        }
    }

    private func loadArtwork(for media: MediaItem?) {
        imageGeneration += 1
        let generation = imageGeneration
        imageJob?.cancel()
        imageJob = nil
        model.artwork = nil
        cover?.image = nil
        if let data = media?.artwork {
            setArtwork(data)
        } else if let url = media?.artworkURL {
            if url.isFileURL {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let data = ArtworkReader.local(url) else { return }
                    DispatchQueue.main.async { if self?.imageGeneration == generation { self?.setArtwork(data) } }
                }
            } else {
                imageJob = ArtworkReader.fetch(url) { [weak self] data in
                    DispatchQueue.main.async { if self?.imageGeneration == generation { self?.setArtwork(data) } }
                }
            }
        }
    }

    private func setArtwork(_ data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 128, kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return }
        let artwork = NSImage(cgImage: image, size: .zero)
        model.artwork = artwork
        cover?.image = artwork
    }

    private func sendMedia(_ track: MediaItem.Track, _ action: String, position: Double?) {
        guard let item = model.media, item.track == track else { return }
        if fixture {
            if CommandLine.arguments.contains("--fixture-media-audit") {
                NSLog("fixture media command %@ %@ %@", item.source, item.id, action)
            }
            var changed = item
            changed.elapsed = position ?? item.position()
            if action == "play" { changed.playing = true }
            if action == "pause" { changed.playing = false }
            if action == "next" || action == "previous" {
                changed.title = changed.title == "Ночной маршрут" ? "Дальше тише" : "Ночной маршрут"
                changed.id = changed.title
                changed.elapsed = 0
            }
            changed.timestamp = Date()
            changed.positionAnchor = MonotonicTime.seconds
            if direct[item.source] != nil { direct[item.source] = changed }
            else if systemItem?.track == track { systemItem = changed }
            refreshMedia()
        } else if direct[item.source] != nil {
            IslandEvents.post(IslandEvent(type: "command", source: item.source, id: item.id,
                                          action: action, position: position), to: IslandEvents.outbound)
        } else if systemItem?.track == track {
            media.command(action, position: position)
        }
    }

    private func openMediaSource(_ track: MediaItem.Track? = nil) {
        guard let item = model.media, track == nil || item.track == track else { return }
        reveal?.cancel()
        reveal = nil
        suppressNotchReveal = true
        if !model.isPinned { beginPanelClose(fromPointer: false) }
        if direct[item.source] != nil {
            IslandEvents.post(IslandEvent(type: "command", source: item.source, id: item.id, action: "open"), to: IslandEvents.outbound)
        } else {
            openApplication(item.parentSource ?? item.source)
        }
    }

    private func openApplication(_ bundle: String, completion: ((Bool) -> Void)? = nil) {
        let identifiers = bundle.hasPrefix("com.lad.music.") ? [bundle, "com.lad.music"] : [bundle]
        let url = identifiers.lazy.compactMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL
                ?? self.workspace.urlForApplication(withBundleIdentifier: id)
        }.first
        guard let url else { completion?(false); return }
        // Reopening also asks a running app to show its window.
        workspace.openApplication(at: url, configuration: .init()) { app, _ in
            DispatchQueue.main.async { completion?(app != nil) }
        }
    }

    private func queueFile(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            model.shelfFeedback = "Файл больше недоступен"
            return
        }
        let source = "com.lad.music"
        if sourcesReady.contains(source) {
            sendQueue(file)
        } else {
            guard !pendingQueue.contains(file) else { return }
            pendingQueue.append(file)
            guard queueTimeout == nil else { return }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingQueue.removeAll()
                self.queueTimeout = nil
                self.model.shelfFeedback = "«Лад» не ответил. Можно попробовать ещё раз."
            }
            queueTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
            model.shelfFeedback = "Ожидаю локальную интеграцию «Лада»"
            openApplication(source) { [weak self] opened in
                guard let self, !opened, self.queueTimeout != nil else { return }
                self.queueTimeout?.cancel()
                self.queueTimeout = nil
                self.pendingQueue.removeAll()
                self.model.shelfFeedback = "Не удалось открыть «Лад»"
            }
        }
    }

    private func sendQueue(_ file: URL) {
        model.shelfFeedback = "Отправлено в «Лад»"
        IslandEvents.post(IslandEvent(type: "command", source: "com.lad.music", path: file.path,
                                      action: "queue"), to: IslandEvents.outbound)
    }

    private func sourceClosed(_ bundle: String) {
        let source = bundle.hasSuffix(".chubzik-test") ? String(bundle.dropLast(".chubzik-test".count)) : bundle
        sourcesReady.remove(source)
        if source == "com.kiridey.ardia.personal" {
            model.transfers.removeAll()
            updateActivity()
        }
        if direct.removeValue(forKey: source) != nil { refreshMedia() }
    }

    private func chooseShelfFiles() {
        guard fileChooser == nil else { return }
        let chooser = NSOpenPanel()
        chooser.title = "Добавить на полку"
        chooser.prompt = "Добавить"
        chooser.allowsMultipleSelection = true
        chooser.canChooseDirectories = true
        fileChooser = chooser
        closePanelUnlessPinned()
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard let self else { return }
            let urls = self.fileChooser?.urls ?? []
            self.fileChooser = nil
            if response == .OK { self.addFiles(urls) }
            self.showShelf()
            self.startCompletionNudgeIfReady()
        }
    }

    private func showFilePreview(_ url: URL) {
        let content = QLPreviewView(frame: CGRect(x: 0, y: 0, width: 720, height: 480), style: .normal)
        guard let content else { model.shelfFeedback = "Не удалось открыть предпросмотр"; return }
        content.previewItem = url as NSURL
        if previewWindow == nil {
            let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.center()
            previewWindow = window
        }
        closePanelUnlessPinned()
        previewWindow?.title = url.lastPathComponent
        previewWindow?.contentView = content
        NSApp.activate()
        previewWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === previewWindow else { return }
        DispatchQueue.main.async { [weak self] in self?.showShelf() }
    }

    private func removeShelfFiles(_ paths: Set<String>) {
        let removed = model.shelf.paths.enumerated().compactMap { paths.contains($0.element) ? ($0.offset, $0.element) : nil }
        guard !removed.isEmpty else { return }
        var shelf = model.shelf
        let removedPins = shelf.pinnedPaths.enumerated().compactMap { paths.contains($0.element) ? ($0.offset, $0.element) : nil }
        let references = shelf.references(for: paths)
        shelf.remove(paths)
        guard persistShelf(shelf) else { return }
        removedShelfItems = removed
        removedShelfPins = removedPins
        removedShelfReferences = references
        model.shelfFeedback = "Убрано с полки · " + String(removed.count)
        model.shelfCanUndo = true
        shelfUndoDeadline?.cancel()
        let expire = DispatchWorkItem { [weak self] in self?.clearShelfUndo() }
        shelfUndoDeadline = expire
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: expire)
    }

    private func undoShelfRemoval() {
        guard !removedShelfItems.isEmpty else { return }
        var shelf = model.shelf
        guard shelf.restore(removedShelfItems, removedPins: removedShelfPins, references: removedShelfReferences) else {
            model.shelfFeedback = "На полке нет места"
            return
        }
        guard persistShelf(shelf) else { return }
        refreshShelfReferences(for: Set(removedShelfItems.map(\.path)))
        clearShelfUndo()
        model.shelfFeedback = "Файлы возвращены"
    }

    private func clearShelfUndo() {
        shelfUndoDeadline?.cancel()
        shelfUndoDeadline = nil
        removedShelfItems.removeAll()
        removedShelfPins.removeAll()
        removedShelfReferences.removeAll()
        model.shelfCanUndo = false
        if model.shelfFeedback.hasPrefix("Убрано с полки") { model.shelfFeedback = "" }
    }

    private func pasteShelfFiles() {
        let files = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.isEmpty { model.shelfFeedback = "В буфере нет файлов" }
        else { addFiles(files) }
    }

    private func pinShelfFiles(_ paths: Set<String>, pinned: Bool) {
        var shelf = model.shelf
        guard shelf.setPinned(paths, pinned: pinned) else {
            model.shelfFeedback = "Можно закрепить до \(ShelfState.pinLimit) файлов"
            return
        }
        guard shelf.pinnedPaths != model.shelf.pinnedPaths else { return }
        if persistShelf(shelf) { model.shelfFeedback = "" }
    }

    private func removeTask(_ id: UUID) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        var tasks = model.tasks
        let removed = tasks.remove(at: index)
        guard persistTasks(tasks, failure: "Не удалось удалить задачу") else { return }
        removedTask = (index, removed)
        model.taskCanUndo = true
        taskUndoDeadline?.cancel()
        let expire = DispatchWorkItem { [weak self] in self?.clearTaskUndo() }
        taskUndoDeadline = expire
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: expire)
    }

    private func undoTaskRemoval() {
        guard let removedTask else { return }
        guard model.tasks.count < 150 else {
            model.taskFeedback = "Список задач заполнен"
            return
        }
        var tasks = model.tasks
        tasks.insert(removedTask.task, at: min(removedTask.index, tasks.count))
        guard persistTasks(tasks, failure: "Не удалось вернуть задачу") else { return }
        clearTaskUndo()
    }

    private func persistTasks(_ tasks: [LocalTask], failure: String = "Не удалось сохранить задачу") -> Bool {
        guard LocalSettings.save(tasks, as: "tasks.json") else {
            model.taskFeedback = failure
            return false
        }
        model.tasks = tasks
        model.taskFeedback = ""
        return true
    }

    private func clearTaskUndo() {
        taskUndoDeadline?.cancel()
        taskUndoDeadline = nil
        removedTask = nil
        model.taskCanUndo = false
    }

    private func addFiles(_ urls: [URL]) {
        let added = saveShelfFiles(urls)
        if added { mascot?.react(.file) }
        if let download = model.download, urls.contains(download),
           model.shelf.paths.contains(download.standardizedFileURL.path) {
            model.download = nil
        }
    }

    private func showDownloadPreview() {
        model.hasNewDownload = false
        guard let download = model.download, downloadPreviewTimeout == nil else { return }
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.downloadPreviewTimeout = nil
            if self.model.download == download { self.model.download = nil }
        }
        downloadPreviewTimeout = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: hide)
    }

    private func saveShelfFiles(_ urls: [URL]) -> Bool {
        var shelf = model.shelf
        let overflow = shelf.add(urls)
        if overflow > 0 {
            let message = "Полка заполнена · не добавлено: " + String(overflow)
            model.shelfFeedback = message
            model.notice(message)
        } else if !urls.isEmpty {
            model.shelfFeedback = ""
        }
        guard shelf.paths != model.shelf.paths else { return false }
        guard persistShelf(shelf) else { return false }
        rememberShelfReferences()
        return true
    }

    private func rememberShelfReferences() {
        refreshShelfReferences(for: Set(model.shelf.paths).subtracting(model.shelf.recordedPaths))
    }

    private func refreshShelfReferences(for paths: Set<String>) {
        pendingShelfReferences.formUnion(paths)
        guard !checkingShelfReferences, !pendingShelfReferences.isEmpty else { return }
        let scanned = pendingShelfReferences
        pendingShelfReferences.removeAll()
        let snapshot = model.shelf
        checkingShelfReferences = true
        shelfReferenceQueue.async { [weak self] in
            var refreshed = snapshot
            let renamed = refreshed.updateReferences(in: scanned)
            let result = refreshed
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkingShelfReferences = false
                if self.model.shelf == snapshot {
                    if result != snapshot { _ = self.persistShelf(result, renamed: renamed) }
                } else {
                    self.pendingShelfReferences.formUnion(scanned.intersection(self.model.shelf.paths))
                }
                self.refreshShelfReferences(for: [])
            }
        }
    }

    private func persistShelf(_ shelf: ShelfState, renamed: [String: String] = [:]) -> Bool {
        guard LocalSettings.save(shelf, as: "shelf.json") else {
            model.shelfFeedback = "Не удалось сохранить полку"
            model.notice(model.shelfFeedback)
            return false
        }
        let selection = Set(model.shelfSelection.map { renamed[$0] ?? $0 }).intersection(shelf.paths)
        model.shelf = shelf
        if model.shelfSelection != selection { model.shelfSelection = selection }
        return true
    }

    private func notchDragEntered() {
        suppressNotchReveal = true
        reveal?.cancel()
        reveal = nil
        updatePointerExit(NSEvent.mouseLocation)
    }

    private func dropFilesAtNotch(_ urls: [URL]) -> Bool {
        let added = saveShelfFiles(urls)
        guard added || urls.contains(where: { model.shelf.paths.contains($0.standardizedFileURL.path) }) else {
            return false
        }
        notchDragEntered()
        if mascotWindow?.isVisible != true || notchDropFeedback != nil {
            notchDropFeedback?.cancel()
            let feedback = DispatchWorkItem { [weak self] in
                self?.notchDropFeedback = nil
                self?.updateVisibility()
            }
            notchDropFeedback = feedback
            updateVisibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: feedback)
        }
        mascot?.react(.file)
        if fixture { NSLog("File drop accepted at notch; panel visible=%@", String(model.active)) }
        return true
    }

    private func takeMascot(_ point: CGPoint) {
        guard cursorChase == nil, completionNudge == nil, let mascotWindow else { return }
        reveal?.cancel()
        reveal = nil
        returnHome?.cancel()
        returnHome = nil
        curiosity?.cancel()
        if !pursuing, let geometry, mascotWindow.frame.origin != geometry.mascot.origin { needsReturn = true }
        stopFlight()
        press = point
        pressOrigin = mascotWindow.frame.origin
        mascot?.hold(true)
    }

    private func dragMascot(_ point: CGPoint) {
        guard let press, let origin = pressOrigin, let geometry, let mascotWindow else { return }
        let dx = point.x - press.x
        let dy = point.y - press.y
        if hypot(dx, dy) > 3 { dragStarted = true }
        guard dragStarted else { return }
        let target = CGPoint(x: origin.x + dx, y: origin.y + dy)
        mascotWindow.setFrameOrigin(geometry.constrained(target, window: mascotWindow.frame.size))
    }

    private func dropMascot() {
        guard press != nil else { return }
        press = nil
        pressOrigin = nil
        mascot?.hold(false)
        needsReturn = needsReturn || dragStarted
        let displaced = needsReturn
        dragStarted = false
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.returnHome = nil
            let shouldReturn = self.needsReturn
            self.needsReturn = false
            self.mascot?.clearBlush()
            if shouldReturn { self.returnMascot(animated: true) }
            self.scheduleCuriosity()
            self.startCompletionNudgeIfReady()
        }
        returnHome = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (displaced ? 2 : 0.78), execute: item)
    }

    private func stopFlight() {
        flight?.invalidate()
        flight = nil
    }

    private func returnMascot(animated: Bool) {
        guard let geometry else { return }
        let moving = mascotWindow.map { hypot($0.frame.minX - geometry.mascot.minX,
                                              $0.frame.minY - geometry.mascot.minY) >= 2 } ?? false
        moveMascot(to: geometry.mascot, animated: animated, reaction: moving && animated ? .landing : nil)
    }

    private func moveMascot(to frame: CGRect, animated: Bool, reaction: MascotView.Gesture?, inQuickChat: Bool = false) {
        guard let mascotWindow else { return }
        stopFlight()
        let origin = mascotWindow.frame.origin
        if !animated || hypot(frame.minX - origin.x, frame.minY - origin.y) < 2 || reducedMotion || !mascotWindow.isVisible {
            mascotWindow.setFrame(frame, display: false)
            if let reaction { mascot?.react(reaction) }
            return
        }
        let destination = inQuickChat ? QuickChatHop.destination(from: origin, to: frame) : frame
        let displacement = CGPoint(x: destination.minX - origin.x, y: destination.minY - origin.y)
        let traveled = hypot(displacement.x, displacement.y)
        let duration = inQuickChat ? QuickChatHop.duration : min(0.66, max(0.18, 0.11 + traveled / 850))
        let started = ProcessInfo.processInfo.systemUptime
        if !inQuickChat || reaction != nil { mascot?.travel(toward: displacement, duration: duration) }
        let timer = Timer(timeInterval: 1.0 / (inQuickChat ? 120 : 60), repeats: true) { [weak self, weak mascotWindow] timer in
            guard let self, let mascotWindow else { timer.invalidate(); return }
            let fraction = (ProcessInfo.processInfo.systemUptime - started) / duration
            if fraction < 1 {
                let progress = inQuickChat && destination != frame ? CGFloat(fraction) : MascotTravel.progress(at: fraction)
                mascotWindow.setFrameOrigin(CGPoint(x: origin.x + displacement.x * progress,
                                                    y: origin.y + displacement.y * progress))
            } else {
                self.stopFlight()
                mascotWindow.setFrame(destination, display: false)
                if destination == frame, let reaction { self.mascot?.react(reaction) }
                self.followAfterLanding()
            }
        }
        timer.tolerance = inQuickChat ? 0.001 : 0.002
        flight = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func followAfterLanding() {
        if quickChat.isOpen {
            followQuickChatPointer(NSEvent.mouseLocation, animated: false)
        } else if pursuing {
            pursue(NSEvent.mouseLocation, jump: false)
        }
    }

    private func scheduleCuriosity(after interval: Double? = nil) {
        curiosity?.cancel()
        guard !hiddenByUser, !fullscreen, !pursuing, !quickChat.isOpen, cursorChase == nil, completionNudge == nil,
              shelfDelivery == nil, fileHandoff?.isFlying != true, press == nil,
              !reducedMotion else { curiosity = nil; return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.curiosity = nil
            guard !self.pursuing, self.press == nil, self.returnHome == nil,
                  self.mascotWindow?.isVisible == true,
                  ProcessInfo.processInfo.systemUptime - self.lastMouseMovement < 80 else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastMouseMovement < 1.4 {
                self.scheduleCuriosity(after: 5)
                return
            }
            if abs(self.lastGaze.x) > 0.35 {
                self.mascot?.react(.curious(self.lastGaze.x > 0 ? 1 : -1))
            } else {
                self.mascot?.react(Bool.random() ? .blink : .curious(Bool.random() ? 1 : -1))
            }
            self.scheduleCuriosity()
        }
        curiosity = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (interval ?? Double.random(in: 20...34)), execute: item)
    }

    private func pursue(_ point: CGPoint, jump: Bool) {
        guard pursuing, !fullscreen, !hiddenByUser, press == nil, returnHome == nil, completionNudge == nil,
              !reducedMotion, let geometry,
              let window = mascotWindow, geometry.screen.contains(point) else { return }
        if geometry.hover.contains(point) || (model.active && player?.frame.contains(point) == true) {
            if jump { mascot?.react(.attention) }
            return
        }
        guard flight == nil else { return }
        let offsets: [CGFloat] = point.x > geometry.screen.minX + 65 ? [-53, 21] : [21, -53]
        let size = window.frame.size
        let candidates = offsets.map { offset in
            CGRect(origin: geometry.constrained(CGPoint(x: point.x + offset, y: point.y - 6), window: size), size: size)
        }
        guard let target = candidates.first(where: { candidate in
            !geometry.hover.intersects(candidate) && (!model.active || player?.frame.intersects(candidate) != true)
        }) else {
            if jump { mascot?.react(.attention) }
            return
        }
        guard jump || hypot(window.frame.minX - target.minX, window.frame.minY - target.minY) > 55 else { return }
        moveMascot(to: target, animated: true, reaction: jump ? .attention : .landing)
    }

    private func scheduleChaseReminder() {
        chaseReminder?.cancel()
        guard pursuing, !fullscreen, !hiddenByUser, !reducedMotion else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pursuing else { return }
            if self.press == nil, self.mascotWindow?.isVisible == true {
                self.pursue(NSEvent.mouseLocation, jump: true)
            }
            self.scheduleChaseReminder()
        }
        chaseReminder = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 26, execute: item)
    }

    private func resolveCodexRequest(_ chat: String?) {
        CodexPendingRequest.resolve(chat, in: &model.pendingCodex)
        if model.pendingCodex.isEmpty {
            mascot?.mood = .idle
            if pursuing { stopPursuitMotion() }
        }
    }

    private func stopPursuitMotion() {
        pursuing = false
        chaseReminder?.cancel()
        guard cursorChase == nil, completionNudge == nil, !quickChat.isOpen else { return }
        if press == nil, returnHome == nil {
            returnMascot(animated: !fullscreen)
        } else {
            needsReturn = true
        }
        scheduleCuriosity()
    }

    private func applicationActivated(_ application: NSRunningApplication?) {
        if fileHandoff?.isDragging != true { dismissFileHandoff() }
        if let application {
            cancelFilePickerSelection()
            quickChat.applicationActivated(application)
            clipboardPocket.applicationActivated(application)
            let newApp = application.processIdentifier
            if cursorChase != nil, cursorChaseApp == nil, newApp != getpid() { cursorChaseApp = newApp }
            let endChase = cursorChaseApp.map { $0 != newApp } ?? false
            let endCompletion = completionCurrent != nil && !allowsCompletion(in: application)
            interruptPointerControl(endChase: endChase, endCompletion: endCompletion)
        }
        if let application, application.bundleIdentifier != "com.apple.UserNotificationCenter" {
            if let attempt = completionReturnAttempt, application.processIdentifier != attempt.codex {
                clearCompletionReturn()
            } else if let ticket = completionReturn {
                let next = application.processIdentifier
                if ticket.requestedChat, ticket.codexApp == nil, application.bundleIdentifier.map(isCodex) == true {
                    completionReturn?.codexApp = application.processIdentifier
                } else if next != (ticket.codexApp ?? ticket.originalApp) {
                    clearCompletionReturn()
                }
            }
        }
        if let id = application?.bundleIdentifier, isCodex(id), pursuing { stopPursuitMotion() }
        if !fixture && (meetingRefresh != nil || !meetingAlerts.isEmpty) != model.calendarFeed.hasAccess {
            scheduleMeetingAlert()
        }
        changedSpace()
    }

    private func isCodex(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("openai") && lower.contains("codex")
    }

    @discardableResult
    private func openCodex(_ chat: String?, verifyRead: Bool = true) -> Bool {
        if let chat, chat.range(of: "^[A-Za-z0-9-]{16,80}$", options: .regularExpression) == nil { return false }
        if fixture {
            if let chat {
                if verifyRead { acknowledgeCodex(chat) }
                NSLog("fixture opened Codex chat %@", chat)
            }
            return chat != nil
        }
        if let chat, let url = URL(string: "codex://threads/" + chat) {
            guard workspace.open(url) else {
                model.notice("Не удалось открыть чат Codex")
                return false
            }
            if completionReturn?.chat == chat { completionReturn?.requestedChat = true }
            if verifyRead {
                Task { @MainActor [weak self] in
                    guard let self, await self.waitForCodexWindow(chat, timeout: 2.5) != nil else { return }
                    self.acknowledgeCodex(chat)
                }
            }
        } else if let app = workspace.runningApplications.first(where: { isCodex($0.bundleIdentifier ?? "") }) {
            app.activate()
        } else if let url = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            workspace.openApplication(at: url, configuration: .init())
        }
        if pursuing { stopPursuitMotion() }
        return chat != nil
    }

    private func acknowledgeCodex(_ chat: String) {
        if completionReturn?.chat == chat, let app = workspace.frontmostApplication,
           app.bundleIdentifier.map(isCodex) == true {
            completionReturn?.codexApp = app.processIdentifier
        }
        CodexPendingRequest.resolve(chat, in: &model.completedCodex)
        withdrawCompletionSignal(for: chat)
        persistCodexInbox()
    }

    private func readAllCompletedCodex() {
        model.completedCodex.removeAll()
        deferredCodexSignal = nil
        if completionSignal?.kind == .codex { clearCompletionSignal() }
        if completionPending?.kind == .codex { completionPending = nil }
        if completionCurrent?.kind == .codex, !completionDidOpen {
            stopCompletionNudge(clearPending: false)
            scheduleCuriosity()
            startCompletionNudgeIfReady()
        }
        persistCodexInbox()
    }

    private func persistCodexInbox() {
        if !fixture { LocalSettings.save(model.completedCodex, as: "codex-inbox.json") }
    }

    private func handle(_ event: IslandEvent) {
        switch event.type {
        case "ready":
            guard let source = event.source, allowedSource(source) else { return }
            sourcesReady.insert(source)
            IslandEvents.post(IslandEvent(type: "hello", source: source), to: IslandEvents.outbound)
            if source == "com.lad.music" {
                queueTimeout?.cancel()
                queueTimeout = nil
                for file in pendingQueue { sendQueue(file) }
                pendingQueue.removeAll()
            }
        case "media":
            guard let item = event.media, allowedSource(item.source) else { return }
            sourcesReady.insert(item.source)
            direct[item.source] = item
            refreshMedia()
        case "bye":
            guard let source = event.source, allowedSource(source) else { return }
            sourceClosed(source)
        case "download-start":
            guard event.source == "com.kiridey.ardia.personal", let id = event.id, let title = event.title else { return }
            model.transfers[id] = title
            updateActivity()
        case "download-end":
            guard event.source == "com.kiridey.ardia.personal", let id = event.id else { return }
            model.transfers.removeValue(forKey: id)
            updateActivity()
        case "download":
            guard event.source == "com.kiridey.ardia.personal" else { return }
            if let id = event.id { model.transfers.removeValue(forKey: id) }
            updateActivity()
            guard let path = event.path, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return }
            if let file = CodexResultFiles.localFile(at: path) {
                recentDownloads.removeAll { $0 == file.path }
                recentDownloads.insert(file.path, at: 0)
                recentDownloads = Array(recentDownloads.prefix(18))
                if !fixture { LocalSettings.save(recentDownloads, as: "recent-download-files.json") }
            }
            downloadPreviewTimeout?.cancel()
            downloadPreviewTimeout = nil
            model.download = URL(fileURLWithPath: path)
            model.hasNewDownload = !model.active || model.page != .shelf
            if !model.hasNewDownload { showDownloadPreview() }
            model.notice("Скачано · " + URL(fileURLWithPath: path).lastPathComponent, destination: .shelf)
            mascot?.react(.file)
        case "work":
            resolveCodexRequest(event.chat)
            if let chat = event.chat {
                if event.source == "codex-hook" { returnAfterSubmitting(chat: chat) }
                if model.completedCodex.contains(where: { $0.chat == chat }) {
                    CodexPendingRequest.resolve(chat, in: &model.completedCodex)
                    persistCodexInbox()
                }
                withdrawCompletion(for: chat)
            }
            if model.pendingCodex.isEmpty {
                mascot?.mood = .working
                mascot?.react(.blink)
            }
        case "done":
            let pending = model.pendingCodex.first { $0.chat == event.chat }
            resolveCodexRequest(event.chat)
            if event.source == "codex-hook", recentCodexFiles.record(event.files ?? []), !fixture {
                LocalSettings.save(recentCodexFiles, as: "recent-codex-files.json")
            }
            if let chat = event.chat {
                let entry = CodexPendingRequest(chat: chat, title: event.title ?? pending?.title)
                model.latestCompletedCodex = entry
                CodexPendingRequest.register(entry, in: &model.completedCodex)
                model.completedCodex = Array(model.completedCodex.prefix(15))
                persistCodexInbox()
                if !fixture { LocalSettings.save(entry, as: "codex-latest.json") }
                model.notice("Codex закончил работу · " + entry.label, codexChat: chat)
            }
            signalCompletion(.codex, chat: event.chat)
        case "fixture-completion-mode" where fixture:
            fixtureCompletionMode = event.action.flatMap(CompletionMode.init(rawValue:))
        case "fixture-completion-done" where fixture:
            handle(IslandEvent(type: "done", title: event.title, chat: event.chat))
        case "fixture-hook-done" where fixture:
            handle(IslandEvent(type: "done", source: event.source, title: event.title, chat: event.chat, files: event.files))
        case "ask":
            CodexPendingRequest.register(.init(chat: event.chat, title: event.title), in: &model.pendingCodex)
            mascot?.mood = .awaiting
            let codexIsFrontmost = workspace.frontmostApplication?.bundleIdentifier.map(isCodex) ?? false
            if preferences.followsCodexRequests, !pursuing, !hiddenByUser, cursorChase == nil, completionNudge == nil, shelfDelivery == nil,
               fileHandoff?.isFlying != true, !quickChat.isOpen,
               event.source != "codex-hook" || !codexIsFrontmost {
                pursuing = true
                curiosity?.cancel()
                pursue(NSEvent.mouseLocation, jump: true)
                scheduleChaseReminder()
            } else if !pursuing {
                mascot?.react(.attention)
            }
        case "clear":
            resolveCodexRequest(event.chat)
        case "show": showPanel()
        case "fixture-shelf" where fixture: showShelf()
        case "fixture-bring-download" where fixture: bringFile(from: .downloads)
        case "fixture-bring-codex-file" where fixture: bringFile(from: .codex)
        case "fixture-quick-chat" where fixture: showQuickChat(selectedText: event.title)
        case "fixture-quick-chat-image" where fixture:
            if let path = event.path { askAboutShelfImage(URL(fileURLWithPath: path)) }
        case "fixture-cursor-chase" where fixture: toggleCursorChase()
        case "fixture-pointer-context" where fixture:
            if event.action == "space" {
                workspace.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            } else if let app = workspace.runningApplications.first(where: {
                $0.activationPolicy == .regular && $0.processIdentifier != workspace.frontmostApplication?.processIdentifier
            }) {
                workspace.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: app])
            }
        case "fixture-system-media" where fixture:
            var update = event
            update.type = "media"
            systemItem = update.media
            refreshMedia()
        case "fixture-source-media" where fixture, "fixture-source-bye" where fixture:
            var update = event
            update.type = event.type == "fixture-source-media" ? "media" : "bye"
            handle(update)
        case "fixture-timer-clock" where fixture:
            fixtureTimerOffset = event.elapsed ?? 0
            switch event.action {
            case "change": NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
            case "sleep": workspace.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            case "wake":
                workspace.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                workspace.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            default: break
            }
        case "fixture-meeting" where fixture:
            let start = Date().addingTimeInterval(event.elapsed ?? 60)
            let id = event.id ?? "fixture-timed"
            if event.action == "update-link" {
                guard let index = fixtureMeetings.firstIndex(where: { $0.id == id }) else { return }
                fixtureMeetings[index].link = event.path.flatMap(URL.init(string:))
                scheduleMeetingAlert()
                return
            }
            if event.action == "append" || event.action == "remove" {
                fixtureMeetings.removeAll { $0.id == id }
            } else {
                fixtureMeetings.removeAll()
            }
            if event.action != "remove" {
                fixtureMeetings.append(CalendarEntry(id: id, title: event.title ?? "Проверка встречи",
                    start: start, end: start.addingTimeInterval(event.duration ?? 1800),
                    allDay: false, link: URL(string: "https://example.com/" + (event.id ?? "test-meeting"))))
            }
            scheduleMeetingAlert()
        default: break
        }
    }

    private func allowedSource(_ id: String) -> Bool {
        id == "com.lad.music" || id == "com.kiridey.ardia.personal"
    }

    @discardableResult private func setCountdown(_ countdown: Countdown?) -> Bool {
        guard saveCountdown(countdown) else { return false }
        model.countdown = countdown
        refreshTimer()
        return true
    }

    @discardableResult private func saveCountdown(_ countdown: Countdown?) -> Bool {
        guard LocalSettings.save(countdown, as: "timer.json") else {
            model.clockFeedback = countdownSaveError
            return false
        }
        countdownSaveRetry?.cancel()
        countdownSaveRetry = nil
        if model.clockFeedback == countdownSaveError { model.clockFeedback = nil }
        return true
    }

    private func retryCountdownSave() {
        guard countdownSaveRetry == nil else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.countdownSaveRetry = nil
            if !self.saveCountdown(self.model.countdown) { self.retryCountdownSave() }
        }
        countdownSaveRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: retry)
    }

    private func refreshTimer() {
        scheduleTimer()
        updateActivity()
    }

    private func scheduleTimer() {
        timerAlarm?.cancel()
        timerAlarm = nil
        guard let countdown = model.countdown, !countdown.isPaused else { return }
        let now = timerDate
        let remaining = countdown.remaining(at: now)
        if remaining > 0 {
            let fire = DispatchWorkItem { [weak self] in self?.refreshTimer() }
            timerAlarm = fire
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + remaining, execute: fire)
            return
        }
        let next = countdown.next(after: now)
        model.countdown = next
        if !saveCountdown(next) { retryCountdownSave() }
        let notice: String
        switch countdown.phase {
        case .timer: notice = "Таймер закончился"
        case .focus: notice = next == nil ? "Pomodoro закончился" : "Время отдохнуть"
        case .rest: notice = "Перерыв закончился"
        }
        model.notice(notice, destination: .quick)
        mascot?.react(.timer)
        if fixture { NSLog("%@", notice) }
        else { NSSound(named: "Glass")?.play() }
        if next != nil { scheduleTimer() }
    }

    @objc private func startAwake() {
        endAwake()
        var assertion = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Чубзик · Keep Awake" as CFString, &assertion) == kIOReturnSuccess {
            awakeID = assertion
            let end = DispatchWorkItem { [weak self] in self?.endAwake() }
            awakeDeadline = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 1800, execute: end)
            model.notice("Сон отложен на 30 минут")
        }
    }

    @objc private func stopAwake() { endAwake(); model.notice("Сон разрешён") }

    private func endAwake() {
        awakeDeadline?.cancel()
        if let awakeID { IOPMAssertionRelease(awakeID) }
        awakeID = nil
    }

    private func installFixture() {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(12 * 3600)
        model.calendarSample = [
            CalendarEntry(id: "fixture-meeting", title: "Встреча по проекту", start: start,
                          end: start.addingTimeInterval(3600), allDay: false,
                          link: URL(string: "https://example.com/meeting"))
        ]
        model.weather = WeatherReading(city: "Москва", temperature: 5, feelsLike: 3, recorded: now,
                                       code: 3, isDay: true, humidity: 78, wind: 3.5, timezone: "Europe/Moscow",
                                       hourly: (1...6).map { hour in
                                           WeatherReading.Hour(time: now.addingTimeInterval(Double(hour * 3600)),
                                                               temperature: Double(6 - hour), code: hour < 3 ? 3 : 61,
                                                               precipitation: hour * 10)
                                       })
        direct["com.lad.music"] = MediaItem(source: "com.lad.music", id: "demo", title: "Ночной маршрут",
                                           artist: "Тестовый источник", playing: true, duration: 210, elapsed: 31,
                                           timestamp: now, rate: 1, artwork: nil, artworkURL: nil, capabilities: nil)
        refreshMedia()
        if CommandLine.arguments.contains("--fixture-hidden") { toggleHidden() }
        if CommandLine.arguments.contains("--show-panel") { showPanel() }
    }
}

private final class MeetingButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchDropView: FileDropView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.02).setFill()
        dirtyRect.fill()
        if showsDropTarget {
            let lip = CGRect(x: 1, y: 1, width: bounds.width - 2, height: 17)
            NSColor(white: 0.19, alpha: 0.90).setFill()
            NSBezierPath(roundedRect: lip, xRadius: 7, yRadius: 7).fill()
        }
    }
}

final class CoverView: FileDropView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Открыть источник воспроизведения")
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let mask = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(srgbRed: 0.20, green: 0.19, blue: 0.24, alpha: 1).setFill()
        mask.fill()
        mask.addClip()
        if let image {
            let side = min(image.size.width, image.size.height)
            let source = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
            image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1)
        } else if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [NSColor(white: 0.93, alpha: 1)])) ?? symbol
            tinted.draw(in: CGRect(x: 5, y: 5, width: 16, height: 16))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

let arguments = CommandLine.arguments
if arguments.dropFirst().first == "--codex-hook" || arguments.dropFirst().first == "--fixture-codex-hook" {
    guard arguments.count == 2 else { exit(EX_USAGE) }
    var input = Data()
    while input.count <= 1_000_000,
          let chunk = try? FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
        input.append(chunk)
    }
    if var event = CodexHook.event(from: input) {
        if arguments[1] == "--fixture-codex-hook" {
            guard event.type == "done" else { exit(EX_USAGE) }
            event.type = "fixture-hook-done"
        }
        IslandEvents.post(event)
    }
} else if arguments.dropFirst().first == "--event" {
    guard (3...4).contains(arguments.count) else { exit(EX_USAGE) }
    IslandEvents.post(IslandEvent(type: arguments[2], chat: arguments.count > 3 ? arguments[3] : nil))
} else if arguments.dropFirst().first == "--event-json" {
    guard arguments.count == 3 else { exit(EX_USAGE) }
    let data = Data(arguments[2].utf8)
    guard data.count <= IslandEvents.payloadLimit,
          let event = try? JSONDecoder().decode(IslandEvent.self, from: data) else { exit(EX_DATAERR) }
    IslandEvents.post(event)
} else {
    let app = NSApplication.shared
    let island = IslandController()
    app.setActivationPolicy(.accessory)
    app.delegate = island
    app.run()
}
