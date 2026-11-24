import SwiftUI

enum PanelContent: Hashable {
    case preview
    case page(PanelPage)

    var page: PanelPage {
        switch self {
        case .preview: .music
        case .page(let page): page
        }
    }
}

final class PanelPaging: ObservableObject {
    struct Turn {
        let origin: PanelContent
        let destination: PanelContent?
        let direction: CGFloat
        var progress: CGFloat
    }

    @Published private(set) var turn: Turn?
    private var start: DispatchWorkItem?
    private var settlement: DispatchWorkItem?
    var isSettling: Bool { settlement != nil }

    func track(from origin: PanelContent, to destination: PanelContent?, direction: CGFloat, progress: CGFloat) {
        guard !isSettling else { return }
        turn = Turn(origin: origin, destination: destination, direction: direction, progress: progress)
    }

    func settle(commit: Bool, startAfterLayout: Bool = false, finished: @escaping () -> Void) {
        guard turn != nil else { finished(); return }
        let target: CGFloat = commit ? 1 : 0
        let remaining = abs(target - (turn?.progress ?? 0))
        let duration = commit ? 0.14 + 0.13 * remaining : 0.18
        let startDelay = startAfterLayout ? 0.018 : 0
        let nextTurn = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.start = nil
            withAnimation(.timingCurve(0.20, 0.78, 0.26, 1, duration: duration)) {
                self.turn?.progress = target
            }
        }
        let end = DispatchWorkItem { [weak self] in
            self?.turn = nil
            self?.settlement = nil
            finished()
        }
        settlement = end
        if startAfterLayout {
            start = nextTurn
            DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: nextTurn)
        } else {
            nextTurn.perform()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay + duration, execute: end)
    }

    func reset() {
        start?.cancel()
        start = nil
        settlement?.cancel()
        settlement = nil
        if turn != nil { turn = nil }
    }
}

struct PanelPages<Page: View>: View {
    @ObservedObject var paging: PanelPaging
    let current: PanelContent
    @ViewBuilder let view: (PanelContent, Bool) -> Page

    var body: some View {
        GeometryReader { bounds in
            let turn = paging.turn
            let pages = turn.map { [$0.origin] + [$0.destination].compactMap { $0 } } ?? [current]
            ZStack(alignment: .topLeading) {
                ForEach(pages, id: \.self) { page in
                    view(page, turn != nil)
                        .frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
                        .offset(x: offset(of: page, width: bounds.size.width, turn: turn))
                        .allowsHitTesting(turn == nil && page == current)
                        .accessibilityHidden(page != current)
                        .transition(.identity)
                }
            }
            .clipped()
        }
    }

    private func offset(of page: PanelContent, width: CGFloat, turn: PanelPaging.Turn?) -> CGFloat {
        guard let turn else { return 0 }
        let displacement = -turn.direction * turn.progress * width
        return page == turn.origin ? displacement : displacement + turn.direction * width
    }
}

struct PanelTabBar: View {
    @ObservedObject var paging: PanelPaging
    let current: PanelPage
    let tileWidth: CGFloat
    let spacing: CGFloat
    let accent: Color
    let muted: Color
    let attentionPage: PanelPage?
    let select: (PanelPage) -> Void

    var body: some View {
        let pages = PanelPage.allCases
        let turn = paging.turn
        let origin = pages.firstIndex(of: turn?.origin.page ?? current) ?? 0
        let destination = pages.firstIndex(of: turn?.destination?.page ?? current) ?? origin
        let index = CGFloat(origin) + CGFloat(destination - origin) * (turn?.progress ?? 0)
        HStack(spacing: spacing) {
            ForEach(Array(pages.enumerated()), id: \.element) { position, page in
                let strength = max(0, 1 - abs(CGFloat(position) - index))
                Button { select(page) } label: {
                    Image(systemName: page.icon)
                        .foregroundStyle(muted)
                        .opacity(1 - strength)
                        .overlay { Image(systemName: page.icon).foregroundStyle(accent).opacity(strength) }
                        .font(.system(size: tileWidth / 2, weight: .medium))
                        .frame(width: tileWidth, height: tileWidth)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: tileWidth / 4))
                        .overlay(alignment: .topTrailing) {
                            if attentionPage == page {
                                Circle().fill(accent).frame(width: 5, height: 5).padding(3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.rawValue)
                .accessibilityHint(attentionPage == page ? "Есть новая загрузка" : "")
                .accessibilityAddTraits(current == page ? .isSelected : [])
                .help(page.rawValue)
            }
        }
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: tileWidth / 4)
                .fill(.white.opacity(0.085))
                .frame(width: tileWidth, height: tileWidth)
                .offset(x: index * (tileWidth + spacing))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
