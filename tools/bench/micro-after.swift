// micro.swift shim for the working tree's metrics code.

func benchClosed() { sample(full: false) }

let benches: [(String, () -> Void)] = [
    ("cpu", { _ = hostCPU() }),
    ("gpu", { _ = gpuUsage() }),
    ("memory", { _ = memStat() }),
    ("swap", { _ = swapUsed() }),
    ("tick (closed)", benchClosed),
    ("tick (open)", { _ = sample(full: true) }),
]
