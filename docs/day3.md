# Day 3：自然语言计划 → 同机日历 → 可追溯报告

## 状态

- **已实现并真机跑通**：手机输入/执行 → 真实 GPT → 原生后台 EventKit 保存/独立读回 → 手机历史报告及 Mac JSON/Markdown。
- **已实测通过**：新输入四事项在王者期间全部 verified；混合计划在中文输入期间 2 项 verified、2 项重要信息不足未创建；另一次过期计划由用户主动继续后 4 项 verified。合计新增 10 条，用户手动核对正确且无重复，反馈游戏和输入体验正常。
- **开发检查**：真机编译/安装；21 个 Python 测试；Swift 校验回归；累计与升级补丁复现；原有个人 Signing 保留。
- **仍待验证**：更多任意自然语言输入的质量、长期稳定性、完整的强制杀进程/拔线故障测试。没有连续录像或性能采样，不声称零掉帧。

[简洁真实报告](day3-report.md) · [机器可读脱敏证据](../evidence/day3-validation.json)

## 架构和执行约束

手机原生 SwiftUI 输入 → 手机原子保存 submission/task/version → Mac 用原 PhoneAgent RPC 拉取并保存输入 → 手机确认已接收 → GPT 在 Mac 解析 → 手机保存不可变计划 → 检查后台状态和剩余预算 → 同一台 iPhone EventKit 保存 → 新 EKEventStore 按事件 ID 独立读回 → 双端报告。

复用上游 `SimulatorRPCServer.swift`、`rpc.py` 和 `forward_rpc_localhost.py`。转发器缓存**已成功连接**的 CoreDevice 数字地址（保留 IPv6 scope），失败后重新发现。实测本机每次域名解析约 5 秒，只缓存域名仍会耗时；改为数字地址后前台 RPC 实测约 9.5 毫秒。不是另建通信框架。

正式模式没有 XCTest、屏幕读取、UI 点击、通知、剪贴板或音频保活。Mac 不写日历。手机默认进入 Wellphone；上游完整产品保留在 `--phoneagent-original` 启动参数下。

## 准备与启动

1. `bash scripts/apply_phoneagent_patch.sh`。首次克隆需要 `git submodule update --init --recursive`。
2. Xcode 打开 `PhoneAgent/PhoneAgent.xcodeproj`，沿用自己的 Signing。脚本不导出或改动个人 Team/Bundle ID。
3. 在 Mac 终端运行 `python3 scripts/configure_model.py`，隐藏输入 OpenAI API Key，写入被 Git 忽略的 `.env`（0600）。不要把 Key 发到聊天、手机或日志。也可设置环境变量。参考 `.env.example`；默认 `WELLPHONE_MODEL=gpt-4.1-mini`。需要代理时仅在本地配置 `HTTPS_PROXY`。
4. 在**准备阶段**运行 `xcrun xctrace list devices` 获取实际 UDID，然后 `python3 scripts/start_native_host.py --udid <实际UDID>`。此命令会安装并打开宿主，不得在游戏期间运行。无 XCTest 或调试器。
5. 手机点“准备连接和日历权限”。首次弹窗选完全访问，因为需要独立读取刚创建的事件。拒绝后可到「设置 → App → PhoneAgent → 日历」调整授权（名称取决于安装显示名称）。
6. 另一个终端启动 worker：

```bash
cd /Users/zhangkai/Documents/LLM_cost_router/Wellphone
python3 scripts/wellphone_worker.py
```

手机输入本次计划，保持测试模式，点“执行”后可留在 Wellphone 等待完成，也可切回游戏；切换不会取消同一任务。输入先在手机落盘，只有 Mac 落盘并回执后才显示“Mac 已接收”。无需逐项预览确认。返回后在“执行报告”打开任务；最终由用户主动打开系统日历核验。

## 计划契约

每批最多 8 个候选；超过则整个计划不执行并明确提示。支持未来的定时事件，包括当天尚未开始的时间；每项最长 24 小时；模型自主补齐的时段最长 3 小时，且不能覆盖本批明确事项；违反策略的候选逐项跳过，不修改其他明确安排。暂不支持全天、重复、邀请或提醒。

每项包含 `item_id`、语义类别和 title/start_at/end_at/time_zone/location。每字段包含：

- `value`（可为 null）、`source`（explicit/inferred/defaulted/unresolved）
- `evidence`（输入中真实片段或 null）、一句 `reason`
- `critical`（不可猜测的重要事实）、`blocks_creation`

