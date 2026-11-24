import SwiftUI

enum OrbitStyle {
    static let text = Color(red: 241 / 255, green: 243 / 255, blue: 245 / 255)
    static let muted = Color(red: 170 / 255, green: 175 / 255, blue: 185 / 255)
    static let accent = Color(red: 226 / 255, green: 230 / 255, blue: 236 / 255)
    static let ink = Color(red: 12 / 255, green: 13 / 255, blue: 15 / 255)
    static let surface = Color(red: 20 / 255, green: 21 / 255, blue: 24 / 255)

    @ViewBuilder static func glass(radius: CGFloat = 0) -> some View {
        ZStack {
            MatteEffect().allowsHitTesting(false)
            surface.opacity(0.86)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

private struct MatteEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct OrbitPointerLight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var point: CGPoint?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { bounds in
                    if let point, !reducedMotion, bounds.size.width > 0, bounds.size.height > 0 {
                        RadialGradient(colors: [OrbitStyle.accent.opacity(0.065), .clear],
                                       center: UnitPoint(x: point.x / bounds.size.width, y: point.y / bounds.size.height),
                                       startRadius: 0, endRadius: 123)
                    }
                }
                .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let next):
                    if point.map({ hypot(next.x - $0.x, next.y - $0.y) >= 5 }) ?? true { point = next }
                case .ended: point = nil
                }
            }
    }
}
