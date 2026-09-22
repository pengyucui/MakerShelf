import Foundation
import Observation

enum DownloadPhase: String {
    case queued = "等待中", running = "下载中", paused = "已暂停"
    case completed = "已完成", failed = "失败", cancelled = "已取消", partial = "部分完成"
}

/// 每行独立观察自己的进度；任务数组只在增删任务时变化。
@MainActor @Observable
final class DownloadJob: Identifiable {
    let id = UUID()
    let model: ModelRecord
    var phase: DownloadPhase = .queued
    var progress = 0.0
    var statusText = "等待处理"
    var errorMessage: String?
    init(model: ModelRecord) { self.model = model }
}

@MainActor @Observable
final class DownloadStore {
    private(set) var jobs: [DownloadJob] = []
    /// 供模型卡片常数时间定位任务；进度保留在 job 内，避免每个字节回调更新整个索引。
    private(set) var latestJobsByModel: [String: DownloadJob] = [:]
    private(set) var pendingCount = 0
    private(set) var completedCount = 0
    private(set) var totalMB = 0.0

    @ObservationIgnored private let executor: any DownloadExecuting
    @ObservationIgnored private let onComplete: @MainActor (ModelRecord) async -> Void
    @ObservationIgnored private var running: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var concurrency: Int
    // 队列索引避免大批量导入时逐项扫描历史，去重和取下一个任务均为常数时间查找。
    @ObservationIgnored private var reservedModels: [String: UUID] = [:]
    @ObservationIgnored private var jobsByID: [UUID: DownloadJob] = [:]
    @ObservationIgnored private var waitingIDs: [UUID] = []
    @ObservationIgnored private var waitingCursor = 0
    @ObservationIgnored private var failedCount = 0

    init(executor: any DownloadExecuting, concurrency: Int,
         onComplete: @escaping @MainActor (ModelRecord) async -> Void) {
        self.executor = executor
        self.concurrency = min(3, max(1, concurrency))
        self.onComplete = onComplete
    }

    @discardableResult
    func enqueue(_ models: [ModelRecord]) -> Int {
        var addedJobs: [DownloadJob] = []
        var latestIndex = latestJobsByModel
        var addedMB = 0.0
        for model in models {
            // 稳定来源 ID 去重；同一模型的未完成任务不能重复占用队列。
            guard reservedModels[model.id] == nil else { continue }
            let job = DownloadJob(model: model)
            reservedModels[model.id] = job.id
            jobsByID[job.id] = job
            waitingIDs.append(job.id)
            addedJobs.append(job)
            latestIndex[model.id] = job
            addedMB += model.sizeMB
        }
        // 批量发布一次集合变更，避免逐项触发模型列表的观察通知。
        jobs.append(contentsOf: addedJobs)
        if !addedJobs.isEmpty { latestJobsByModel = latestIndex }
        totalMB += addedMB
        updateCounts()
        schedule()
        return addedJobs.count
    }

    func setConcurrency(_ value: Int) {
        concurrency = min(3, max(1, value))
        // 降低上限时允许正在运行的任务完成，不破坏已有进度。
        schedule()
    }

    func pause(_ job: DownloadJob) {
        guard job.phase == .running || job.phase == .queued else { return }
        job.phase = .paused
        stop(job)
        updateCounts()
        schedule()
    }

    func resume(_ job: DownloadJob) {
        guard [.paused, .failed, .cancelled, .partial].contains(job.phase) else { return }
        // 重试旧记录时同样检查去重，避免取消后新建任务再恢复旧任务。
        guard reservedModels[job.model.id] == nil || reservedModels[job.model.id] == job.id else { return }
        if job.phase == .failed { failedCount -= 1 }
        reservedModels[job.model.id] = job.id
        latestJobsByModel[job.model.id] = job
        waitingIDs.append(job.id)
        job.errorMessage = nil
        job.phase = .queued
        updateCounts()
        schedule()
    }

    func cancel(_ job: DownloadJob) {
        guard job.phase != .completed && job.phase != .cancelled else { return }
        if job.phase == .failed { failedCount -= 1 }
        releaseReservation(job)
        job.phase = .cancelled
        stop(job)
        updateCounts()
        schedule()
    }

    func pauseAll() {
        // 先统一切状态再取消，避免单个任务暂停时启动下一个等待任务。
        for job in jobs where job.phase == .running || job.phase == .queued {
            job.phase = .paused
            stop(job)
        }
        updateCounts()
    }

    func shutdown() {
        pauseAll()
    }

    private func stop(_ job: DownloadJob) {
        running.removeValue(forKey: job.id)?.task.cancel()
    }

    private func schedule() {
        while running.count < concurrency && waitingCursor < waitingIDs.count {
            let id = waitingIDs[waitingCursor]
            waitingCursor += 1
            guard let job = jobsByID[id], job.phase == .queued else { continue }
            start(job)
        }
        // 分批回收已消费的队列前缀，避免 removeFirst 的逐次搬移开销。
        if waitingCursor > 256 && waitingCursor > waitingIDs.count / 2 {
            waitingIDs.removeFirst(waitingCursor)
            waitingCursor = 0
        }
    }

    private func releaseReservation(_ job: DownloadJob) {
        // 旧失败记录可能已有新的重试任务，不能删除另一个任务持有的预约。
        if reservedModels[job.model.id] == job.id { reservedModels[job.model.id] = nil }
    }

    private func start(_ job: DownloadJob) {
        job.phase = .running
        let token = UUID()
        let executor = executor
        let model = job.model
        let initialProgress = job.progress
        let task = Task { [weak self, weak job] in
            do {
                let result = try await executor.run(model: model, startingAt: initialProgress) { [weak self, weak job] progress, message in
                    await self?.receive(progress: progress, message: message, job: job, token: token)
                }
                try Task.checkCancellation()
                guard let self, let job, self.running[job.id]?.token == token else { return }
                job.progress = 1
                job.phase = result.warnings.isEmpty ? .completed : .partial
                job.statusText = result.warnings.isEmpty ? "已完成" : result.warnings.joined(separator: "；")
                self.completedCount += 1
                self.releaseReservation(job)
                self.running[job.id] = nil
                self.updateCounts()
                self.schedule()
                await self.onComplete(result.record)
            } catch is CancellationError {
                // 主动暂停先移除 token；执行器自行取消时也要释放槽位，避免队列卡住。
                guard let self, let job, self.running[job.id]?.token == token else { return }
                job.phase = .paused
                self.running[job.id] = nil
                self.updateCounts()
                self.schedule()
            } catch {
                guard let self, let job, self.running[job.id]?.token == token else { return }
                job.phase = .failed
                self.failedCount += 1
                self.releaseReservation(job)
                job.errorMessage = error.localizedDescription
                self.running[job.id] = nil
                self.updateCounts()
                self.schedule()
            }
        }
        running[job.id] = (token, task)
    }

    private func receive(progress: Double, message: String, job: DownloadJob?, token: UUID) {
        guard let job, running[job.id]?.token == token, job.phase == .running else { return }
        job.progress = progress
        job.statusText = message
    }

    private func updateCounts() {
        pendingCount = reservedModels.count + failedCount
    }
}
