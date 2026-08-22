import AppKit
import IOKit
import ServiceManagement

// MARK: - metrics

let pageSize = Double(vm_kernel_page_size)
let totalMem = Double(ProcessInfo.processInfo.physicalMemory)

func hostCPU() -> host_cpu_load_info {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    var info = host_cpu_load_info()
    withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            _ = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    return info
}

var prevTicks = hostCPU()

func cpuUsage() -> Double {
    let c = hostCPU()
    let user = Double(c.cpu_ticks.0 &- prevTicks.cpu_ticks.0)
    let sys  = Double(c.cpu_ticks.1 &- prevTicks.cpu_ticks.1)
    let idle = Double(c.cpu_ticks.2 &- prevTicks.cpu_ticks.2)
    let nice = Double(c.cpu_ticks.3 &- prevTicks.cpu_ticks.3)
    prevTicks = c
    let total = user + sys + idle + nice
    return total > 0 ? (user + sys + nice) / total : 0
}

struct MemStat { var used = 0.0; var pressure = 0.0; var swap = 0.0 }

func memStat() -> MemStat {
    var st = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    withUnsafeMutablePointer(to: &st) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    // Activity Monitor's "memory used": app + wired + compressed
    let used = (Double(st.active_count) + Double(st.inactive_count) + Double(st.speculative_count)
                + Double(st.wire_count) + Double(st.compressor_page_count)
                - Double(st.purgeable_count) - Double(st.external_page_count)) * pageSize
    let pressure = (Double(st.wire_count) + Double(st.compressor_page_count)) * pageSize / totalMem
    var xsw = xsw_usage()
    var sz = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &xsw, &sz, nil, 0)
    return MemStat(used: used, pressure: pressure, swap: Double(xsw.xsu_used))
}

func gpuUsage() -> Double {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS
    else { return 0 }
    defer { IOObjectRelease(it) }
    var best = 0.0
    while case let e = IOIteratorNext(it), e != 0 {
        if let raw = IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
           let perf = raw.takeRetainedValue() as? [String: Any],
           let util = perf["Device Utilization %"] as? Int {
            best = max(best, Double(util) / 100)
        }
        IOObjectRelease(e)
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
    private var dies: [AnyObject] = []                                    // M3+ "PMU tdieN"
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
            else if n.hasPrefix("PMU tdie") { dies.append(svc) }
        }
    }

    /// (cpu, gpu) in Celsius, NaN when unavailable.
    /// M3+ chips expose 14 unlabeled die sensors instead of per-block ones. On a single
    /// die the hot spot is the CPU cluster and the GPU side tracks the die average, so
    /// that is what carnival reports. `carnival --sensors` dumps the raw list.
    func temps() -> (Double, Double) {
        if !named.cpu.isEmpty || !named.gpu.isEmpty { return (mean(named.cpu), mean(named.gpu)) }
        let v = values(dies)
        guard !v.isEmpty else { return (.nan, .nan) }
        return (v.max()!, v.reduce(0, +) / Double(v.count))
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

// MARK: - view

struct History {
    private var v = [Float](repeating: 0, count: 60)
    private var head = 0
    mutating func push(_ x: Double) { v[head] = Float(x); head = (head + 1) % v.count }
    var count: Int { v.count }
    func at(_ i: Int) -> Float { v[(head + i) % v.count] }   // 0 = oldest
}

func tint(_ v: Double) -> NSColor {
    v < 0.6 ? .systemGreen : (v < 0.85 ? .systemOrange : .systemRed)
}

final class Panel: NSView {
    var cpu = History(), gpu = History(), mem = History()
    var cpuV = 0.0, gpuV = 0.0, memV = 0.0
    var cpuT = Double.nan, gpuT = Double.nan
    var prs = 0.0, swap = 0.0

    override var isFlipped: Bool { true }

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

    private func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ a: [NSAttributedString.Key: Any]) {
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
    }

    private func textRight(_ s: String, _ x: CGFloat, _ y: CGFloat, _ a: [NSAttributedString.Key: Any]) {
        (s as NSString).draw(at: NSPoint(x: x - (s as NSString).size(withAttributes: a).width, y: y), withAttributes: a)
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

    private func row(_ name: String, _ v: Double, _ h: History, _ y: CGFloat, _ w: CGFloat,
                     temp: Double = .nan, meta: String? = nil, heat: Double? = nil) -> CGFloat {
        text(name, 14, y, Panel.head)
        if !temp.isNaN { textRight(String(format: "%.0f°C", temp), w - 14, y - 3, Panel.temp) }
        if let meta { textRight(meta, w - 14, y - 3, Panel.meta) }
        text(String(format: "%.0f%%", v * 100), 13, y + 13, Panel.value)
        graph(h, NSRect(x: 76, y: y + 14, width: w - 90, height: 27), tint(heat ?? v))
        return y + 55
    }

    override func draw(_ dirty: NSRect) {
        let w = bounds.width
        var y: CGFloat = 13
        y = row("CPU", cpuV, cpu, y, w, temp: cpuT)
        rule(y - 7, w)
        y = row("GPU", gpuV, gpu, y, w, temp: gpuT)
        rule(y - 7, w)
        let swapTxt = swap > 0 ? String(format: "%.1f GB", swap / 1_073_741_824) : "0"
        let memTxt = String(format: "%.1f GB · PRS %d%% · SWAP %@", memV * totalMem / 1_073_741_824,
                            Int(prs * 100), swapTxt as NSString)
        _ = row("MEM", memV, mem, y, w, meta: memTxt, heat: prs)
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
    lazy var sensors = Sensors()
    var open = false

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

        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common keeps it ticking while the menu is tracking
        tick()
    }

    func menuWillOpen(_ m: NSMenu) {
        open = true
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off   // may have changed in System Settings
        tick()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    func menuDidClose(_ m: NSMenu) { open = false }

    func tick() {
        let c = cpuUsage(), g = gpuUsage(), m = memStat()
        panel.cpuV = c; panel.gpuV = g; panel.memV = m.used / totalMem
        panel.prs = m.pressure; panel.swap = m.swap
        panel.cpu.push(c); panel.gpu.push(g); panel.mem.push(panel.memV)
        guard open else { return }              // temps + redraw only while the menu is up
        let t = sensors?.temps() ?? (.nan, .nan)
        panel.cpuT = t.0; panel.gpuT = t.1
        panel.needsDisplay = true
    }
}
