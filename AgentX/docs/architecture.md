# 设计、隔离与扩展

## 页面与交互

`AssistantModule` 定义名称、图标、主题色、欢迎语与示例。首页按固定顺序显示全能助手、日程助手与能力目录。两个模块共用 `AssistantChatView`，以 `assistant_id` 分组持久化任务；输入草稿各自保留在内存中。示例只填入草稿。每条输入独立处理，不暗示可以编辑上一条计划。

聊天记录由真实 `PlanJob` 渲染，一次提交对应一张更新中的卡片。状态为理解与复核中、准备执行、执行中、完成/部分完成/未完成、等待继续、结果待核对等。不为未知模型阶段制造进度。状态刷新不调用滚动；仅用户成功提交时滚至底部。任务报告由当前任务 ID 获取最新结果，返回首页或打开报告不会执行任务。

日程范围不匹配时，按钮把原始文本放到全能助手的草稿中并切换页面，没有调用 `submit`。邮件/短信目录项不可安装或执行。模型错误、服务断开和范围不匹配独立呈现。系统弹窗仅在用户点击准备按钮时申请权限。

## 执行与路由

手机创建带 `ax-` 前缀的任务并原子持久化，Mac 轮询领取。`agentx_model.py` 在第一次请求同时生成 route 与 plan，再进行一次独立复核，共两次调用，共享 22 秒预算。第二次收到原始输入、冻结时间上下文和候选，不继承首轮会话。时间比较辅助信息不选择或重写日期。

输出结构按四种路由分支约束：calendar 必须有计划；unsupported、clarify、mixed 的 plan 必须为 null。Mac 校验与手机 `AgentXRouting` 再做白名单及结构检查。模型不返回可执行 RPC 名称，worker 只调用固定的计划协议。语义分类本身仍可能错，两次模型检查不提供数学保证。

混合请求本轮采用整体不执行策略，列明支持和不支持的动作，让用户单独提交日程请求。因而不会静默做一部分后宣称全部完成。重要日历事实空缺仍属于日程输入，沿用 blocked/defaulted/inferred 契约。

`CalendarHost` 复用原有限窗口与显式继续机制：前台也可执行，后台须持有合法的系统 assertion 和足够剩余时间。页面展示、导航和恢复前台不会重开旧窗口。已提交计划不可变；worker 发送执行前记录“结果未知”，仅收到明确“尚未写入的界面过渡延期”时才重试同一 lease。EventKit 账本在保存前落盘，保存后通过新的 store 重新查询比较，支持同 ID 跨进程去重；结果未知不自动新建。

## 独立通道

| 内容 | AgentX | 旧版 |
|---|---|---|
| Project / scheme | AgentX.xcodeproj / AgentX | 原 PhoneAgent |
| Bundle / 沙盒 | 本机单独配置 / AgentX | 保持原标识与沙盒 |
| 手机与 Mac 转发端口 | AgentXConfig.plist，默认 45679 | 45678 |
| RPC 标识 | client=agentx, protocol_version=1；响应 app_id=agentx | 原协议 |
| Mac 记录 / 锁 | AgentX/data、AgentX/.runtime | 原目录 |
| 手机记录 | Application Support/AgentX | 原沙盒 |
| 测试事件 | AgentX Test / ax-任务 ID | 原前缀/ID |

启动器仅复用精确路径、端口和目标设备一致的本项目转发器；遇到占用拒绝启动，不终止其他进程。客户端拒绝不匹配的响应标识，无旧端口降级。RPC 标识用于防混线，**不是密码认证机制**；沿用原桥接的连接范围，使用可信本机与已配对设备。两个 App 不承诺同时后台常驻。

## 复用边界

复用 Rounak 的 PhoneAgent RPC server、rpc.py、CoreDevice/usbmuxd 转发实现，以及当前 Wellphone 原生 EventKit、计划契约、复核与 worker 实现的独立源码快照。具体原文件和 SHA-256 见 `SOURCE_SNAPSHOT.json`；基础上游提交为 `4f0e201572c2cc6f36bab1e1f80c61878b4a90b7`。CalendarHost 与报告从原混合文件抽取，业务代码含本地尚未提交的 Wellphone 扩展，不能冒称都是上游能力。

新增部分为独立工程、模块配置、主页/统一聊天/目录/设置、受限路由及复核协议、独立启动与验证。未复制 GUI 自动化动作、XCTest runner、旧产品的大模型主界面；新 App 不使用 XCTest 驱动手机。所有必要快照随 AgentX 源码交付，无不可获取的 submodule 本地提交依赖。已回退的日期编译器与全天规范化没有迁入。

## 下一项能力如何扩展

先确认 iOS 原生 API 能执行、权限范围和前后台限制，再增加一个明确受限的业务契约与执行器。只有真实执行与读回/验证通过后，才加入 `AssistantModule` 和模型、Mac、手机三处白名单，更新版本并加拒绝/部分成功/重试测试。不要把通用方法名或模型自由生成代码交给执行层。发送类动作另行设计收件人和发送确认，不能复用日历自动补齐身份信息的方式。

## 预览

Debug 参数 `--agentx-preview` 使用独立预览路径，不启动服务器、不加载真实任务、不允许提交/授权。可叠加 `--preview-chat`、`--preview-long`、`--preview-keyboard`、`--preview-catalog`、`--preview-settings`。Release 不开启该入口。截图标注预览，不用合成成功冒充真机结果。
