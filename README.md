# PomoSentry / 学霸番茄 for macOS

PomoSentry 是独立的双语 macOS 专注应用，不依赖番茄 ToDo。macOS 26 及以上使用系统 Liquid Glass，macOS 13–15 使用材质玻璃兼容样式。

## 1.2.0 功能

- 1–240 分钟自由专注时长，支持 25/45/60/90 分钟快捷值
- 基于截止时间的倒计时：睡眠、唤醒和界面卡顿不会延长专注时间
- 活动会话、模式、截止时间和当前任务持久化；重新打开后继续未结束的专注
- “今天”和“全部任务”使用不同任务范围
- App 白名单与黑名单；浏览器也能作为 App 加入
- 默认只阻止 App 切到前台，进程和网络连接保持运行；也可主动选择强制退出
- 精确网站域名黑名单；浏览器继续运行，只拦截已添加的主机名
- 中英文界面、菜单栏倒计时、本地任务和番茄统计

## 权限与限制

App 前台拦截使用 `NSWorkspace`，不需要辅助功能权限。

网站域名规则通过带有严格所有权标记的 `/etc/hosts` 条目实现。开始和结束时 macOS 会分别请求管理员确认；PomoSentry 会校验标记结构、原文件摘要和最终状态，并使用同文件系统原子替换，避免覆盖并发修改。该机制按精确主机名工作：例如 `youtube.com` 会同时处理 `www.youtube.com`，但 `m.youtube.com` 需要单独添加。

任何运行在用户账户下的普通 App 都无法对电脑所有者提供不可绕过的控制：用户仍能使用“强制退出”或终端结束进程。PomoSentry 会在重新打开时恢复仍未到期的会话，但真正抵抗本机管理员需要 Apple 批准的系统扩展或 MDM。界面不会把当前模式描述成系统级、不可绕过的家长控制。

## 本地开发构建

```sh
./build-app.sh
```

默认生成带 `-development` 后缀的临时签名测试包。它不能作为公开发行包，也不应指导用户绕过 Gatekeeper。

## 正式发行

正式构建会在缺少 Developer ID 或公证凭据时直接失败：

```sh
export POMOSENTRY_RELEASE_MODE=public
export POMOSENTRY_SIGN_IDENTITY="Developer ID Application: Your Company (TEAMID)"
export POMOSENTRY_NOTARY_PROFILE="pomosentry-notary"
./build-app.sh
```

也可以提供 `POMOSENTRY_APPLE_ID`、`POMOSENTRY_TEAM_ID` 和 `POMOSENTRY_APP_PASSWORD`。脚本会执行测试、通用架构校验、Hardened Runtime 签名、公证、staple、Gatekeeper 检查和 SHA-256 摘要生成。

---

PomoSentry is a bilingual macOS focus timer with deadline-based sessions, persistent recovery, task scopes, verified app allowlists/blocklists, background-preserving foreground blocking, and exact-host website blocking. Accessibility permission is not required. Public artifacts must pass Developer ID signing, notarization, and Gatekeeper verification.

## License

MIT © 2026 jovial-liu
