# AgentX 仓库整合

本次将 AgentX 提升为仓库根目录唯一工程，仓库与本地目录统一命名 AgentX。移除旧测试日历工程、PhoneAgent 子模块、旧启动器和旧产品文档；已有 Git 提交历史保留，用于追溯技术演进。

## 当前目录

- `AgentX/`：SwiftUI 界面、原生 EventKit 执行、任务持久化与 RPC。
- `AgentX.xcodeproj`、`AgentXConfig.plist`、`Config.xcconfig`：工程及共同配置。
- `scripts/`：模型协议、worker、一键启动器、注明来源的传输组件。
- `tests/`、`docs/`、`evidence/`：回归、设计与合成/去标识验证记录。
- `data/`、`artifacts/`、`.runtime/`、`.env`、`Signing.local.xcconfig`：本机文件，不提交。

## 配置迁移

模型变量统一为 `AGENTX_MODEL`，配置脚本随项目一起交付。现有本机配置已原位迁移，Key 不输出、不进入 Git；不再读取父目录 `.env`。既有 AgentX 的本机签名标识、任务账本和手机沙盒不因仓库更名而改变，不重新创建历史事项。旧工程与本机未提交修改在仓库之外保留私有备份。

用户安装与启动以根 README 为准，无需下载旧子模块。历史实验文档记录当时结果，协议与预算以当前架构文档及源码为准。

## 本次验证

迁移回归与公开前审查结果见 `evidence/repository-consolidation.json`。本次整理不构成新的真机业务验收，也没有重新执行已有日历任务。
