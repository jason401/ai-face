// The face picker: a grid of every mood (recent picks first, then the groups), opened by
// clicking the big face at the top of the menu. The hovered face's name shows at the bottom.
import Cocoa

/// A face in the grid; tells the picker when the mouse is over it.
final class FaceButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

final class FacePicker: NSViewController {
    static let cell: CGFloat = 40, gap: CGFloat = 4, columns = 7, margin: CGFloat = 12

    let sections: [(String, [[String: Any]])]
    let current: String
    let icon: ([String: Any]) -> NSImage?
    let choose: (String) -> Void
    private let hint = NSTextField(labelWithString: "")

    init(sections: [(String, [[String: Any]])], current: String,
         icon: @escaping ([String: Any]) -> NSImage?, choose: @escaping (String) -> Void) {
        self.sections = sections
        self.current = current
        self.icon = icon
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func loadView() {
        let C = FacePicker.cell, G = FacePicker.gap, M = FacePicker.margin, N = FacePicker.columns
        let width = M * 2 + CGFloat(N) * C + CGFloat(N - 1) * G
        let doc = FlippedView()
        var y = M
        for (title, moods) in sections where !moods.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: M, y: y, width: width - M * 2, height: 15)
            doc.addSubview(label)
            y += 19
            for (i, mood) in moods.enumerated() {
                guard let id = mood["id"] as? String else { continue }
                let b = FaceButton(frame: NSRect(x: M + CGFloat(i % N) * (C + G), y: y + CGFloat(i / N) * (C + G),
                                                 width: C, height: C))
                b.isBordered = false
                b.image = icon(mood)
                b.imageScaling = .scaleProportionallyUpOrDown
                b.title = ""
                b.toolTip = mood["name"] as? String
                b.identifier = NSUserInterfaceItemIdentifier(id)
                b.target = self
                b.action = #selector(picked(_:))
                b.wantsLayer = true
                b.layer?.cornerRadius = 8
                if id == current { b.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor }
                let name = (mood["name"] as? String) ?? id
                b.onHover = { [weak self, weak b] inside in
                    self?.hint.stringValue = inside ? name : ""
                    if id != self?.current {
                        b?.layer?.backgroundColor = inside ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
                    }
                }
                doc.addSubview(b)
            }
            y += CGFloat((moods.count + N - 1) / N) * (C + G) + 8
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: y + M - 8)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let visible = min(doc.frame.height, 380)
        scroll.frame = NSRect(x: 0, y: 28, width: width, height: visible)
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: M, y: 6, width: width - M * 2, height: 16)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: visible + 28))
        root.addSubview(scroll)
        root.addSubview(hint)
        view = root
        preferredContentSize = root.frame.size
    }

    @objc private func picked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        choose(id)
    }
}
