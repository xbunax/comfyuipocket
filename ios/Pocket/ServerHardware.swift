import Foundation

struct ServerHardware {
    var cpu: Double?
    var gpu: Double?
    var ramUsed: Double?
    var ramTotal: Double?
    var vramUsed: Double?
    var vramTotal: Double?
    var gpuName = ""
    var sampledAt: Date?
    var ram: Double? { Self.ratio(used: ramUsed, total: ramTotal) }
    var vram: Double? { Self.ratio(used: vramUsed, total: vramTotal) }

    init(stats: JSONValue = .null, resources: JSONValue? = nil, sampledAt: Date? = nil) {
        let system = stats["system"], device = stats["devices"].array.first ?? .null
        ramTotal = Self.number(system["ram_total"]); vramTotal = Self.number(device["vram_total"])
        if let total = ramTotal, let free = Self.number(system["ram_free"]), free <= total { ramUsed = total - free }
        if let total = vramTotal, let free = Self.number(device["vram_free"]), free <= total { vramUsed = total - free }
        gpuName = device["name"].text
        if let resources {
            cpu = Self.percent(resources["cpuPercent"]); gpu = Self.percent(resources["gpu"]["utilizationPercent"])
            if let used = Self.number(resources["ram"]["usedBytes"]), let total = Self.number(resources["ram"]["totalBytes"]), Self.ratio(used: used, total: total) != nil {
                ramUsed = used; ramTotal = total
            }
            if let used = Self.number(resources["gpu"]["memory"]["usedBytes"]), let total = Self.number(resources["gpu"]["memory"]["totalBytes"]), Self.ratio(used: used, total: total) != nil {
                vramUsed = used; vramTotal = total
            }
            if !resources["gpu"]["name"].text.isEmpty { gpuName = resources["gpu"]["name"].text }
        }
        self.sampledAt = sampledAt
    }
    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .integer, .unsigned, .number:
            let result = value.double
            return result.isFinite && result >= 0 ? result : nil
        default: return nil
        }
    }
    static func percent(_ value: JSONValue) -> Double? {
        guard let value = number(value), value <= 100 else { return nil }
        return value
    }
    static func ratio(used: Double?, total: Double?) -> Double? {
        guard let used, let total, used.isFinite, total.isFinite, total > 0, used >= 0, used <= total else { return nil }
        return used / total * 100
    }
}
