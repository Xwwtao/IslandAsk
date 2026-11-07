//
//  PerformanceTrace.swift
//  IslandAsk
//
//  性能打点：Instruments 的 Points of Interest 里能看到区间（os_signpost），
//  关键区间另外在 Console 打一行 elapsedMs 日志，不开 Instruments 也能在真机上对比优化前后。
//  性能数字以 Release 真机为准，Debug 包明显更慢。
//

import Foundation
import os

nonisolated enum PerformanceTrace {

    static let signposter = OSSignposter(subsystem: AppGroup.logSubsystem, category: .pointsOfInterest)

    /// 进程里第一次用到这个类型的时刻，约等于 App 结构体初始化的时刻（IslandAskApp.init 里会先碰一下）。
    static let processStart = ContinuousClock.now

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        milliseconds(ContinuousClock.now - start)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    /// 同步区间：signpost + 返回耗时（毫秒），由调用方决定要不要打日志（高频区间只留 signpost）。
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> (value: T, ms: Int) {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer { signposter.endInterval(name, state) }
        let value = try body()
        return (value, milliseconds(since: start))
    }
}
