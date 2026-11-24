import SwiftUI

/// The Development views in the toolbar: one capsule with the open view
/// filled, every view named at every width.
struct DevSegmentBar: View {
    @Binding var selection: DevelopmentModel.Segment
    let segments: [DevelopmentModel.Segment]

    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.self) { segment in
                let isOn = selection == segment
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { selection = segment }
                } label: {
                    Text(segment.title)
                        .appFont(fixed: 12, weight: isOn ? .semibold : .regular)
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if isOn {
                                Capsule().fill(.primary.opacity(0.15))
                                    .matchedGeometryEffect(id: "segment", in: space)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(segment.title)
                .accessibilityLabel(segment.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Development View")
    }
}
