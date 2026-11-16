import SwiftUI

struct WorkshopMessageDeliveryView: View {
    let state: WorkshopDeliveryState
    let canRetry: Bool
    let retry: () -> Void
    let cancel: () -> Void
    let check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .waiting:
                Label("等待前一条消息发送", systemImage: "clock")
                    .foregroundStyle(HakoStyle.muted)
            case .uploading(let progress):
                HStack(spacing: 8) {
                    Text("正在上传图片").foregroundStyle(HakoStyle.muted)
                    Spacer(minLength: 8)
                    Text("\(Int(progress * 100))%").monospacedDigit()
                    Button(action: cancel) {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.buttonStyle(.plain).foregroundStyle(HakoStyle.muted)
                        .accessibilityLabel("取消这条消息的图片上传")
                }
                ProgressView(value: progress).tint(HakoStyle.text)
                    .accessibilityLabel("图片上传进度")
                    .accessibilityValue("\(Int(progress * 100))%")
            case .sending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在发送…").foregroundStyle(HakoStyle.muted)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).textSelection(.enabled)
                Button("重试", action: retry).disabled(!canRetry)
                    .buttonStyle(HakoActionButtonStyle())
                    .accessibilityLabel("重试这条原消息")
            case .unconfirmed(let message):
                Label(message, systemImage: "questionmark.circle")
                    .foregroundStyle(HakoStyle.muted).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button("检查结果", action: check).buttonStyle(HakoActionButtonStyle(primary: false))
                    Button("重试", action: retry).buttonStyle(HakoActionButtonStyle()).disabled(!canRetry)
                }
            }
        }.font(.caption)
    }
}
