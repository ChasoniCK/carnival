// Per-call cost of one sample: back to back ("hot") and once a second ("cold", closer to
// what the 10 s idle tick meets), with the Mach traps and BSD syscalls each call makes.
// run.sh links this twice, against the metrics code of the baseline and of the working
// tree, each through a micro-<side>.swift shim that exposes `benches` and `benchClosed`.
import Darwin
import Foundation

func syscalls() -> (mach: Int32, unix: Int32) {
    var ti = proc_taskinfo()
    _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
    return (ti.pti_syscalls_mach, ti.pti_syscalls_unix)
}

func nanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@main
enum Micro {
    static func main() {
        let args = CommandLine.arguments
        let side = args.count > 1 ? args[1] : "?"
        if args.count > 2 && args[2] == "cold" {
            var us: [Double] = []
            for _ in 0..<20 {
                usleep(1_000_000)
                let t0 = nanos()
                benchClosed()
                us.append(Double(nanos() - t0) / 1000)
            }
            us.sort()
            print("cold\t\(side)\ttick (closed)\t" + String(format: "%.1f\t%.1f", us[us.count / 2], us[us.count * 9 / 10]))
            return
        }
        for (name, f) in benches {
            for _ in 0..<100 { f() }
            let n = 2000
            let c0 = syscalls(), t0 = nanos()
            for _ in 0..<n { f() }
            let t1 = nanos(), c1 = syscalls()
            // the second syscalls() call is itself one BSD syscall
            print("hot\t\(side)\t\(name)\t" + String(format: "%.2f\t%.2f\t%.2f",
                  Double(t1 - t0) / Double(n) / 1000,
                  Double(c1.mach - c0.mach) / Double(n), Double(c1.unix - c0.unix - 1) / Double(n)))
        }
    }
}
