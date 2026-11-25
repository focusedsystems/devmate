import DevMateCore
import SwiftUI

/// A run's stages, jobs and steps in a sidebar, and the selected one's log
/// beside it, as the host's web page lays it out. The app supplies the run's
/// header, which sits above both panes.
public struct RunDetailView<Header: View>: View {
    @ObservedObject var model: RunDetailModel
    let header: Header
    @Environment(\.devMateFontScale) private var fontScale
    @AppStorage("devmate.runDetail.sidebarWidth") private var sidebarWidth: Double = 290

    public init(model: RunDetailModel, @ViewBuilder header: () -> Header) {
        self.model = model
        self.header = header()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                RunOutlineList(model: model)
                    .frame(width: sidebarWidth)
                RunSplitHandle(width: $sidebarWidth)
                RunLogPane(model: model, fontScale: fontScale)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
        .focusedSceneValue(\.runDetailModel, model)
        .task { await model.run() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .rawLog(let title, let text): RawLogSheet(title: title, text: text)
            case .taskInputs(let title, let rows): TaskInputsSheet(title: title, rows: rows)
            }
        }
    }
}

extension RunDetailView where Header == EmptyView {
    public init(model: RunDetailModel) {
        self.init(model: model) { EmptyView() }
    }
}

// MARK: - Snapshots

/// How the log is drawn. Snapshot tools draw the view twice, once with the
/// log left blank, because a window that is never shown does not paint
/// SwiftUI around a text view; they lay the second drawing over the first.
public enum RunLogRendering: Sendable {
    case native, blank
}

private struct RunLogRenderingKey: EnvironmentKey {
    static let defaultValue = RunLogRendering.native
}

public extension EnvironmentValues {
    var runLogRendering: RunLogRendering {
        get { self[RunLogRenderingKey.self] }
        set { self[RunLogRenderingKey.self] = newValue }
    }
}

// MARK: - Divider

/// The line between the outline and the log. Drag it to resize the outline;
/// the width is remembered.
struct RunSplitHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?
    static let range: ClosedRange<Double> = 220...520

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = startWidth ?? width
                            startWidth = base
                            width = min(max(base + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                        }
                        .onEnded { _ in startWidth = nil })
            }
            .accessibilityElement()
            .accessibilityLabel("Outline width")
            .accessibilityAdjustableAction { direction in
                let step = 20.0
                width = min(max(width + (direction == .increment ? step : -step), Self.range.lowerBound), Self.range.upperBound)
            }
    }
}

// MARK: - Sidebar

struct RunOutlineList: View {
    @ObservedObject var model: RunDetailModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.choose($0) })) {
            ForEach(model.timeline.stages) { stage in
                Section {
                    ForEach(stage.jobs) { job in
                        DisclosureGroup(isExpanded: expandedBinding(job.id)) {
                            ForEach(job.steps) { step in
                                StepRow(step: step)
                                    .tag(RunSelection.step(job: job.id, step: step.id))
                                    .contextMenu { rowMenu(.step(job: job.id, step: step.id)) }
                            }
                        } label: {
                            JobRow(job: job)
                                .tag(RunSelection.job(job.id))
                                .contextMenu { rowMenu(.job(job.id)) }
                        }
                    }
                } header: {
                    if !stage.name.isEmpty { StageHeader(stage: stage) }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.leftArrow) { model.collapse(); return .handled }
        .onKeyPress(.rightArrow) { model.expand(); return .handled }
        .overlay { overlay }
        .accessibilityLabel("Stages, jobs and steps")
    }

    @ViewBuilder
    private var overlay: some View {
        if !model.hasLoaded {
            ProgressView("Reading the run\u{2026}")
        } else if let error = model.loadError, model.timeline.stages.isEmpty {
            ContentUnavailableView("Could Not Read the Run", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.timeline.stages.isEmpty {
            ContentUnavailableView("Nothing Has Started", systemImage: "circle.dashed",
                                   description: Text("This run has no jobs yet."))
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.expanded.contains(id) },
                set: { if $0 { model.expanded.insert(id) } else { model.expanded.remove(id) } })
    }

    @ViewBuilder
    private func rowMenu(_ selection: RunSelection) -> some View {
        Button("Show Log") { model.choose(selection) }
        if case .job(let id) = selection {
            Button(model.expanded.contains(id) ? "Collapse" : "Expand") {
                if model.expanded.contains(id) { model.expanded.remove(id) } else { model.expanded.insert(id) }
            }
        }
        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.title(for: selection), forType: .string)
        }
    }
}

private struct StageHeader: View {
    let stage: RunStage

    var body: some View {
        HStack(spacing: 6) {
            RunStatusIcon(state: stage.state, size: 14)
            Text(stage.name).font(.headline).lineLimit(1)
            if stage.state == .waiting { WaitingTag() }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stage \(stage.name), \(stage.state.label)")
    }
}

private struct JobRow: View {
    let job: RunJob

