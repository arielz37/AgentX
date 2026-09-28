Day 3 已完成真机最小闭环验收，见 [真实报告](day3-report.md) 与 [部署/限制](day3.md)。下一步优先准备 1–2 分钟同屏演示、扩充自然语言测试样本及故障恢复验证；不需要立即扩展通用 Agent。以下保留之前的路线记录。

# 下一步：先证明不打扰，再接入规划

> Day 2 更新：本页保留 Day 1 时的路线假设。实际发现 XCTest 水印影响屏幕；原生宿主已在有限后台窗口内通过游戏和中文输入实验。最新证据与限制以 [Day 2](day2.md) 为准。

状态：以下是 Day 1 时的建议与待验证假设。按最初约定的 4 天开发预算安排；面试题原文的 7 天截止以实际收到题目的时间为准。

## 判断

题目允许自选任务，不要求所有任务都通过 UI 完成。应把“用户独占屏幕与键盘”作为执行层硬约束，先找到不依赖这些资源的真实任务。Day 1 已有真机 RPC 通道，继续加 LLM 并不能解决 XCTest 前台 UI 与人的竞争。

建议先做 iOS 原生语义操作实验：复用现有 XCTest-hosted RPC，在受控、预先授权的范围内尝试调用 EventKit 读写测试日历/提醒事项。人机并行阶段禁用 `open_app`、`tap`、`enter_text`、`swipe` 等前台动作。这不是通用第三方 App 后台 UI 自动化，必须如实说明能力边界。

关键假设：XCTest runner 在用户 App 前台期间可完成被授权的 EventKit 操作，并在演示时持续响应。Day 1 的 runner 在 Settings 前台时存活约 5 分钟，支持尝试该假设，但没有证明 EventKit 权限或人机并行执行成立。先给这个实验最多 2–3 小时。

## 路线比较

| 路线 | 可取之处 | 未解决的问题 | 优先级 |
|---|---|---|---|
| iOS 原生语义操作 + 现有 RPC | 继续使用现有真机；数据真正在手机侧落地；不需模拟键盘 | Runner 的权限、生命周期、真实 App 持续使用时的行为要验证；仅支持开放 API 的任务 | 先验证 |
| Android + scrcpy 虚拟显示 | 同一物理手机可有独立显示面，复用成熟项目 | 独立画面不等于独立焦点/IME；厂商兼容、目标 App、输入与树的 display 路由均要验证 | 有 Android 真机时，限时备选 |
| 当前 iOS 前台 XCTest + LLM | Day 1 能力可直接复用 | 会激活 App、改变画面、使用当前键盘，违背核心验收 | 仅作基线/设置阶段 |
| 仅云端 API 或电脑浏览器操作再同步手机 | 部分业务容易完成 | 可能无法证明任务由同一台手机执行，应明确远端执行边界 | 不作为主要演示证据 |

## Day 2：无模型的隔离可行性验证

1. 一次性准备测试清单/测试日历，事前获得用户授权；权限弹窗只发生在准备阶段。
2. 用户打开第三方聊天 App 并持续输入；Mac 在用户开始使用之后发送固定任务。
3. 手机侧创建一条新提醒事项，返回本机保存的记录 ID，再独立读取校验。
4. 用户切换 App、连续打字、滚动时重复执行；Agent 不打开任何 App，不显示通知横幅，不触碰剪贴板/键盘。完成状态先显示在 Mac。
5. 两路同步录像：持续展示物理手机和 Mac 任务时间线。任务接收、保存、验证时间必须落在用户持续使用区间内。
6. 若 EventKit 在测试 runner 中无法授权，先分析错误，再决定是否需要最小原生宿主；不要把 iOS 普通 App 的后台延时当永久后台服务器。

停止条件：2–3 小时内连“用户打字时手机侧创建一条提醒事项”都无法稳定证明，则暂停模型开发，评估 Android 真机路线，不靠隐藏切屏凑演示。

## Android 备选实验

复用 scrcpy 的 `--new-display` 与 `--start-app`，从实际设备发现 display ID。虚拟显示存在于同一部手机，Mac 只负责控制与展示。先测试用户在主屏连续中文输入、Agent 在虚拟显示执行另一任务。

必须分别验证：主屏画面不变、输入焦点不变、中文输入法候选不丢、字符不串入其他窗口、Agent 截图与 UI Tree 来自目标 display。`--display-ime-policy=local` 只控制 IME 展示位置，不能当作双输入会话的证明。禁止默认使用系统剪贴板共享输入。

当前 PhoneAgent Android 脚本使用普通 `input`、`uiautomator dump`，没有 display 选择参数，不能直接声称其支持隔离显示。若采用此路，需要最小范围添加/复用 display-aware 适配，先证明图片/点击/文字均指向正确 display。Android 文档明确存在焦点和单 IME 的约束；厂商 ROM 还可能不同。

## Day 3：只完成一个有用任务

建议任务：将用户给定的一段行程/待办说明，结合已授权的日历空闲时段，生成若干提醒事项和日程。用户一直聊天或刷信息流，完成后自行打开系统 App 查看真实结果。

隔离实验通过后，再加入最小规划层：自然语言 → 有类型的计划 → 参数/权限校验 → 顺序执行 → 读取验证。模型不能在执行阶段选择前台 UI 原语。加入 task_id、重复请求去重、逐步结果与部分失败报告；不得仅凭模型宣称“完成”。不做通用 Agent 框架、复杂多 Agent 或 token 优化。

## Day 4：验收、录屏、答辩

- 10 次同类任务重复验证，报告实际成功率及失败原因。
- 强干扰用例：用户持续中文输入、选择候选、切换 App、滚动，而非仅播放视频。
- 主屏 Agent 触发的切换次数为 0；输入丢字/串字为 0；任务实际落地且没有重复创建。
- 录制 1–2 分钟连续演示：说明任务 → 用户持续操作 → Mac 显示完成 → 用户主动打开结果 App 核验。
- README 保持一页，完整部署另放文档；明确复用部分、本人新增部分、局限和失败记录。私有仓库在正式提交前需授予面试方访问权限。

## 一手资料与推论边界

- [Apple EventKit：创建日历事件与提醒事项](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders)：获得授权后可用原生 API 写入数据，无需操作系统 App 的 UI。这支持语义操作方向，未证明在本项目 runner 中可用。
- [Apple：延长 App 后台执行时间](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)：普通后台 App 可能被挂起，有限延时不能代替常驻执行通道。
- [Apple：App Intents 运行方式](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)：可作为后续正式产品的系统集成方向；存在后台 Intent 不意味着能任意后台操控其他 App。
- [scrcpy 虚拟显示](https://github.com/Genymobile/scrcpy/blob/master/doc/virtual-display.md)：支持新虚拟显示、启动 App 与 display IME policy；未承诺两个操作者的完整资源隔离。
- [AOSP：Per-display focus](https://source.android.com/docs/core/display/multi_display/displays#per-display-focus)：焦点策略是独立问题，不能只看截图。
- [AOSP：IME support](https://source.android.com/docs/core/display/multi_display/ime-support)：文档描述单 IME 在显示间迁移；目标机型必须验证并行输入。
