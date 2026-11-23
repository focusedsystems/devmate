import AppKit
import SwiftUI

/// A list beside a detail pane with a draggable divider. The detail opens at
/// `fraction` of the width and slides in and out. While the divider is being
/// dragged only this view updates, and the fraction is saved when it is let go.
public struct DetailSplitView<Leading: View, Trailing: View>: View {
    @Binding var fraction: Double
    let showsDetail: Bool
    let minLeading: CGFloat
    let minTrailing: CGFloat
    let leading: () -> Leading
    let trailing: () -> Trailing

    @State private var dragFraction: Double?
    @State private var dragStart: Double?
    @State private var hoveringDivider = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(fraction: Binding<Double>, showsDetail: Bool, minLeading: CGFloat = 380, minTrailing: CGFloat = 440,
                @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        _fraction = fraction
        self.showsDetail = showsDetail
        self.minLeading = minLeading
        self.minTrailing = minTrailing
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let detail = showsDetail ? Self.detailWidth(total: total, fraction: dragFraction ?? fraction,
                                                        minLeading: minLeading, minTrailing: minTrailing) : 0
            HStack(spacing: 0) {
                leading()
                    .frame(width: max(total - detail - (showsDetail ? 1 : 0), 0))
                    .clipped()
                if showsDetail {
                    divider(total: total)
                    trailing()
                        .frame(width: detail)
                        .clipped()
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: showsDetail)
        }
        .onDisappear(perform: endHover)
    }

    static func detailWidth(total: CGFloat, fraction: Double, minLeading: CGFloat, minTrailing: CGFloat) -> CGFloat {
        let upper = max(total - minLeading, minTrailing)
        return min(max(total * fraction, minTrailing), upper)
    }

    private func endHover() {
        if hoveringDivider { NSCursor.pop() }
        hoveringDivider = false
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                guard inside != hoveringDivider else { return }
                hoveringDivider = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear(perform: endHover)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        let start = dragStart ?? fraction
                        dragStart = start
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            dragFraction = min(max(start - value.translation.width / total, 0.1), 0.9)
                        }
                    }
                    .onEnded { _ in
                        if let dragFraction { fraction = dragFraction }
                        dragFraction = nil
                        dragStart = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Detail width")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: fraction = min(fraction + 0.05, 0.9)
                case .decrement: fraction = max(fraction - 0.05, 0.1)
                @unknown default: break
                }
            }
    }
}