    var body: some View {
        HStack(spacing: 6) {
            RunStatusIcon(state: job.state)
            Text(job.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if job.state == .waiting { WaitingTag() } else { RunDuration(start: job.startedAt, end: job.finishedAt, running: job.state.isActive) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.name), \(job.state.label)")
    }
}

private struct StepRow: View {
    let step: RunStep

    var body: some View {
        HStack(spacing: 6) {
            RunStatusIcon(state: step.state, size: 12)
            Text(step.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if step.state == .waiting { WaitingTag() } else if step.state != .pending {
                RunDuration(start: step.startedAt, end: step.finishedAt, running: step.state.isActive)
            }
        }
        .help(step.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.name), \(step.state.label)")
    }
}

private struct WaitingTag: View {
    var body: some View {
        Text("waiting")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }
}

private struct RunDuration: View {
    let start: Date?
    let end: Date?
    let running: Bool

    var body: some View {
        if running, end == nil, let start {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RunTime.duration(max(0, context.date.timeIntervalSince(start)))).monospacedDigit()
            }
            .font(.callout).foregroundStyle(.secondary)
        } else if let start {
            Text(RunTime.duration(max(0, (end ?? start).timeIntervalSince(start))))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Log pane

struct RunLogPane: View {
    @ObservedObject var model: RunDetailModel
    let fontScale: Double
    @Environment(\.runLogRendering) private var rendering

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if model.selection == nil {
                ContentUnavailableView("No Step Selected", systemImage: "list.bullet.rectangle",
                                       description: Text("Choose a job or step to read its log."))
            } else {
                VStack(spacing: 0) {
                    if let approval = model.approvalForSelection {
                        RunApprovalCard(approval: approval, runName: model.runName) { approve, comment in
                            try await model.respond(to: approval, approve: approve, comment: comment)
                        }
                        .padding(12)
                        Divider()
                    }
                    logBody
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            if let state = model.state(of: model.selection) { RunStatusIcon(state: state, size: 20) }
            Text(model.title(for: model.selection)).font(.title2.weight(.semibold)).lineLimit(1)
            if model.log.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.requestFind() } label: { Label("Find in Log", systemImage: "magnifyingglass") }
                .labelStyle(.iconOnly)
                .help("Find in this log (\u{2318}F)")
                .disabled(model.selection == nil)
            Button("View raw log") { model.showRawLog() }
                .disabled(model.selection == nil || model.log.text.isEmpty)
            Button("View task inputs") { model.showTaskInputs() }
                .disabled(!model.canShowTaskInputs)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var logBody: some View {
        if let error = model.log.error, model.log.text.isEmpty {
            ContentUnavailableView("No Log", systemImage: "doc.text", description: Text(error))
        } else if model.log.text.isEmpty, !model.log.isLoading {
            ContentUnavailableView("No Log Output", systemImage: "doc.text",
                                   description: Text(model.state(of: model.selection) == .pending
                                                     ? "This step has not run." : "This step wrote nothing."))
        } else {
            let parsed = model.parsedLog
            if rendering == .blank {
                Color(nsColor: .textBackgroundColor).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            RunLogView(parsed: parsed, collapsed: model.collapsedGroups,
                       identity: model.log.selection.map { "\($0)" } ?? "", follow: model.follow && model.state(of: model.selection)?.isActive == true,
                       findRequests: model.findRequests, fontSize: (11 * fontScale).rounded(),
                       onToggleGroup: { model.toggleGroup($0) }, onFollowChange: { model.follow = $0 })
            }
        }
    }
}

// MARK: - Sheets

struct RawLogSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Raw log \u{2014} \(title)").font(.headline).lineLimit(1)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            DevLogTextView(text: text)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct TaskInputsSheet: View {
    let title: String
    let rows: [RunDetailModel.TaskRow]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task inputs \u{2014} \(title)").font(.headline).lineLimit(1)
            if rows.isEmpty {
                Text("The host reports nothing about this step's task.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 520)
    }
}

// MARK: - Menu commands

private struct RunDetailModelKey: FocusedValueKey {
    typealias Value = RunDetailModel
}

public extension FocusedValues {
    /// The run view in the focused window, so an app can route its own Back,
    /// Forward and Find commands to it while it has the keyboard.
    var runDetailModel: RunDetailModel? {
        get { self[RunDetailModelKey.self] }
        set { self[RunDetailModelKey.self] = newValue }
    }
}

/// The run view's commands. An app adds this to its scene's `.commands`; the
/// items work while a run's view is the focused one.
public struct RunDetailCommands: Commands {
    @FocusedValue(\.runDetailModel) private var model
    private let navigation: Bool

    /// `navigation` false leaves out Back, Forward and Find in Log, for an
    /// app that already owns Command-[, Command-] and Command-F and routes
    /// them to the run view itself through `FocusedValues.runDetailModel`.
    public init(navigation: Bool = true) {
        self.navigation = navigation
    }

    public var body: some Commands {
        CommandMenu("Run") {
            if navigation {
                Button("Back") { model?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model?.canGoBack != true)
                Button("Forward") { model?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model?.canGoForward != true)
                Divider()
                Button("Find in Log") { model?.requestFind() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model?.selection == nil)
            }
            Button("View Raw Log") { model?.showRawLog() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model?.selection == nil || model?.log.text.isEmpty != false)
            Button("View Task Inputs") { model?.showTaskInputs() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model?.canShowTaskInputs != true)
            Toggle("Follow Running Log", isOn: Binding(get: { model?.follow ?? true }, set: { model?.follow = $0 }))
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button("Expand Job") { model?.expand() }
                .disabled(model?.selection == nil)
            Button("Collapse Job") { model?.collapse() }
                .disabled(model?.selection == nil)
            Button("Expand All Jobs") { model?.expandAll() }
                .disabled(model == nil)
            Button("Collapse All Jobs") { model?.collapseAll() }
                .disabled(model == nil)
            Button("Reload Run") { Task { await model?.reload() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model == nil)
        }
    }
}
