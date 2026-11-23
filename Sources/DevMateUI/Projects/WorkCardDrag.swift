import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// An app that shows board cards declares this in `UTExportedTypeDeclarations`
    /// (conforming to `public.data`), so the system recognises the drag.
    public static let devMateWorkCard = UTType(exportedAs: "systems.focused.devmate.work-card")
}

/// A card being dragged. Inside the app it carries which card it is; dragged
/// to another app it is the item's web address, or its title.
///
/// A drop can come from anywhere, so this names a card and nothing more. The
/// model looks the card up on the open board and ignores everything else.
public struct WorkCardDrag: Codable, Hashable, Sendable, Transferable {
    public var boardKey: String
    public var cardID: String
    /// The column it was picked up from, for a card that shows in several.
    public var columnKey: String?
    public var title: String
    public var url: String?

    public init(boardKey: String, cardID: String, columnKey: String?, title: String, url: String?) {
        self.boardKey = boardKey
        self.cardID = cardID
        self.columnKey = columnKey
        self.title = title
        self.url = url
    }

    /// The web address, only when it is http or https.
    public var webURL: URL? {
        guard let url, let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return parsed
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .devMateWorkCard)
        ProxyRepresentation<WorkCardDrag, URL>(exporting: { $0.webURL ?? URL(string: "about:blank")! })
            .exportingCondition { $0.webURL != nil }
        ProxyRepresentation<WorkCardDrag, String>(exporting: { drag in
            drag.webURL.map { "\(drag.title)\n\($0.absoluteString)" } ?? drag.title
        })
    }
}
