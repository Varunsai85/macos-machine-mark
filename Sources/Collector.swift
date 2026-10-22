import AppKit
import CoreGraphics
import Foundation
import IOKit

// Reads what the window draws, as one JSON-ready dictionary: the same shape
// the original `machine-mark` helper printed, with a Mac's facts in it.
// It only reads: sysctl, system_profiler, the disk's capacity, Homebrew's
// folders, the install history, the launch agent folders and the Applications
// folder. Nothing is written or changed, and nothing leaves the machine.
enum Collector {

    // Everything, when the window opens. `frontmost` is the app the user came
    // from (its dot in the Apps ring is the larger one).
    static func read(frontmost: URL?, look: Look) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        let profile = systemProfile()
        let hw = (profile["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
        let gpuInfo = (profile["SPDisplaysDataType"] as? [[String: Any]]) ?? []

        let installed = setupDate()
        let history = installHistory()
        let brew = homebrew()
        let events = (history + brew.events).sorted { $0.date < $1.date }
        let last = events.last
        let setup = installed ?? events.first?.date.timeIntervalSince1970 ?? 0

        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(osv.majorVersion).\(osv.minorVersion)" + (osv.patchVersion > 0 ? ".\(osv.patchVersion)" : "")

        return [
            "host": hostName(),
            "os": ["version": version, "name": osName(osv.majorVersion), "build": sysctlString("kern.osversion") ?? "",
                   "model": hw["machine_name"] as? String ?? "", "modelId": sysctlString("hw.model") ?? ""],
            "kernel": sysctlString("kern.osrelease") ?? "",
            "wm": ["name": "", "version": ""],
            "cpu": cpu(),
            "gpu": gpu(gpuInfo),
            "memory": memory(),
            "disk": disk(),
            "display": display(gpuInfo),
            "packages": [
                "count": brew.found ? brew.formulae + brew.casks : NSNull(),
                "formulae": brew.formulae, "casks": brew.casks,
                "sizes": brew.sizes.isEmpty ? NSNull() : brew.sizes as Any,
            ] as [String: Any],
            "upgrades": events.count,
            "lastUpgrade": Int(last?.date.timeIntervalSince1970 ?? 0),
            "lastWhat": last?.name ?? "",
            "installed": Int(setup),
            "upgradesByWeek": weekly(events, installed: setup, now: now) as Any,
            "uptime": uptime() as Any,
            "now": Int(now),
            "theme": look.name,
            "look": ["accent": look.accentIndex],
            "themes": apps(frontmost: frontmost),
            "plugins": startupItems() as Any,
        ]
    }

    // Memory, GPU load and uptime, every few seconds while the window is open.
    static func live() -> [String: Any] {
        return ["memory": memory(), "uptime": uptime() as Any, "now": Int(Date().timeIntervalSince1970),
                "gpu": ["usage": gpuUsage() as Any]]
    }

    // ------------------------------------------------------------ helpers

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == 4 { var v: Int32 = 0; guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }; return Int(v) }
        var v: Int64 = 0
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return data
    }

    static func hostName() -> String {
        if let d = run("/usr/sbin/scutil", ["--get", "ComputerName"], timeout: 2),
           let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func osName(_ major: Int) -> String {
        let names = [11: "Big Sur", 12: "Monterey", 13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]
        return names[major] ?? ""
    }

    static func systemProfile() -> [String: Any] {
        guard let d = run("/usr/sbin/system_profiler", ["-json", "-detailLevel", "mini", "SPHardwareDataType", "SPDisplaysDataType"], timeout: 12),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    // ------------------------------------------------------------ hardware

    static func cpu() -> [String: Any] {
        var c: [String: Any] = [
            "name": sysctlString("machdep.cpu.brand_string") ?? "",
            "cores": sysctlInt("hw.physicalcpu") as Any,
            "threads": sysctlInt("hw.logicalcpu") as Any,
        ]
        // Intel Macs report a clock; Apple Silicon doesn't.
        if let hz = sysctlInt("hw.cpufrequency_max") ?? sysctlInt("hw.cpufrequency"), hz > 0 { c["mhz"] = hz / 1_000_000 }
        // Apple Silicon: performance and efficiency cores.
        if (sysctlInt("hw.nperflevels") ?? 1) >= 2, let p = sysctlInt("hw.perflevel0.physicalcpu"), let e = sysctlInt("hw.perflevel1.physicalcpu") {
            c["perf"] = p; c["eff"] = e
        }
        return c
    }

    static func gpu(_ info: [[String: Any]]) -> [String: Any] {
        // A discrete GPU over an integrated one, as the original picks.
        let pick = info.first { ($0["sppci_bus"] as? String) != "spdisplays_builtin" && ($0["sppci_model"] != nil) } ?? info.first ?? [:]
        let name = pick["sppci_model"] as? String ?? ""
        let apple = (pick["spdisplays_vendor"] as? String ?? "").contains("Apple") || name.hasPrefix("Apple")
        var g: [String: Any] = ["name": name, "type": apple || (pick["sppci_bus"] as? String) == "spdisplays_builtin" ? "Integrated" : "Discrete",
                                "driver": apple ? "apple" : "", "usage": gpuUsage() as Any]
        if let cores = Int(pick["sppci_cores"] as? String ?? "") { g["cores"] = cores }
        if let vram = (pick["spdisplays_vram"] ?? pick["spdisplays_vram_shared"]) as? String, let b = bytes(vram) { g["vram"] = b }
        return g
    }

    // "8 GB", "1536 MB" → bytes.
    static func bytes(_ s: String) -> Int? {
        let parts = s.split(separator: " ")
        guard parts.count >= 2, let v = Double(parts[0]) else { return nil }
        let mult = Double(parts[1].hasPrefix("T") ? 1 << 40 : parts[1].hasPrefix("G") ? 1 << 30 : parts[1].hasPrefix("M") ? 1 << 20 : 1)
        return Int(v * mult)
    }

    static func gpuUsage() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, u)
            }
        }
        return best
    }

    // Used as Activity Monitor counts it: app memory, wired and compressed.
    static func memory() -> [String: Any] {
        let total = Int(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return ["total": total, "used": NSNull()] }
        let page = Int(vm_kernel_page_size)
        let app = Int(stats.internal_page_count) - Int(stats.purgeable_count)
        let used = (app + Int(stats.wire_count) + Int(stats.compressor_page_count)) * page
        return ["total": total, "used": min(total, max(0, used))]
    }

    static func disk() -> [String: Any] {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return [:] }
        let free = v.volumeAvailableCapacityForImportantUsage.map { Int($0) } ?? v.volumeAvailableCapacity ?? 0
        return ["total": total, "used": max(0, total - free), "fs": v.volumeLocalizedFormatDescription ?? ""]
    }

    // The biggest display (by pixels), then the fastest.
    static func display(_ info: [[String: Any]]) -> [String: Any] {
        var best: [String: Any] = [:]
        var bestScore = (0, 0.0)
        for g in info {
            for d in (g["spdisplays_ndrvs"] as? [[String: Any]]) ?? [] {
                let px = (d["_spdisplays_pixels"] as? String ?? "").split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard px.count == 2 else { continue }
                var hz = 0.0
                if let r = d["_spdisplays_resolution"] as? String, let at = r.range(of: "@") {
                    hz = Double(r[at.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Hz", with: "")) ?? 0
                }
                var inches: Double?
                if let id = UInt32(d["_spdisplays_displayID"] as? String ?? "") {
                    let mm = CGDisplayScreenSize(id)
                    if mm.width > 0 && mm.height > 0 { inches = (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4 }
                    if hz == 0, let mode = CGDisplayCopyDisplayMode(id) { hz = mode.refreshRate }
                }
                let score = (px[0] * px[1], hz)
                if score > bestScore {
                    bestScore = score
                    best = ["width": px[0], "height": px[1], "hz": hz > 0 ? hz : NSNull(), "inches": inches as Any]
                }
            }
        }
        if best.isEmpty, let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
            best = ["width": mode.pixelWidth, "height": mode.pixelHeight, "hz": mode.refreshRate > 0 ? mode.refreshRate : NSNull()]
        }
        return best
    }

    static func uptime() -> Int? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Int(Date().timeIntervalSince1970) - tv.tv_sec
    }

    // ------------------------------------------------------------ software

    struct Event { let date: Date; let name: String }

    // When Setup Assistant finished: the closest thing to an install date.
    static func setupDate() -> Double? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: "/var/db/.AppleSetupDone"),
              let d = a[.creationDate] as? Date else { return nil }
        return d.timeIntervalSince1970
    }

    // macOS updates, App Store installs and installer packages, as macOS logs them.
    static func installHistory() -> [Event] {
        guard let d = FileManager.default.contents(atPath: "/Library/Receipts/InstallHistory.plist"),
              let list = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let date = e["date"] as? Date else { return nil }
            return Event(date: date, name: e["displayName"] as? String ?? "")
        }
    }

    struct Brew { var found = false; var formulae = 0; var casks = 0; var sizes: [Int] = []; var events: [Event] = [] }

    // Homebrew's formulae (their size on disk, in the order they were
    // installed) and casks. Each install is also one event in the history.
    static func homebrew() -> Brew {
        let fm = FileManager.default
        var b = Brew()
        guard let prefix = ["/opt/homebrew", "/usr/local"].first(where: { fm.fileExists(atPath: $0 + "/Cellar") || fm.fileExists(atPath: $0 + "/Caskroom") }) else { return b }
        b.found = true
        var kegs: [(time: Double, path: String)] = []
        let cellar = prefix + "/Cellar"
        for name in (try? fm.contentsOfDirectory(atPath: cellar)) ?? [] where !name.hasPrefix(".") {
            b.formulae += 1
            let versions = ((try? fm.contentsOfDirectory(atPath: cellar + "/" + name)) ?? []).filter { !$0.hasPrefix(".") }
            var newest: (Double, String)?
            for v in versions {
                let keg = cellar + "/" + name + "/" + v
                var t = 0.0
                if let d = fm.contents(atPath: keg + "/INSTALL_RECEIPT.json"),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let time = (j["time"] as? NSNumber)?.doubleValue {
                    t = time
                } else if let m = (try? fm.attributesOfItem(atPath: keg))?[.modificationDate] as? Date {
                    t = m.timeIntervalSince1970
                }
                if newest == nil || t > newest!.0 { newest = (t, keg) }
            }
            if let n = newest {
                kegs.append((n.0, n.1))
                if n.0 > 0 { b.events.append(Event(date: Date(timeIntervalSince1970: n.0), name: "brew " + name)) }
            }
        }
        let caskroom = prefix + "/Caskroom"
        for name in (try? fm.contentsOfDirectory(atPath: caskroom)) ?? [] where !name.hasPrefix(".") {
            b.casks += 1
            if let m = (try? fm.attributesOfItem(atPath: caskroom + "/" + name))?[.modificationDate] as? Date {
                b.events.append(Event(date: m, name: "brew " + name))
            }
        }
        kegs.sort { $0.time < $1.time }
        if !kegs.isEmpty, let d = run("/usr/bin/du", ["-sk"] + kegs.map { $0.path }, timeout: 20),
           let text = String(data: d, encoding: .utf8) {
            var size: [String: Int] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2, let kb = Int(parts[0]) { size[String(parts[1])] = kb }
            }
            b.sizes = kegs.map { size[$0.path] ?? 0 }
        }
        return b
    }

    // Updates and installs in each week since setup, oldest first.
    static func weekly(_ events: [Event], installed: Double, now: Double) -> [Int]? {
        guard installed > 0 else { return nil }
        let n = min(2600, Int((now - installed) / 604800))
        var c = [Int](repeating: 0, count: n + 1)
        for e in events {
            let w = Int((e.date.timeIntervalSince1970 - installed) / 604800)
            if w >= 0 && w <= n { c[w] += 1 }
        }
        return c
    }

    // Apps in /Applications and ~/Applications (and one folder down), by name.
    static func apps(frontmost: URL?) -> [String: Any] {
        let fm = FileManager.default
        var found: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                if item.pathExtension == "app" { found.append(item); continue }
                var dir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &dir), dir.boolValue {
                    for sub in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] where sub.pathExtension == "app" {
                        found.append(sub)
                    }
                }
            }
        }
        found.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        let current = frontmost.flatMap { f in found.firstIndex { $0.standardizedFileURL.path == f.standardizedFileURL.path } }
        return ["count": found.count, "current": current as Any]
    }

    // Launch agents and daemons outside the system's own, and which are on.
    static func startupItems() -> [String: Any]? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var items: [(label: String, on: Bool)] = []
        let off = disabledLabels()
        for dir in [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                let plist = fm.contents(atPath: path).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let label = plist?["Label"] as? String ?? String(file.dropLast(6))
                let disabled = (plist?["Disabled"] as? Bool ?? false) || off.contains(label)
                items.append((label, !disabled))
            }
        }
        items.sort { $0.label < $1.label }
        return ["count": items.count, "on": items.map { $0.on }]
    }

    // Labels launchd has been told to keep off (for this user and system-wide).
    static func disabledLabels() -> Set<String> {
        var out = Set<String>()
        for domain in ["gui/\(getuid())", "system"] {
            guard let d = run("/bin/launchctl", ["print-disabled", domain], timeout: 3), let text = String(data: d, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
                let parts = line.split(separator: "\"")
                if parts.count >= 2 { out.insert(String(parts[1])) }
            }
        }
        return out
    }
}