GPT 判断语义重要性；代码拒绝把 critical 字段 defaulted，拒绝虚假的原文片段/不一致来源、非法时间/时区、过去时间、未知动作。必填字段 null 必须阻止创建。地点 null 可以不阻止创建。建议时段不代表已预约、不代表真实空闲；不读取私人日历做可用性检查。

使用 OpenAI Responses API 的严格 JSON Schema，以 anyOf 约束来源/null/阻止创建的一致性，并把 evidence 限定在本次输入的原文片段枚举（或 null），`store=false`，单次请求不自动重试。只发送本次文本和提交时间/时区，模型不获得执行工具。原文引用片段仅按标点/长度分段，不用关键词判断任务含义；语义决策仍由 GPT 负责。原文与日期/时区上下文分开传入；若模型把与手机提供值完全相同的时区当成原文引用，适配层将其改为 inferred、evidence=null，并在 Mac model.provenance_normalizations 记录原字段和修正理由。不会修正任意引文、猜测日期或把重要空缺变成事实。拒绝、格式错误、截断或 API 错误不进入执行。模型接口依据：[Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)、[GPT-4.1 mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini)。

## 生命周期、恢复与去重

- 点击执行开启一次系统后台任务，应用上限 45 秒；系统常可能提前收回。不会在后台续期。
- 前台可以立即执行，无需先切后台或等待 3 秒；后台执行仍要求有效系统 assertion 和大于 5 秒的系统预算。两种状态均要求原 45 秒单次窗口还剩大于 5 秒，每项写入前再次检查。
- 返回前台不再取消尚未到期的任务；已过期的任务不会因回到前台自动重新开启。切屏的 inactive 状态暂缓执行；只有手机明确回复尚未写入的 transition deferral，Mac 才可在恢复可执行状态后使用同一 lease 再发送。回执丢失仍不自动重发。
- 模型 HTTP 读取超时 22 秒；这不是严格端到端时限。真实耗时用 Mac monotonic 测量，手机窗口仍独立校验。
- 模型结束后重新获取状态，不能沿用模型请求前的预算。
- 窗口结束：Mac 保留计划；宿主恢复可连接后同步到手机，显示“计划已生成，日历未执行”。只有用户主动点击“继续执行这份计划”才创建新窗口；仍复用原 task/item/plan。
- Mac 每次发送执行前先落盘记录该 lease 已发送；响应丢失不重发、不换 ID，恢复后只查询手机报告。明确回复的切屏暂缓不属于结果未知，也不产生 EventKit reservation。
- 手机持久化不可变计划和任务状态；执行前先存 executing。重启看到 executing 会标 unknown，要求核验。
- EventKit ledger 保存 task/item、精确请求及结果；保存前先原子记录 reservation。重启后的 reservation 表示 unknown，禁止再次创建。同 ID 不同内容冲突拒绝。
- **不是跨 EventKit 和文件系统的严格恰好一次**。保存、独立查询和报告落盘之间仍有故障窗口；未知项需人工检查事件标识/日历，不能自动换 ID 重建。系统清除 App 数据或卸载后不再有旧去重账本。
- 一批部分成功如实记录。预算不足的剩余项不会偷偷安排另一次唤醒。第一版不提供部分失败事项的自动补偿。

## 报告与隐私

手机 Application Support/Wellphone 保存 jobs.json 和 ledger.json；Mac `wellphone-data/<submission_id>.json/.md`。包含原文、版本、字段来源、补齐/空缺、发送记录、手机保存和验证时间、事件 ID、实际读回和错误。保存与 verified 分开；混合成功显示 partial，不把候选理解完成当成日历完成。

这些数据、原始日志、API Key、签名仅本机保留。提交的 evidence 只能是脱敏验收摘要。模型的语义判断仍可能出错，应通过下面的真实验收评估，不能由契约测试替代。

## 验收记录

