import SwiftUI
import UIKit

@MainActor
protocol AssistantToolSource: ObservableObject {
    associatedtype ToolPresentation: AssistantToolPresentation
    var toolCalls: [UUID: AssistantToolCall<ToolPresentation>] { get }
    var toolFollowUps: [UUID: UUID] { get }
}

@MainActor
struct AssistantToolRow<Presentation: AssistantToolPresentation>: View, Equatable {
    let record: AssistantToolCall<Presentation>
    var resolved = false
    let open: () -> Void

    nonisolated static func == (left: Self, right: Self) -> Bool { left.record == right.record && left.resolved == right.resolved }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: record.icon)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(HakoStyle.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: record.title).font(.subheadline.weight(.medium)).foregroundStyle(HakoStyle.text)
                    Text(verbatim: record.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    AssistantToolStatus(record: record, resolved: resolved)
                    if !record.durationText.isEmpty {
                        Text(verbatim: record.durationText).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看调用参数、返回结果和执行状态")
    }
}

private struct AssistantToolStatus<Presentation: AssistantToolPresentation>: View {
    let record: AssistantToolCall<Presentation>
    var resolved = false

    private var color: Color {
        if resolved { return .secondary }
        return switch record.state {
        case .failed: .red
        case .needsClarification: .orange
        case .running: .blue
        default: .secondary
        }
    }

    private var icon: String {
        if resolved { return "checkmark" }
        return switch record.state {
        case .running: "ellipsis"
        case .succeeded: "checkmark"
        case .needsClarification, .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .interrupted: "pause.circle"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if record.state == .running { ProgressView().controlSize(.mini) }
            else { Image(systemName: icon) }
            Text(resolved ? "后续已补齐" : record.statusTitle)
        }
        .font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
struct AssistantToolDetail<Source: AssistantToolSource>: View {
    private enum Display: String, CaseIterable { case overview = "调用概览", raw = "原始参数与结果" }
    private enum Payload { case arguments, result }

    @ObservedObject var source: Source
    let id: UUID
    @State private var display: Display = .overview
    @State private var expanded: Payload? = .arguments
    @State private var copied: Payload?

    private var record: AssistantToolCall<Source.ToolPresentation>? { source.toolCalls[id] }
    private var followUp: AssistantToolCall<Source.ToolPresentation>? {
        source.toolFollowUps[id].flatMap { source.toolCalls[$0] }
    }

    var body: some View {
        SettingsSheet(title: record?.title ?? "工具调用") {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: record.name).font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                AssistantToolStatus(record: record, resolved: followUp != nil)
                                Spacer()
                                Text(record.startedAt, format: .dateTime.hour().minute().second())
                                if !record.durationText.isEmpty { Text(verbatim: "· " + record.durationText) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("调用详情", selection: $display) {
                            ForEach(Display.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if let followUp {
                            Text("后续「\(followUp.title)」已通过校验。下方保留当次检查的参数和结果。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if record.state == .needsClarification {
                            Text("当次调用的参数尚未完善。需要你回答时，助手会在对话中列出具体问题。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if display == .overview {
                            fields("传入信息", values: record.inputs.isEmpty ? [.init(label: "参数", value: "查看原始参数。")] : record.inputs)
                            Divider()
                            fields("返回结果", values: record.outputs)
                        } else {
                            payload("传入参数", value: record.arguments, kind: .arguments)
                            if let result = record.result { payload("返回结果", value: result, kind: .result) }
                            else { fields("返回结果", values: record.outputs) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("调用标识").font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: record.callID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        Text("调用记录随本次会话保留。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(HakoStyle.background)
            } else {
                ContentUnavailableView("调用记录已清空", systemImage: "text.bubble")
            }
        }
    }

    private func fields(_ title: String, values: [AssistantToolField]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.subheadline.weight(.medium))
            ForEach(values.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: values[index].label).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: values[index].value).font(.subheadline).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func payload(_ title: String, value: String, kind: Payload) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded == kind }, set: { expanded = $0 ? kind : nil })) {
            Text(verbatim: AssistantToolJSON.pretty(value))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    copied = kind
                } label: {
                    Label(copied == kind ? "已复制" : "复制", systemImage: copied == kind ? "checkmark" : "doc.on.doc")
                        .font(.caption).padding(.vertical, 8)
                }
                .buttonStyle(.borderless).accessibilityLabel("复制" + title)
            }
        }
        .tint(HakoStyle.text)
    }
}
