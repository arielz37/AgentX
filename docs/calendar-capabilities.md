# 自然语言日历能力（版本 3）

目标是让自然语言映射到实际 EventKit 字段，而不是把所有请求变成单次事件。Mac GPT 生成候选计划；iPhone 校验、创建、重新查询并比较字段。仍支持留在前台完成或在有限后台窗口内继续，无 UI 自动化。

## 当前能力

| 输入意图 | 实际执行与边界 |
|---|---|
| 每天、每周五、每周二和周四、隔周 | 一条 `EKRecurrenceRule` 系列；每 N 个周期，N=1…99；星期采用事件时区 |
| 每月 15 日、每月最后一天 | monthly 的日期选择器；31 日在没有 31 日的月份跳过，不擅自换为月末 |
| 每年公历 5 月 20 日 | yearly 的公历月日；不支持农历 |
| 共六次、到某日为止 | 包含首次的总发生次数（1…1000），或包含截止当天；没有要求则不设结束日期 |
| “每周五早上我都要去游泳” | 每周五重复；个人活动可建议早上时段，报告将开始、结束标为自动补齐；地点未知保留为空 |
| 下周六到周日全天 | `isAllDay=true`，起始为周六当地零点，结束为周一零点（排他边界） |
| 明晚十点到后天六点、明确多日活动 | 实际起止日期，最长 366 个当地日；自主建议的定时活动仍限制 3 小时 |
| 备注带泳镜、提供资料链接 | 写 `notes`、`url`；URL 只能来自用户原文且使用 http/https，不打开链接、不猜链接 |
| 提前两小时提醒 | 沿用自适应提醒；重复系列使用相对提醒，随每次事件触发 |

**尚未实现：** 农历、节假日/调休例外、每月第 N 个星期几、单次重复例外、指定日历、忙闲状态、附件、邀请人、查询空闲时间、修改或删除已有事件。模型应将无法满足的要求标为 unresolved/unsupported，整项不创建，不静默降级。结构和明确的农历/调休来源有二次拦截；模型仍可能误解未覆盖的自然语言，不能承诺任意表达绝对正确。操作范围是创建，不代表已经预约或通知他人。

重复系列上的绝对日期提醒暂不支持，保留原要求、报告该提醒未配置，事件和其他有效相对提醒可以保存并标 partial。不会把“某天提醒”偷换成“每次都提醒”。系统通知送达仍需要单独观察。

## 执行与核验

新提交为 `version=3`，每项新增 `calendar`：`is_all_day`、`notes`、`url`、`recurrence`、`reason`、`unsupported`。重复含频率、间隔、星期/月日/月、结束类型/次数/日期、原文证据及原因。原始计划不可变。

手机验证日期和时区、全天当地零点、首次日期是否符合重复选择器、截止日期是否早于首次；拒绝非法组合。多星期几映射为同一个系列；同一原文被拆为明显重叠的周重复系列时，后续项被拦截并说明原因。

保存后使用新的 `EKEventStore` 按事件 ID 重新查询。比较标题、起止、时区、地点、全天、备注（含任务标识）、URL、完整重复规则和结束条件，以及提醒。规则丢失、间隔或结束条件改变均不算 verified。报告包含 `calendar_features_verification_status` 和实际 `readback.recurrence_rules`；手机报告可展开查看，Mac JSON/Markdown 同样保留。这是规则配置读回验证，不声称遍历证明了未来所有发生日期。

去重仍是持久化的 task_id/item_id；重复选择器排序后比较，星期数组重排不产生新系列，改次数或备注等内容会冲突。未知保存结果禁止自动重建。历史 v1/v2 任务不添加重复、不重新解析，原来已建的单次“游泳”不会自动升级或删除；需要用户主动整理旧测试事件，避免和新系列并存。

## 部署与使用

1. 在准备阶段结束游戏/输入，连接并解锁 iPhone。
2. 首次拉取源码执行 `bash scripts/apply_phoneagent_patch.sh`，保留个人 Signing；原 Day 2、Day 3、提醒版均有受检查的升级补丁。
3. 更新 iPhone App：停止旧转发器后运行 `python3 scripts/start_native_host.py --udid <实际设备UDID>`；安装会打开 App。
4. 正常停止旧 Mac worker 后启动新版 worker；日常继续使用根目录“一键启动”入口。旧服务被复用不会自动加载新 Python 代码，升级后必须重启 worker。
5. 手机“重复与全天示例”包含有限四次游泳及两天全天活动；保持测试模式，点执行。可留在前台，也可切回游戏。回来查看报告，再由用户手动打开系统日历核对重复和结束条件。

单次执行仍限 45 秒，后台时间可被系统提前收回。连接中断或时间不足时不偷偷切屏或重放；查看报告后按既有继续流程处理。

## 验证

```bash
bash scripts/test_alerts.sh
# 真实 GPT，仅合成输入，不调用日历 RPC：
python3 scripts/check_calendar_features_model.py
```

本轮完成：40 项 Python 测试、Swift 日期/规则/生命周期回归、EventKit 测试替身的保存/读回/故障/重启去重测试、iOS 无签名及现有签名构建。六组真实 GPT 最终回归通过，覆盖原句、多星期几隔周、月末/年重复、全天备注链接、跨夜/每日截止、未支持规则。初轮发现重复拆分、空原因、农历误映射，增加约束/拦截后重测通过；这不等于模型永不出错。

原始合成结果仅在被忽略的 `calendar-features-artifacts/`，脱敏结果见 `evidence/calendar-capabilities-validation.json`。真机保存/系统日历 UI/后台游戏的新版验收状态以该证据文件为准，离线和模型测试不能替代真机验收。

可复现累计补丁为 `patches/phoneagent-calendar-features.patch`，旧补丁保留为历史基线。共享源文件 `CalendarFeatures.swift` 由配置脚本加入 App target；不包含个人签名变更，不向上游推送。

参考：[Apple 重复事件](https://developer.apple.com/documentation/eventkit/creating-a-recurring-event)、[EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)、[全天事件](https://developer.apple.com/documentation/eventkit/ekevent/isallday)。

安装记录（2026-09-29）：新版已使用本地签名安装到配对 iPhone，系统启动成功并确认进程存在；Mac worker 已重启。安装后 RPC 曾暂时超时；用户手动打开准备页面后恢复，已确认原生宿主、full_access 和前台状态，用户确认能看到“重复与全天示例”。尚未提交本轮真机测试事件。
