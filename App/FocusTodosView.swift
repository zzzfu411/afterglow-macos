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
            && model.todoDraft == nil && !model.isBusy
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
        .onChange(of: model.showSearch) { _, shown in if shown { quickEntryFocused = false } }
        .onChange(of: model.searchRequest) { _, _ in quickEntryFocused = false }
        .onChange(of: model.section) { _, _ in viewState.selectedIDs.removeAll(); viewState.selectionAnchor = nil }
        .onChange(of: model.searchText) { _, _ in viewState.selectedIDs.removeAll(); viewState.selectionAnchor = nil }
        .onChange(of: model.visibleTodos.map(\.id)) { _, ids in
            viewState.selectedIDs.formIntersection(ids)
            if let id = viewState.customFocusID, !ids.contains(id) { viewState.customFocusID = nil }
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
                    if model.visibleTodos.filter(\.isPending).count > 1 {
                        Divider()
                        Button(model.hasMoreTodos ? "依次专注已显示事项" : "依次专注当前清单", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            model.startFocusQueue(model.visibleTodos.filter(\.isPending).map(\.id))
                        }
                        .disabled(model.isBusy)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("清单排序与专注")
                .accessibilityLabel("清单操作")
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
                    .id("detached-editor-\(model.todoDraft?.id.uuidString ?? "")")
                    .selectionDisabled(true)
                    .moveDisabled(true)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color(nsColor: .textBackgroundColor))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            ForEach(model.visibleTodos) { item in
                taskRow(item)
                    .id(item.id)
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
                if model.todoDraft?.id == item.id {
                    // The native selection belongs to the task header alone.
                    // An editor is a separate, nonselectable row so AppKit never
                    // turns all fields into one large highlighted table cell.
                    TodoEditor(model: model)
                        .id("editor-\(item.id.uuidString)")
                        .padding(.leading, 34).padding(.trailing, 6).padding(.bottom, 14)
                        .background(Color(nsColor: .textBackgroundColor))
                        .selectionDisabled(true)
                        .moveDisabled(true)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color(nsColor: .textBackgroundColor))
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
                    .selectionDisabled(true)
                    .disabled(model.isBusy)
            }
        }
        .listStyle(.inset)
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
                guard model.section != .trash, model.todoDraft == nil else { return .ignored }
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
                .foregroundStyle(viewState.selectedIDs.contains(item.id) ? Color.primary : (isFocusing(item) ? Color.accentColor : Color.secondary))
                .help(isFocusing(item) ? "正在专注" : "开始专注")
                .accessibilityLabel("专注：\(item.title)")
                .accessibilityIdentifier("todo-focus-\(item.id.uuidString)")
                .disabled(model.isBusy)
                .popover(isPresented: focusDurationPresented(for: item.id), arrowEdge: .trailing) {
                    TodoFocusDurationEditor(model: model, viewState: viewState, itemID: item.id)
                }
                .contextMenu { focusDurationActions(item) }
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
        if !item.steps.isEmpty { fields.append("步骤 \(item.steps.filter(\.isCompleted).count)/\(item.steps.count)") }
        if let rule = item.repeatRule { fields.append(repeatTitle(rule.frequency) + "重复") }
        return fields.joined(separator: "，")
    }

    @ViewBuilder private func metadata(_ item: FocusTodo) -> some View {
        let hasMetadata = item.dueDate != nil || item.plannedDate != nil || item.estimatedMinutes != nil
            || item.reminderDate != nil || !item.notes.isEmpty || !item.steps.isEmpty || item.repeatRule != nil
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
        if !item.steps.isEmpty {
            Label("\(item.steps.filter(\.isCompleted).count)/\(item.steps.count)", systemImage: "checklist")
                .help("步骤完成进度").accessibilityLabel("已完成 \(item.steps.filter(\.isCompleted).count) 个步骤，共 \(item.steps.count) 个")
        }
        if let rule = item.repeatRule {
            Image(systemName: "repeat").help(repeatTitle(rule.frequency) + "重复")
                .accessibilityLabel(repeatTitle(rule.frequency) + "重复")
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
                Menu("专注时长", systemImage: "timer") { focusDurationActions(item) }
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

    @ViewBuilder private func focusDurationActions(_ item: FocusTodo) -> some View {
        ForEach([15, 25, 45], id: \.self) { minutes in
            Button("专注 \(minutes) 分钟") { model.startFocus(item.id, minutes: minutes) }
        }
        Divider()
        Button("自定义…") {
            viewState.customFocusMinutes = String(Int(model.state.focusDuration / 60))
            viewState.customFocusID = item.id
        }
    }

    private func focusDurationPresented(for id: UUID) -> Binding<Bool> {
        Binding(get: { viewState.customFocusID == id }, set: { presented in
            if !presented && viewState.customFocusID == id { viewState.customFocusID = nil }
        })
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
            let ids = model.visibleTodos.filter { viewState.selectedIDs.contains($0.id) && $0.isPending }.map(\.id)
            if ids.count > 1 {
                Button("依次专注", systemImage: "text.line.first.and.arrowtriangle.forward") { model.startFocusQueue(ids) }
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
                Menu { selectionActions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("批量操作").accessibilityLabel("选中事项操作")
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
              model.todoDraft == nil, !model.isBusy, !viewState.selectedIDs.isEmpty else { return }
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
    @SwiftUI.FocusState private var focusedStepID: UUID?
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
            if editorState.showSteps || model.todoDraft?.steps.isEmpty == false { stepsField }
            if editorState.showRepeat || model.todoDraft?.repeatRule != nil { repeatField }

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
                        if !editorState.showSteps && model.todoDraft?.steps.isEmpty != false {
                            Button("步骤", systemImage: "checklist") { addStep() }
                        }
                        if !editorState.showRepeat && model.todoDraft?.repeatRule == nil {
                            Button("重复", systemImage: "repeat") {
                                repeatFrequency.wrappedValue = .daily
                                editorState.showRepeat = true
                            }
                        }
                    } label: { Label("添加属性", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            focusSummary
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
            if model.todoDraft?.steps.contains(where: { !$0.isValid }) == true { editorState.showSteps = true }
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

    private var stepsField: some View {
        DisclosureGroup(isExpanded: $editorState.showSteps) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.todoDraft?.steps ?? []) { step in
                    HStack(spacing: 7) {
                        Toggle("完成步骤", isOn: stepBinding(step.id, \.isCompleted, fallback: false))
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel("完成步骤：" + (step.title.isEmpty ? "未命名步骤" : step.title))
                        TextField("下一步", text: stepBinding(step.id, \.title, fallback: ""))
                            .textFieldStyle(.plain).focused($focusedStepID, equals: step.id)
                            .strikethrough(step.isCompleted)
                            .accessibilityLabel("步骤内容").accessibilityIdentifier("todo-step-title-\(step.id.uuidString)")
                            .onSubmit(addStep)
                        removeButton("移除步骤") { model.todoDraft?.steps.removeAll { $0.id == step.id } }
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .contain)
                }
                if (model.todoDraft?.steps.count ?? 0) < FocusTodo.maximumStepCount {
                    Button(action: addStep) { Label("添加步骤", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("todo-add-step")
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Label("步骤", systemImage: "checklist")
                if let steps = model.todoDraft?.steps, !steps.isEmpty {
                    Text("\(steps.filter(\.isCompleted).count)/\(steps.count)").monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func stepBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<TodoStep, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { model.todoDraft?.steps.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let index = model.todoDraft?.steps.firstIndex(where: { $0.id == id }) else { return }
            model.todoDraft?.steps[index][keyPath: keyPath] = value
        })
    }

    private func addStep() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        guard !model.isBusy, let steps = model.todoDraft?.steps else { return }
        editorState.showSteps = true
        if let unfinished = steps.first(where: { !$0.isValid }) {
            focusedStepID = unfinished.id
            return
        }
        guard steps.count < FocusTodo.maximumStepCount else { return }
        let step = TodoStep(title: "")
        model.todoDraft?.steps.append(step)
        focusedStepID = step.id
    }

    private var repeatField: some View {
        DisclosureGroup(isExpanded: $editorState.showRepeat) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("频率", selection: repeatFrequency) {
                    Text("不重复").tag(nil as TodoRepeatFrequency?)
                    ForEach(TodoRepeatFrequency.allCases, id: \.self) { frequency in
                        Text(repeatTitle(frequency)).tag(Optional(frequency))
                    }
                }
                .pickerStyle(.menu).accessibilityIdentifier("todo-repeat-frequency")
                if let rule = model.todoDraft?.repeatRule {
                    HStack(spacing: 8) {
                        Text("起始").foregroundStyle(.secondary)
                        DatePicker("重复起始日期", selection: repeatAnchor, displayedComponents: .date)
                            .datePickerStyle(.field).labelsHidden()
                            .environment(\.calendar, repeatCalendar)
                            .environment(\.timeZone, repeatCalendar.timeZone)
                            .accessibilityLabel("重复起始日期").accessibilityIdentifier("todo-repeat-anchor")
                        Spacer(minLength: 0)
                    }
                    if rule.timeZoneIdentifier != TimeZone.current.identifier {
                        Text(rule.timeZoneIdentifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(model.todoDraft?.repeatRule.map { repeatTitle($0.frequency) + "重复" } ?? "重复", systemImage: "repeat")
                .foregroundStyle(.secondary)
        }
    }

    private var repeatCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let identifier = model.todoDraft?.repeatRule?.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        } else { calendar.timeZone = .current }
        return calendar
    }

    private var repeatFrequency: Binding<TodoRepeatFrequency?> {
        Binding(get: { model.todoDraft?.repeatRule?.frequency }, set: { frequency in
            guard let frequency else {
                model.todoDraft?.repeatRule = nil; model.todoDraft?.repeatScheduledDate = nil
                return
            }
            let old = model.todoDraft?.repeatRule
            let anchor = old?.anchorDate ?? repeatCalendar.startOfDay(for: Date())
            model.todoDraft?.repeatRule = TodoRepeatRule(frequency: frequency, anchorDate: anchor,
                                                       timeZoneIdentifier: old?.timeZoneIdentifier ?? TimeZone.current.identifier)
            if model.todoDraft?.repeatScheduledDate == nil { model.todoDraft?.repeatScheduledDate = anchor }
        })
    }

    private var repeatAnchor: Binding<Date> {
        Binding(get: { model.todoDraft?.repeatRule?.anchorDate ?? repeatCalendar.startOfDay(for: Date()) }, set: { date in
            guard let rule = model.todoDraft?.repeatRule else { return }
            let anchor = repeatCalendar.startOfDay(for: date)
            model.todoDraft?.repeatRule = TodoRepeatRule(frequency: rule.frequency, anchorDate: anchor,
                                                       timeZoneIdentifier: rule.timeZoneIdentifier)
            model.todoDraft?.repeatScheduledDate = anchor
        })
    }

    @ViewBuilder private var focusSummary: some View {
        if let id = model.todoDraft?.id, let summary = model.summary(for: id), summary.sessionCount > 0 {
            let seconds = Int(summary.totalSeconds)
            let duration = seconds < 60 ? "\(seconds) 秒" : seconds < 3600 ? "\(seconds / 60) 分钟" : "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
            Label("已记录 \(duration) · \(summary.sessionCount) 次专注", systemImage: "clock")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help("其中 \(summary.completedSessionCount) 次到点结束")
                .accessibilityIdentifier("todo-focus-summary")
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
            || (!editorState.showSteps && draft.steps.isEmpty)
            || (!editorState.showRepeat && draft.repeatRule == nil)
    }

    private var validationHint: String? {
        guard let draft = model.todoDraft else { return nil }
        if draft.title.count > FocusTodo.maximumTitleLength { return "事项最多 \(FocusTodo.maximumTitleLength) 字" }
        if draft.notes.count > FocusTodo.maximumNotesLength { return "备注最多 \(FocusTodo.maximumNotesLength) 字" }
        if !draft.minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && FocusTodo.parseMinutes(draft.minutes) == nil {
            return "预计时长为 1–\(FocusTodo.minutesRange.upperBound) 分钟"
        }
        if draft.steps.contains(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "填写步骤内容，或移除空白步骤" }
        if draft.steps.contains(where: { $0.title.count > TodoStep.maximumTitleLength }) { return "步骤最多 \(TodoStep.maximumTitleLength) 字" }
        if let date = draft.reminderDate, date <= Date() { return "提醒时间已过去" }
        return nil
    }

    private var hasChanges: Bool { model.todoDraft?.hasUnsavedChanges ?? false }

    private func requestCancel() {
        guard !model.isBusy else { return }
        if hasChanges { editorState.confirmDiscard = true }
        else { model.cancelTodoDraft() }
    }
}

private final class TodoListViewState: ObservableObject {
    @Published var selectedIDs: Set<UUID> = []
    @Published var selectionAnchor: UUID?
    @Published var customFocusID: UUID?
    @Published var customFocusMinutes = "25"

    var focusMinutes: Int? {
        guard let minutes = FocusTodo.parseMinutes(customFocusMinutes), (1...180).contains(minutes) else { return nil }
        return minutes
    }
}

private struct TodoFocusDurationEditor: View {
    @ObservedObject var model: FocusModel
    @ObservedObject var viewState: TodoListViewState
    let itemID: UUID
    @SwiftUI.FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本轮专注").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                TextField("25", text: $viewState.customFocusMinutes)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .font(.system(size: 24, weight: .regular)).monospacedDigit()
                    .frame(width: 85).focused($inputFocused)
                    .onSubmit(start)
                    .accessibilityLabel("本轮专注分钟数").accessibilityIdentifier("todo-focus-minutes")
                    .help("1–180 分钟")
                Text("分钟").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Stepper("调整分钟数", value: Binding(
                    get: { viewState.focusMinutes ?? 25 },
                    set: { viewState.customFocusMinutes = String($0) }
                ), in: 1...180)
                .labelsHidden().fixedSize().disabled(viewState.focusMinutes == nil)
                .accessibilityLabel("调整本轮专注分钟数")
            }
            if viewState.focusMinutes == nil {
                Text("输入 1–180 的整数").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { viewState.customFocusID = nil }
                Button("开始", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewState.focusMinutes == nil || model.isBusy)
            }
            .controlSize(.small)
        }
        .padding(20).frame(width: 238)
        .defaultFocus($inputFocused, true)
        .onAppear { inputFocused = true }
        .onExitCommand { viewState.customFocusID = nil }
    }

    private func start() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        guard viewState.customFocusID == itemID, !model.isBusy, let minutes = viewState.focusMinutes else { return }
        viewState.customFocusID = nil
        model.startFocus(itemID, minutes: minutes)
    }
}

private final class TodoEditorState: ObservableObject {
    @Published var showEstimate = false
    @Published var confirmDiscard = false
    @Published var showSteps = false
    @Published var showRepeat = false
}

private func repeatTitle(_ frequency: TodoRepeatFrequency) -> String {
    switch frequency {
    case .daily: "每日"
    case .weekly: "每周"
    case .monthly: "每月"
    }
}
