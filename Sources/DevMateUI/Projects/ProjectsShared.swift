import AppKit
import DevMateCore
@preconcurrency import MarkdownUI
import SwiftUI

// MARK: Text size

private struct DevMateFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// Multiplies every size in DevMate's views, for an app with its own zoom.
    public var devMateFontScale: Double {
        get { self[DevMateFontScaleKey.self] }
        set { self[DevMateFontScaleKey.self] = newValue }
    }
}

enum DevTextStyle {
    case title3, headline, body, callout, subheadline, footnote, caption

    var size: CGFloat {
        switch self {
        case .title3: return 16
        case .headline: return 14
        case .body, .callout: return 13
        case .subheadline: return 12
        case .footnote, .caption: return 11
        }
    }

    var weight: Font.Weight { self == .headline ? .semibold : .regular }
}

private struct DevFontModifier: ViewModifier {
    @Environment(\.devMateFontScale) private var scale
    let style: DevTextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: (style.size * CGFloat(scale)).rounded(), weight: weight ?? style.weight))
    }
}

extension View {
    func devFont(_ style: DevTextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(DevFontModifier(style: style, weight: weight))
    }
}

// MARK: Markdown

/// Provider Markdown. Text can be selected and copied, a link opens only when
/// it is http(s), and an image loads only when the provider allows its address.
struct WorkMarkdown: View {
    let content: String
    let provider: any ProjectsProvider
    var emptyText = "No description."

    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(emptyText).devFont(.body).foregroundStyle(.secondary)
        } else {
            let allows: @Sendable (URL?) -> Bool = { [provider] in provider.allowsImage($0) }
            Markdown(content)
                .markdownTheme(.basic)
                .markdownImageProvider(AllowlistedImageProvider(allows: allows, note: provider.vocabulary.imagePolicyNote))
                .markdownInlineImageProvider(AllowlistedInlineImageProvider(allows: allows))
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction(url) : .discarded
                })
        }
    }
}

/// Any image the provider does not allow shows a placeholder naming its host,
/// so an issue cannot plant a tracking pixel.
struct AllowlistedImageProvider: ImageProvider {
    let allows: @Sendable (URL?) -> Bool
    let note: String

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if allows(url) {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            Label("Image not loaded\(url?.host.map { " (\($0))" } ?? "")", systemImage: "photo")
                .devFont(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .help(note)
        }
    }
}

struct AllowlistedInlineImageProvider: InlineImageProvider {
    struct Blocked: Error {}
    let allows: @Sendable (URL?) -> Bool

    func image(with url: URL, label: String) async throws -> Image {
        guard allows(url) else { throw Blocked() }
        return try await DefaultInlineImageProvider.default.image(with: url, label: label)
    }
}

// MARK: Small views

struct TagChip: View {
    let tag: WorkTag

    var body: some View {
        Text(tag.name)
            .devFont(.caption, weight: .medium)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(TagColor.color(tag.color) ?? Color.secondary.opacity(0.25), in: Capsule())
            .foregroundStyle(TagColor.readable(on: tag.color))
            .help(tag.description ?? tag.name)
            .accessibilityLabel(tag.name)
    }
}

enum TagColor {
    static func rgb(_ hex: String?) -> (Double, Double, Double)? {
        guard var hex else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func color(_ hex: String?) -> Color? {
        rgb(hex).map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }

    /// Black on light colours, white on dark ones.
    static func readable(on hex: String?) -> Color {
        guard let (r, g, b) = rgb(hex) else { return .primary }
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6 ? .black : .white
    }
}

struct WorkStateIcon: View {
    let item: WorkItem

    private var symbol: String {
        if item.isOpen { return "smallcircle.filled.circle" }
        return item.resolution == .notPlanned ? "slash.circle" : "checkmark.circle"
    }

    private var tint: Color {
        if item.isOpen { return .green }
        return item.resolution == .notPlanned ? .secondary : .purple
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .accessibilityLabel(item.stateName)
    }
}

/// A dismissible line saying something failed.
struct ProjectsErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).devFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { self.message = nil }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Says a card went back, with Try Again.
struct MoveFailureBanner: View {
    @ObservedObject var model: ProjectsModel

    var body: some View {
        if let failure = model.moveFailure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(failure.title)” could not move to \(failure.destination), so it went back.")
                        .devFont(.callout, weight: .medium)
                    Text(failure.message).devFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try Again") { model.retryFailedMove() }
                Button("Dismiss") { model.moveFailure = nil }
            }
            .padding(10)
            .background(Color.red.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}

struct ProjectsLoadFooter: View {
    let isLoading: Bool
    let loadedAt: Date?
    let errors: [String]
    let count: String

    var body: some View {
        HStack(spacing: 6) {
            if isLoading { ProgressView().controlSize(.small) }
            if !errors.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(errors.joined(separator: "\n"))
                    .accessibilityLabel("Some could not be read")
            }
            Text(text).devFont(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private var text: String {
        var parts = [count]
        if let loadedAt { parts.append("updated \(loadedAt.formatted(date: .omitted, time: .shortened))") }
        else if isLoading { parts.append("reading…") }
        if !errors.isEmpty { parts.append("\(errors.count) not read") }
        return parts.joined(separator: " · ")
    }
}

enum WorkTime {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum WorkLinks {
    static func open(_ address: String?) {
        guard let address, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String, url: String? = nil) {
        let board = NSPasteboard.general
        board.clearContents()
        if let url, let link = URL(string: url) { board.writeObjects([link as NSURL]) }
        board.setString(text, forType: .string)
    }
}
