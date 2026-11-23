import DevMateCore
import SwiftUI

/// Columns of cards: a provider board's columns, or the filtered items
/// grouped. Cards drag between columns, and "Move to" does the same from the
/// keyboard, the menu bar and VoiceOver.
struct WorkBoardView: View {
    @ObservedObject var model: ProjectsModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if let id = model.boardID {
                    if let board = model.displayedBoard, board.id == id {
                        ForEach(board.columns) { column in
                            providerColumn(column, board: board)
                        }
                    } else {
                        ProgressView("Reading the board…").padding(40)
                    }
                } else {
                    let columns = model.grouping.columns(for: model.visible, vocabulary: model.vocabulary)
                    ForEach(columns) { column in
                        groupedColumn(column)
                    }
                }
            }
            .padding(12)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { model.moveBoardSelection($0) }
        .accessibilityLabel("Board")
    }

    private func providerColumn(_ column: WorkBoardColumn, board: WorkBoard) -> some View {
        let cards = board.cards(in: column.id).filter { card in
            guard let id = card.itemID, let item = model.displayedItems.first(where: { $0.id == id }) else {
                return model.query.container == nil || card.container == model.query.container
            }
            return model.query.matches(item)
        }
        return BoardColumnView(model: model, title: column.name, count: cards.count, columnID: column.id,
                               acceptsDrops: column.acceptsDrops) {
            ForEach(cards) { card in
                let drag = WorkCardDrag(boardKey: model.dragBoardKey, cardID: card.id, columnKey: column.id,
                                        title: card.title, url: card.url)
                let targets = model.moveTargets(forCard: card, on: board)
                if let id = card.itemID, let item = model.displayedItems.first(where: { $0.id == id }) {
                    ItemCard(model: model, item: item, cardID: card.id, drag: drag, targets: targets) { target in
                        model.moveCard(card.id, on: board.id, to: target.id)
                    }
                } else {
                    PlainCard(model: model, card: card, drag: drag, targets: targets) { target in
                        model.moveCard(card.id, on: board.id, to: target.id)
                    }
                }
            }
        }
    }

    private func groupedColumn(_ column: WorkItemColumn) -> some View {
        BoardColumnView(model: model, title: column.name, count: column.items.count, columnID: column.id,
                        acceptsDrops: model.canMoveGroupedCards) {
            ForEach(column.items) { item in
                let drag = WorkCardDrag(boardKey: model.dragBoardKey, cardID: item.id, columnKey: column.key,
                                        title: item.title, url: item.url)
                ItemCard(model: model, item: item, cardID: item.id, drag: drag,
                         targets: model.moveTargets(forItem: item, inColumn: column.key)) { target in
                    model.moveGrouped(item, from: column.key, toColumn: target.id)
                }
            }
        }
    }
}

private struct BoardColumnView<Content: View>: View {
    @ObservedObject var model: ProjectsModel
    let title: String
    let count: Int
    let columnID: String
    let acceptsDrops: Bool
    @ViewBuilder let content: () -> Content
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).devFont(.headline).lineLimit(1)
                Text("\(count)").devFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.bottom, 40)
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isTargeted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: WorkCardDrag.self) { drags, _ in
            guard acceptsDrops, let drag = drags.first else { return false }
            return model.drop(drag, onColumn: columnID)
        } isTargeted: { over in
            isTargeted = over && acceptsDrops
        }
    }
}

/// A card for a work item in the loaded list.
private struct ItemCard: View {
    @ObservedObject var model: ProjectsModel
    let item: WorkItem
    let cardID: String
    let drag: WorkCardDrag
    let targets: [BoardMoveTarget]
    let move: (BoardMoveTarget) -> Void

    private var isSelected: Bool { model.selectedItemID == item.id }
    private var isPending: Bool { model.isPending(cardID: cardID) }
    private var didFail: Bool { model.moveFailure?.cardID == cardID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WorkStateIcon(item: item)
                Text(item.title).devFont(.body, weight: .medium).lineLimit(3)
                Spacer(minLength: 0)
                if isPending { ProgressView().controlSize(.mini) }
            }
            Text("\(item.container) #\(item.number)").devFont(.caption).foregroundStyle(.secondary)
            if !item.tags.isEmpty {
                HStack(spacing: 4) { ForEach(item.tags.prefix(4)) { TagChip(tag: $0) } }
            }
            if !item.people.isEmpty {
                Label(item.people.map(\.id).joined(separator: ", "), systemImage: "person")
                    .devFont(.caption).foregroundStyle(.secondary)
            }
        }
        .modifier(CardChrome(isSelected: isSelected, didFail: didFail))
        .opacity(isPending ? 0.65 : 1)
        .onTapGesture { model.selectedItemID = item.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { WorkLinks.open(item.url) })
        .contextMenu {
            MoveToMenu(targets: targets, move: move)
            WorkItemMenuItems(model: model, item: item)
        }
        .draggable(drag) { CardDragPreview(title: item.title) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedItemID = item.id }
        .modifier(MoveAccessibilityActions(targets: targets, move: move))
    }
}

/// A card with no item in the list, such as a draft.
private struct PlainCard: View {
    @ObservedObject var model: ProjectsModel
    let card: WorkBoardCard
    let drag: WorkCardDrag
    let targets: [BoardMoveTarget]
    let move: (BoardMoveTarget) -> Void

    private var isPending: Bool { model.isPending(cardID: card.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title).devFont(.body, weight: .medium).lineLimit(3)
                Spacer(minLength: 0)
                if isPending { ProgressView().controlSize(.mini) }
            }
            Text(card.subtitle).devFont(.caption).foregroundStyle(.secondary)
        }
        .modifier(CardChrome(isSelected: false, didFail: model.moveFailure?.cardID == card.id))
        .opacity(isPending ? 0.65 : 1)
        .contextMenu {
            MoveToMenu(targets: targets, move: move)
            if let url = card.url { Button("Open in Browser") { WorkLinks.open(url) } }
        }
        .draggable(drag) { CardDragPreview(title: card.title) }
        .accessibilityElement(children: .combine)
        .modifier(MoveAccessibilityActions(targets: targets, move: move))
    }
}

private struct CardChrome: ViewModifier {
    let isSelected: Bool
    let didFail: Bool

    private var stroke: Color {
        if didFail { return .red }
        return isSelected ? .accentColor : Color(nsColor: .separatorColor)
    }

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stroke, lineWidth: isSelected || didFail ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CardDragPreview: View {
    let title: String

    var body: some View {
        Text(title)
            .devFont(.body, weight: .medium)
            .lineLimit(2)
            .padding(8)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MoveToMenu: View {
    let targets: [BoardMoveTarget]
    let move: (BoardMoveTarget) -> Void

    var body: some View {
        if !targets.isEmpty {
            Menu("Move to") {
                ForEach(targets) { target in
                    Button(target.name) { move(target) }
                        .disabled(target.isCurrent)
                }
            }
            Divider()
        }
    }
}

/// "Move to <column>" as a VoiceOver action on the card.
private struct MoveAccessibilityActions: ViewModifier {
    let targets: [BoardMoveTarget]
    let move: (BoardMoveTarget) -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(targets.filter { !$0.isCurrent }) { target in
                Button("Move to \(target.name)") { move(target) }
            }
        }
    }
}