| 用例 | 自动验证 | 真实模型/手机 |
|---|---|---|
| A 4 条完整事项 | 4 候选契约接受 | 新输入 → 王者：4/4 保存并验证；用户体验正常 |
| B 灵活事项补齐 | 默认来源/可选地点空缺通过 | 整理房间建议 9 月 29 日 10–12 点，已保存并验证 |
| C 重要信息缺失 | 保留 null 并阻止创建；禁止 critical defaulted | 项目截止和预约课程的关键时间 null，未创建 |
| D 地点缺失 | 不阻止创建 | 早餐地点 null，事件保存并验证 |
| E 混合输入 | 手机逐项执行或跳过已实现 | 2 verified + 2 信息不足，报告 partial |
| F 重复、断连、冲突 | Mac 响应丢失/重启不重发、内容冲突拒绝 | 真机完成结果重放相同，ledger 10→10；冲突拒绝。全面故障注入待做 |
| G 模型慢/过期 | 旧预算不用于发送、过期不执行 | 实测窗口耗尽，未执行；用户主动继续后成功 |
| H 中文输入 | 不用 UI 自动化 | 用户确认键盘、焦点、候选词、画面全部正常 |
| I 人工日历核验 | 独立读回路径复用 Day 2 | 用户确认新增 10 条标题/时间/数量正确，无重复 |

自动检查：`python3 -m unittest discover -s tests -p 'test_*.py'`。Swift 纯 Foundation 测试分别编译 `CalendarEventInput.swift + tests/calendar_validation.swift`，以及 `CalendarEventInput.swift + PhoneAgent/PlanModels.swift + tests/day3_validation.swift`。原生日志仅在 `day3-artifacts/`。

## 复现源码

固定上游 `4f0e201572c2cc6f36bab1e1f80c61878b4a90b7`。`patches/phoneagent-day3.patch` 为从上游开始的累计源码补丁；`phoneagent-day2-to-day3.patch` 可升级未另行改动的 Day 2 源码。应用脚本先 check，再修改；存在其他修改时停止，不覆盖。共享源文件的 target membership 由 configure_native_host.py 添加，可容忍 Xcode 重排格式。个人 Signing 不包含在补丁中。上游 MIT 归属保持；不向 rounak 推送，不产生不可获取的本地 submodule commit。

下一步只根据真实验收修正模型语义/延迟和故障报告，不扩展通用 Agent。没有录像或性能采样，不声称全程无干扰或零掉帧。

## 真实模型开发记录（无日历写入）

本机 OpenAI Key 已配置并成功调用 GPT。初轮发现模型将手机时区错误标为原文引文，被来源校验拒绝；一轮混合计划还出现整理房间 11 小时并覆盖早餐的错误，结构校验本身未能发现。已加入逐项默认时长/同批冲突保护、字段 anyOf 一致性约束、原文与上下文分离以及可审计的时区来源纠正。失败样本和后续真实模型探针保存在忽略的 day3-artifacts/model-*.json，不把这些解析记录当成 EventKit 成功。

真实模型探针命令：`python3 scripts/check_model.py`。同时检查四条明确时间是否原样解析、灵活时段是否合理且不冲突、关键缺失是否保持 null、地点未知是否不阻止创建。它从不执行日历。

当前脱敏证据见 [day3-validation.json](../evidence/day3-validation.json)。新版已安装，完整验收见 [day3-report.md](day3-report.md)。早期一份窗口过期任务和一份模型引用失败任务仍保留历史，均未创建事件；不要为了清除失败状态而随意再次执行。

## 本机完整报告与服务

- 完整新输入游戏报告：`wellphone-data/AB10A81A-3333-4957-93B0-3675793131E2.json/.md`。
- 完整混合输入报告：`wellphone-data/76166FFC-DDC5-4709-B3FF-CA8760C57615.json/.md`。
- 手动继续报告：`wellphone-data/4BE5192D-5CF4-4531-8AE5-230630ABB194.json/.md`。
- 这些文件被 Git 忽略；上方脱敏证据不包含原始设备 ID、签名、API Key 或事件 ID。
- Mac worker 与转发器为本地前台命令进程，并非登录自启动服务。断开/退出后在准备阶段按部署步骤恢复；不要在游戏期间重跑安装启动命令。
- 正常计划可关闭“测试模式”；该开关只控制测试标题前缀，不改变窗口、校验与报告规则。

## 前台执行更新

按用户要求移除了仅后台可执行和后台停留 3 秒的验收门槛。Swift 策略测试覆盖前台、后台、切屏、预算不足、过期、存储故障和回前台；Python 覆盖前台发送、明确切屏暂缓后同 lease 继续以及丢失回执不重发。单次执行窗口仍为 45 秒，并未延长 iOS 后台时间。真机前台结果待本轮验收后记录。
