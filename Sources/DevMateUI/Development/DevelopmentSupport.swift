import DevMateCore
import DevMateGit
import SwiftUI

private struct AppFontModifier: ViewModifier {
    @Environment(\.devMateFontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(.system(size: (size * CGFloat(scale)).rounded(), weight: weight ?? .regular, design: design ?? .default))
    }
}

extension View {
    func appFont(_ style: DevTextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(AppFontModifier(size: style.size, weight: weight ?? style.weight, design: design))
    }

    func appFont(fixed size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(size: size, weight: weight, design: design))
    }
}

extension EnvironmentValues {
    var appFontScale: Double { devMateFontScale }
}

/// Title and icon when there is room, icon only when there isn't. The title
/// stays the accessibility label either way.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

extension DevRepo {
    /// The checkout's absolute path.
    var localPath: String { GitPaths.expand(path) }
    func checkout(_ withheld: WithheldPaths) -> GitCheckout {
        GitCheckout(id: id, displayName: name, path: localPath, withheld: withheld)
    }
}

/// Views an app adds to the Repos workspace, such as agent actions. DevMate
/// knows nothing about what they do.
@MainActor
public struct RepoWorkspaceSlots {
    public var repositoryMenu: (DevRepo) -> AnyView
    public var fileMenu: (DevRepo, String) -> AnyView
    /// Folders this app must never show, search, stash or commit, whatever
    /// `.gitignore` says.
    public var withheld: WithheldPaths

    public init(repositoryMenu: @escaping (DevRepo) -> AnyView = { _ in AnyView(EmptyView()) },
                fileMenu: @escaping (DevRepo, String) -> AnyView = { _, _ in AnyView(EmptyView()) },
                withheld: WithheldPaths = .none) {
        self.repositoryMenu = repositoryMenu
        self.fileMenu = fileMenu
        self.withheld = withheld
    }
}
