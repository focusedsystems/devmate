import AppKit
import DevMateCore
import SwiftUI

/// A log in a native text view: monospaced, line numbers in a ruler, ANSI and
/// `##[...]` colouring, collapsible groups, clickable addresses and the
/// system find bar. It is read-only; text can be selected and copied.
struct RunLogView: NSViewRepresentable {
    typealias NSViewType = NSScrollView
    let parsed: RunLogParser.Parsed
    let collapsed: Set<Int>
    let identity: String
    let follow: Bool
    let findRequests: Int
    let fontSize: CGFloat
    let onToggleGroup: (Int) -> Void
    let onFollowChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let view = GroupTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = []
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Log")
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.findBarPosition = .aboveContent
        scroll.clipsToBounds = true
        let ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clipsToBounds = true
        ruler.clientView = view
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        context.coordinator.view = view
        context.coordinator.ruler = ruler
        view.onToggle = { [weak coordinator = context.coordinator] id in coordinator?.toggle(id) }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggle = onToggleGroup
        coordinator.onFollowChange = onFollowChange
        guard let view = coordinator.view else { return }
        let key = "\(identity)|\(parsed.lines.count)|\(collapsed.sorted())|\(fontSize)"
        if key != coordinator.renderedKey {
            coordinator.renderedKey = key
            let wasAtBottom = coordinator.isAtBottom()
            let keepOffset = scroll.contentView.bounds.origin
            let sameLog = coordinator.renderedIdentity == identity
            coordinator.renderedIdentity = identity
            let rendered = Self.render(parsed, collapsed: collapsed, fontSize: fontSize)
            view.textStorage?.setAttributedString(rendered.text)
            view.lineStarts = rendered.lineStarts
            view.headerGroups = rendered.headerGroups
            coordinator.ruler?.numbers = rendered.numbers
            coordinator.ruler?.lineStarts = rendered.lineStarts
            coordinator.ruler?.fontSize = fontSize
            view.sizeToFitContent()
            coordinator.ruler?.needsDisplay = true
            if follow && (wasAtBottom || !sameLog) {
                coordinator.scrollToEnd()
            } else if sameLog {
                scroll.contentView.scroll(to: keepOffset)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if findRequests != coordinator.findRequests {
            coordinator.findRequests = findRequests
            if findRequests > 0 { coordinator.showFind() }
        }
    }

    // MARK: Rendering

    struct Rendered {
        var text: NSAttributedString
        var numbers: [Int]
        var lineStarts: [Int]
        var headerGroups: [Int: Int]
    }

    static func render(_ parsed: RunLogParser.Parsed, collapsed: Set<Int>, fontSize: CGFloat) -> Rendered {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let out = NSMutableAttributedString()
        var numbers: [Int] = []
        var starts: [Int] = []
        var headers: [Int: Int] = [:]
        for line in parsed.lines {
            if line.inside.contains(where: collapsed.contains) { continue }
            let isHeader = line.opens != nil
            var text = line.text
            if let opens = line.opens {
                text = (collapsed.contains(opens) ? "\u{25B8} " : "\u{25BE} ") + text
                headers[numbers.count] = opens
            }
            let color = baseColor(line)
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: isHeader ? bold : font, .foregroundColor: color,
            ])
            let shift = line.opens != nil ? 2 : 0
            for span in line.spans {
                let range = NSRange(location: span.location + shift, length: span.length)
                guard NSMaxRange(range) <= attributed.length else { continue }
                if let spanColor = span.style.color { attributed.addAttribute(.foregroundColor, value: nsColor(spanColor), range: range) }
                if span.style.bold { attributed.addAttribute(.font, value: bold, range: range) }
                if span.style.underline { attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            }
            for link in RunLogParser.links(in: text) {
                attributed.addAttribute(.link, value: link.url, range: link.range)
            }
            starts.append(out.length)
            numbers.append(line.number)
            out.append(attributed)
            out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        return Rendered(text: out, numbers: numbers, lineStarts: starts, headerGroups: headers)
    }

    static func baseColor(_ line: RunLogLine) -> NSColor {
        if line.isMarker { return .systemGreen }
        switch line.kind {
        case .plain, .group: return .labelColor
        case .section: return .systemGreen
        case .command: return .systemBlue
        case .warning, .notice: return .systemOrange
        case .error: return .systemRed
        case .debug: return .secondaryLabelColor
        }
    }

    static func nsColor(_ color: RunLogColor) -> NSColor {
        switch color {
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .standard(let index, let bright):
            switch index {
            case 0: return bright ? .systemGray : .labelColor
            case 1: return .systemRed
            case 2: return .systemGreen
            case 3: return .systemYellow
            case 4: return bright ? .systemCyan : .systemBlue
            case 5: return .systemPink
            case 6: return .systemTeal
            default: return bright ? .labelColor : .secondaryLabelColor
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scroll: NSScrollView?
        weak var view: GroupTextView?
        weak var ruler: LineNumberRuler?
        var renderedKey = ""
        var renderedIdentity = ""
        var findRequests = 0
        var onToggle: (Int) -> Void = { _ in }
        var onFollowChange: (Bool) -> Void = { _ in }
        private var programmatic = false

        func toggle(_ id: Int) { onToggle(id) }

        func isAtBottom() -> Bool {
            guard let scroll, let document = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= document.frame.height - 24
        }

        func scrollToEnd() {
            guard let scroll, let document = scroll.documentView else { return }
            programmatic = true
            let y = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            programmatic = false
        }

        @objc func scrolled() {
            ruler?.needsDisplay = true
            guard !programmatic else { return }
            onFollowChange(isAtBottom())
        }

        func showFind() {
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            let item = NSMenuItem()
            item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            view.performFindPanelAction(item)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

/// The text view: a click on a group's arrow opens or closes the group.
final class GroupTextView: NSTextView {
    var lineStarts: [Int] = []
    var headerGroups: [Int: Int] = [:]
    var onToggle: ((Int) -> Void)?

    func sizeToFitContent() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = max(used.width + textContainerInset.width * 2 + 24, enclosingScrollView?.contentSize.width ?? 0)
        let height = max(used.height + textContainerInset.height * 2, enclosingScrollView?.contentSize.height ?? 0)
        setFrameSize(NSSize(width: width, height: height))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let line = lineIndex(of: index), let group = headerGroups[line], index - lineStarts[line] <= 1 {
            onToggle?(group)
            return
        }
        super.mouseDown(with: event)
    }

    func lineIndex(of location: Int) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Line numbers beside the text, as the log's own numbering: a collapsed
/// group leaves a gap in the sequence.
final class LineNumberRuler: NSRulerView {
    var numbers: [Int] = [] { didSet { updateThickness() } }
    var lineStarts: [Int] = []
    var fontSize: CGFloat = 11

    private func updateThickness() {
        let digits = max(3, String(numbers.last ?? 0).count)
        ruleThickness = CGFloat(digits) * fontSize * 0.62 + 18
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer,
              let scroll = scrollView, !lineStarts.isEmpty else { return }
        // A view does not clip to its bounds by default, so the rect asked
        // for can reach past the ruler; filling all of it paints over the
        // rest of the window.
        NSColor.textBackgroundColor.setFill()
        rect.intersection(bounds).fill()
        let visible = scroll.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characters.location { low = mid } else { high = mid - 1 }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var index = low
        while index < lineStarts.count, lineStarts[index] <= NSMaxRange(characters) {
            let glyph = layout.glyphIndexForCharacter(at: lineStarts[index])
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = fragment.minY + view.textContainerInset.height - visible.minY
            let label = String(numbers[index]) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            index += 1
        }
    }
}
