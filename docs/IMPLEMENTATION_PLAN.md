# 实施记录

## GitHub 自动构建与更新

已加入 `.github/workflows/release.yml`：推送 `v<major>.<minor>.<patch>` 标签或手工运行工作流后，在 `macos-14` runner 上同时构建 Intel 与 Apple Silicon 包，生成 SHA-256 校验文件并发布 GitHub Release。

应用内自动更新已按以下流程实现：

1. 启动后自动读取 `citrusjunoss/model-status` 的 GitHub Releases `latest` API，菜单中也提供“检查更新”；只比较结构化版本号，不执行远程脚本。
2. 下载与当前架构匹配的 zip 和 `SHA256SUMS`，校验 SHA-256、Bundle ID、版本号与代码签名。用户确认后由独立替换进程保留回滚副本、替换应用并重启；不可写或处于 App Translocation 时降级为手动安装。

仓库必须保持 Public，应用不内置 GitHub Token；私有仓库只能通过用户手动下载或另行部署带授权的更新代理。

正式对外分发若要减少首次打开提示，应改用 Developer ID 与 Apple 公证；本项目默认使用 `InputStatus Local Signing`，并兼容已有的 `ModelStatus Local Signing`，GitHub Actions 使用 ad-hoc 签名，不保存任何开发者私钥。

## 请求失败指数退避

已在 `AppDelegate` 为每个模型维护连续失败次数和下一次允许探测时间：

- 第一次失败：5 分钟；第二次：10 分钟；第三次及以后：30 分钟封顶。
- 任意成功后清零并恢复用户设置的刷新频率。
- 立即刷新按钮可人工覆盖退避，请求完成后重新计算退避。
- 退避状态持久化到 `UserDefaults`，应用重启不立即打破退避窗口。

## 睡眠/唤醒监听

已订阅 `NSWorkspace.willSleepNotification`、`NSWorkspace.didWakeNotification`、`screensDidSleepNotification` 和 `screensDidWakeNotification`。睡眠前取消 Timer、额度请求和探针；唤醒后等待 2 秒网络恢复窗口，再按当前退避状态或用户频率重新排程。锁屏与睡眠使用统一暂停原因集合，避免通知交错导致重复启动 Timer。
