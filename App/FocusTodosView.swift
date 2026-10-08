import AppKit
import SwiftUI

/// The main task surface. Selection, completion and focus each have their own
/// control; a running focus session never makes the list read-only.
struct FocusTodosView: View {
    @ObservedObject var model: FocusModel
    @SwiftUI.FocusState private var quickEntryFocused: Bool
    @StateObject private var viewState = TodoListViewState()

    private var canAdd: Bool { model.section != .completed && model.section != .trash }
    private var canReorder: Bool {
        model.sort == .manual && model.searchText.isEmpty && canAdd
    }
    private var detachedDraft: Bool {
        guard let draft = model.todoDraft else { return false }
        return !model.visibleTodos.contains(where: { $0.id == draft.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if canAdd { quickEntry }
            if viewState.selectedIDs.count > 1 { batchActions }
            taskList
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.quickEntryRequest) { _, _ in quickEntryFocused = true }
        .onChange(of: model.section) { _, _ in viewState.selectedIDs.removeAll(); viewState.selectionAnchor = nil }
        .onChange(of: model.searchText) { _, _ in viewState.selectedIDs.removeAll(); viewState.selectionAnchor = nil }
        .onChange(of: model.visibleTodos.map(\.id)) { _, ids in
            viewState.selectedIDs.formIntersection(ids)
        }
        .onChange(of: viewState.selectedIDs) { _, ids in
            if ids.count == 1, let id = ids.first { model.selectTodo(id) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.searchText.isEmpty ? model.sectionTitle : "搜索结果")
                .font(.system(size: 23, weight: .semibold))
                .lineLimit(2).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(model.visibleTodoCount.formatted())
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityLabel("\(model.visibleTodoCount) 项")
            Spacer(minLength: 8)
            if !model.visibleTodos.isEmpty && canAdd && model.searchText.isEmpty {
                Menu {
                    Picker("排序", selection: $model.sort) {
                        Text("截止日期").tag(TodoSort.deadline)
                        Text("手动排序").tag(TodoSort.manual)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(model.sort == .manual ? "手动排序，可拖动事项" : "按截止日期排序")
                .accessibilityLabel("事项排序")
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
    }

    private var quickEntry: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            TextField("添加事项", text: $model.quickEntryText)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($quickEntryFocused)
                .onSubmit(submitQuickEntry)
                .accessibilityLabel("添加事项")
                .accessibilityIdentifier("todo-quick-entry")
                .help("输入标题，按 Return 添加；⌘N 开始录入")
            if !model.quickEntryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submitQuickEntry) {
                    Image(systemName: "return").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(model.isBusy)
                .help("添加事项").accessibilityLabel("保存新事项")
            }
        }
        .padding(.horizontal, 10).frame(minHeight: 38)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var taskList: some View {
        ScrollViewReader { proxy in
            taskListBody
                .onChange(of: model.selectedTodoID) { _, id in
                    guard let id, model.visibleTodos.contains(where: { $0.id == id }),
                          !viewState.selectedIDs.contains(id) else { return }
                    viewState.selectedIDs = [id]
                    proxy.scrollTo(id, anchor: .center)
                }
        }
    }

    private var taskListBody: some View {
        List(selection: $viewState.selectedIDs) {
            if detachedDraft {
                TodoEditor(model: model)
                    .id(model.todoDraft?.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            ForEach(model.visibleTodos) { item in
                VStack(alignment: .leading, spacing: 0) {
                    taskRow(item)
                    if model.todoDraft?.id == item.id {
                        TodoEditor(model: model)
                            .id(item.id)
                            .padding(.leading, 34).padding(.trailing, 6).padding(.bottom, 14)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("todo-row-\(item.id.uuidString)")
                .accessibilityActions { accessibleTaskActions(item) }
                .tag(item.id)
                .moveDisabled(!canReorder)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                .listRowSeparator(.hidden)
                .contextMenu {
                    if viewState.selectedIDs.count > 1 && viewState.selectedIDs.contains(item.id) {
                        selectionActions
                    } else { itemActions(item) }
                }
            }
            .onMove { indices, destination in
                guard canReorder else { return }
                model.reorderVisibleTodos(from: indices, to: destination)
            }
            if model.hasMoreTodos {
                Button("显示更多") { model.loadMoreTodos() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .listRowSeparator(.hidden)
                    .disabled(model.isBusy)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.visibleTodos.isEmpty && !detachedDraft { emptyState }
        }
        .accessibilityIdentifier("todo-list")
        .onDeleteCommand(perform: deleteSelection)
        .onKeyPress(keys: [.return, .space]) { event in
            guard event.modifiers.isEmpty, !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !model.isBusy, !viewState.selectedIDs.isEmpty else { return .ignored }
            if event.key == .return {
                guard viewState.selectedIDs.count == 1, let id = viewState.selectedIDs.first,
                      model.section != .trash else { return .ignored }
                model.editTodo(id)
            } else {
                guard model.section != .trash else { return .ignored }
                let selected = model.visibleTodos.filter { viewState.selectedIDs.contains($0.id) }
                model.setTodosCompleted(Array(viewState.selectedIDs), !selected.allSatisfy(\.isCompleted))
            }
            return .handled
        }
    }

    private func taskRow(_ item: FocusTodo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if item.deletedAt != nil {
                Button { model.restoreTodo(item.id) } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 34)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("恢复事项").accessibilityLabel("恢复：\(item.title)")
                .disabled(model.isBusy)
            } else {
                Toggle("完成：\(item.title)", isOn: Binding(
                    get: { item.isCompleted }, set: { _ in model.toggleTodo(item.id) }
                ))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: 28, height: 34)
                .accessibilityLabel(item.isCompleted ? "恢复待办：\(item.title)" : "完成：\(item.title)")
                .accessibilityIdentifier("todo-complete-\(item.id.uuidString)")
                .help(item.isCompleted ? "恢复为待办" : "标记完成")
                .disabled(model.isBusy)
            }

            Button { selectAndEdit(item) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 14))
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .strikethrough(item.isCompleted, color: .secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    metadata(item)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.deletedAt == nil ? "编辑：\(item.title)" : "已删除：\(item.title)")
            .accessibilityIdentifier("todo-select-\(item.id.uuidString)")
            .accessibilityValue(accessibilityMetadata(item))
            .help(item.title)

            if !item.isCompleted && item.deletedAt == nil {
                Button { model.startFocus(item.id) } label: {
                    Image(systemName: isFocusing(item) ? "waveform" : "play.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFocusing(item) ? Color.accentColor : Color.secondary)
                .help(isFocusing(item) ? "正在专注" : "开始专注")
                .accessibilityLabel("专注：\(item.title)")
                .accessibilityIdentifier("todo-focus-\(item.id.uuidString)")
                .disabled(model.isBusy)
            }

            Menu { itemActions(item) } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 34)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("事项操作：\(item.title)")
            .accessibilityIdentifier("todo-actions-\(item.id.uuidString)")
            .disabled(model.isBusy)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    /// Named row actions remain available in VoiceOver's Actions menu even on
    /// OS versions whose native table coalesces controls until a row is focused.
    @ViewBuilder private func accessibleTaskActions(_ item: FocusTodo) -> some View {
        if item.isDeleted {
            Button("恢复事项") { model.restoreTodo(item.id) }
            Button("永久删除…") { model.requestPurgeTodos([item.id]) }
        } else {
            Button("编辑") { model.selectTodo(item.id); model.editTodo(item.id) }
            Button(item.isCompleted ? "恢复待办" : "标记完成") { model.toggleTodo(item.id) }
            if item.isPending {
                Button("开始专注") { model.startFocus(item.id) }
                Button("安排到今天") { model.scheduleTodos([item.id], on: Date()) }
            }
            Button("移到最近删除") { model.trashTodo(item.id) }
        }
    }

    private func accessibilityMetadata(_ item: FocusTodo) -> String {
        var fields: [String] = []
        if let date = item.dueDate {
            fields.append("截止 " + date.formatted(date: .complete, time: item.hasDueTime ? .shortened : .omitted))
        }
        if let date = item.plannedDate { fields.append("计划 " + date.formatted(date: .complete, time: .omitted)) }
        if let minutes = item.estimatedMinutes { fields.append("预计 \(minutes) 分钟") }
        if item.reminderDate != nil { fields.append("已设置提醒") }
        if !item.notes.isEmpty { fields.append("含备注") }
        return fields.joined(separator: "，")
    }

    @ViewBuilder private func metadata(_ item: FocusTodo) -> some View {
        let hasMetadata = item.dueDate != nil || item.plannedDate != nil || item.estimatedMinutes != nil
            || item.reminderDate != nil || !item.notes.isEmpty
        if hasMetadata {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { metadataLabels(item) }
                VStack(alignment: .leading, spacing: 4) { metadataLabels(item) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func metadataLabels(_ item: FocusTodo) -> some View {
        if let date = item.dueDate {
            Label(dueLabel(item, date: date), systemImage: isOverdue(item) ? "exclamationmark.circle" : "flag")
                .foregroundStyle(isOverdue(item) ? Color.red : Color.secondary)
                .help("截止：" + date.formatted(date: .complete, time: item.hasDueTime ? .shortened : .omitted))
                .lineLimit(1)
        }
        if let date = item.plannedDate {
            Label(planLabel(date), systemImage: "calendar")
                .help("计划：" + date.formatted(date: .complete, time: .omitted))
                .lineLimit(1)
        }
        if let minutes = item.estimatedMinutes {
            Label("\(minutes) 分", systemImage: "hourglass")
                .help("预计 \(minutes) 分钟").lineLimit(1)
        }
        if item.reminderDate != nil {
            Image(systemName: "bell").help("已设置提醒").accessibilityLabel("已设置提醒")
        }
        if !item.notes.isEmpty {
            Image(systemName: "text.alignleft").help("含备注").accessibilityLabel("含备注")
        }
    }

    @ViewBuilder private func itemActions(_ item: FocusTodo) -> some View {
        if item.deletedAt != nil {
            Button("恢复事项", systemImage: "arrow.uturn.backward") { model.restoreTodo(item.id) }
            Button("永久删除…", systemImage: "trash", role: .destructive) { model.requestPurgeTodos([item.id]) }
        } else {
            Button(item.isCompleted ? "恢复待办" : "标记完成", systemImage: item.isCompleted ? "arrow.uturn.backward" : "checkmark") {
                model.toggleTodo(item.id)
            }
            if !item.isCompleted {
                Button("开始专注", systemImage: "play") { model.startFocus(item.id) }
                Divider()
                scheduleActions(ids: [item.id], hasPlan: item.plannedDate != nil)
            }
            Button("编辑", systemImage: "pencil") { model.editTodo(item.id) }
            Menu("移至清单") {
                Button("收件箱") { model.moveTodo(item.id, to: nil) }
                ForEach(model.collections) { collection in
                    Button(collection.title) { model.moveTodo(item.id, to: collection.id) }
                }
            }
            Divider()
            Button("移到最近删除", systemImage: "trash", role: .destructive) { model.trashTodo(item.id) }
        }
    }

    @ViewBuilder private var selectionActions: some View {
        if model.section == .trash {
            Button("恢复 \(viewState.selectedIDs.count) 项") {
                model.restoreTodos(Array(viewState.selectedIDs)); viewState.selectedIDs.removeAll()
            }
            Button("永久删除…", role: .destructive) { model.requestPurgeTodos(Array(viewState.selectedIDs)) }
        } else {
            Button(model.section == .completed ? "恢复选中事项" : "完成选中事项") {
                model.setTodosCompleted(Array(viewState.selectedIDs), model.section != .completed)
                viewState.selectedIDs.removeAll()
            }
            if model.section != .completed {
                scheduleActions(ids: Array(viewState.selectedIDs), hasPlan: true)
            }
            Menu("移至清单") {
                Button("收件箱") { moveSelection(to: nil) }
                ForEach(model.collections) { collection in
                    Button(collection.title) { moveSelection(to: collection.id) }
                }
            }
            Button("移到最近删除", role: .destructive) {
                model.trashTodos(Array(viewState.selectedIDs)); viewState.selectedIDs.removeAll()
            }
        }
    }

    @ViewBuilder private func scheduleActions(ids: [UUID], hasPlan: Bool) -> some View {
        Button("安排到今天", systemImage: "sun.max") { model.scheduleTodos(ids, on: Date()) }
        Button("安排到明天", systemImage: "calendar") {
            model.scheduleTodos(ids, on: Calendar.current.date(byAdding: .day, value: 1, to: Date()))
        }
        if hasPlan { Button("取消安排") { model.scheduleTodos(ids, on: nil) } }
    }

    private var batchActions: some View {
        HStack(spacing: 12) {
            Text("已选 \(viewState.selectedIDs.count) 项").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if model.section == .trash {
                Button("恢复") {
                    model.restoreTodos(Array(viewState.selectedIDs)); viewState.selectedIDs.removeAll()
                }
                Button { model.requestPurgeTodos(Array(viewState.selectedIDs)) } label: { Image(systemName: "trash") }
                    .help("永久删除…").accessibilityLabel("永久删除选中事项…")
            } else {
                Button(model.section == .completed ? "恢复" : "完成") {
                    model.setTodosCompleted(Array(viewState.selectedIDs), model.section != .completed)
                    viewState.selectedIDs.removeAll()
                }
                Menu("移动") {
                    Button("收件箱") { moveSelection(to: nil) }
                    ForEach(model.collections) { collection in
                        Button(collection.title) { moveSelection(to: collection.id) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button {
                    model.trashTodos(Array(viewState.selectedIDs)); viewState.selectedIDs.removeAll()
                } label: { Image(systemName: "trash") }
                .help("移到最近删除").accessibilityLabel("删除选中的事项")
            }
            Button { viewState.selectedIDs.removeAll() } label: { Image(systemName: "xmark") }
                .help("取消选择").accessibilityLabel("取消选择")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 26).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.055))
        .disabled(model.isBusy)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.searchText.isEmpty ? emptySymbol : "magnifyingglass")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? emptyTitle : "没有找到事项")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if canAdd && model.searchText.isEmpty {
                Button("添加事项") { model.newTodo() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySymbol: String {
        switch model.section {
        case .today: "sun.max"
        case .upcoming: "calendar"
        case .completed: "checkmark.circle"
        case .trash: "trash"
        default: "tray"
        }
    }
    private var emptyTitle: String {
        switch model.section {
        case .today: "今天没有待办"
        case .upcoming: "没有接下来的安排"
        case .completed: "还没有完成记录"
        case .trash: "最近删除为空"
        default: "清单为空"
        }
    }

    private func submitQuickEntry() {
        // The native field editor owns marked-text confirmation. Never convert
        // a Chinese/Japanese IME candidate-confirming Return into an Add action.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        guard !model.isBusy else { return }
        model.quickAddTodo()
        quickEntryFocused = true
    }

    private func selectAndEdit(_ item: FocusTodo) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            if viewState.selectedIDs.contains(item.id) { viewState.selectedIDs.remove(item.id) }
            else { viewState.selectedIDs.insert(item.id) }
            viewState.selectionAnchor = item.id
            return
        }
        if modifiers.contains(.shift), let anchor = viewState.selectionAnchor,
           let start = model.visibleTodos.firstIndex(where: { $0.id == anchor }),
           let end = model.visibleTodos.firstIndex(where: { $0.id == item.id }) {
            viewState.selectedIDs.formUnion(model.visibleTodos[min(start, end)...max(start, end)].map(\.id))
            return
        }
        viewState.selectedIDs = [item.id]
        viewState.selectionAnchor = item.id
        model.selectTodo(item.id)
        if item.deletedAt == nil { model.editTodo(item.id) }
    }

    private func deleteSelection() {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView), model.section != .trash,
              !model.isBusy, !viewState.selectedIDs.isEmpty else { return }
        model.trashTodos(Array(viewState.selectedIDs))
        viewState.selectedIDs.removeAll()
    }

    private func moveSelection(to collection: UUID?) {
        model.moveTodos(Array(viewState.selectedIDs), to: collection)
        viewState.selectedIDs.removeAll()
    }

    private func isFocusing(_ item: FocusTodo) -> Bool {
        model.state.mode == .focus && model.state.isActive && (model.state.sessionTodoIDs ?? []).contains(item.id)
    }

    private func isOverdue(_ item: FocusTodo) -> Bool {
        item.isOverdue()
    }

    private func dueLabel(_ item: FocusTodo, date: Date) -> String {
        let day = Calendar.current.isDateInToday(date) ? "今天" : shortDay(date)
        let time = item.hasDueTime ? " " + date.formatted(date: .omitted, time: .shortened) : ""
        return (isOverdue(item) ? "逾期 · " : "截止 ") + day + time
    }

    private func planLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInTomorrow(date) { return "明天" }
        return shortDay(date)
    }

    private func shortDay(_ date: Date) -> String {
        if Calendar.current.component(.year, from: date) != Calendar.current.component(.year, from: Date()) {
            return date.formatted(.dateTime.year().month().day())
        }
        return date.formatted(.dateTime.month().day())
    }
}

private struct TodoEditor: View {
    @ObservedObject var model: FocusModel
    @SwiftUI.FocusState private var titleFocused: Bool
    @StateObject private var editorState = TodoEditorState()

    private func binding<Value>(_ keyPath: WritableKeyPath<TodoDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { model.todoDraft?[keyPath: keyPath] ?? fallback }, set: { model.todoDraft?[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("事项", text: binding(\.title, fallback: ""), axis: .vertical)
                .font(.system(size: 15, weight: .medium)).textFieldStyle(.plain)
                .lineLimit(1...4).focused($titleFocused)
                .accessibilityLabel("事项标题").accessibilityIdentifier("todo-editor-title")
            TextField("备注", text: binding(\.notes, fallback: ""), axis: .vertical)
                .font(.system(size: 13)).textFieldStyle(.plain).lineLimit(2...5)
                .accessibilityLabel("备注")
            Divider()
            Picker("清单", selection: binding(\.listID, fallback: nil)) {
                Text("收件箱").tag(nil as UUID?)
                ForEach(model.collections) { collection in Text(collection.title).tag(Optional(collection.id)) }
            }
            .pickerStyle(.menu).font(.system(size: 12))
            .accessibilityIdentifier("todo-editor-list")

            if model.todoDraft?.plannedDate != nil { plannedField }
            if model.todoDraft?.dueDate != nil { dueField }
            if model.todoDraft?.reminderDate != nil { reminderField }
            if editorState.showEstimate || model.todoDraft?.minutes.isEmpty == false { estimateField }

            HStack {
                if canAddAttribute {
                    Menu {
                        if model.todoDraft?.plannedDate == nil {
                            Button("计划日期", systemImage: "calendar") { model.todoDraft?.plannedDate = Calendar.current.startOfDay(for: Date()) }
                        }
                        if model.todoDraft?.dueDate == nil {
                            Button("截止日期", systemImage: "flag") {
                                model.todoDraft?.dueDate = Calendar.current.startOfDay(for: Date())
                                model.todoDraft?.hasDueTime = false
                            }
                        }
                        if model.todoDraft?.reminderDate == nil {
                            Button("提醒", systemImage: "bell") { model.todoDraft?.reminderDate = Date().addingTimeInterval(3600) }
                        }
                        if !editorState.showEstimate && model.todoDraft?.minutes.isEmpty != false {
                            Button("预计时长", systemImage: "hourglass") { editorState.showEstimate = true }
                        }
                    } label: { Label("添加属性", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let validationHint {
                Text(validationHint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: requestCancel).disabled(model.isBusy)
                Button("保存") { model.saveTodo() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.todoDraft?.isValid != true || model.isBusy)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .font(.system(size: 12))
        .onAppear {
            editorState.showEstimate = model.todoDraft?.minutes.isEmpty == false
            titleFocused = true
        }
        .onExitCommand(perform: requestCancel)
        .alert("放弃这次修改？", isPresented: $editorState.confirmDiscard) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { model.cancelTodoDraft() }
        }
    }

    private var plannedField: some View {
        HStack(spacing: 8) {
            Label("计划", systemImage: "calendar").frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
            DatePicker("计划日期", selection: dateBinding(\.plannedDate), displayedComponents: .date)
                .datePickerStyle(.field).labelsHidden().accessibilityLabel("计划日期")
                .accessibilityIdentifier("todo-planned-date")
            Spacer(minLength: 0)
            removeButton("移除计划日期") { model.todoDraft?.plannedDate = nil }
        }
    }

    private var dueField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("截止", systemImage: "flag").frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
                DatePicker("截止日期", selection: dateBinding(\.dueDate), displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().accessibilityLabel("截止日期")
                    .accessibilityIdentifier("todo-due-date")
                Spacer(minLength: 0)
                removeButton("移除截止日期") { model.todoDraft?.dueDate = nil; model.todoDraft?.hasDueTime = false }
            }
            HStack(spacing: 8) {
                Toggle("具体时间", isOn: binding(\.hasDueTime, fallback: false))
                    .toggleStyle(.checkbox).accessibilityIdentifier("todo-due-time-enabled")
                if model.todoDraft?.hasDueTime == true {
                    DatePicker("截止时间", selection: dateBinding(\.dueDate), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field).labelsHidden().accessibilityLabel("截止时间")
                        .accessibilityIdentifier("todo-due-time")
                }
            }
            .padding(.leading, 62)
        }
    }

    private var reminderField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("提醒", systemImage: "bell").frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
                DatePicker("提醒日期", selection: dateBinding(\.reminderDate), displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().accessibilityLabel("提醒日期")
                Spacer(minLength: 0)
                removeButton("移除提醒") { model.todoDraft?.reminderDate = nil }
            }
            DatePicker("提醒时间", selection: dateBinding(\.reminderDate), displayedComponents: .hourAndMinute)
                .datePickerStyle(.field).labelsHidden().accessibilityLabel("提醒时间")
                .padding(.leading, 62)
        }
    }

    private var estimateField: some View {
        HStack(spacing: 8) {
            Label("预计", systemImage: "hourglass").frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
            TextField("可选", text: binding(\.minutes, fallback: ""))
                .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
                .accessibilityLabel("预计分钟数").accessibilityIdentifier("todo-estimate")
            Text("分钟").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            removeButton("移除预计时长") { model.todoDraft?.minutes = ""; editorState.showEstimate = false }
        }
    }

    private func dateBinding(_ keyPath: WritableKeyPath<TodoDraft, Date?>) -> Binding<Date> {
        Binding(get: { model.todoDraft?[keyPath: keyPath] ?? Date() }, set: { model.todoDraft?[keyPath: keyPath] = $0 })
    }

    private func removeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark").frame(width: 22, height: 22) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }

    private var canAddAttribute: Bool {
        guard let draft = model.todoDraft else { return false }
        return draft.plannedDate == nil || draft.dueDate == nil || draft.reminderDate == nil
            || (!editorState.showEstimate && draft.minutes.isEmpty)
    }

    private var validationHint: String? {
        guard let draft = model.todoDraft else { return nil }
        if draft.title.count > FocusTodo.maximumTitleLength { return "事项最多 \(FocusTodo.maximumTitleLength) 字" }
        if draft.notes.count > FocusTodo.maximumNotesLength { return "备注最多 \(FocusTodo.maximumNotesLength) 字" }
        if !draft.minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && FocusTodo.parseMinutes(draft.minutes) == nil {
            return "预计时长为 1–\(FocusTodo.minutesRange.upperBound) 分钟"
        }
        if let date = draft.reminderDate, date <= Date() { return "提醒时间已过去" }
        return nil
    }

    private var hasChanges: Bool {
        guard let draft = model.todoDraft else { return false }
        guard let item = model.state.todos.first(where: { $0.id == draft.id }) else {
            return !draft.title.isEmpty || !draft.notes.isEmpty || !draft.minutes.isEmpty
                || draft.plannedDate != nil || draft.dueDate != nil || draft.reminderDate != nil
        }
        return draft.title != item.title || draft.notes != item.notes
            || draft.minutes != (item.estimatedMinutes.map(String.init) ?? "")
            || draft.listID != item.listID || draft.plannedDate != item.plannedDate
            || draft.dueDate != item.dueDate || draft.hasDueTime != item.hasDueTime
            || draft.reminderDate != item.reminderDate
    }

    private func requestCancel() {
        guard !model.isBusy else { return }
        if hasChanges { editorState.confirmDiscard = true }
        else { model.cancelTodoDraft() }
    }
}

private final class TodoListViewState: ObservableObject {
    @Published var selectedIDs: Set<UUID> = []
    @Published var selectionAnchor: UUID?
}

private final class TodoEditorState: ObservableObject {
    @Published var showEstimate = false
    @Published var confirmDiscard = false
}
