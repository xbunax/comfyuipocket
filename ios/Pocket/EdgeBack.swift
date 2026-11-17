import SwiftUI

extension View {
    /// Reserve only the physical left edge; ordinary canvas/image gestures stay intact.
    func edgeSwipeBack(enabled: Bool = true, preferSystem: Bool = true, action: @escaping () -> Void) -> some View {
        background { EdgeBackArea(enabled: enabled, preferSystem: preferSystem, action: action).allowsHitTesting(false).accessibilityHidden(true) }
    }
}

private struct EdgeBackArea: UIViewRepresentable {
    var enabled: Bool
    var preferSystem: Bool
    var action: () -> Void
    func makeUIView(context: Context) -> EdgeBackView { EdgeBackView() }
    func updateUIView(_ view: EdgeBackView, context: Context) { view.enabled = enabled; view.preferSystem = preferSystem; view.action = action }
    static func dismantleUIView(_ view: EdgeBackView, coordinator: ()) { view.detach() }
}

private final class EdgeBackView: UIView, UIGestureRecognizerDelegate {
    var enabled = true
    var preferSystem = true
    var action: (() -> Void)?
    private weak var installedWindow: UIWindow?
    private lazy var edge: UIScreenEdgePanGestureRecognizer = {
        let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
        gesture.edges = .left; gesture.delegate = self; gesture.cancelsTouchesInView = true
        return gesture
    }()
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if installedWindow !== window { detach(); window?.addGestureRecognizer(edge); installedWindow = window }
    }
    func detach() { installedWindow?.removeGestureRecognizer(edge); installedWindow = nil }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard enabled, let window, !isHidden, !bounds.isEmpty,
              convert(bounds, to: window).contains(gestureRecognizer.location(in: window)) else { return false }
        // A covered editor must never react to swipes in its sheet or alert.
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        if let top, !isDescendant(of: top.view) { return false }
        // Let the system handle native navigation stacks when there is a real pop.
        var responder: UIResponder? = preferSystem ? window.hitTest(gestureRecognizer.location(in: window), with: nil) : nil
        while let current = responder {
            if let controller = current as? UIViewController,
               let navigation = controller.navigationController, navigation.viewControllers.count > 1,
               navigation.interactivePopGestureRecognizer?.isEnabled == true { return false }
            responder = current.next
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        !preferSystem && otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view !== installedWindow
    }
    @objc private func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard enabled, gesture.state == .ended else { return }
        let translation = gesture.translation(in: window)
        let threshold = max(60, min(120, bounds.width * 0.2))
        if translation.x >= threshold || (translation.x >= 24 && gesture.velocity(in: window).x > 600) { action?() }
    }
}
