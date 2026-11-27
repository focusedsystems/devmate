import DevMateCore
import SwiftUI

/// One run's outline and log: the stages, jobs and steps on the left, the
/// selected one's log on the right. It reads through a `RunDetailProvider`,
/// reads again every few seconds while anything is still running, and keeps
/// the person's place as they move about, with Back and Forward.
@MainActor
public final class RunDetailModel: ObservableObject {
    public struct LogState: Equatable {
        public var selection: RunSelection?
        public var text = ""
        public var isLoading = false
        public var error: String?
    }

    public let provider: any RunDetailProvider
    /// The run's name and number, for the approval's confirmation.
    public let runName: String
    private let pollInterval: Duration

    @Published public private(set) var timeline = RunTimeline()
    @Published public private(set) var approvals: [RunApproval] = []
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var log = LogState()
    @Published public private(set) var selection: RunSelection?
    @Published public var expanded: Set<String> = []
    /// Follow the end of a running log. Scrolling up stops it; reaching the
    /// end again, or this menu item, starts it.
    @Published public var follow = true
    @Published public var collapsedGroups: Set<Int> = []
    @Published public private(set) var findRequests = 0
    @Published public private(set) var history: [RunSelection] = []
    @Published public private(set) var historyIndex = -1
    @Published public var sheet: Sheet?
    @Published public var actionError: String?

    public enum Sheet: Identifiable {
        case rawLog(title: String, text: String)
        case taskInputs(title: String, rows: [TaskRow])
        public var id: String {
            switch self {
            case .rawLog(let title, _): return "raw-\(title)"
            case .taskInputs(let title, _): return "inputs-\(title)"
            }
        }
    }

    public struct TaskRow: Identifiable {
        public let id = UUID()
        public let name: String
        public let value: String
    }

    /// True until the person picks a row themselves; until then the outline
    /// follows the step that is running or failed.
    private var followsActive = true
    private var cache: [RunSelection: String] = [:]
    private var logTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var parsedKey: String?
    private var parsedValue = RunLogParser.Parsed(lines: [], groups: [])

    public init(provider: any RunDetailProvider, runName: String, pollInterval: Duration = .seconds(5)) {
        self.provider = provider
        self.runName = runName
        self.pollInterval = pollInterval
    }

    deinit {
        logTask?.cancel()
        pollTask?.cancel()
    }

    // MARK: Reading

