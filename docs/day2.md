# Day 2：iPhone 侧无 UI 日历执行

日期：2026-09-27。状态：XCTest 路线因系统覆盖层未通过屏幕要求；已改用原生宿主，在王者持续操作期间写入/读回成功，用户确认没有水印和先前的停手变暗。中文输入与候选词选择场景也已通过本次用户观察。

## 实现

Mac `scripts/calendar_task.py` 导入 PhoneAgent 原有 `rpc.py`，使用原有 TCP、CoreDevice 转发与 XCTest runner。在 iPhone runner 内调用 EventKit 保存事件，再用新的 `EKEventStore` 按事件 ID 查询并比对标题、起止时间、时区、无提醒/邀请/重复规则。Mac 不写日历，不调用云端 API，不接 LLM。

新增 `calendar_status`、`calendar_prepare`、`calendar_lock`、`calendar_execute`。只有 prepare 可请求系统权限。lock 在当前会话不可撤销，随后服务端拒绝所有非日历 RPC（stop 除外），包括截图、UI Tree、前台操作和模型调用。每个 execute 最多 3 项，逐项返回结果；没有 UI 回退和自动重启。

使用默认可写日历，标题必须以 `Wellphone Test ` 开头。只创建未来日期的测试事项，不修改已有事项、不邀请联系人、不设置提醒。报告只包含请求及按新建 ID 查询的事件，不枚举私人日历内容。

## 复现与启动

PhoneAgent submodule 仍固定于 `4f0e201572c2cc6f36bab1e1f80c61878b4a90b7`。Wellphone 的扩展保存在 `patches/phoneagent-day2.patch`，没有依赖无法下载的本地 submodule commit；保留上游 MIT 归属。个人 Signing 不在补丁中。

```bash
git submodule update --init --recursive
bash scripts/apply_phoneagent_patch.sh
# 首次部署：在 Xcode 为 PhoneAgent 和 PhoneAgentUITests 选择自己的 Team / Bundle ID。
bash scripts/start_calendar_bridge.sh
```

选择当次设备列表中的真实 iPhone，等 `PHONEAGENT_RPC_READY port=45678`。启动会打开 PhoneAgent，必须在用户进入游戏之前完成。不要在已应用补丁后用 reset 清理个人签名。

Xcode 26.2 的自动生成 Runner Info.plist 仅含旧版 `NSCalendarsUsageDescription`，测试 Target 的 `INFOPLIST_KEY_...` 不会传入 Runner。因此启动包装器复用官方脚本的发现/转发/签名流程，先 build-for-testing，再给**生成产物**加入 `NSCalendarsFullAccessUsageDescription`，用该产物现有公开证书指纹选择原开发签名，最后 test-without-building。未修改 Xcode 安装模板、证书、私钥、Team 或 Bundle ID。此适配与当前 Xcode 构建布局有关，升级后需重新核验。

终端 B（仓库根目录）：

```bash
python3 scripts/calendar_task.py status
python3 scripts/calendar_task.py prepare
# 用户在 iPhone 系统弹窗选择“允许完全访问”。
python3 scripts/calendar_task.py lock
```

要求 full access 是因为必须读取并校验刚保存的事件；write-only 无法满足读回验证。若拒绝授权，在准备阶段手动进入 **设置 → 隐私与安全性 → 日历 → PhoneAgentUITests-Runner → 完全访问**（实际显示名称以系统为准）。游戏期间不请求权限。

复制 `examples/calendar-task.json` 到本机 `day2-artifacts/task.json`，把 `session_id` 替换为 status 返回值，日期换为执行当天之后的日期。标题、起止时间必须明确，时区与 ISO 8601 偏移必须一致。然后由用户主动进入游戏或中文输入场景，确认开始后才执行：

```bash
python3 scripts/calendar_task.py run day2-artifacts/task.json \
  --output day2-artifacts/result.json
```

JSON 与同名 Markdown 报告来自真实 RPC 响应；传输失败标记结果未知，不会假定未保存。结束实验且用户停止当前操作后，可运行官方 `PhoneAgent/.agents/skills/phoneagent/scripts/rpc.py stop`。

## 状态与去重

