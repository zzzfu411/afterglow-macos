import SwiftUI

struct FocusTodosView: View {
    @ObservedObject var model: FocusModel
    @StateObject private var viewState = TodoPanelState()

    private var pending: [FocusTodo] { model.state.todoList?.pending ?? [] }
    private var completed: [FocusTodo] { model.state.todos.filter(\.isCompleted) }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if model.todoDraft != nil {
                    ScrollView {
                        TodoEditor(model: model).padding(4)
                    }
                } else {
                    checklist(compact: geometry.size.width < 240)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.primary.opacity(0.025))
        .accessibilityIdentifier("todo-sidebar")
        .focusSection()
        .onAppear { if pending.isEmpty { viewState.showCompleted = true } }
        .onExitCommand {
            if model.todoDraft != nil { model.todoDraft = nil }
        }
        .alert("删除这项待办？", isPresented: Binding(get: { model.todoToDelete != nil }, set: { if !$0 { model.todoToDelete = nil } })) {
            Button("取消", role: .cancel) { model.todoToDelete = nil }
            Button("删除", role: .destructive) {
                if let item = model.todoToDelete { model.send(.deleteTodo(item.id)) }
                model.todoToDelete = nil
            }
        } message: { Text(model.todoToDelete?.title ?? "") }
    }

    private func checklist(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待办").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { model.newTodo() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加待办（⌘N）").accessibilityLabel("添加待办")
                .disabled(model.state.todos.count >= FocusTodo.maximumCount)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 4) {
                targetOption("自由专注", symbol: "circle.dotted.circle", target: .free)
                targetOption("整张清单", symbol: "list.bullet", target: .list)
                    .disabled(pending.isEmpty)
            }
            .disabled(model.state.isActive)

            if model.state.isActive {
                Label("结束本轮后可更换事项", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
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
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(pending) { row($0, compact: compact) }
                        if pending.isEmpty {
                            Label("清单已完成", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary).padding(.vertical, 14)
                        }
                        if !completed.isEmpty {
                            DisclosureGroup("已完成（\(completed.count)）", isExpanded: $viewState.showCompleted) {
                                ForEach(completed) { row($0, compact: compact) }
                            }
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 10)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                .accessibilityLabel("待办事项")
            }
            if let undo = model.completionUndo {
                HStack(spacing: 8) {
                    Label("已完成：\(undo.item.title)", systemImage: "checkmark")
                        .lineLimit(1).help(undo.item.title)
                    Spacer(minLength: 0)
                    Button("撤销") { model.undoTodoCompletion() }
                        .buttonStyle(.plain).fontWeight(.medium).foregroundStyle(.primary)
                        .fixedSize()
                        .accessibilityLabel("撤销完成：\(undo.item.title)")
                }
                .font(.caption)
                .padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
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
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ item: FocusTodo, compact: Bool) -> some View {
        let selected = model.state.focusTarget == .todo(item.id)
        return HStack(spacing: 4) {
            if item.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 16).accessibilityHidden(true)
                itemTitle(item)
                Button { model.send(.setTodoCompleted(item.id, false)) } label: {
                    if compact {
                        Image(systemName: "arrow.uturn.backward").frame(width: 20)
                    } else { Text("恢复待办") }
                }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    .fixedSize().frame(minHeight: 32)
                    .help("恢复待办")
                    .accessibilityLabel("恢复待办：\(item.title)")
            } else {
                Button { select(.todo(item.id)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "record.circle" : "circle")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        itemTitle(item)
                        if !compact {
                            Text(selected ? "已选" : "专注")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary).fixedSize()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(model.state.isActive)
                .accessibilityLabel("选择专注：\(item.title)，预计 \(item.minutes) 分钟\(item.dueDate.map { "，截止 " + $0.formatted(date: .complete, time: .shortened) } ?? "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("todo-select-\(item.id.uuidString)")
                .help(model.state.isActive ? "结束本轮后可更换事项" : "选择这项待办，带入预计时长")
            }

            Menu {
                itemActions(item)
            } label: {
                Label("事项操作：\(item.title)", systemImage: "ellipsis")
                    .labelStyle(.iconOnly).frame(width: 20, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("事项操作：\(item.title)")
            .accessibilityIdentifier("todo-actions-\(item.id.uuidString)")
            .help(item.isCompleted ? "编辑或删除" : "标记完成、编辑或删除")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(selected && !item.isCompleted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { itemActions(item) }
    }

    @ViewBuilder private func itemActions(_ item: FocusTodo) -> some View {
        if !item.isCompleted {
            Button("标记完成", systemImage: "checkmark") { model.completeTodo(item.id) }
            Divider()
        }
        Button("编辑") { model.todoDraft = TodoDraft(item: item) }
        Button("删除…", role: .destructive) { model.todoToDelete = item }
    }

    private func itemTitle(_ item: FocusTodo) -> some View {
        let inSession = model.state.mode == .focus && model.state.status != .idle && (model.state.sessionTodoIDs ?? []).contains(item.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.system(size: 13)).lineLimit(2)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
            Text("\(item.minutes) 分\(inSession ? " · 本轮" : "")")
                .font(.caption).foregroundStyle(.secondary)
            if let dueDate = item.dueDate {
                Label {
                    Text(dueDate, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "calendar") }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help("截止：" + dueDate.formatted(date: .complete, time: .shortened))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .help(item.title)
    }

    private func select(_ target: FocusTarget) {
        model.selectFocusTarget(target)
    }
}

private struct TodoEditor: View {
    @ObservedObject var model: FocusModel
    @SwiftUI.FocusState private var focused: Bool
    private var title: Binding<String> { Binding(get: { model.todoDraft?.title ?? "" }, set: { model.todoDraft?.title = $0 }) }
    private var minutes: Binding<String> { Binding(get: { model.todoDraft?.minutes ?? "" }, set: { model.todoDraft?.minutes = $0 }) }
    private var hasDueDate: Binding<Bool> {
        Binding(get: { model.todoDraft?.dueDate != nil }, set: { enabled in
            model.todoDraft?.dueDate = enabled ? (model.todoDraft?.dueDate ?? TodoDraft.suggestedDueDate()) : nil
        })
    }
    private var dueDate: Binding<Date> {
        Binding(get: { model.todoDraft?.dueDate ?? TodoDraft.suggestedDueDate() },
                set: { model.todoDraft?.dueDate = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    .frame(width: 48).monospacedDigit().accessibilityLabel("预计分钟数")
                    .onSubmit { model.saveTodo() }
                Text("分钟").foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("截止时间", isOn: hasDueDate).toggleStyle(.checkbox)
                    .accessibilityIdentifier("todo-due-enabled")
                if hasDueDate.wrappedValue {
                    DatePicker("截止日期", selection: dueDate, in: Date.distantPast...Date.distantFuture, displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden()
                        .accessibilityLabel("截止日期").accessibilityIdentifier("todo-due-date")
                    DatePicker("截止时刻", selection: dueDate, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field).labelsHidden()
                        .accessibilityLabel("截止时刻").accessibilityIdentifier("todo-due-time")
                }
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
        .onChange(of: model.showSidebar) { _, visible in focused = visible }
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
}
