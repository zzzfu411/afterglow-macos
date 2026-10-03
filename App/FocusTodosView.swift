import SwiftUI

struct FocusTodosView: View {
    @ObservedObject var model: FocusModel
    @StateObject private var viewState = TodoPanelState()

    private var pending: [FocusTodo] { model.state.todos.filter { !$0.isCompleted } }
    private var completed: [FocusTodo] { model.state.todos.filter(\.isCompleted) }

    var body: some View {
        Group {
            if model.todoDraft != nil {
                TodoEditor(model: model)
            } else {
                checklist
            }
        }
        .padding(20)
        .frame(width: 340)
        .onExitCommand {
            if model.todoDraft != nil { model.todoDraft = nil }
            else { model.showTodos = false }
        }
        .alert("删除这项待办？", isPresented: Binding(get: { viewState.deleting != nil }, set: { if !$0 { viewState.deleting = nil } })) {
            Button("取消", role: .cancel) { viewState.deleting = nil }
            Button("删除", role: .destructive) {
                if let item = viewState.deleting { model.send(.deleteTodo(item.id)) }
                viewState.deleting = nil
            }
        } message: { Text(viewState.deleting?.title ?? "") }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("待办").font(.headline)
                Spacer()
                Button { model.newTodo() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加待办（⌘N）").accessibilityLabel("添加待办")
                .disabled(model.state.todos.count >= FocusTodo.maximumCount)
            }

            HStack(spacing: 8) {
                targetOption("自由专注", symbol: "circle.dotted.circle", target: .free)
                targetOption("整张清单", symbol: "list.bullet", target: .list)
                    .disabled(pending.isEmpty)
            }
            .disabled(model.state.isActive)

            if model.state.isActive {
                Label("本轮计时中", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.state.status == .done && !(model.state.sessionTodoIDs ?? []).isEmpty {
                Text("勾选已完成的事项").font(.caption).foregroundStyle(.secondary)
            } else if !pending.isEmpty {
                Text("\(pending.count) 项 · 预计 \(pending.reduce(0) { $0 + $1.minutes }) 分钟")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if pending.isEmpty && completed.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("还没有待办").foregroundStyle(.secondary)
                    Button("添加待办") { model.newTodo() }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(pending) { row($0) }
                        if pending.isEmpty {
                            Label("清单已完成", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary).padding(.vertical, 14)
                        }
                        if !completed.isEmpty {
                            DisclosureGroup("已完成（\(completed.count)）", isExpanded: $viewState.showCompleted) {
                                ForEach(completed) { row($0) }
                            }
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 10)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(300, CGFloat(max(1, pending.count) * 60 + (completed.isEmpty ? 4 : 52)
                    + (viewState.showCompleted ? completed.count * 60 : 0))))
            }
            if model.state.todos.count == FocusTodo.maximumCount {
                Text("已达 \(FocusTodo.maximumCount) 项，删除旧事项后可继续添加")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func targetOption(_ title: String, symbol: String, target: FocusTarget) -> some View {
        let selected = model.state.focusTarget == target
        return Button { select(target) } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark" : symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ item: FocusTodo) -> some View {
        let selected = model.state.focusTarget == .todo(item.id)
        let inSession = model.state.mode == .focus && model.state.status != .idle && (model.state.sessionTodoIDs ?? []).contains(item.id)
        return HStack(spacing: 10) {
            Button { model.send(.setTodoCompleted(item.id, !item.isCompleted)) } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("\(item.isCompleted ? "恢复待办" : "完成事项")：\(item.title)")
            .help(item.isCompleted ? "恢复待办" : "标记完成")

            Button { select(.todo(item.id)) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 13)).lineLimit(2)
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    HStack(spacing: 5) {
                        Text("\(item.minutes) 分")
                        if inSession { Text("· 本轮") }
                        else if selected { Image(systemName: "checkmark") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(item.isCompleted || model.state.isActive)
            .accessibilityLabel("专注于：\(item.title)，预计 \(item.minutes) 分钟")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(item.title)

            Menu {
                Button("编辑") { model.todoDraft = TodoDraft(item: item) }
                Button("删除…", role: .destructive) { viewState.deleting = item }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("编辑或删除：\(item.title)")
            .help("编辑或删除：\(item.title)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected && !item.isCompleted ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func select(_ target: FocusTarget) {
        guard !model.state.isActive else { return }
        if model.send(.selectTarget(target)) { model.showTodos = false }
    }
}

private struct TodoEditor: View {
    @ObservedObject var model: FocusModel
    @SwiftUI.FocusState private var focused: Bool
    private var title: Binding<String> { Binding(get: { model.todoDraft?.title ?? "" }, set: { model.todoDraft?.title = $0 }) }
    private var minutes: Binding<String> { Binding(get: { model.todoDraft?.minutes ?? "" }, set: { model.todoDraft?.minutes = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.todoDraft?.isNew == true ? "添加待办" : "编辑待办").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Text("事项").font(.caption).foregroundStyle(.secondary)
                TextField("要做什么", text: title, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .focused($focused).accessibilityLabel("待办内容")
            }
            HStack(spacing: 8) {
                Text("预计").foregroundStyle(.secondary)
                TextField("25", text: minutes)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 62).monospacedDigit().accessibilityLabel("预计分钟数")
                    .onSubmit { model.saveTodo() }
                Text("分钟").foregroundStyle(.secondary)
                Spacer()
            }
            Text(validationHint).font(.caption).foregroundStyle(.secondary)
                .frame(height: 15).accessibilityHidden(validationHint.isEmpty)
            HStack {
                Button("取消") { model.todoDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.todoDraft?.isNew == true ? "添加" : "保存") { model.saveTodo() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.todoDraft?.isValid != true)
            }
        }
        .font(.system(size: 13))
        .defaultFocus($focused, true)
    }

    private var validationHint: String {
        guard let draft = model.todoDraft else { return "" }
        if draft.title.count > FocusTodo.maximumTitleLength { return "事项最多 \(FocusTodo.maximumTitleLength) 字" }
        if FocusTodo.parseMinutes(draft.minutes) == nil { return "预计时长为 1–180 分钟" }
        return ""
    }
}

private final class TodoPanelState: ObservableObject {
    @Published var showCompleted = false
    @Published var deleting: FocusTodo?
}
