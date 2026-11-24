import SwiftUI
import UIKit

struct SwissArmyKnifeRandomStringView: View {
    @State private var lengthText = "16"
    @State private var options = RandomStringGenerator()
    @State private var result = ""
    @State private var copied = false
    @State private var generationError: String?
    @FocusState private var editingLength: Bool

    private var configuration: RandomStringGenerator {
        var configuration = options
        configuration.length = Int(lengthText) ?? 0
        return configuration
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("字符串长度")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField("1–1024", text: $lengthText)
                        .keyboardType(.numberPad)
                        .focused($editingLength)
                        .accessibilityLabel("字符串长度")
                }
                Toggle("数字（0–9）", isOn: $options.includesDigits)
                Toggle("小写字母（a–z）", isOn: $options.includesLowercase)
                Toggle("大写字母（A–Z）", isOn: $options.includesUppercase)
                Toggle("标点符号（!@#…）", isOn: $options.includesPunctuation)
            } header: {
                Text("生成选项")
            } footer: {
                Text("长度为 1–1024 位，每种勾选的字符类型至少包含一个字符。标点符号使用英文半角字符，不包含空格。")
            }

            Section {
                if let message = configuration.validationMessage ?? generationError {
                    Text(message)
                        .font(.footnote).foregroundStyle(.red)
                }
                Button {
                    editingLength = false
                    do {
                        result = try configuration.generate()
                        copied = false
                        generationError = nil
                    } catch {
                        generationError = error.localizedDescription
                    }
                } label: {
                    Label(result.isEmpty ? "生成字符串" : "重新生成", systemImage: "shuffle")
                }
                .buttonStyle(HakoActionButtonStyle())
                .disabled(configuration.validationMessage != nil)
            }

            if !result.isEmpty {
                Section {
                    Text(result)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("生成结果")
                        .accessibilityValue(result)
                    Button {
                        UIPasteboard.general.string = result
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制字符串", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(HakoActionButtonStyle(primary: false))
                } header: {
                    Text("生成结果 · \(result.count) 位")
                } footer: {
                    Text("更改选项后点击“重新生成”更新结果。字符串仅在本机生成，不上传或保存历史记录。")
                }
            }
        }
        .navigationTitle("随机字符串")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editingLength = false }
            }
        }
    }
}
