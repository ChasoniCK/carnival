import AppKit
import CoreText
import IOKit
import os
import ServiceManagement

// MARK: - metrics

let pageSize = Double(vm_kernel_page_size)
let totalMem = Double(ProcessInfo.processInfo.physicalMemory)
// mach_host_self() is a trap that adds a reference to the host port every time it is
// called; one right held for the life of the process takes a syscall out of each sample.
let hostPort = mach_host_self()

/// Seconds awake since boot, read from the commpage: no syscall, no Objective-C.
func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

func hostCPU() -> host_cpu_load_info {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    var info = host_cpu_load_info()
    withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            _ = host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    return info
}

/// Busy share of the CPU ticks that elapsed between two readings of the counters.
func cpuLoad(_ a: host_cpu_load_info, _ b: host_cpu_load_info) -> Double {
    let user = Double(b.cpu_ticks.0 &- a.cpu_ticks.0)
    let sys  = Double(b.cpu_ticks.1 &- a.cpu_ticks.1)
    let idle = Double(b.cpu_ticks.2 &- a.cpu_ticks.2)
    let nice = Double(b.cpu_ticks.3 &- a.cpu_ticks.3)
    let total = user + sys + idle + nice
    return total > 0 ? (user + sys + nice) / total : 0
}

struct MemStat { var used = 0.0; var pressure = 0.0 }

func memStat() -> MemStat {
    var st = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    withUnsafeMutablePointer(to: &st) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            _ = host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
        }
    }
    // Activity Monitor's "memory used": app + wired + compressed
    let used = (Double(st.active_count) + Double(st.inactive_count) + Double(st.speculative_count)
                + Double(st.wire_count) + Double(st.compressor_page_count)
                - Double(st.purgeable_count) - Double(st.external_page_count)) * pageSize
    let pressure = (Double(st.wire_count) + Double(st.compressor_page_count)) * pageSize / totalMem
    return MemStat(used: used, pressure: pressure)
}

/// Swap in use. Only the open panel prints it, so the closed tick never asks; the MIB is
/// spelled out because sysctlbyname spends a second syscall looking the name up.
func swapUsed() -> Double {
    var mib = (CTL_VM, VM_SWAPUSAGE)
    var xsw = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let r = withUnsafeMutablePointer(to: &mib) {
        $0.withMemoryRebound(to: Int32.self, capacity: 2) { sysctl($0, 2, &xsw, &size, nil, 0) }
    }
    return r == 0 ? Double(xsw.xsu_used) : 0
}

// The accelerator entries never change during a session, so look them up once:
// IOServiceGetMatchingServices was 90% of the per-tick cost.
let gpuServices: [io_service_t] = {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(it) }
    var out: [io_service_t] = []
    while case let e = IOIteratorNext(it), e != 0 { out.append(e) }
    return out
}()

let perfKey = "PerformanceStatistics" as CFString
let utilKey = "Device Utilization %" as CFString

