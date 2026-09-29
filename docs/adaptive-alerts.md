# 自适应日历提醒

## 当前状态（2026-09-29）

已实现模型规划、手机策略、EventKit 保存/独立读回、双端报告及 v1 历史兼容。iOS 原生 App 无签名编译通过；28 项 Python 测试及 Swift 策略、生命周期、执行故障回归通过。四组真实 GPT 合成语义测试通过，耗时约 5.7–13.0 秒。

**新版已使用现有签名构建并安装到真实 iPhone；首次启动被系统以 Locked 拒绝；用户解锁后已启动，RPC 和 full_access 已确认。前台三项事件与提醒保存/读回已验证；用户反馈首轮日历结果正常，随后确认第二轮未进行并要求停止测试；后台、逐条提醒 UI 核对及通知触发仍待验证。** Day 3 的无提醒事件验收不能代替本次提醒验收。

## 产品规则

先解释指令作用域：明确的单项例外优先于一般要求；同一作用域内矛盾且无法解释则保留 unresolved。其次，禁止提醒优先于模型建议，明确时间/次数不被追加，未指定时模型建议 0–2 次，优先一次。模型只使用输入及提交日期/时区；不读取无关日历、不假定交通或用户作息。

第一版上限两次是产品限制，并非对所有日历服务的保证。按实际触发时刻去重后超过两次（或用户更小的次数限制）时，整组不设置，不挑一个子集。即使其中某条已过去，也不借此将超量请求静默变成子集。最多表示 16 条原要求，更多用 overflow=true、空列表明确拒绝提醒部分；不阻止有效事件保存。

“提前一天”是开始前 86400 秒；“前一天上午九点”按事件时区前一个自然日 09:00 解析成绝对时间。夏令时下两者可能相差一小时。后者的自然语言日期计算由模型完成，Swift 检查时间/时区合法；模型语义仍可能错误。

相对 offset<=0，绝对时间不得晚于事件开始。偏移额外限制在十年以内以限制无意义值。`AlertPolicy.minimumLeadSeconds=300` 集中定义保护：保存前按手机当前时间剔除已过去或不足五分钟的提醒，不换成即时提醒、不再调用模型。事件和其他有效提醒仍可保存，但整项为 partial。当前不支持地点/邮件提醒、事件开始后的提醒、独立通知。

## 数据契约与兼容

新提交 `version=2`，每个 PlanItem 有 `alerts`；旧 version=1 保持原模型 schema、无提醒，不给旧计划添加默认建议、不重新解析或执行历史任务。Swift optional 字段允许原 jobs.json 读取；历史结果不冒充新版提醒验证。继续已过期的旧计划仍然无提醒。

```json
{
  "mode": "explicit",
  "evidence": "提前一天提醒我",
  "reason": "按用户要求，仅一次",
  "count_limit": 1,
  "no_extra": true,
  "overflow": false,
  "items": [{
    "alert_id": "a1",
    "trigger_type": "relative",
    "offset_seconds": -86400,
    "at": null,
    "source": "explicit",
    "evidence": "提前一天提醒我",
    "reason": "用户指定"
  }]
}
```

模式 explicit/disabled/suggested/unresolved；建议项 source=defaulted。absolute 用 `at`、offset=null；relative 反之。原文证据限制在输入片段枚举，Mac 和手机再次校验。模式语义由 GPT 判断，结构约束不能保证其语义判断必然正确。无事件开始时间时保留相对提醒意图，但事件阻止创建，不产生独立通知。

原计划保持不可变，`planData` 保留原请求。执行报告独立保存 requested、configured、decisions、readback；不以过滤后的配置覆盖原要求。手机传给执行器的 Codable 对象可能省略 null，可选字段语义相同。

## 保存与验证

继续复用 PhoneAgent RPC/转发和 CalendarBridge。事件与提醒同一次 EventKit save，不二次补写，不调用日历 UI。创建前先记录 reservation；保存后记录事件 ID，使用新的 EKEventStore 按 ID 查询，不枚举其他私人事件。

读回保留每条提醒的类型、offset、absolute_at、trigger_at、位置/接近信息。比较数量及排序后的触发时刻，误差必须小于一秒，拒绝额外、缺失、重复或位置提醒。允许相对/绝对表达对应同一触发时刻：这是 Wellphone 的**时间等价验证规则**，不是声称 Apple 一定进行这种转换。事件标题/起止/时区等另行验证；未来改期功能尚未实现。

状态分三层：
- `event_verification_status`：事件字段读回结果。
- `alerts.verification_status`：实际准备写入的提醒配置是否匹配（包括空列表）。
- `alerts.user_requirement_status`：met/unmet/unknown/pending_verification/not_specified。建议被过滤时用户要求为 not_specified，但 policy_complete=false，整体仍 partial。

