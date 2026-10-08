# Moro 待办改造实施记录

2026-10-08。依据 TODO_FIRST_PLAN.md，默认采用清单工作台。Goal 已开启。

## 协作边界

- 数据 Agent：Shared/FocusTodo.swift、Shared/FocusState.swift、Shared/FocusStore.swift、Tests/FocusStateTests.swift。任务字段、旧数据迁移、事务撤销、筛选排序基础。
- 界面 Agent：App/FocusTodosView.swift、App/TodoNavigationView.swift、App/FocusLayout.swift、App/NativeMaterial.swift。主列表、行内详情、导航与材质。
- 通知 Agent：App/TodoReminders.swift、Tests/TodoReminderTests.swift、scripts/test-todo-reminders.sh。待办通知调度与独立测试。
- 主 Agent：FocusModel、FocusWindow、App 入口、构建集成、快捷键、备份导入导出、集成测试与最终审核。每个 Agent 完成后先复核差异，再独立运行相关验证。

Agent 不提交、推送、安装或操作真实待办；各自只修改分配文件。构建中遇到其他工作区尚未落地的接口应沟通，不能擅自改写他人文件。

## 第一批接口约定

数据层保留现有 FocusState / FocusTodo 名称和旧调用兼容性。

- FocusTodo：id、title、estimatedMinutes: Int?（新增，minutes 保留兼容访问）、notes: String、plannedDate: Date?、dueDate: Date?、hasDueTime: Bool、listID: UUID?、isCompleted、completedAt: Date?、deletedAt: Date?、createdAt: Date?、sortOrder: Int。
- 原 minutes 初始化器保持可用；新增 title + estimatedMinutes 可选初始化器。新任务可没有预计时间，旧任务的 minutes 正确迁入 estimatedMinutes。旧 dueDate 按精确时刻保留。未知创建/完成时间保持 nil。
- TodoCollection：id: UUID、title: String。FocusTodoList.collections 默认空。nil listID 表示收件箱。
- FocusAction 新增 upsertTodo(FocusTodo)、trashTodo(UUID)、restoreTodo(UUID)、upsertCollection(TodoCollection)、deleteCollection(UUID)、reorderTodos([UUID])；保留旧 action 兼容测试和已有调用。
- FocusStore.performTodoAction(_:) 返回 (state: FocusState, undo: TodoUndoRecord?)；FocusStore.undoTodo(_:) 同样返回新的状态与反向记录，用于重做。记录只含受影响任务/清单，不复制日志；冲突不覆盖其他操作。
- version 4 迁移保留备份并验证，旧运行中的计时不改变。预计时长不再自动决定新的一轮专注时长。任务上限不能把已完成计入旧的 100 项额度，历史分批展示。

主 Agent 提供给 UI 的展示接口：

- TodoSection: Hashable = inbox / today / upcoming / all / completed / trash / collection(UUID)。title、symbol。
- TodoSort: String, CaseIterable = deadline / manual。
- FocusModel 发布 section、sort、searchText、selectedTodoID、quickEntryText、quickEntryRequest: Int、todoDraft、notice: String?、isBusy。
- FocusModel 提供 visibleTodos、visibleTodoCount、collections、sectionTitle、canUndoTodo、canRedoTodo、hasMoreTodos；loadMoreTodos()；count(in:)。
- 方法 quickAddTodo()、newTodo()、editTodo(UUID)、saveTodo()、cancelTodoDraft()、toggleTodo(UUID)、trashTodo(UUID)、restoreTodo(UUID)、undoTodoChange()、redoTodoChange()、selectTodo(UUID)、startFocus(UUID)、moveTodo(UUID,to: UUID?)、reorderVisibleTodos(from: IndexSet,to: Int)、addCollection(title:)、renameCollection(UUID,title:)、deleteCollection(UUID)。
- TodoDraft 包含 title / minutes（空表示不估计）/ notes / plannedDate / dueDate / hasDueTime / listID / isNew / isValid / id。
- 可见历史默认 100 项，点击加载更多；列表使用 LazyVStack 或原生按需 List。
- FocusTodosView 是主内容清单；TodoNavigationView 是侧栏，均以 init(model:) 接收同一 FocusModel。
- Root 的 FocusWindow 负责顶栏搜索、⌘B、⌘N、底部专注控制及错误提示；不重复在列表中放搜索框。

通知层只依赖 FocusTodo，截止日期不自动成为提醒。数据 Agent 加 reminderDate: Date?，UI 详情按需提供独立提醒字段。通知 reconcile 只在事项/授权变化触发，无周期轮询；新的任务提醒 worker 与原计时提醒使用不同 identifier。

## 进度

- [ ] 第一阶段 待办主界面、可靠录入与恢复
- [ ] 第二阶段 安排、清单、提醒与导入导出
- [ ] 第三阶段 专注日志、子步骤、重复事项与快速入口
- [ ] 第四阶段 集成回归、资源测量、签名条件与发布

## 审查记录

各 Agent 完成后在此记录审查、测试结果与修复，禁止将未验证内容标记完成。

### 第一、二阶段复核（2026-10-08）

主 Agent 已阅读各分工差异并独立运行：Core 271 项 + 6 进程 246 次事务；待办提醒 59 项；归档/导入/永久删除 60 项；运行时 129 项；原生外观/窗口约束 117 项，均通过。App typecheck 和 WidgetKit 编译/链接通过（不等同小组件签名注册）。

交叉审查实际修复：Intent 串行队列、读取期间补读、重复点击标题的草稿丢失、千项同序值排序扫描、锁内条件编辑及草稿基线冲突、完成不丢草稿、移动清单/日期同步基线、空白快速输入的反馈、选择与计时独立、读屏行操作。撤销只持有受影响对象，20 条/4 MB 上限。

隔离 Lab 窗口实操：标题回车保存、完成后 ⌘Z 恢复、⌘B、重复标题点击保留编辑、搜索、25 分钟独立于任务估时、草稿保留时暂停/继续/专注视图、深色与自动外观切换通过。发现 ⌘F 首次展开焦点未生效，已在搜索框 onAppear 显式聚焦，待最终重建回归。

优化构建的 1,000 条同 sortOrder 任务：列表模型 p95 1.97 ms，搜索模型 p95 3.50 ms；这不是完整渲染帧延迟。升级前已安装 Moro 的一次空闲采样 RSS 123,040 KB / CPU 0.0%；后续安装版按同任务数据比对。数据与旧应用将在安装前备份。