// The one value is read straight out of the CFDictionary: bridging the dictionary to
// [String: Any] converted every entry in it, every tick, to look at one of them.
func gpuUsage() -> Double {
    var best = 0.0
    for e in gpuServices {
        guard let perf = IORegistryEntryCreateCFProperty(e, perfKey, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(perf) == CFDictionaryGetTypeID(),
              let raw = CFDictionaryGetValue(unsafeDowncast(perf, to: CFDictionary.self),
                                             Unmanaged.passUnretained(utilKey).toOpaque())
        else { continue }
        let util = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        var v = 0.0
        if CFGetTypeID(util) == CFNumberGetTypeID(),
           CFNumberGetValue(unsafeDowncast(util, to: CFNumber.self), .doubleType, &v) {
            best = max(best, v / 100)
        }
    }
    return best
}

// MARK: - temperature (private IOHIDEventSystem; the only route on Apple Silicon)

final class Sensors {
    private typealias FnCreate  = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias FnMatch   = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias FnCopySvc = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias FnCopyPrp = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias FnCopyEvt = @convention(c) (AnyObject, Int32, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FnFloat   = @convention(c) (AnyObject, Int32) -> Double

    private let client: AnyObject          // services die with their client - keep it alive
    private let copyEvt: FnCopyEvt
    private let getFloat: FnFloat
    private let field: Int32 = 15 << 16   // kIOHIDEventTypeTemperature

    private var named: (cpu: [AnyObject], gpu: [AnyObject]) = ([], [])   // Intel / M1-M2 naming
    private var dieNames: [String] = []                                   // M3+ "PMU tdieN"
    private var dieGroups: [[AnyObject]] = []   // each physical die is exposed 3x
    private(set) var all: [(String, AnyObject)] = []

    init?() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sCreate = dlsym(lib, "IOHIDEventSystemClientCreate"),
              let sMatch = dlsym(lib, "IOHIDEventSystemClientSetMatching"),
              let sSvc = dlsym(lib, "IOHIDEventSystemClientCopyServices"),
              let sPrp = dlsym(lib, "IOHIDServiceClientCopyProperty"),
              let sEvt = dlsym(lib, "IOHIDServiceClientCopyEvent"),
              let sFlt = dlsym(lib, "IOHIDEventGetFloatValue")
        else { return nil }

        copyEvt = unsafeBitCast(sEvt, to: FnCopyEvt.self)
        getFloat = unsafeBitCast(sFlt, to: FnFloat.self)
        let create = unsafeBitCast(sCreate, to: FnCreate.self)
        let match = unsafeBitCast(sMatch, to: FnMatch.self)
        let services = unsafeBitCast(sSvc, to: FnCopySvc.self)
        let prop = unsafeBitCast(sPrp, to: FnCopyPrp.self)

        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        client = c
        // AppleVendor usage page 0xff00, temperature-sensor usage 5
        _ = match(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let list = services(c)?.takeRetainedValue() as? [AnyObject] else { return nil }

        for svc in list {
            guard let n = prop(svc, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            all.append((n, svc))
            if n.contains("GPU") { named.gpu.append(svc) }
            else if n.hasPrefix("pACC MTR") || n.hasPrefix("eACC MTR") || n.contains("CPU") { named.cpu.append(svc) }
            else if n.hasPrefix("PMU tdie") {
                if let i = dieNames.firstIndex(of: n) { dieGroups[i].append(svc) }
                else { dieNames.append(n); dieGroups.append([svc]) }
            }
        }
    }

    /// (cpu, gpu) in Celsius, NaN when unavailable.
    /// M3+ chips expose 14 unlabeled die sensors instead of per-block ones. On a single
    /// die the hot spot is the CPU cluster and the GPU side tracks the die average, so
    /// that is what carnival reports. `carnival --sensors` dumps the raw list.
    /// Each read is a ~845 us blocking round trip to the PMU and cost is strictly linear
    /// in read count, so this reads one client per die (14) and only re-reads the three
    /// hottest dies in full (20 total instead of 42). Ranking comes from the current pass,
    /// never a cached one: a stale ranking mis-reports the hot spot by up to 1.4 C and is
    /// wrong on the first read after launch.
    func temps() -> (Double, Double) {
        if !named.cpu.isEmpty || !named.gpu.isEmpty { return (mean(named.cpu), mean(named.gpu)) }
        let n = dieGroups.count
        guard n > 0 else { return (.nan, .nan) }
        var peak = [Double](repeating: -1, count: n)
        var avg = [Double](repeating: -1, count: n)
        var ok = [Bool](repeating: false, count: n)
        for j in 0..<n {
            let v = read(dieGroups[j][0])
            if v > 0 && v < 150 { peak[j] = v; avg[j] = v; ok[j] = true }
        }
        for j in (0..<n).filter({ ok[$0] }).sorted(by: { peak[$0] > peak[$1] }).prefix(3) {
            var best = peak[j], acc = peak[j], c = 1.0
            for svc in dieGroups[j].dropFirst() {
                let v = read(svc)
                if v > 0 && v < 150 { best = max(best, v); acc += v; c += 1 }
            }
            peak[j] = best; avg[j] = acc / c
        }
        let live = (0..<n).filter { ok[$0] }
        guard !live.isEmpty else { return (.nan, .nan) }
        return (live.map { peak[$0] }.max()!,
                live.reduce(0.0) { $0 + avg[$1] } / Double(live.count))
    }

    private func read(_ svc: AnyObject) -> Double {
        guard let ev = copyEvt(svc, 15, 0, 0)?.takeRetainedValue() else { return -1 }
        return getFloat(ev, field)
    }

    func values(_ group: [AnyObject]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(group.count)
        for svc in group {
            guard let ev = copyEvt(svc, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, field)
            if v > 0 && v < 150 { out.append(v) }
        }
        return out
    }

    private func mean(_ group: [AnyObject]) -> Double {
        let v = values(group)
        return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
    }
}

// Opened by the first temperature pass, on the temperature queue: until the menu opens,
// the HID client and its ~77 service handles would only sit in memory.
let sensors = Sensors()

// MARK: - sampling

// Nobody is looking 99.9% of the time, and a wakeup costs ~284 us whatever it does,
// so the closed cadence is what the battery actually pays for.
let closedTick = 10.0
let openTick = 2.0
let histStep = 10.0   // sparkline step, held fixed so the two cadences never mix scales

struct History {
    private var v = [Float](repeating: 0, count: 60)
    private var head = 0
    mutating func push(_ x: Double) { v[head] = Float(x); head = (head + 1) % v.count }
    var count: Int { v.count }
    func at(_ i: Int) -> Float { v[(head + i) % v.count] }   // 0 = oldest
}

/// Everything a sample leaves behind. The idle ticker writes it while the menu is closed
/// and the main thread while it is open, so it lives behind a lock and the panel keeps a
/// copy. Only the stores happen under the lock, never the system calls.
struct Stats {
    var cpu = History(), gpu = History(), mem = History()
    var pushes = 0                      // sparkline generation, so the panel knows to redraw
    var cpuV = 0.0, gpuV = 0.0, memV = 0.0, prs = 0.0, swap = 0.0
    var ticks = host_cpu_load_info()
    var lastCPU = 0.0, lastHist = 0.0
    var acc = (cpu: 0.0, gpu: 0.0, mem: 0.0, n: 0.0)
}

let latest = OSAllocatedUnfairLock(uncheckedState: Stats())

/// Takes one sample; `full` adds swap, which only the open panel shows.
@discardableResult
func sample(full: Bool) -> Stats {
    let now = uptime()
    let t = hostCPU(), g = gpuUsage(), m = memStat()
    let swap = full ? swapUsed() : -1
    return latest.withLockUnchecked { s in
        // the CPU figure is a delta of tick counters: sampled too close together it is
        // noise, which is exactly what an immediate tick on menu-open would produce
        if now - s.lastCPU > 0.4 {
            s.cpuV = cpuLoad(s.ticks, t)
            s.ticks = t
            s.lastCPU = now
        }
        s.gpuV = g
        s.memV = m.used / totalMem
        s.prs = m.pressure
        if swap >= 0 { s.swap = swap }
        // History advances on wall-clock, not on ticks, so opening the menu does not
        // stretch the right-hand side of the sparkline into a different time scale.
        s.acc.cpu += s.cpuV; s.acc.gpu += s.gpuV; s.acc.mem += s.memV; s.acc.n += 1
        if now - s.lastHist >= histStep - 0.5 {
            s.cpu.push(s.acc.cpu / s.acc.n)
            s.gpu.push(s.acc.gpu / s.acc.n)
            s.mem.push(s.acc.mem / s.acc.n)
            s.acc = (0, 0, 0, 0)
            s.lastHist = now
            s.pushes += 1
        }
        return s
    }
}

/// Keeps the sparklines fed while the menu is closed, which is all carnival does 99.9% of
/// the time. The tick has a thread of its own, asleep in kevent on a kqueue timer, so it is
/// one wakeup of one thread: a main run-loop timer also ran every observer AppKit keeps on
/// that run loop (~4 context switches a tick instead of ~1.3), and a dispatch timer wakes
/// libdispatch's manager thread before the worker (twice the timer wakeups). Background QoS
/// keeps the thread on Apple silicon's efficiency cores.
final class IdleTicker {
    private let kq = kqueue()

    init() {
        let q = kq
        let t = Thread {
            var ev = kevent64_s()
            while true {
                let n = kevent64(q, nil, 0, &ev, 1, 0, nil)
                if n > 0 { autoreleasepool { _ = sample(full: false) } }
                else if n < 0 && errno != EINTR { return }   // no kqueue: better no idle ticks than a spin
            }
        }
        t.name = "carnival.idle"
        t.qualityOfService = .background
        t.start()
    }

    /// Arms or disarms a repeating closedTick timer with the same 25% leeway the main
    /// run-loop timer had as tolerance.
    func run(_ on: Bool) {
        let ns = UInt64(closedTick * 1e9)
        var ev = kevent64_s(ident: 1, filter: Int16(EVFILT_TIMER), flags: UInt16(on ? EV_ADD : EV_DELETE),
                            fflags: UInt32(NOTE_NSECONDS | NOTE_LEEWAY), data: Int64(ns), udata: 0,
                            ext: (0, ns / 4))
        _ = kevent64(kq, &ev, 1, nil, 0, 0, nil)
    }
}

// MARK: - view

final class Panel: NSView {
    var stats = Stats()                 // a copy of the last sample
    var temps = (Double.nan, Double.nan)

    override var isFlipped: Bool { true }

    /// Everything the panel prints, in the form it prints it. A tick whose readout is the
    /// one already on screen skips the redraw, and with it the window-surface flush that
    /// is 83% of a redraw.
    struct Readout: Equatable {
        var cpu, gpu, mem, cpuT, gpuT, meta: String
        var cpuTint, gpuTint, memTint, pushes: Int

        init(_ s: Stats, _ t: (Double, Double)) {
            func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
            func deg(_ v: Double) -> String { v.isNaN ? "" : String(format: "%.0f°C", v) }
            func level(_ v: Double) -> Int { v < 0.6 ? 0 : (v < 0.85 ? 1 : 2) }
            cpu = pct(s.cpuV); gpu = pct(s.gpuV); mem = pct(s.memV)
            cpuT = deg(t.0); gpuT = deg(t.1)
            let swap = s.swap > 0 ? String(format: "%.1f GB", s.swap / 1_073_741_824) : "0"
            meta = String(format: "%.1f GB · PRS %d%% · SWAP %@", s.memV * totalMem / 1_073_741_824,
                          Int(s.prs * 100), swap as NSString)
            cpuTint = level(s.cpuV); gpuTint = level(s.gpuV); memTint = level(s.prs)
            pushes = s.pushes
        }
    }
    private var shown: Readout?

    /// Call after `stats` or `temps` change: queues a redraw only when a string, a tint or
    /// a sparkline would come out different.
    func refresh() {
        let r = Readout(stats, temps)
        if r != shown { shown = r; needsDisplay = true }
    }

    /// The menu closed: let the laid-out text go (the next open rebuilds it in ~70 us) and
    /// draw in full next time.
    func closed() {
        lines.removeAll()
        shown = nil
    }

    private static let tints: [NSColor] = [.systemGreen, .systemOrange, .systemRed]

    private static let head: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.9]
    private static let meta: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor]
    private static let temp: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor]
    private static let value: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor.labelColor]

    private static let styles: [[NSAttributedString.Key: Any]] = [head, meta, temp, value]
    // NSString.draw(at:) puts the line top at y; CTLineDraw wants the baseline.
    private static let baselines: [CGFloat] = styles.map { ($0[.font] as! NSFont).ascender.rounded() - 0.25 }

    private struct LineKey: Hashable { let s: String; let style: Int; let appearance: String }
    private var lines: [LineKey: (line: CTLine, width: CGFloat)] = [:]

    // Laying a string out costs ~8 us, drawing a laid-out one ~1 us, and the panel
    // redraws the same handful of strings for as long as the menu is open.
    private func laid(_ s: String, _ style: Int) -> (line: CTLine, width: CGFloat) {
        let key = LineKey(s: s, style: style, appearance: effectiveAppearance.name.rawValue)
        if let v = lines[key] { return v }
        if lines.count > 192 { lines.removeAll(keepingCapacity: true) }  // MEM row strings are unbounded
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: Panel.styles[style]))
        let v = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        lines[key] = v
        return v
    }

    private func draw(_ v: (line: CTLine, width: CGFloat), _ x: CGFloat, _ y: CGFloat, _ style: Int) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // the view is flipped
        ctx.textPosition = CGPoint(x: x, y: y + Panel.baselines[style])
        CTLineDraw(v.line, ctx)
    }

    private func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ style: Int) {
        draw(laid(s, style), x, y, style)
    }

    private func textRight(_ s: String, _ x: CGFloat, _ y: CGFloat, _ style: Int) {
        let v = laid(s, style)
        draw(v, x - v.width, y, style)
    }

    private func graph(_ h: History, _ r: NSRect, _ c: NSColor) {
        let n = h.count
        let line = NSBezierPath()
        line.lineJoinStyle = .round
        for i in 0..<n {
            let x = r.minX + r.width * CGFloat(i) / CGFloat(n - 1)
            let y = r.maxY - (r.height - 2) * CGFloat(min(max(Double(h.at(i)), 0), 1))
            i == 0 ? line.move(to: NSPoint(x: x, y: y)) : line.line(to: NSPoint(x: x, y: y))
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: r.maxX, y: r.maxY))
        fill.line(to: NSPoint(x: r.minX, y: r.maxY))
        fill.close()
        NSGradient(colors: [c.withAlphaComponent(0.38), c.withAlphaComponent(0.01)])?.draw(in: fill, angle: -90)
        c.setStroke()
        line.lineWidth = 1.4
        line.stroke()
    }

    private func rule(_ y: CGFloat, _ w: CGFloat) {
        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: y, width: w - 28, height: 1).fill()
    }

    private func row(_ name: String, _ value: String, _ side: String, _ sideStyle: Int,
                     _ h: History, _ tint: Int, _ y: CGFloat, _ w: CGFloat) -> CGFloat {
        text(name, 14, y, 0)
        if !side.isEmpty { textRight(side, w - 14, y - 3, sideStyle) }
        text(value, 13, y + 13, 3)
        graph(h, NSRect(x: 76, y: y + 14, width: w - 90, height: 27), Panel.tints[tint])
        return y + 55
    }

    override func draw(_ dirty: NSRect) {
        let r = shown ?? Readout(stats, temps)
        let w = bounds.width
        var y: CGFloat = 13
        y = row("CPU", r.cpu, r.cpuT, 2, stats.cpu, r.cpuTint, y, w)
        rule(y - 7, w)
        y = row("GPU", r.gpu, r.gpuT, 2, stats.gpu, r.gpuTint, y, w)
        rule(y - 7, w)
        _ = row("MEM", r.mem, r.meta, 1, stats.mem, r.memTint, y, w)
    }
}

