import AppKit
import DevMateCore
import DevMateUI
import SwiftUI

// Renders the run view offscreen from made-up fixtures and writes PNGs. It
// opens no visible window and calls no network endpoint.
// Usage: RunDetailSnapshot <output-directory>

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
_ = NSApplication.shared

let clock = Date().addingTimeInterval(-3 * 3600)
func at(_ seconds: Double) -> Date { clock.addingTimeInterval(seconds) }

let esc = "\u{1B}"
let logs: [String: String] = [
    "log-fetch": """
    2026-01-01T10:00:00.0000000Z ##[group]Condition evaluation
    2026-01-01T10:00:00.0000000Z Evaluating: succeeded()
    2026-01-01T10:00:00.0000000Z Result: True
    2026-01-01T10:00:00.0000000Z ##[endgroup]
    2026-01-01T10:00:01.0000000Z ##[section]Starting: Fetch the sample dataset
    2026-01-01T10:00:01.0000000Z ==============================================================================
    2026-01-01T10:00:01.0000000Z Task         : Command line
    2026-01-01T10:00:01.0000000Z Description  : Run a script using Bash on Linux and macOS
    2026-01-01T10:00:01.0000000Z Version      : 2.250.0
    2026-01-01T10:00:01.0000000Z Author       : Example Vendor
    2026-01-01T10:00:01.0000000Z More information on this task can be found in the [task reference](https://docs.example.com/tasks/command-line).
    2026-01-01T10:00:01.0000000Z ==============================================================================
    2026-01-01T10:00:01.0000000Z ##[command]/usr/bin/bash /agent/work/_temp/fetch.sh
    2026-01-01T10:00:02.0000000Z Fetching 3 files from https://data.example.com/sample
    2026-01-01T10:00:02.0000000Z \(esc)[32mok\(esc)[0m  customers.csv
    2026-01-01T10:00:02.0000000Z \(esc)[32mok\(esc)[0m  orders.csv
    2026-01-01T10:00:03.0000000Z ##[warning]orders.csv has 2 rows with an empty region
    2026-01-01T10:00:03.0000000Z \(esc)[31mfailed\(esc)[0m  returns.csv (retrying)
    2026-01-01T10:00:04.0000000Z \(esc)[32mok\(esc)[0m  returns.csv
    2026-01-01T10:00:04.0000000Z Fetched sample data; nothing identifying was logged.
    2026-01-01T10:00:04.0000000Z
    2026-01-01T10:00:05.0000000Z ##[section]Finishing: Fetch the sample dataset
    """,
    "log-job": """
    2026-01-01T10:00:00.0000000Z ##[section]Starting: Initialize job
    2026-01-01T10:00:00.0000000Z Agent name: 'Hosted Agent 1'
    2026-01-01T10:00:01.0000000Z ##[section]Finishing: Initialize job
    2026-01-01T10:00:01.0000000Z ##[section]Starting: Fetch the sample dataset
    2026-01-01T10:00:05.0000000Z ##[section]Finishing: Fetch the sample dataset
    """,
]

struct FixtureRun: RunDetailProvider {
    var finished = false
    func timeline() async throws -> RunTimeline {
        func step(_ id: String, _ name: String, _ state: RunNodeState, _ start: Double, _ length: Double,
                  log: String? = nil, identifier: String? = nil) -> RunStep {
            RunStep(id: id, name: name, state: state, startedAt: state == .pending ? nil : at(start),
                    finishedAt: state.isFinished && state != .pending ? at(start + length) : nil, logID: log, identifier: identifier)
        }
        let build = RunJob(id: "j1", name: "Prepare", state: .succeeded, startedAt: at(0), finishedAt: at(35), logID: "log-job", steps: [
            step("s1", "Initialize job", .succeeded, 0, 4, log: "log-job"),
            step("s2", "Checkout sample-app", .succeeded, 4, 1, log: "log-job"),
            step("s3", "Fetch the sample dataset", .succeeded, 5, 5, log: "log-fetch"),
            step("s4", "Publish the report", .succeeded, 10, 19, log: "log-job"),
            step("s5", "Post-job: Checkout sample-app", .succeeded, 29, 0.4, log: "log-job"),
            step("s6", "Finalize Job", .succeeded, 29.4, 0.4, log: "log-job"),
        ])
        let verify = RunJob(id: "j2", name: "Verify", state: .failed, startedAt: at(36), finishedAt: at(80), logID: "log-job", steps: [
            step("s7", "Initialize job", .succeeded, 36, 3, log: "log-job"),
            step("s8", "Run the unit tests", .failed, 39, 40, log: "log-job"),
            step("s9", "Publish test results", .skipped, 79, 0),
        ])
        let apply = RunJob(id: "j3", name: "Apply the change", state: .waiting, startedAt: at(90), logID: "log-job", steps: [
            step("s10", "Initialize job", .succeeded, 90, 2, log: "log-job"),
            RunStep(id: "s11", name: "Approve the plan", state: .running, startedAt: at(92),
                    logID: "log-job", identifier: "approval-one", task: "ManualValidation@0"),
            step("s12", "Apply the plan", .pending, 0, 0),
            step("s13", "Finalize Job", .pending, 0, 0),
        ])
        return RunTimeline(stages: [
            RunStage(id: "g1", name: "Prepare", state: .succeeded, startedAt: at(0), finishedAt: at(35), jobs: [build]),
            RunStage(id: "g2", name: "Verify", state: .failed, startedAt: at(36), finishedAt: at(80), jobs: [verify]),
            RunStage(id: "g3", name: "Apply", state: .running, startedAt: at(90), jobs: [apply]),
        ])
    }

