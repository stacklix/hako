import SwiftUI
import UIKit

struct SwissArmyKnifeView: View {
    var body: some View {
        List {
            Section("实用工具") {
                NavigationLink {
                    SwissArmyKnifeRandomStringView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("随机字符串")
                            Text("自定义长度与字符类型，一键生成并复制")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "shuffle")
                    }
                    .padding(.vertical, 6)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                NavigationLink {
                    SwissArmyKnifeQRScannerView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("二维码扫描器")
                            Text("扫描二维码，获取并复制文本")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .padding(.vertical, 6)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            }
        }
        .navigationTitle("瑞士军刀")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct SwissArmyKnifeQRScannerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var text: String?
    @State private var error: String?
    @State private var copied = false
    @State private var scanID = UUID()
    @State private var visible = false

    var body: some View {
        Group {
            if let text {
                VStack(alignment: .leading, spacing: 20) {
                    Label("识别结果", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                    ScrollView {
                        Text(text.isEmpty ? "（空文本）" : text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .accessibilityLabel("二维码文本")
                            .accessibilityValue(text)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制文本", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(HakoActionButtonStyle())
                        if let url = webURL(in: text) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("在浏览器中打开", systemImage: "safari")
                            }
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                        }
                        Button("重新扫描", action: scanAgain)
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
                .background(Color(uiColor: .systemGroupedBackground))
            } else if let error {
                ContentUnavailableView {
                    Label("无法扫描二维码", systemImage: "camera.fill")
                } description: {
                    Text(error)
                } actions: {
                    VStack(spacing: 12) {
                        Button("重新扫描", action: scanAgain)
                            .buttonStyle(HakoActionButtonStyle())
                        Button("前往系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(HakoActionButtonStyle(primary: false))
                    }
                }
            } else {
                ZStack(alignment: .bottom) {
                    Color.black
                    if visible && scenePhase == .active {
                        HakoQRCodeScanner(onScan: { text = $0 }, onError: { error = $0 })
                            .id(scanID)
                    }
                    Text("将二维码放入镜头中")
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                        .padding(.bottom, 28)
                }
                .accessibilityLabel("相机二维码扫描预览")
            }
        }
        .navigationTitle("二维码扫描器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private func webURL(in text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func scanAgain() {
        text = nil
        error = nil
        copied = false
        scanID = UUID()
    }
}
