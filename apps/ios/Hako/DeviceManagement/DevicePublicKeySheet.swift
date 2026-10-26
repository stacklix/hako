import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
    @State private var copied = false
    @State private var exportKey = false
    @State private var exportedPublicKey = ""

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
                if let message = client.message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("设备公钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
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

}