    func log(job: RunJob, step: RunStep?) async throws -> String {
        if let id = step?.logID { return logs[id] ?? "" }
        return logs[job.logID ?? ""] ?? ""
    }

    func approvals() async throws -> [RunApproval] {
        [RunApproval(id: "approval-one", kind: .manualValidation,
                     instructions: "Review the plan in the previous step. Resume only if no resources are destroyed.",
                     createdAt: at(92), approvers: ["Platform Team", "Sample User"], stageName: "Apply",
                     stepName: "Approve the plan", startedAt: at(92), timeoutMinutes: 1440)]
    }
}

struct FixtureHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dotted.circle").font(.title3).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Example Workstream").font(.title3.weight(.semibold))
                    Text("20260101.4").monospacedDigit().foregroundStyle(.secondary)
                }
                Text("main \u{00B7} 1a2b3c4d \u{00B7} Sample User \u{00B7} Jan 1, 10:00 AM \u{00B7} 1m 32s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {}
            Button("Open in Web") {}
        }
        .padding(14)
    }
}

/// One drawing of the view in a window that is never shown.
@MainActor func draw(_ model: RunDetailModel, dark: Bool, size: NSSize, rendering: RunLogRendering, asPDF: Bool) -> NSImage? {
    let view = RunDetailView(model: model) { FixtureHeader() }
        .environment(\.runLogRendering, rendering)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: view)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    NSApp.appearance = appearance
    NSAppearance.current = appearance
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    if asPDF { return NSImage(data: host.dataWithPDF(inside: host.bounds)) }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

@MainActor func render(_ model: RunDetailModel, name: String, dark: Bool, size: NSSize) {
    // SwiftUI draws in the first pass and the log's text view in the second.
    guard let base = draw(model, dark: dark, size: size, rendering: .blank, asPDF: false),
          let logs = draw(model, dark: dark, size: size, rendering: .native, asPDF: true),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let canvas = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    canvas.fill()
    base.draw(in: canvas)
    // Only the log pane comes from the second drawing: below the header and
    // right of the outline, whose width is the view's default.
    NSBezierPath(rect: NSRect(x: 291 * 2, y: 0, width: canvas.width - 291 * 2, height: canvas.height - 121 * 2)).addClip()
    // Whichever of the two is darker in a light drawing, lighter in a dark one,
    // so the text lands on the first drawing without shading what both drew.
    logs.draw(in: canvas, from: .zero, operation: dark ? .lighten : .darken, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let url = outputDirectory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try? png.write(to: url)
    print(url.path)
}

@MainActor func settled(_ model: RunDetailModel) async {
    await model.reload()
    for _ in 0..<40 where model.log.isLoading || model.log.selection == nil {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor func main() async {
    let size = NSSize(width: 1280, height: 780)
    for dark in [false, true] {
        let model = RunDetailModel(provider: FixtureRun(), runName: "Example Workstream 20260101.4")
        await settled(model)
        model.choose(.step(job: "j1", step: "s3"))
        await settled(model)
        render(model, name: "step-log", dark: dark, size: size)
    }
    let waiting = RunDetailModel(provider: FixtureRun(), runName: "Example Workstream 20260101.4")
    await settled(waiting)
    render(waiting, name: "waiting-approval", dark: false, size: size)

    let failed = RunDetailModel(provider: FixtureRun(), runName: "Example Workstream 20260101.4")
    await settled(failed)
    failed.choose(.job("j2"))
    await settled(failed)
    render(failed, name: "job-log", dark: false, size: size)
    exit(0)
}

Task { @MainActor in await main() }
RunLoop.main.run()