每项包含请求、task_id/item_id、接收/保存/验证时间、事件 ID、readback、error；`save_status` 与 `verification_status` 分开。保存成功但读回失败为 `saved_unverified`，批次可返回 `partial`。

去重账本仅在 runner 内存中。同 session 的同 task_id/item_id、同内容重试返回原结果及原时间戳，`deduplicated=true`，不会再保存；不同内容返回 `id_conflict`。失败项也保留原结果，修改内容须新 ID。保存抛错保守记录 unknown，不自动重试。重试不会重新验证日历是否后来被人工改动。

请求必须含 session_id；runner 重启后旧请求被拒绝。**不具备跨进程持久去重或崩溃恰好一次保障**，不得自动替换 session_id 重发旧任务。重启恢复需先人工核对已创建事件。

## 验证记录

- 真机发现：通过；与 Day 1 相同 iPhone，已连接。
- Swift 真机构建：通过。
- 参数校验：1 个有效请求与 10 个非法时间/时区/字段用例通过；报告单元测试通过（通信未知、部分失败、RPC 拒绝等）。
- 补丁复现：可应用到原始上游源码，新增源码与当前工作区一致。
- 完整日历授权：iPhone 系统弹窗由用户确认，runner 返回 full_access。
- 单条写入/新 EventKit store 读回：verified，明天 14:00–15:00。
- 相同请求重试：同 event_id、同保存/验证时间，deduplicated=true；未再保存。
- 非法时间（结束早于开始）：failed / save_status=not_attempted。
- 同 ID 不同内容：id_conflict，未保存。
- 部分成功：已验证项目重放 + 非法项目返回 partial，保留各项结果。
- 实验 A 批次：用户回复“游戏中，开始发送任务”后发送，3 条事件全部 verified；Mac 21:25:21.627 → 21:25:26.800（Asia/Shanghai）。
- 实验 A（王者画面与操作影响）：用户报告没有明显切断操作的弹窗，但屏幕中央一直存在 Automation Running 图标，停手后变暗并显现水印。**不满足严格无干扰要求。**
- 停止 XCTest：会话 530.717 秒，1 test / 0 failures。用户确认水印消失。输入实验按用户要求暂缓。
- 分类：XCTest 系统自动化覆盖层限制，非 EventKit 保存失败。Appium 官方文档同样列出该限制，并指出截图无法显示此覆盖层。
- 实验 B（原生宿主）：用户持续中文输入并选词时，新事件 verified；用户确认无输入/候选词/画面异常。
- 用户主动打开日历核验：6 条测试事件全部存在，时间正确，没有重复。

Mac 和 iPhone 时钟未校准（观测到约 0.3 秒偏差）；只用同一设备的时间戳计算区间，不跨时钟计算延迟。

原始构建/设备日志、完整事件标识和个人签名快照只在已忽略的 `day2-artifacts/`。无录像和性能采样时，只记录 RPC 时间及用户观察，不声称“已证明全程无干扰”或“零掉帧”。

## 限制与下一步

这是开发签名下的 XCTest 实验通道，依赖 Mac、配对连接和 runner 存活；6 小时 test 等待上限不是后台稳定性承诺。没有静音音频保活，也不把普通 iOS App 视为永久服务器。

先完成两个人机共用场景的真机验收，再考虑 Day 3 的自然语言 → 有类型计划 → 用户确认歧义 → 此执行层。尚不开发通用 Planner、复杂前端或自动空闲时间安排。

参考：[Appium 官方 XCTest 已知限制](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/troubleshooting/index.md)、[Apple EventKit 授权](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)、[完整日历权限说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription)。

## 水印问题后的原生宿主实验（游戏、中文输入通过）

用户在王者中观察到了 XCTest 水印和停手后变暗；停止 runner 后水印消失。因此没有继续把 XCTest 路线包装为无干扰成功。

替代宿主使用现有 PhoneAgent App 的签名与 target，直接编译共享的 `SimulatorRPCServer.swift`、`CalendarBridge.swift`、`CalendarEventInput.swift`。没有重写 server 或 EventKit 实现；不启动 XCTest、不连接调试器。`scripts/configure_native_host.py` 仅添加源文件 target membership，保留用户 Team / Bundle ID。

