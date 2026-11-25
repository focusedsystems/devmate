import DevMateCore
import SwiftUI

/// Runs across the repositories, with re-run, cancel, the log and open in
/// browser. While a run is going, the list reads itself again every thirty
/// seconds.
struct DevPipelinesView: View {
    @ObservedObject var model: DevelopmentModel
    @State private var logRun: DevPipelineRun?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                if model.runs.value.contains(where: { !$0.isFinished }) { model.loadRuns(force: true) }
            }
        }
        .sheet(item: $logRun) { run in DevRunSheet(model: model, run: run) }
        .confirmationDialog("Cancel this run?", isPresented: cancelPresented, titleVisibility: .visible,
                            presenting: model.pendingCancel) { _ in
            Button("Cancel Run", role: .destructive) { model.confirmCancel() }
            Button("Keep Running", role: .cancel) { model.pendingCancel = nil }
        } message: { run in
            Text("\(run.pipeline) in \(run.repo) stops where it is.")
        }
    }

    private var cancelPresented: Binding<Bool> {
        Binding(get: { model.pendingCancel != nil }, set: { if !$0 { model.pendingCancel = nil } })
    }

    private var table: some View {
        let rows = model.visibleRuns
        return Table(rows, selection: $model.selectedRun) {
            TableColumn("Status") { (run: DevPipelineRun) in DevRunStateLabel(run: run) }
                .width(min: 90, ideal: 110)
            TableColumn("Workflow") { (run: DevPipelineRun) in
                Text(run.pipeline).appFont(.body).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Run") { (run: DevPipelineRun) in
                Text(run.title).appFont(.body).lineLimit(1).help(run.title)
            }
            .width(min: 160, ideal: 320)
            TableColumn("Repository") { (run: DevPipelineRun) in
                Text(run.repo).appFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Branch") { (run: DevPipelineRun) in
                Text(run.branch ?? "").appFont(.body, design: .monospaced).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Event") { (run: DevPipelineRun) in
                Text(run.event ?? "").appFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Started") { (run: DevPipelineRun) in
                Text(DevWeb.relative(run.startedAt)).appFont(.body).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Duration") { (run: DevPipelineRun) in
                Text(DevWeb.duration(run.duration())).appFont(.body).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: DevPipelineRun.ID.self) { ids in
            if let run = rows.first(where: { ids.contains($0.id) }) { runMenu(run) }
        } primaryAction: { ids in
            if let run = rows.first(where: { ids.contains($0.id) }) { logRun = run }
        }
        .onCopyCommand {
            guard let run = model.run else { return [] }
            return [NSItemProvider(object: run.url as NSString)]
        }
        .overlay { if rows.isEmpty { emptyState } }
        .overlay(alignment: .bottomTrailing) {
            DevLoadFooter(isLoading: model.runs.isLoading, loadedAt: model.runs.loadedAt,
                          errors: model.runs.errors, count: "\(rows.count) runs")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Status", selection: $model.runStateFilter) {
                Text("All Runs").tag(DevPipelineRun.State?.none)
                ForEach(DevPipelineRun.State.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .frame(width: 200)
            Spacer()
            if let run = model.run {
                Button("View Log") { logRun = run }
                Button("Copy Log") { model.copyLog(of: run) }
                    .help("Copy the log with the run's details")
                if model.slots.sendRunToAgent != nil {
                    Button("Send to Agent") { model.sendToAgent(run) }
                        .help("Send what failed and the log's last lines to the agent in this repository")
                }
                Button("Re-run") { model.rerun(run, failedOnly: false) }
                    .disabled(!run.isFinished || model.isBusy(run))
                    .help("Run every job of this run again")
                Button("Re-run Failed Jobs") { model.rerun(run, failedOnly: true) }
                    .disabled(run.state != .failed || model.isBusy(run))
                Button("Cancel Run…") { model.requestCancel(run) }
                    .disabled(run.isFinished || model.isBusy(run))
                Button("Open in Browser") { DevWeb.open(run.url) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func runMenu(_ run: DevPipelineRun) -> some View {
        Button("View Log") { logRun = run }
        Button("Open in Browser") { DevWeb.open(run.url) }
        Divider()
        Button("Re-run") { model.rerun(run, failedOnly: false) }
            .disabled(!run.isFinished || model.isBusy(run))
        Button("Re-run Failed Jobs") { model.rerun(run, failedOnly: true) }
            .disabled(run.state != .failed || model.isBusy(run))
        Button("Cancel Run…") { model.requestCancel(run) }
            .disabled(run.isFinished || model.isBusy(run))
        Divider()
        Button("Copy Log") { model.copyLog(of: run) }
        if model.slots.sendRunToAgent != nil {
            Button("Send to Agent") { model.sendToAgent(run) }
        }
        Button("Copy Link") { DevWeb.copy(run.url) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.runs.isLoading {
            ProgressView("Reading runs…")
        } else {
            ContentUnavailableView("No Runs", systemImage: "gearshape.2", description: Text("No runs match."))
        }
    }
}

struct DevRunStateLabel: View {
    let run: DevPipelineRun

    var body: some View {
        Label {
            Text(run.state.rawValue).appFont(.body)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .help(run.detail)
    }

    private var symbol: String {
        switch run.state {
        case .running: return "circle.dotted.circle"
        case .queued: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .needsAction: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private var color: Color {
        switch run.state {
        case .running, .queued: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .needsAction: return .orange
        case .cancelled, .skipped: return .secondary
        }
    }
}

private struct DevRunLogSheet: View {
    @ObservedObject var model: DevelopmentModel
    let run: DevPipelineRun
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).appFont(.headline).lineLimit(1)
                    Text("\(run.repo) · \(run.pipeline)").appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Copy Log") { DevWeb.copy(RunReport.copy(run, log: text)) }
                    .disabled(text.isEmpty)
                    .help("Copy the whole log with the run's details; select text to copy part of it")
                if model.slots.sendRunToAgent != nil {
                    Button("Send to Agent") { model.sendToAgent(run, log: text); dismiss() }
                        .disabled(text.isEmpty)
                        .help("Send what failed and the log's last lines to the agent in this repository")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let problem {
                ContentUnavailableView("No Log", systemImage: "doc.text", description: Text(problem))
            } else {
                DevLogTextView(text: text)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            do {
                text = try await model.log(of: run)
            } catch {
                problem = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// A run opened from the list: the stages, jobs and steps with the selected
/// one's log when the host can show them, else the run's one log.
private struct DevRunSheet: View {
    @ObservedObject var model: DevelopmentModel
    let run: DevPipelineRun
    private let usesOutline: Bool
    @StateObject private var detail: RunDetailModel
    @Environment(\.dismiss) private var dismiss

    init(model: DevelopmentModel, run: DevPipelineRun) {
        self.model = model
        self.run = run
        let provider = model.runDetailProvider(for: run)
        usesOutline = provider != nil
        _detail = StateObject(wrappedValue: RunDetailModel(provider: provider ?? NoRunDetail(),
                                                           runName: "\(run.pipeline) \(run.title)"))
    }

    var body: some View {
        if usesOutline {
            RunDetailView(model: detail) { header }
                .frame(minWidth: 960, minHeight: 600)
        } else {
            DevRunLogSheet(model: model, run: run)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            DevRunStateLabel(run: run).labelStyle(.iconOnly).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).appFont(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(run.repo) \u{00B7} \(run.pipeline)")
                    if let branch = run.branch { Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon) }
                    if let duration = run.duration() { Text(DevWeb.duration(duration)).monospacedDigit() }
                }
                .appFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel Run\u{2026}") { model.requestCancel(run) }
                .disabled(run.isFinished || model.isBusy(run))
            Button("Re-run") { model.rerun(run, failedOnly: false) }
                .disabled(!run.isFinished || model.isBusy(run))
            Button("Copy Link") { DevWeb.copy(run.url) }
            Button("Open in Browser") { DevWeb.open(run.url) }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(12)
    }
}

private struct NoRunDetail: RunDetailProvider {
    func timeline() async throws -> RunTimeline { RunTimeline() }
    func log(job: RunJob, step: RunStep?) async throws -> String { "" }
}
