import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum DeviceKeySheetRoute: String, Identifiable {
    case publicKey, reset
    var id: String { rawValue }
}

struct ConsolePublicKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct DevicePublicKeySheet: View {
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset: Bool
    @State private var copied = false
    @State private var exportKey = false
    @State private var exportedPublicKey = ""

    init(confirmReset: Bool) { _confirmingReset = State(initialValue: confirmReset) }

    var body: some View {
        NavigationStack {
            Form {
                Section("公钥内容 · PEM") {
                    Text(verbatim: client.publicKeyPEM)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                Section("设备身份") {
                    Text("设备 ID：" + client.deviceId)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("这里只显示和导出公钥。私钥保留在本机 Secure Enclave 中。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if confirmingReset {
                    Section("重置密钥对") {
                        Label("旧密钥不可恢复", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text("确认后将生成新密钥并退出本机设备监控登录。请导出新公钥，替换服务端旧公钥并重启服务后重新登录。")
                            .font(.footnote)
                        Button("确认重置密钥对", role: .destructive) {
                            Task { await resetKeyPair() }
                        }
                        .foregroundStyle(.red)
                        .disabled(client.busy)
                        Button("取消重置") { confirmingReset = false }
                            .disabled(client.resettingKey)
                    }
                } else {
                    Section {
                        Button {
                            do {
                                UIPasteboard.general.string = try client.publicKeyForExport()
                                copied = true
                            } catch { client.message = error.localizedDescription }
                        } label: {
                            Label(copied ? "已复制公钥" : "复制公钥内容", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.disabled(client.resettingKey)
                        Button {
                            do {
                                exportedPublicKey = try client.publicKeyForExport()
                                exportKey = true
                            } catch { client.message = error.localizedDescription }
                        } label: {
                            Label("导出公钥文件", systemImage: "square.and.arrow.up")
                        }.disabled(client.resettingKey)
                    }
                    Section {
                        Button("重置密钥对", role: .destructive) { confirmingReset = true }
                            .foregroundStyle(.red)
                            .disabled(client.busy)
                    }
                }
                if client.resettingKey { ProgressView("正在重置密钥对…") }
                if let message = client.message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(confirmingReset ? "重置密钥对" : "设备公钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(confirmingReset ? "取消" : "完成") { dismiss() }
                        .disabled(client.resettingKey)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(client.resettingKey)
        .onChange(of: client.publicKeyPEM) { _, _ in copied = false }
        .fileExporter(isPresented: $exportKey, document: ConsolePublicKeyDocument(text: exportedPublicKey), contentType: .plainText, defaultFilename: "iphone.public.pem") { result in
            if case .failure(let error) = result { client.message = error.localizedDescription }
        }
    }

    @MainActor private func resetKeyPair() async {
        let previousID = client.deviceId
        await client.resetKeyPair()
        if client.deviceId != previousID {
            confirmingReset = false
            copied = false
            exportedPublicKey = ""
        }
    }
}