    /// Reads the run, and keeps reading while it is going. Cancelled with the
    /// view's task.
    public func run() async {
        while !Task.isCancelled {
            await reload()
            guard timeline.isActive || !hasLoaded else { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    public func reload() async {
        do {
            async let reading = provider.timeline()
            async let waiting = (try? await provider.approvals()) ?? []
            let (read, held) = try await (reading, waiting)
            loadError = nil
            approvals = held
            timeline = Self.presented(read, approvals: held)
            hasLoaded = true
            if selection == nil || (followsActive && timeline.isActive) {
                if let next = timeline.activeSelection, next != selection { move(to: next, user: false) }
            }
            if let selection, state(of: selection)?.isActive == true || log.selection != selection {
                loadLog(for: selection, force: true)
            }
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription; hasLoaded = true }
        }
    }

    /// The timeline with approvals shown where they hold the run. One the
    /// timeline has no step for gets a step of its own in its stage.
    static func presented(_ timeline: RunTimeline, approvals: [RunApproval]) -> RunTimeline {
        var result = timeline.marking(waiting: Set(approvals.map { $0.id.lowercased() }))
        let known = Set(result.stages.flatMap(\.jobs).flatMap(\.steps).compactMap { $0.identifier?.lowercased() })
        for approval in approvals where !known.contains(approval.id.lowercased()) {
            let index = result.stages.firstIndex { !$0.name.isEmpty && $0.name == approval.stageName }
                ?? (result.stages.isEmpty ? nil : result.stages.count - 1)
            guard let index else { continue }
            let step = RunStep(id: "approval-\(approval.id)", name: approval.kindTitle, state: .waiting,
                               startedAt: approval.waitingSince, identifier: approval.id)
            if let existing = result.stages[index].jobs.firstIndex(where: { $0.id == "approvals-\(result.stages[index].id)" }) {
                result.stages[index].jobs[existing].steps.append(step)
            } else {
                result.stages[index].jobs.append(RunJob(id: "approvals-\(result.stages[index].id)", name: "Approvals and checks",
                                                        state: .waiting, steps: [step]))
            }
            result.stages[index].state = .waiting
        }
        return result
    }

    // MARK: Selection

    public func selectionNode(_ selection: RunSelection) -> (job: RunJob?, step: RunStep?)? {
        switch selection {
        case .stage: return (nil, nil)
        case .job(let id): return timeline.job(id).map { ($0.job, nil) }
        case .step(let jobID, let stepID):
            guard let job = timeline.job(jobID)?.job else { return nil }
            return (job, job.steps.first { $0.id == stepID })
        }
    }

    public func title(for selection: RunSelection?) -> String {
        if case .stage(let id)? = selection { return timeline.stages.first { $0.id == id }?.name ?? "" }
        guard let selection, let node = selectionNode(selection) else { return "" }
        return node.step?.name ?? node.job?.name ?? ""
    }

    public func state(of selection: RunSelection?) -> RunNodeState? {
        if case .stage(let id)? = selection { return timeline.stages.first { $0.id == id }?.state }
        guard let selection, let node = selectionNode(selection) else { return nil }
        return node.step?.state ?? node.job?.state
    }

    /// The person chose this row.
    public func choose(_ next: RunSelection?) {
        guard let next, next != selection else { return }
        followsActive = false
        move(to: next, user: true)
    }

    private func move(to next: RunSelection, user: Bool) {
        selection = next
        if let jobID = next.jobID { expanded.insert(jobID) }
        if user {
            history = Array(history.prefix(historyIndex + 1)) + [next]
            historyIndex = history.count - 1
        } else if history.isEmpty {
            history = [next]
            historyIndex = 0
        } else {
            history[historyIndex] = next
        }
        resetGroups()
        loadLog(for: next, force: false)
    }

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    public func goBack() { step(by: -1) }
    public func goForward() { step(by: 1) }

    private func step(by offset: Int) {
        let target = historyIndex + offset
        guard history.indices.contains(target) else { return }
        historyIndex = target
        followsActive = false
        selection = history[target]
        if let jobID = history[target].jobID { expanded.insert(jobID) }
        resetGroups()
        loadLog(for: history[target], force: false)
    }

    // MARK: Outline movement

    public func collapse() {
        guard let selection else { return }
        switch selection {
        case .step(let job, _): choose(.job(job)); expanded.remove(job)
        case .job(let id): expanded.remove(id)
        case .stage: break
        }
    }

    public func expand() {
        guard let jobID = selection?.jobID else { return }
        expanded.insert(jobID)
    }

    public func expandAll() { expanded = Set(timeline.jobs.map(\.id)) }
    public func collapseAll() { expanded = [] }

    // MARK: Logs

    func loadLog(for selection: RunSelection, force: Bool) {
        logTask?.cancel()
        guard let node = selectionNode(selection), let job = node.job else {
            log = LogState(selection: selection)
            return
        }
        let active = (node.step?.state ?? job.state).isActive
        if !active, let cached = cache[selection] {
            log = LogState(selection: selection, text: cached)
            syncGroups()
            return
        }
        if log.selection != selection { log = LogState(selection: selection, isLoading: true) } else { log.isLoading = true }
        let provider = provider
        logTask = Task { [weak self] in
            do {
                let text = try await provider.log(job: job, step: node.step)
                guard !Task.isCancelled, let self else { return }
                if !active { self.cache[selection] = text }
                if self.selection == selection {
                    self.log = LogState(selection: selection, text: text)
                    self.syncGroups()
                }
            } catch {
                guard !Task.isCancelled, let self, self.selection == selection else { return }
                self.log = LogState(selection: selection, text: self.log.text, error: error.localizedDescription)
            }
        }
    }

    public var parsedLog: RunLogParser.Parsed {
        let key = "\(log.selection.map { "\($0)" } ?? "")#\(log.text.utf8.count)"
        if key != parsedKey {
            parsedKey = key
            parsedValue = RunLogParser.parse(log.text)
        }
        return parsedValue
    }

    private var knownGroups = 0

    private func resetGroups() {
        collapsedGroups = []
        knownGroups = 0
    }

    /// Groups that appear as a running log grows start collapsed.
    private func syncGroups() {
        let parsed = parsedLog
        guard parsed.groups.count > knownGroups else { return }
        let collapsed = defaultCollapsed(parsed)
        for id in parsed.groups where id >= knownGroups && collapsed.contains(id) { collapsedGroups.insert(id) }
        knownGroups = parsed.groups.count
    }

    public func toggleGroup(_ id: Int) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    /// Opens a group by default only where it holds a line that failed.
    public func defaultCollapsed(_ parsed: RunLogParser.Parsed) -> Set<Int> {
        var open = Set<Int>()
        for line in parsed.lines where line.kind == .error { open.formUnion(line.inside) }
        return Set(parsed.groups).subtracting(open)
    }

    // MARK: Commands

    public func requestFind() { findRequests += 1 }

    public var approvalForSelection: RunApproval? {
        guard case .step(let jobID, let stepID)? = selection,
              let step = timeline.job(jobID)?.job.steps.first(where: { $0.id == stepID }),
              let identifier = step.identifier?.lowercased() else { return nil }
        return approvals.first { $0.id.lowercased() == identifier }
    }

    public func showRawLog() {
        guard selection != nil else { return }
        sheet = .rawLog(title: title(for: selection), text: log.text)
    }

    public func showTaskInputs() {
        guard case .step(let jobID, _)? = selection, let node = selectionNode(selection!), let job = node.job,
              let step = node.step, jobID == job.id else { return }
        let provider = provider
        Task { [weak self] in
            let rows = (try? await provider.taskDetails(job: job, step: step)) ?? []
            self?.sheet = .taskInputs(title: step.name, rows: rows.map { TaskRow(name: $0.name, value: $0.value) })
        }
    }

    public var canShowTaskInputs: Bool {
        if case .step? = selection { return true }
        return false
    }

    public func respond(to approval: RunApproval, approve: Bool, comment: String) async throws {
        try await provider.respond(to: approval, approve: approve, comment: comment)
        await reload()
    }
}
