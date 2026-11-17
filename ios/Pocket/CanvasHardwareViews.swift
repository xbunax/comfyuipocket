import SwiftUI

struct CanvasHardwareBar: View {
    let hardware: ServerHardware
    var body: some View {
        HStack(spacing: 14) {
            metric("GPU", value: hardware.gpu)
            metric("CPU", value: hardware.cpu)
            metric("VRAM", value: hardware.vram)
            metric("RAM", value: hardware.ram)
        }.accessibilityElement(children: .combine)
    }
    private func metric(_ title: String, value: Double?) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—").monospacedDigit().foregroundStyle(.primary)
            }.font(.caption2.weight(.medium))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let value { Capsule().fill(PocketPalette.accent).frame(width: proxy.size.width * value / 100) }
                }
            }.frame(height: 3)
        }.frame(maxWidth: .infinity)
    }
}

struct CanvasHardwareDetails: View {
    let hardware: ServerHardware
    let server: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("服务器") {
                    Text(server).textSelection(.enabled)
                    if !hardware.gpuName.isEmpty { LabeledContent("GPU", value: hardware.gpuName) }
                }
                Section {
                    LabeledContent("GPU 利用率", value: percent(hardware.gpu))
                    LabeledContent("CPU 利用率", value: percent(hardware.cpu))
                    LabeledContent("显存", value: memory(hardware.vramUsed, hardware.vramTotal))
                    LabeledContent("内存", value: memory(hardware.ramUsed, hardware.ramTotal))
                    if let date = hardware.sampledAt { LabeledContent("更新于") { Text(date, style: .time) } }
                } header: { Text("资源") } footer: { Text("显示服务器实际返回的数据；未提供或暂时不可用的指标显示为 —。") }
            }.navigationTitle("服务器硬件").toolbar { Button("完成") { dismiss() } }
        }
    }
    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    private func memory(_ used: Double?, _ total: Double?) -> String {
        guard let used, let total, ServerHardware.ratio(used: used, total: total) != nil else { return "—" }
        return String(format: "%.1f / %.1f GB", used / 1073741824, total / 1073741824)
    }
}