```bash
# 只在用户结束游戏、进入准备阶段时运行：这会打开 PhoneAgent。
xcrun xctrace list devices
python3 scripts/start_native_host.py --udid <当次真实设备UDID>
# 另一终端，完成原生 App 自己的首次权限（与 XCTest runner 不同）：
python3 scripts/calendar_task.py prepare
python3 scripts/calendar_task.py lock
```

宿主提供一个**最多 45 秒且系统可提前结束**的导入窗口。用户在手机上手动点击“开启一次导入窗口”才调用 `beginBackgroundTask`；没有后台续期。一个 `calendar_execute` 响应发送完毕后立即结束后台任务并停止 server；系统到期也停止。普通 App 仍可能被挂起或终止，**不是永久后台监听方案**。

为了不把人回复消息的时间耗在窗口里，先启动客户端：

```bash
python3 scripts/calendar_task.py run day2-artifacts/task-native-game.json \
  --wait-for-background --output day2-artifacts/native-game.json
```

随后用户点击宿主按钮，立刻切回已加载的王者并持续操作。客户端只查询宿主自身生命周期；观测到已 arm 且宿主处于后台后，再等 8 秒才发送日历任务。服务端还会检查执行时确实是 `.background`。任务 JSON 必须含本次 status 返回的 session_id，不会自动替换旧 session ID 重放。游戏是否已经开始实际交互仍需用户观察确认，不能仅凭宿主后台状态推断具体前台 App。

当前原生 App 已完成安装、RPC 连通、完整日历授权。后台游戏任务已保存并独立读回 verified：Mac 21:39:26.686 → 21:39:31.934，手机返回 application_state=background、剩余系统后台预算约 14.29 秒。用户确认当时持续玩游戏，没有水印，也没有之前的停手变暗。中文输入实验也已通过：Mac 21:43:13.427 → 21:43:18.660，手机仍处于后台，剩余系统后台预算约 13.88 秒。用户确认输入和候选词正常，没有水印、切屏或弹窗。`execution_location=iphone_native_app` 将区分此路与旧 XCTest 证据。历史 RPC 字段 `deduplication_scope=this_runner_session_only` 在复用宿主中同样仅指当前内存会话，不具备跨进程保障。

## 本次证据与后续边界

- 原始结果（本机）：`day2-artifacts/05-single.json`、`06-retry.json`、`07-invalid.json`、`08-conflict.json`、`09-partial.json`、`10-game.json`（XCTest 路线）；`23-native-game.json`、`25-native-typing.json`（原生路线），各有同名 Markdown。
- 可公开的脱敏摘要：`evidence/day2-validation.json`，保留实际状态、时间及测试事件字段，不含事件 ID 或个人签名。
- 原生宿主只重用了已通过批次/去重/参数测试的执行层；本次原生路线实测为两次单项任务，未重新宣称原生三条批次与跨重启去重都测试过。
- 尚未验证：长时间游戏后再下发任务、后台过期恢复、断线恰好一次、App 被系统杀死后恢复、正式录像/帧率指标。普通 App 不支持无限后台等请求，不能把这次成功扩写成全天待命。
- 下一步应围绕“用户提交计划 → 立即开始短任务 → 用户切回游戏”的生命周期设计自然语言入口；先明确有限窗口和恢复流程，再接最小解析层。

## 收尾

用户最终主动打开日历，确认 6 条测试事件均存在、时间正确、没有重复。本次 Day 2 的有限窗口核心演示已完成；XCTest 方案的屏幕干扰不能算通过，成功结论来自之后的原生宿主游戏/输入两次实验。未录制连续外部视频、未采集帧率。

Mac 转发器已清理，127.0.0.1:45678 不再监听。手机侧每次原生导入均在响应后结束后台任务；未在后台自动重启。6 条测试事件保留供用户检查，没有删除或修改已有事件。

最终本地检查：Swift 时间/Schema 11 个用例、Python 报告/不发送失败路径 4 个测试、真机构建、原始上游补丁复现、plist/Shell/Python 语法、diff 空白检查和个人标识排除检查通过。Day 2 改动保存在本地工作区，尚未 commit/push；PhoneAgent gitlink 仍是原上游提交，新增代码由主仓库补丁完整承载。
