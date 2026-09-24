// micro.swift shim for the baseline's metrics code.
import Foundation

// What tick() sampled at the baseline, menu closed or open alike.
func benchClosed() {
    _ = ProcessInfo.processInfo.systemUptime
    _ = cpuUsage()
    _ = gpuUsage()
    _ = memStat()
}

let benches: [(String, () -> Void)] = [
    ("cpu", { _ = cpuUsage() }),
    ("gpu", { _ = gpuUsage() }),
    ("memory + swap", { _ = memStat() }),
    ("tick (closed)", benchClosed),
    ("tick (open)", benchClosed),
]
