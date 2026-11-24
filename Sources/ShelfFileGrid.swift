import AppKit
import CoreText
import Darwin
import QuickLookThumbnailing
import SwiftUI

final class ShelfGridViewport {
    fileprivate weak var scroller: NSScrollView?
    fileprivate var savedOffset: CGFloat = 0
    fileprivate var paths: [String] = []
    fileprivate var revisions: [String: ShelfFileRevision] = [:]
    fileprivate let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        return cache
    }()

    fileprivate func offset(for paths: [String]) -> CGFloat {
        guard self.paths == paths else { return 0 }
        return max(0, scroller?.contentView.bounds.minY ?? savedOffset)
    }
}

private struct ShelfFileRevision: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init?(path: String) {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return nil }
        device = metadata.st_dev
        inode = metadata.st_ino
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

struct ShelfGridPreview: View {
    let paths: [String]
    let selection: Set<String>
    let pinned: Set<String>
    let scale: CGFloat
    let viewport: ShelfGridViewport

    var body: some View {
        GeometryReader { bounds in
            let itemWidth = 72 * scale
            let itemHeight = 53 * scale
            let columnGap = 5 * scale
            let rowGap = 2 * scale
            let rowHeight = itemHeight + rowGap
            let columns = max(1, Int((bounds.size.width - 6 * scale + columnGap) / (itemWidth + columnGap)))
            let offset = viewport.offset(for: paths)
            let firstRow = Int(offset / rowHeight)
            let endRow = firstRow + Int(ceil(bounds.size.height / rowHeight)) + 1
            let visiblePaths = paths.dropFirst(firstRow * columns).prefix((endRow - firstRow) * columns)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: columnGap), count: columns),
                      alignment: .leading, spacing: rowGap) {
                ForEach(visiblePaths, id: \.self) { path in
                    VStack(spacing: rowGap) {
                        Group {
                            if let image = viewport.images.object(forKey: path as NSString) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                Image(systemName: "doc").font(.system(size: 22 * scale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 39 * scale, height: 27 * scale)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 9.3 * scale, weight: .medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 3)
                    }
                    .padding(.top, 2)
                    .frame(width: itemWidth, height: itemHeight, alignment: .top)
                    .background(.white.opacity(selection.contains(path) ? 0.15 : 0),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if pinned.contains(path) {
                            Image(systemName: "pin.fill").font(.system(size: 8 * scale))
                                .foregroundStyle(OrbitStyle.muted)
                                .padding(3)
                        }
                    }
                }
            }
            .padding(.leading, 3 * scale)
            .offset(y: rowGap + CGFloat(firstRow) * rowHeight - offset)
        }
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ShelfFileGrid: NSViewRepresentable {
    let paths: [String]
    let availabilityPaths: [String]
    @Binding var selection: Set<String>
    let pinned: Set<String>
    let scale: CGFloat
    let viewport: ShelfGridViewport
    let focusRequest: Int
    let open: (URL) -> Void
    let preview: (URL) -> Void
    let askAboutImage: (URL) -> Void
    let setPinned: (Set<String>, Bool) -> Void
    let remove: (Set<String>) -> Void
    let feedback: (String) -> Void
    let didCheckAvailability: (Set<String>, Set<String>, Set<String>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let grid = ShelfCollection()
        grid.collectionViewLayout = NSCollectionViewFlowLayout()
        grid.backgroundColors = [.clear]
        grid.appearance = NSAppearance(named: .darkAqua)
        grid.autoresizingMask = [.width]
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.setAccessibilityLabel("Файлы на полке")
        grid.setDraggingSourceOperationMask(.copy, forLocal: true)
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.register(ShelfFileItem.self, forItemWithIdentifier: ShelfFileItem.reuseID)
        grid.delegate = context.coordinator
        grid.dataSource = context.coordinator
        grid.commands = context.coordinator

        let scroller = ShelfScrollView()
        scroller.pendingOffset = viewport.offset(for: paths)
        scroller.documentView = grid
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        viewport.scroller = scroller
        return scroller
    }

    func updateNSView(_ scroller: NSScrollView, context: Context) {
        guard let grid = scroller.documentView as? ShelfCollection,
              let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let coordinator = context.coordinator
        let pinsChanged = coordinator.view.pinned != pinned
        coordinator.view = self
        let itemSize = CGSize(width: 72 * scale, height: 53 * scale)
        if layout.itemSize != itemSize {
            layout.itemSize = itemSize
            layout.minimumLineSpacing = 2 * scale
            layout.minimumInteritemSpacing = 5 * scale
            layout.sectionInset = NSEdgeInsets(top: 2 * scale, left: 3 * scale, bottom: 2 * scale, right: 3 * scale)
            layout.invalidateLayout()
        }
        let pathsChanged = coordinator.paths != paths
        if pathsChanged {
            coordinator.paths = paths
            viewport.paths = paths
        }
        let availabilityPathsChanged = coordinator.availabilityPaths != availabilityPaths
        if availabilityPathsChanged {
            coordinator.availabilityPaths = availabilityPaths
            coordinator.available.formIntersection(availabilityPaths)
            viewport.revisions = viewport.revisions.filter { availabilityPaths.contains($0.key) }
        }
        let indexes = Set(paths.indices.filter { selection.contains(paths[$0]) }.map { IndexPath(item: $0, section: 0) })
        coordinator.updatingSelection = true
        if pathsChanged { grid.reloadData() }
        else if pinsChanged { coordinator.updatePins(in: grid) }
        if grid.selectionIndexPaths != indexes { grid.selectionIndexPaths = indexes }
        coordinator.updatingSelection = false
        if availabilityPathsChanged {
            coordinator.startCheckingAvailability(in: grid)
            coordinator.refreshAvailability(in: grid, pathsChanged: true)
        }
        if focusRequest != 0, coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak grid, weak coordinator] in
                guard let grid, let coordinator, let window = grid.window, window.isKeyWindow else { return }
                window.makeFirstResponder(grid)
                if grid.selectionIndexPaths.isEmpty, !coordinator.paths.isEmpty {
                    grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
                    coordinator.publishSelection(grid)
                }
            }
        }
    }

    static func dismantleNSView(_ scroller: NSScrollView, coordinator: Coordinator) {
        coordinator.stopCheckingAvailability()
        let viewport = coordinator.view.viewport
        guard viewport.scroller === scroller else { return }
        viewport.savedOffset = max(0, scroller.contentView.bounds.minY)
        viewport.scroller = nil
    }

    private final class ShelfScrollView: NSScrollView {
        var pendingOffset: CGFloat = 0

        override func layout() {
            super.layout()
            guard pendingOffset > 0, bounds.height > 0, let documentView,
                  documentView.frame.height > bounds.height else { return }
            var visible = contentView.bounds
            visible.origin.y = pendingOffset
            pendingOffset = 0
            contentView.scroll(to: contentView.constrainBoundsRect(visible).origin)
            reflectScrolledClipView(contentView)
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var view: ShelfFileGrid
        var paths: [String] = []
        var availabilityPaths: [String] = []
        var available: Set<String> = []
        var lastFocusRequest = 0
        var updatingSelection = false
        private var picker: NSSharingServicePicker?
        private var availabilityTimer: Timer?
        private var availabilityRevision = 0
        private var isCheckingAvailability = false

        init(_ view: ShelfFileGrid) { self.view = view }

        deinit { availabilityTimer?.invalidate() }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { paths.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
            -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ShelfFileItem.reuseID, for: indexPath) as! ShelfFileItem
            let path = paths[indexPath.item]
            item.configure(path: path, exists: available.contains(path), scale: view.scale, viewport: view.viewport)
            item.showPin(view.pinned.contains(path))
            return item
        }

        func updatePins(in grid: NSCollectionView) {
            for index in grid.indexPathsForVisibleItems() where paths.indices.contains(index.item) {
                (grid.item(at: index) as? ShelfFileItem)?.showPin(view.pinned.contains(paths[index.item]))
            }
        }

        func startCheckingAvailability(in grid: NSCollectionView) {
            if availabilityPaths.isEmpty {
                stopCheckingAvailability()
                return
            }
            guard availabilityTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak grid] timer in
                guard let self, let grid else { timer.invalidate(); return }
                guard grid.window?.isVisible == true else { return }
                self.refreshAvailability(in: grid)
            }
            timer.tolerance = 0.4
            availabilityTimer = timer
        }

        func stopCheckingAvailability() {
            availabilityTimer?.invalidate()
            availabilityTimer = nil
        }

        func refreshAvailability(in grid: NSCollectionView, pathsChanged: Bool = false) {
            if pathsChanged { availabilityRevision += 1 }
            guard availabilityTimer != nil, !isCheckingAvailability else { return }
            isCheckingAvailability = true
            let listedPaths = availabilityPaths
            let revision = availabilityRevision
            DispatchQueue.global(qos: .utility).async { [weak self, weak grid] in
                let revisions = Dictionary(listedPaths.compactMap { path in
                    ShelfFileRevision(path: path).map { (path, $0) }
                }, uniquingKeysWith: { first, _ in first })
                let readable = Set(revisions.keys)
                DispatchQueue.main.async { [weak self, weak grid] in
                    guard let self, let grid else { return }
                    self.isCheckingAvailability = false
                    guard self.availabilityTimer != nil else { return }
                    guard revision == self.availabilityRevision else {
                        self.refreshAvailability(in: grid)
                        return
                    }
                    let viewport = self.view.viewport
                    let revised = Set(revisions.compactMap { path, revision in
                        viewport.revisions[path].flatMap { $0 == revision ? nil : path }
                    })
                    viewport.revisions = revisions
                    self.updateAvailability(readable, revised: revised, in: grid)
                    if grid.window?.isVisible == true {
                        self.view.didCheckAvailability(Set(listedPaths), readable, revised)
                    }
                }
            }
        }

        private func updateAvailability(_ readable: Set<String>, revised: Set<String> = [], in grid: NSCollectionView) {
            let changed = readable.symmetricDifference(available).union(revised)
            guard !changed.isEmpty else { return }
            for path in available.subtracting(readable).union(revised) {
                view.viewport.images.removeObject(forKey: path as NSString)
            }
            available = readable
            for index in grid.indexPathsForVisibleItems() where paths.indices.contains(index.item) {
                let path = paths[index.item]
                guard changed.contains(path), let item = grid.item(at: index) as? ShelfFileItem else { continue }
                item.configure(path: path, exists: readable.contains(path), scale: view.scale, viewport: view.viewport)
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection(collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection(collectionView)
        }

        func publishSelection(_ grid: NSCollectionView) {
            guard !updatingSelection else { return }
            let selected = Set(selectedPaths(grid))
            if view.selection != selected { view.selection = selected }
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath)
            -> NSPasteboardWriting? {
            guard paths.indices.contains(indexPath.item) else { return nil }
            let path = paths[indexPath.item]
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return NSURL(fileURLWithPath: path)
        }

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                            with event: NSEvent) -> Bool {
            let selected = indexPaths.compactMap { paths.indices.contains($0.item) ? paths[$0.item] : nil }
            return selected.contains { FileManager.default.fileExists(atPath: $0) }
        }

        private func selectedPaths(_ grid: NSCollectionView) -> [String] {
            grid.selectionIndexPaths.map(\.item).sorted().compactMap { paths.indices.contains($0) ? paths[$0] : nil }
        }

        private func readableSelection(_ grid: NSCollectionView) -> [URL] {
            let selected = selectedPaths(grid)
            let readable = selected.filter { FileManager.default.fileExists(atPath: $0) }
            let next = available.subtracting(selected).union(readable)
            if next != available {
                availabilityRevision += 1
                updateAvailability(next, in: grid)
            }
            if selected.count != readable.count {
                view.feedback(readable.isEmpty ? "Выбранные файлы недоступны" : "Часть файлов недоступна")
            }
            return readable.map { URL(fileURLWithPath: $0) }
        }

        func openItem(_ index: IndexPath, in grid: NSCollectionView) {
            guard paths.indices.contains(index.item) else { return }
            let path = paths[index.item]
            if FileManager.default.fileExists(atPath: path) { view.open(URL(fileURLWithPath: path)) }
            else { _ = readableSelection(grid) }
        }

        func openSelection(_ grid: NSCollectionView) {
            if let url = readableSelection(grid).first { view.open(url) }
        }

        func previewSelection(_ grid: NSCollectionView) {
            if let url = readableSelection(grid).first { view.preview(url) }
        }

        func copySelection(_ grid: NSCollectionView) {
            let files = readableSelection(grid)
            guard !files.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.writeObjects(files.map { $0 as NSURL }) { view.feedback("Скопировано · " + String(files.count)) }
        }

        func removeSelection(_ grid: NSCollectionView) {
            view.remove(Set(selectedPaths(grid)))
        }

        func contextMenu(_ grid: NSCollectionView) -> NSMenu {
            let menu = NSMenu()
            let single = grid.selectionIndexPaths.count == 1
            let files = readableSelection(grid)
            let valid = !files.isEmpty
            menu.autoenablesItems = false
            if single, let image = files.first, QuickChatImage.supports(image) {
                addMenuItem("Спросить об этом", enabled: true, to: menu) { [weak self] in
                    self?.view.askAboutImage(image)
                }
                menu.addItem(.separator())
            }
            addMenuItem("Открыть", enabled: valid && single, to: menu) { [weak self, weak grid] in
                if let grid { self?.openSelection(grid) }
            }
            addMenuItem("Быстрый просмотр", enabled: valid && single, to: menu) { [weak self, weak grid] in
                if let grid { self?.previewSelection(grid) }
            }
            addMenuItem("Показать в Finder", enabled: valid, to: menu) {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
            addMenuItem("Скопировать", enabled: valid, to: menu) { [weak self, weak grid] in
                if let grid { self?.copySelection(grid) }
            }
            addMenuItem("Поделиться…", enabled: valid, to: menu) { [weak self, weak grid] in
                guard let self, let grid, let index = grid.selectionIndexPaths.min(),
                      let item = grid.item(at: index) else { return }
                let picker = NSSharingServicePicker(items: files)
                self.picker = picker
                picker.show(relativeTo: item.view.bounds, of: item.view, preferredEdge: .maxY)
            }
            let selection = Set(selectedPaths(grid))
            let pin = !selection.isSubset(of: view.pinned)
            addMenuItem(pin ? "Закрепить на полке" : "Открепить", enabled: !selection.isEmpty, to: menu) { [weak self] in
                self?.view.setPinned(selection, pin)
            }
            addMenuItem("Убрать с полки", enabled: !grid.selectionIndexPaths.isEmpty, to: menu) { [weak self, weak grid] in
                if let grid { self?.removeSelection(grid) }
            }
            return menu
        }

        private func addMenuItem(_ title: String, enabled: Bool, to menu: NSMenu, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.isEnabled = enabled
            menu.addItem(item)
        }

        @objc private func performMenuItem(_ item: NSMenuItem) {
            (item.representedObject as? () -> Void)?()
        }
    }

    private final class ShelfCollection: NSCollectionView {
        weak var commands: Coordinator?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
            if event.clickCount == 2, let hit = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
                commands?.openItem(hit, in: self)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let hit = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
            if !selectionIndexPaths.contains(hit) {
                selectionIndexPaths = [hit]
                commands?.publishSelection(self)
            }
            return commands?.contextMenu(self)
        }

        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": commands?.copySelection(self)
                default: super.keyDown(with: event)
                }
                return
            }
            switch event.keyCode {
            case 36, 76: commands?.openSelection(self)
            case 49: commands?.previewSelection(self)
            case 51, 117: commands?.removeSelection(self)
            default: super.keyDown(with: event)
            }
        }
    }
}

