import SwiftUI

/// A native source list. Tasks live in the detail column, never inside this rail.
struct TodoNavigationView: View {
    @ObservedObject var model: FocusModel
    @StateObject private var viewState = TodoNavigationState()

    private var selection: Binding<TodoSection?> {
        Binding(get: { model.section }, set: { if let value = $0 { model.section = value } })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    destination(.inbox)
                    destination(.today)
                    destination(.upcoming)
                    destination(.all)
                }
                if !model.collections.isEmpty {
                    Section("清单") {
                        ForEach(model.collections) { collection in
                            destination(.collection(collection.id), title: collection.title)
                                .contextMenu {
                                    Button("重新命名") { beginNaming(collection) }
                                    Button("删除清单…", role: .destructive) { viewState.collectionToDelete = collection }
                                }
                        }
                    }
                }
                Section {
                    destination(.completed)
                    destination(.trash)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("todo-navigation")

            Button { beginNaming(nil) } label: {
                Label("新建清单", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .disabled(model.isBusy)
            .help("新建清单")
        }
        .background(NativeSidebarSurface())
        .alert(viewState.editingCollectionID == nil ? "新建清单" : "重新命名", isPresented: $viewState.isNamingCollection) {
            TextField("清单名称", text: $viewState.collectionName)
            Button("取消", role: .cancel) { viewState.collectionName = "" }
            Button("确定") {
                let title = viewState.collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = viewState.editingCollectionID { model.renameCollection(id, title: title) }
                else { model.addCollection(title: title) }
            }
            .disabled(!TodoCollection(title: viewState.collectionName).isValid)
        }
        .alert("删除清单？", isPresented: Binding(get: { viewState.collectionToDelete != nil }, set: { if !$0 { viewState.collectionToDelete = nil } })) {
            Button("取消", role: .cancel) { viewState.collectionToDelete = nil }
            Button("删除清单", role: .destructive) {
                if let collection = viewState.collectionToDelete { model.deleteCollection(collection.id) }
                viewState.collectionToDelete = nil
            }
        } message: {
            Text("其中的事项将移至收件箱。")
        }
    }

    private func destination(_ section: TodoSection, title: String? = nil) -> some View {
        let count = model.count(in: section)
        return Label {
            HStack(spacing: 6) {
                Text(title ?? section.title).lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(count.formatted()).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: section.symbol).frame(width: 18)
        }
        .font(.system(size: 13))
        .frame(minHeight: 25)
        .tag(section)
        .help(title ?? section.title)
        .accessibilityLabel("\(title ?? section.title)，\(count) 项")
    }

    private func beginNaming(_ collection: TodoCollection?) {
        viewState.editingCollectionID = collection?.id
        viewState.collectionName = collection?.title ?? ""
        viewState.isNamingCollection = true
    }
}

private final class TodoNavigationState: ObservableObject {
    @Published var collectionName = ""
    @Published var editingCollectionID: UUID?
    @Published var isNamingCollection = false
    @Published var collectionToDelete: TodoCollection?
}
