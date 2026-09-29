# Mac 一键启动

完成首次部署、模型配置和 iPhone App 安装后，日常无需重新编译。

1. 用 USB 连接已配对的 iPhone，并解锁。
2. 在 Finder 中进入项目目录，双击 **启动 Wellphone.command**。
3. 在 iPhone 手动打开 Wellphone，等待终端显示连接正常。首次使用需点“准备连接和日历权限”，允许完全访问。
4. 输入计划、点执行；可留在前台，也可切回游戏，稍后查看报告。

启动器自动发现真机，启动现有 PhoneAgent 转发器和 Wellphone 模型 worker。多台 iPhone 时会要求选择。已有的本项目、同设备转发器及默认数据目录 worker 会被复用；其他进程占用端口时明确报错，不强制结束。不会编译、安装、打开手机 App 或创建测试任务。worker 启动后会按原有协议处理手机提交的任务。

**使用期间保持 Mac 不休眠、设备连接，以及承载服务的终端窗口开启。** 按 Control+C 停止本窗口启动的服务；复用的旧服务需在其原终端停止。若提示两个服务原本已运行，新窗口可关闭，原终端仍须保留。脚本结束后按回车关闭窗口。

也可在终端运行：

```bash
cd /Users/zhangkai/Documents/LLM_cost_router/Wellphone
./"启动 Wellphone.command"
# 仅检查环境和服务，不启动服务或发送任务：
python3 scripts/start_wellphone.py --check
# 多台设备时可指定实际 UDID：
python3 scripts/start_wellphone.py --udid <实际真机UDID>
```

需要 Python 3.10+、Xcode 命令行工具、已初始化的 PhoneAgent submodule，以及本机 `.env` 中的模型配置。缺少 Key 时运行 `python3 scripts/configure_model.py`，不要把 Key 发到聊天或提交 Git。

未发现手机时，检查 USB、解锁、手机“信任此电脑”，必要时在 Xcode → Window → Devices and Simulators 完成配对。若提示等待手机连接，手动回到 Wellphone 并点“准备连接和日历权限”。遇到权限错误或后台窗口过期，回到 App 查看报告后按提示处理，不要重复提交同一计划。

启动日志在本机 `.wellphone-runtime/forwarder.log`、`worker.log`，执行报告仍在 `wellphone-data/`；均已忽略，不提交。日志追加保留，需要时可在服务停止后清理。安装或更新手机代码仍使用 `scripts/start_native_host.py`，见 README 的首次部署步骤。