private final class ShelfFileItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("shelf-file")
    private let icon = NSImageView()
    private let pin = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let continuation = NSTextField(labelWithString: "")
    private var thumbnail: QLThumbnailGenerator.Request?
    private var iconHeight: NSLayoutConstraint!
    private var gap: NSLayoutConstraint!

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(icon)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Закреплён")
        pin.contentTintColor = .secondaryLabelColor
        pin.imageScaling = .scaleProportionallyUpOrDown
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.isHidden = true
        view.addSubview(pin)
        for label in [name, continuation] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3)
            ])
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.cell)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 33)
        gap = name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3)
        NSLayoutConstraint.activate([
            pin.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            pin.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            pin.widthAnchor.constraint(equalToConstant: 10),
            pin.heightAnchor.constraint(equalToConstant: 10),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            icon.widthAnchor.constraint(equalTo: icon.heightAnchor, multiplier: 1.45),
            iconHeight, gap,
            continuation.topAnchor.constraint(equalTo: name.bottomAnchor, constant: -1)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
    }

    func showPin(_ pinned: Bool) {
        pin.isHidden = !pinned
    }

    deinit { cancelThumbnail() }

    func configure(path: String, exists: Bool, scale: CGFloat, viewport: ShelfGridViewport) {
        loadViewIfNeeded()
        cancelThumbnail()
        let filename = (path as NSString).lastPathComponent
        let font = NSFont.systemFont(ofSize: 9.3 * scale, weight: .medium)
        configureName(filename, font: font, width: 72 * scale - 8)
        iconHeight.constant = 27 * scale
        gap.constant = 2 * scale
        view.toolTip = exists ? filename : filename + " · Файл недоступен"
        view.setAccessibilityLabel(view.toolTip)
        let cachedImage = exists ? viewport.images.object(forKey: path as NSString) : nil
        icon.image = cachedImage ?? NSImage(systemSymbolName: exists ? "doc" : "exclamationmark.circle",
                                            accessibilityDescription: nil)
        icon.contentTintColor = cachedImage == nil ? .secondaryLabelColor : nil
        icon.alphaValue = exists ? 1 : 0.66
        for label in [name, continuation] { label.textColor = exists ? .labelColor : .secondaryLabelColor }
        updateSelection()
        guard exists else { return }
        let size = CGSize(width: iconHeight.constant * 1.45, height: iconHeight.constant)
        let request = QLThumbnailGenerator.Request(fileAt: URL(filePath: path, directoryHint: .inferFromPath), size: size,
                                                  scale: view.window?.backingScaleFactor ?? 2,
                                                  representationTypes: .all)
        thumbnail = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak viewport] result, _ in
            DispatchQueue.main.async { [weak self, weak viewport] in
                guard let self, self.thumbnail === request else { return }
                self.thumbnail = nil
                if let result {
                    let image = result.nsImage
                    viewport?.images.setObject(image, forKey: path as NSString)
                    self.icon.contentTintColor = nil
                    self.icon.image = image
                }
            }
        }
    }

    private func configureName(_ filename: String, font: NSFont, width: CGFloat) {
        let text = filename.components(separatedBy: .newlines).joined(separator: " ")
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = CTTypesetterSuggestLineBreak(typesetter, 0, Double(width))
        // Keep filenames without spaces readable and leave the extension on the last line.
        name.font = font
        continuation.font = font
        if length > 0, length < attributed.length, let split = Range(NSRange(location: 0, length: length), in: text)?.upperBound {
            name.stringValue = text[..<split].trimmingCharacters(in: .whitespaces)
            continuation.stringValue = text[split...].trimmingCharacters(in: .whitespaces)
        } else {
            name.stringValue = text
            continuation.stringValue = ""
        }
        continuation.isHidden = continuation.stringValue.isEmpty
    }

    private func cancelThumbnail() {
        if let thumbnail { QLThumbnailGenerator.shared.cancel(thumbnail) }
        thumbnail = nil
    }

    private func updateSelection() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.15).cgColor : nil
        view.setAccessibilitySelected(isSelected)
    }
}
