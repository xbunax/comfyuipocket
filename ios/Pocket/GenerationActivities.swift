import BackgroundTasks
import OSLog
import UIKit

/// iOS presents a system Live Activity for a user-initiated continued task.
/// The computer owns generation. Ending this work only ends phone-side tracking.
@MainActor
final class GenerationActivities {
    private struct Tracked {
        let identifier: String
        var scheduled = false
        var execution: BGContinuedProcessingTask?
        var subtitle = ""
    }
    private var tracked: [String: Tracked] = [:]
    var backgroundExecutionChanged: (() -> Void)?
    var hasBackgroundExecution: Bool { tracked.values.contains { $0.execution != nil } }
    private let log = Logger(subsystem: "com.xbunax.comfyuipocket", category: "GenerationActivity")

    func start(_ task: GenerationTask) {
        guard tracked[task.id] == nil else { return }
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.xbunax.comfyuipocket").generation.\(task.id)"
        tracked[task.id] = Tracked(identifier: identifier)
        guard UIApplication.shared.applicationState == .active else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] work in
            MainActor.assumeIsolated {
                guard let self, let work = work as? BGContinuedProcessingTask else {
                    work.setTaskCompleted(success: false)
                    return
                }
                self.attach(work, taskID: task.id, count: task.requestedCount)
            }
        }
        if registered {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: task.name, subtitle: "正在提交生成任务")
            do {
                try BGTaskScheduler.shared.submit(request)
                tracked[task.id]?.scheduled = true
            } catch {
                log.notice("iOS did not start background tracking: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func attach(_ work: BGContinuedProcessingTask, taskID: String, count: Int) {
        guard tracked[taskID] != nil else {
            work.setTaskCompleted(success: false)
            return
        }
        tracked[taskID]?.execution = work
        work.progress.totalUnitCount = Int64(max(1, count) * 100)
        work.expirationHandler = { [weak self] in
            Task { @MainActor in self?.endExecution(taskID, success: false) }
        }
        backgroundExecutionChanged?()
    }

    private func endExecution(_ id: String, success: Bool) {
        guard let entry = tracked[id] else { return }
        tracked[id]?.execution = nil
        tracked[id]?.scheduled = false
        if let execution = entry.execution {
            execution.expirationHandler = nil
            execution.setTaskCompleted(success: success)
            backgroundExecutionChanged?()
        } else if entry.scheduled {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: entry.identifier)
        }
    }

    func stop() {
        for id in Array(tracked.keys) { endExecution(id, success: false) }
        tracked.removeAll()
    }

    func update(tasks: [GenerationTask], queue: JSONValue, history: JSONValue,
                activePrompt: String, progress: Double) {
        guard !tracked.isEmpty else { return }
        let currentIDs = Set(tasks.map(\.id))
        for id in tracked.keys.filter({ !currentIDs.contains($0) }) {
            endExecution(id, success: false)
            tracked.removeValue(forKey: id)
        }
        for task in tasks where tracked[task.id] != nil {
            let summary = task.summary(queue: queue, history: history)
            let state = GenerationActivityState(task: task, summary: summary, activePrompt: activePrompt, progress: progress)
            if let execution = tracked[task.id]?.execution {
                let units = state.terminal ? execution.progress.totalUnitCount : state.units
                execution.progress.completedUnitCount = max(execution.progress.completedUnitCount, units)
                if tracked[task.id]?.subtitle != state.subtitle {
                    tracked[task.id]?.subtitle = state.subtitle
                    execution.updateTitle(task.name, subtitle: state.subtitle)
                }
            }
            guard state.terminal else { continue }
            endExecution(task.id, success: state.succeeded)
            tracked.removeValue(forKey: task.id)
        }
    }
}