// MARK: - app

@main
final class Carnival: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: Carnival?

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let panel = Panel(frame: NSRect(x: 0, y: 0, width: 290, height: 180))
    let menu = NSMenu()
    let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let idle = IdleTicker()

    var timer: Timer?                   // the open-menu tick; the idle ticker covers the rest
    var open = false

    // A temperature pass blocks its thread for ~17 ms while the PMU answers, but burns
    // under 1 ms of CPU doing it. Off the main thread that wait costs the UI nothing.
    let tempQ = DispatchQueue(label: "carnival.temps", qos: .utility)
    var tempBusy = false
    var lastTemp = 0.0

    static func main() {
        if CommandLine.arguments.contains("--sensors") {
            guard let s = Sensors() else { print("no sensors"); return }
            for (n, svc) in s.all { print(n + "\t" + String(format: "%.2f", s.values([svc]).first ?? .nan)) }
            let t = s.temps()
            print(String(format: "--\ncpu %.1f  gpu %.1f", t.0, t.1))
            return
        }
        // --login on|off|status: the Launch at Login registration records the bundle's
        // path, so a moved app has to re-register from its new location
        if let i = CommandLine.arguments.firstIndex(of: "--login") {
            let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
            do {
                if arg == "on" { try SMAppService.mainApp.register() }
                if arg == "off" { try SMAppService.mainApp.unregister() }
            } catch { print("failed: \(error)") }
            let s = SMAppService.mainApp.status
            let names = [0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"]
            print("\(names[s.rawValue] ?? "\(s.rawValue)")  \(Bundle.main.bundlePath)")
            return
        }
        let app = NSApplication.shared
        let d = Carnival()
        shared = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Without a stable autosave name the system re-picks a slot on every launch, so
        // a reinstall drops the icon back into the overflow area behind the chevron.
        item.autosaveName = "carnival"
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "carnival")

        let mi = NSMenuItem()
        mi.view = panel
        menu.addItem(mi)
        menu.addItem(.separator())
        login.target = self
        // Quit gets a system-drawn glyph; without one of its own this item's title
        // sits in the icon column and jumps left whenever the checkmark is off
        login.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit carnival", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu       // NSMenu handles open/close/highlight natively - no activation dance

        sample(full: false)    // the first sparkline point
        idle.run(true)
    }

    func menuWillOpen(_ m: NSMenu) {
        open = true
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off   // may have changed in System Settings
        idle.run(false)
        cadence(openTick)
        tick(opening: true)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuDidClose(_ m: NSMenu) {
        open = false
        timer?.invalidate()
        timer = nil
        idle.run(true)
        panel.closed()
    }

    private func cadence(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)   // .common keeps it ticking while the menu is tracking
        timer = t
    }

    /// The open-menu tick: sample, read temperatures every ~4 s, redraw if anything
    /// visible changed.
    func tick(opening: Bool = false) {
        panel.stats = sample(full: true)
        if !tempBusy && uptime() - lastTemp > 3.5 {
            tempBusy = true
            tempQ.async { [weak self] in
                let t = sensors?.temps() ?? (.nan, .nan)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.tempBusy = false
                    self.lastTemp = uptime()
                    self.panel.temps = t
                    if self.open { self.panel.refresh() }
                }
            }
            // The pass lands within ~17 ms: this tick's numbers wait for it and go out in
            // one redraw instead of two. A menu that is just opening cannot wait.
            if !opening { return }
        }
        panel.refresh()
    }
}
