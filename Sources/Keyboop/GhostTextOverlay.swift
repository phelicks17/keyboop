import AppKit

/// Серый «призрачный» текст подсказки справа от каретки (docs/inline-prediction.md).
///
/// Это наложение поверх чужого окна, а не текст в поле: панель не активируется, не берёт фокус и
/// пропускает мышь насквозь, поэтому печатать человеку она не мешает ничем. Фон полупрозрачный,
/// чтобы подсказку было видно и на тёмном, и на светлом поле.
final class GhostTextOverlay {
    static let shared = GhostTextOverlay()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let keyHint = NSTextField(labelWithString: "")

    var isVisible: Bool { panel.isVisible }

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byClipping
        keyHint.textColor = .quaternaryLabelColor
        keyHint.font = .systemFont(ofSize: 10, weight: .medium)
        let stack = NSStackView(views: [label, keyHint])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        panel.contentView = box
    }

    /// `caret` — прямоугольник каретки в Cocoa-координатах (CaretLocator). Шрифт подбираем по его
    /// высоте: точный шрифт чужого поля AX не отдаёт, а высота строки близка к кеглю × 1,2.
    func show(_ text: String, at caret: NSRect, keyName: String) {
        let size = min(28, max(11, caret.height / 1.2))
        label.font = .systemFont(ofSize: size)
        label.stringValue = text
        keyHint.stringValue = keyName
        panel.contentView?.layoutSubtreeIfNeeded()
        let fit = panel.contentView?.fittingSize ?? .zero
        let height = max(caret.height, fit.height)
        var frame = NSRect(x: caret.maxX + 1, y: caret.midY - height / 2, width: fit.width, height: height)
        // Не уезжаем за правый край экрана каретки: лучше перекрыть кусок поля, чем пропасть.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) {
            frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
