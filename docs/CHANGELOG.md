# Changelog

## 2026-07-07

### 新增

- **比赛 Tab**：新增/编辑/确认比赛日程，自动查询 Watch 去重，`get_match_schedule` 工具
- **Dashboard 页面**：训练计划 + 7日趋势两个 Tab，6h TTL 缓存，10 分钟自动刷新
- **数据库单例**：`DatabaseService.live` 全局共享，避免多连接数据不同步
- **7日趋势 AI 分析**：专用 prompt，按 ## 睡眠/HR/HRV/运动/恢复/综述 6 段输出
- **比赛信息注入**：Executor prompt 自动带最近 2 场未来比赛

### 优化

- **Tab 重构**：Picker 从 2 段扩至 5 段（趋势/训练/比赛/记录/对话），默认趋势
- **Planner 稳定性**：`PlannerError` 枚举区分 extractJSON/decode 失败，带完整上下文
- **Planner prompt**：示例加 range=1 今日值 + range=7 趋势 + `get_match_schedule`；加"只输出 JSON"
- **DeepSeekClientError**：实现 `LocalizedError`，中文描述（"网络错误: ...", "HTTP 401: ..."）
- **Executor 超时分层**：Planner 30s / Executor 120s（`timeoutInterval` 入参）
- **训练计划格式**：Executor prompt 要求具体可执行（"死虫式 10×3"），结合比赛节奏 + 伤病约束
- **7日趋势交叉分析**：prompt 要求结合运动负荷解释 RHR/HRV/睡眠波动
- **UI 修复**：比赛 Tab Picker 从 `.constant(0)` 改为 `@State` 双向绑定；已完成列表过滤
- **Dashboard 数据源**：训练计划从 `:memory:` 改为 `DatabaseService.live`，人工记录查真实 DB
- **自测升级**：从 7 场景扩至 9 场景，新增比赛工具 + 比赛注入

### 修复

- **PromptBuilder JSON 示例**：修复缺逗号 + duplicate call_id
- **migrate() 方法**：改为 migrations 数组模板
- **全部 print() → os.Logger**：12 处替换
- **Dev flow 重构**：`selftest` 命令改用 XCUITest 编排 + `devicectl copy from` 拉取日志
- **queryPastMatches**：修复未过滤导致完成列表显示未来比赛

### 技术改进

- `Tab` 存储属性 `isRecordMode: Bool` → `selectedTab: Int`（用 computed property 保持兼容）
- `DashboardService` 独立模块（缓存 + 双查询管线）
- `MatchScheduleTool` + 完整 CRUD 测试（4 个）
- 代码架构文档化：`docs/SPEC.md` + `docs/ARCHITECTURE.md` + `CHANGELOG.md`

---

## 格式说明

所有变更按日期分组，使用以下标记：

- **新增**：新功能
- **优化**：体验/性能/代码改进
- **修复**：Bug 修复
- **技术改进**：架构/代码质量/测试/文档

未来每次功能迭代，在此文件顶部新增日期条目。