整体 verified 要求事件及提醒匹配且提醒策略完整；保存成功、部分提醒未满足为 partial；读回不匹配为 saved_unverified。若事件保存失败或结果未知，不假装配置成功。无提醒模式实际出现默认提醒同样验证失败。

通知由系统日历触发，未来不依赖 Mac 或 Wellphone 在线。**配置已验证不等于通知已送达**；通知权限、专注模式、账户和系统行为仍可能影响展示。本功能不修改这些设置。

## 去重、故障与运行窗口

去重键仍为 task_id/item_id。提醒原请求属于 payload，按稳定 alert_id 排序后比较，单纯数组重排不产生新请求；修改提醒内容明确冲突。原始顺序仍保存在报告。账本兼容旧 payload，不在旧任务上补写提醒；重放返回原结果和原验证时间。提醒被过去/过近策略剔除的 partial 也不自动重写。

文件账本与 EventKit 不是跨存储事务，不承诺严格恰好一次。保存过程中失败/断连/重启可能为 unknown，禁止新 ID 自动重建。已有前台/后台/切屏策略保持，单窗口最多45秒且后台可提前结束；每项写入前检查。未引入额外保活、UI自动化或即时通知。

## 启动和测试

准备阶段（安装会打开宿主，先结束游戏/输入）：

```bash
bash scripts/apply_phoneagent_patch.sh
xcrun xctrace list devices
python3 scripts/start_native_host.py --udid <本次实际设备UDID>
# 另一个终端，旧 worker 先正常退出，不能并行启动两个：
python3 scripts/wellphone_worker.py
```

继续使用已有 Mac .env，密钥不发到手机/日志。提醒属于事件，无需申请 Reminders 权限，不额外申请本地通知权限。需要 EventKit full access 以读回；只在准备阶段由用户确认。

```bash
bash scripts/test_alerts.sh
python3 scripts/check_alerts_model.py
# 单个真实模型探针（从不写日历）：
python3 scripts/check_alerts_model.py --only scope
```

合成输入见 `examples/adaptive-alerts.txt`，手机新增“提醒示例”按钮。正式写入仍由用户在手机点击执行，避免把模型探针误当手机执行。

自动测试包含 Python 契约/worker、Swift 时间策略/DST/读回比较/历史计划，以及编译实际 CalendarBridge 搭配 **EventKit 测试替身** 的 reservation、重启重放、冲突、保存后异常、提醒丢失/增加/改时/乱序/等价绝对时间。这些测试不会写系统日历，不能替代真机 EventKit 验收。

真实 GPT 四组：明确一次/两次；全局禁止与面试例外；绝对时间、三次超量请求及未知课程时间；自主建议。均为合成文本，原结果在忽略的 alert-artifacts/model-*.json，不代表任意输入稳定。

## 真机验收计划与证据

A 前台：测试模式提交“提醒示例”，留在 Wellphone，核对明确两次、系统建议、禁止提醒三种情况。B 后台：先载入游戏或备忘录，再提交第二段示例，切回持续操作；完成后手动核对系统日历的提醒设置。不能通过 Agent 自动切屏验证。

额外验证 partial、同请求重放、提醒内容冲突；不创建第二份事件测试重试。数据和事件 ID 只保留本机。通知触发为独立观察实验，应事先告知用户并在并行验收结束后进行，提醒至少五分钟之后，不改专注模式；用户不方便则明确待验证。

前台真实执行 JSON/Markdown 位于 wellphone-data/5976F65C-4BE1-45AD-826D-87817C4347A1；三项均 verified，执行状态foreground。用户随后澄清第二轮没有提交，后台验收未进行；按要求交由用户稍后手动测试。模型原结果、编译及测试日志保存在被忽略的 `alert-artifacts/`；脱敏状态见 `evidence/adaptive-alerts-validation.json`。

## 可复现源码

上游仍固定 `4f0e201572c2cc6f36bab1e1f80c61878b4a90b7`，保留 MIT 归属。`phoneagent-alerts.patch` 是完整累计补丁，`phoneagent-day3-to-alerts.patch` / `phoneagent-day2-to-alerts.patch` 是升级补丁。原 Day 2/3 补丁保留为历史基线。应用脚本先 check，差异不匹配则停止，不覆盖签名。configure_native_host.py 只添加共享源文件 target membership，不修改个人 Team/Bundle ID。

参考：[Apple EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm)、[提醒设置](https://developer.apple.com/documentation/eventkit/setting-an-alarm)、[relativeOffset](https://developer.apple.com/documentation/eventkit/ekalarm/relativeoffset)、[EventKit 权限](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)、[OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)。
