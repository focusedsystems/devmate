import Charts
import SwiftUI

/// The chart text size, following the app's text scale.
enum AppTextStyle {
    static func chartLabel(_ scale: Double) -> Font {
        .system(size: (DevTextStyle.caption.size * CGFloat(scale)).rounded())
    }
}

/// The storage key for whether the Development graphs are hidden.
let developmentGraphsCollapsedKey = "devmate.development.graphsCollapsed"

/// A strip of chart cards, shown or hidden from the Graphs button. With
/// `maxHeight`, a strip taller than that scrolls inside itself rather than
/// pushing the content below it off the screen.
struct WidgetsSection<Content: View>: View {
    var maxHeight: CGFloat?
    @ViewBuilder var content: Content

    /// Development opens on the work itself, so graphs start hidden.
    @AppStorage(developmentGraphsCollapsedKey) private var collapsed = true
    @State private var contentHeight: CGFloat = 0

    init(maxHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                Group {
                    if let maxHeight {
                        ScrollView(.vertical) {
                            rows.background {
                                GeometryReader { geo in
                                    Color.clear.preference(key: WidgetStripHeight.self, value: geo.size.height)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: max(1, min(contentHeight, maxHeight)))
                        .onPreferenceChange(WidgetStripHeight.self) { contentHeight = $0 }
                    } else {
                        rows
                    }
                }
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    private var rows: some View {
        WidgetRowLayout(spacing: 12, minUnitWidth: 240, wraps: true) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct WidgetStripHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Shows or hides the Development graphs.
public struct DevelopmentGraphsButton: View {
    @AppStorage(developmentGraphsCollapsedKey) private var collapsed = true

    public init() {}

    public var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
        } label: {
            Label {
                Text("Graphs")
            } icon: {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(collapsed ? Color.secondary : Color.accentColor)
            }
        }
        .keyboardShortcut("g", modifiers: [.command, .option])
        .help(collapsed ? "Show Graphs (⌥⌘G)" : "Hide Graphs (⌥⌘G)")
        .accessibilityValue(collapsed ? "Hidden" : "Shown")
    }
}

/// How many width units a card takes in `WidgetRowLayout` (default 1).
struct WidgetSpan: LayoutValueKey {
    static let defaultValue = 1
}

extension View {
    func widgetSpan(_ units: Int) -> some View { layoutValue(key: WidgetSpan.self, value: units) }
    /// The card takes a row of its own, whatever the width.
    func widgetFullRow() -> some View { layoutValue(key: WidgetSpan.self, value: WidgetRowLayout.fullRow) }
}

/// A responsive grid for a tab's cards.
///
/// The width is cut into units of at least `minUnitWidth`; a card takes its
/// span of them. Cards keep their order and are split into the fewest rows
/// that hold them, then balanced so every row carries about the same number
/// of units — never a full row followed by one stretched leftover. Each row
/// spans the full width, and every card in a row is offered the row's
/// tallest height, so a row reads as one level band with no holes beside or
/// below its cards.
struct WidgetRowLayout: Layout {
    static let fullRow = 1_000

    var spacing: CGFloat = 12
    var minUnitWidth: CGFloat = 240
    var wraps = true

    private struct Placement { var index: Int; var x: CGFloat; var y: CGFloat; var width: CGFloat; var rowHeight: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> (placements: [Placement], height: CGFloat) {
        guard !subviews.isEmpty else { return ([], 0) }
        let rawSpans = subviews.map { max(1, $0[WidgetSpan.self]) }
        let unitsPerRow = wraps
            ? max(1, Int((width + spacing) / (minUnitWidth + spacing)))
            : rawSpans.filter { $0 < Self.fullRow }.reduce(0, +)
        let rows = WidgetRowPacking.rows(spans: rawSpans, unitsPerRow: max(1, unitsPerRow), fullRow: Self.fullRow)
        let spans = rawSpans.map { min($0, max(1, unitsPerRow)) }

        var placements: [Placement] = []
        var y: CGFloat = 0
        for row in rows {
            let units = row.reduce(0) { $0 + spans[$1] }
            let unitWidth = (width - spacing * CGFloat(row.count - 1)) / CGFloat(max(units, 1))
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            let rowStart = placements.count
            for i in row {
                let w = unitWidth * CGFloat(spans[i])
                let h = subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                placements.append(Placement(index: i, x: x, y: y, width: w))
                rowHeight = max(rowHeight, h)
                x += w + spacing
            }
            for k in rowStart..<placements.count { placements[k].rowHeight = rowHeight }
            y += rowHeight + spacing
        }
        return (placements, max(0, y - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(subviews.count) * (minUnitWidth + spacing)
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for p in arrange(width: bounds.width, subviews: subviews).placements {
            subviews[p.index].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                                    anchor: .topLeading,
                                    proposal: ProposedViewSize(width: p.width, height: p.rowHeight))
        }
    }
}

// MARK: - Chart text

/// A chart legend in the same caption text as the axes, flowing onto more
/// lines rather than shrinking. Entries keep the series order.
struct WidgetChartLegend: View {
    let items: [(label: String, color: Color)]

    var body: some View {
        WidgetFlowLayout(spacing: 10) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.label).appFont(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widget Card

/// A titled card in a Widgets row, sized to its content and capped so a long
/// chart never turns the strip into the page.
struct WidgetCard<Content: View>: View {
    let title: String
    var isLoading = false
    var maxHeight: CGFloat = 240
    var onTitle: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let onTitle {
                    Button(action: onTitle) {
                        HStack(spacing: 4) {
                            Text(title).appFont(.subheadline, weight: .bold)
                            Image(systemName: "chevron.right")
                                .appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title).appFont(.subheadline, weight: .bold)
                }
                if isLoading { ProgressView().controlSize(.mini).padding(.leading, 2) }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .clipped()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }
}

struct WidgetEmptyState: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message)
            .appFont(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }
}

struct WidgetFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
