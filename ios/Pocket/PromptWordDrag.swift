import SwiftUI
import UIKit

/// Local session identity is reliable even when UIKit changes the item provider's name.
private final class PromptWordDragPayload {
    let boardID: UUID
    let wordID: UUID
    init(boardID: UUID, wordID: UUID) { self.boardID = boardID; self.wordID = wordID }
}

struct PromptWordDropActions {
    let boardID: UUID
    let accepts: (UUID) -> Bool
    let entered: () -> Void
    let exited: () -> Void
    let dropped: (UUID) -> Void
}

@MainActor class PromptWordDropCoordinator: NSObject, UIDropInteractionDelegate {
    var actions: PromptWordDropActions
    init(actions: PromptWordDropActions) { self.actions = actions }
    private func source(_ session: UIDropSession) -> UUID? {
        guard session.items.count == 1,
              let payload = session.localDragSession?.localContext as? PromptWordDragPayload,
              let item = session.items.first?.localObject as? PromptWordDragPayload,
              item.boardID == payload.boardID, item.wordID == payload.wordID,
              payload.boardID == actions.boardID, actions.accepts(payload.wordID) else { return nil }
        return payload.wordID
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        source(session) != nil
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        if source(session) != nil { actions.entered() }
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard source(session) != nil else { return UIDropProposal(operation: .forbidden) }
        actions.entered()
        return UIDropProposal(operation: .move)
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { actions.exited() }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { actions.exited() }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let id = source(session) else { return }
        actions.dropped(id)
    }
}

/// Native interactions on the actual text button avoid List and nested SwiftUI button gestures.
struct PromptNativeChip: UIViewRepresentable {
    let block: PromptBlock
    let boardID: UUID
    let highlighted: Bool
    let dragging: Bool
    let actions: PromptWordDropActions
    let edit: () -> Void
    let delete: () -> Void
    let move: (Int) -> Void
    let lifted: () -> Void
    let ended: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PromptNativeChipView {
        let view = PromptNativeChipView()
        view.textButton.addTarget(context.coordinator, action: #selector(Coordinator.editWord), for: .touchUpInside)
        view.closeButton.addTarget(context.coordinator, action: #selector(Coordinator.deleteWord), for: .touchUpInside)
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true // iPhone drag interactions must be enabled explicitly.
        view.textButton.addInteraction(drag)
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ uiView: PromptNativeChipView, context: Context) {
        _ = dynamicTypeSize; _ = colorScheme
        context.coordinator.parent = self; context.coordinator.actions = actions
        uiView.update(block: block, highlighted: highlighted, dragging: dragging)
        uiView.textButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "前移", target: context.coordinator, selector: #selector(Coordinator.moveEarlier)),
            UIAccessibilityCustomAction(name: "后移", target: context.coordinator, selector: #selector(Coordinator.moveLater))
        ]
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PromptNativeChipView, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: PromptWordDropCoordinator, UIDragInteractionDelegate {
        var parent: PromptNativeChip
        init(_ parent: PromptNativeChip) { self.parent = parent; super.init(actions: parent.actions) }
        @objc func editWord() { parent.edit() }
        @objc func deleteWord() { parent.delete() }
        @objc func moveEarlier() -> Bool { parent.move(-1); return true }
        @objc func moveLater() -> Bool { parent.move(1); return true }
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            guard parent.actions.accepts(parent.block.id) else { return [] }
            let payload = PromptWordDragPayload(boardID: parent.boardID, wordID: parent.block.id)
            session.localContext = payload
            let item = UIDragItem(itemProvider: NSItemProvider(object: parent.block.id.uuidString as NSString))
            item.localObject = payload
            return [item]
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { parent.lifted() }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) { parent.ended() }
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
            guard let view = interaction.view?.superview else { return nil }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 10)
            return UITargetedDragPreview(view: view, parameters: parameters)
        }
    }
}

final class PromptNativeChipView: UIView {
    let textButton = UIButton(type: .system)
    let closeButton = UIButton(type: .system)
    private let weightLabel = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        textButton.contentHorizontalAlignment = .leading
        textButton.titleLabel?.numberOfLines = 2
        textButton.titleLabel?.lineBreakMode = .byTruncatingTail
        textButton.titleLabel?.adjustsFontForContentSizeCategory = true
        weightLabel.adjustsFontForContentSizeCategory = true
        weightLabel.isUserInteractionEnabled = false
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        addSubview(textButton); addSubview(weightLabel); addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(block: PromptBlock, highlighted: Bool, dragging: Bool) {
        textButton.setTitle((block.enabled ? "" : "⏸ ") + block.text, for: .normal)
        textButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        textButton.setTitleColor(block.enabled ? .label : .secondaryLabel, for: .normal)
        textButton.accessibilityLabel = "编辑词块 \(block.text)"
        textButton.accessibilityIdentifier = "promptChip.\(block.text)"
        textButton.accessibilityHint = "轻点打开详细设置，长按拖动排序"
        closeButton.accessibilityLabel = "删除词块 \(block.text)"
        weightLabel.font = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traitCollection)
        weightLabel.text = block.weight == 1 ? nil : PromptBlock.weightText(block.weight)
        weightLabel.textColor = .systemTeal
        backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(block.enabled ? 1 : 0.45)
        layer.borderWidth = highlighted ? 2 : 1
        layer.borderColor = (highlighted ? UIColor.systemTeal : UIColor.tertiaryLabel).resolvedColor(with: traitCollection).cgColor
        alpha = dragging ? 0.45 : 1
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }
    private var badgeWidth: CGFloat { weightLabel.text == nil ? 0 : ceil(weightLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width) + 6 }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let limit = max(1, size.width)
        let reserved: CGFloat = 12 + 32 + badgeWidth
        let available = max(1, limit - reserved)
        let text = textButton.titleLabel?.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)) ?? .zero
        return CGSize(width: min(limit, ceil(text.width) + reserved), height: max(44, ceil(text.height) + 22))
    }
    override var intrinsicContentSize: CGSize { sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let closeWidth = min(32, bounds.width)
        closeButton.frame = CGRect(x: bounds.width - closeWidth, y: 0, width: closeWidth, height: bounds.height)
        let textWidth = max(1, bounds.width - closeWidth - 12 - badgeWidth)
        textButton.frame = CGRect(x: 12, y: 0, width: textWidth, height: bounds.height)
        weightLabel.frame = CGRect(x: textButton.frame.maxX + 4, y: 0, width: max(0, badgeWidth - 6), height: bounds.height)
    }
}

/// Empty category space is also a native drop target, including collapsed groups.
struct PromptCategoryDropZone: UIViewRepresentable {
    let actions: PromptWordDropActions
    func makeCoordinator() -> PromptWordDropCoordinator { PromptWordDropCoordinator(actions: actions) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.actions = actions }
}

@MainActor final class PromptDragHaptics {
    private let lift = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let drop = UIImpactFeedbackGenerator(style: .soft)
    private var lastSelection = 0.0
    func began() {
        lift.prepare(); selection.prepare(); drop.prepare()
        lift.impactOccurred(intensity: 0.7)
        lastSelection = ProcessInfo.processInfo.systemUptime
    }
    func targetChanged() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSelection > 0.07 else { return }
        selection.selectionChanged(); selection.prepare(); lastSelection = now
    }
    func completed() { drop.impactOccurred(intensity: 0.6) }
}
