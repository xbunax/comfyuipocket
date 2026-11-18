import Foundation
import IrohLib
import Observation

/// Runs on its own stream of the already authenticated connection. A write
/// completing locally is not a bandwidth measurement: wait for the peer's ACK.
@MainActor @Observable final class DirectSpeedTest {
    private(set) var stage = ""
    private(set) var running = false
    private(set) var latency: Double?
    private(set) var download: Double?
    private(set) var upload: Double?
    @ObservationIgnored private var id: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var abortStream: (() -> Void)?
    private static let bytes = 2 * 1024 * 1024

    func start(on connection: IrohLib.Connection) {
        guard !running else { return }
        clear()
        let run = UUID()
        id = run; running = true; stage = "准备测速…"
        task = Task {
            do {
                try await PairingDeadline<Void>.run(80, timeoutMessage: "测速超时，请稍后重试。") {
                    let stream = try await connection.openBi()
                    let send = stream.send(), recv = stream.recv()
                    let abort: () -> Void = {
                        Task { try? await recv.stop(errorCode: 1) }
                        Task { try? await send.reset(errorCode: 1) }
                    }
                    guard self.id == run, !Task.isCancelled else { abort(); throw CancellationError() }
                    self.abortStream = abort
                    try await self.measure(send: send, recv: recv)
                }
                guard id == run else { return }
                abortStream = nil; stage = "测速完成"
            } catch {
                guard id == run else { return }
                abortStream?(); abortStream = nil
                stage = (error as? PocketError)?.localizedDescription ?? "测速中断，请检查直连后重试。"
            }
            running = false; task = nil; id = nil
        }
    }
    func cancel() {
        guard running else { return }
        id = nil; task?.cancel(); task = nil
        abortStream?(); abortStream = nil
        running = false; stage = "测速已取消"
    }
    func clear() {
        cancel()
        latency = nil; download = nil; upload = nil; stage = ""
    }
    private func measure(send: SendStream, recv: RecvStream) async throws {
        try await send.writeAll(buf: Data([0]))
        let ready = try await recv.readExact(size: 1)
        guard ready == Data("R".utf8) else {
            throw PocketError.message(ready == Data("B".utf8) ? "电脑正在测速，请稍后重试。" : "电脑返回了无效的测速响应。")
        }
        try Task.checkCancellation()
        stage = "测量往返延迟…"
        var samples: [Double] = []
        for i in 1...5 {
            let ping = Data([UInt8(i)])
            let start = ContinuousClock.now
            try await send.writeAll(buf: ping)
            guard try await recv.readExact(size: 1) == ping else { throw PocketError.message("延迟探测响应不匹配。") }
            samples.append(seconds(since: start) * 1000)
            try Task.checkCancellation()
        }
        latency = samples.sorted()[2]
        stage = "测量下载速度…"
        let downStart = ContinuousClock.now
        try await send.writeAll(buf: Data("D".utf8))
        let body = try await recv.readExact(size: UInt32(Self.bytes))
        let downTime = seconds(since: downStart)
        try Task.checkCancellation()
        guard body.count == Self.bytes, downTime > 0 else { throw PocketError.message("下载探测未完成。") }
        download = Double(body.count * 8) / downTime / 1_000_000
        stage = "测量上传速度…"
        let upStart = ContinuousClock.now
        try await send.writeAll(buf: body)
        try await send.finish()
        guard try await recv.readExact(size: 1) == Data("U".utf8) else { throw PocketError.message("电脑未确认收到测速数据。") }
        let upTime = seconds(since: upStart)
        try Task.checkCancellation()
        guard upTime > 0 else { throw PocketError.message("上传探测计时无效。") }
        upload = Double(body.count * 8) / upTime / 1_000_000
    }
    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
