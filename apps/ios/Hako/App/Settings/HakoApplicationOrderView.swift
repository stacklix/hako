import SwiftUI

struct HakoApplicationOrderView: View {
    @AppStorage(HakoApplicationOrder.storageKey) private var orderData = Data()

    var body: some View {
        List {
            ForEach(HakoApplications.Category.allCases, id: \.self) { category in
                Section {
                    let apps = applications(in: category)
                    ForEach(apps) { app in
                        Label(app.rawValue, systemImage: app.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                            .hakoReorderRow(showsSeparator: app.id != apps.last?.id)
                    }
                    .onMove { offsets, destination in
                        var ids = applications(in: category).map(\.rawValue)
                        ids.move(fromOffsets: offsets, toOffset: destination)
                        var order = HakoApplicationOrder(data: orderData)
                        order.set(ids, in: category.rawValue)
                        orderData = order.data
                    }
                } header: {
                    Text(category.rawValue)
                } footer: {
                    Text("拖动右侧把手调整本分类的子应用顺序，修改自动保存。")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("子应用排序")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func applications(in category: HakoApplications.Category) -> [HakoApplications.Application] {
        HakoApplicationOrder(data: orderData)
            .applications(in: category.rawValue, available: category.applications.map(\.rawValue))
            .compactMap(HakoApplications.Application.init(rawValue:))
    }
}
