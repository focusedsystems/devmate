import DevMateCore
import SwiftUI

extension RunNodeState {
    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .running: return "circle.dotted.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped: return "minus.circle"
        case .waiting: return "hand.raised.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .cancelled, .skipped: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .partial, .waiting: return .orange
        case .failed: return .red
        }
    }
}

/// A node's state as a symbol: a hollow circle until it runs, then the
/// colour of how it went.
struct RunStatusIcon: View {
    let state: RunNodeState
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size))
            .foregroundStyle(state.tint)
            .symbolEffect(.pulse, isActive: state == .running)
            .frame(width: size + 3)
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

enum RunTime {
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds.rounded())
        if seconds < 1 { return "<1s" }
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}
