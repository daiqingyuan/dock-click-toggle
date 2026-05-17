# DockClickToggle 工作总结与当前限制

这份文档记录近期对 DockClickToggle 做过的主要改动、已经验证的结论、目前限制，以及后续继续优化时应该注意的地方。

## 项目目标

DockClickToggle 的目标是让 macOS Dock 图标具备类似 Windows 任务栏的行为：

- 点击当前前台 App 的 Dock 图标时，最小化该 App 的可见窗口。
- 该 App 已最小化后，再点击 Dock 图标时，交还给 Dock 的原生恢复行为。

实现上依赖两类 macOS 权限：

- Accessibility：读取 Dock item 信息，并最小化 App 窗口。
- Input Monitoring：通过 `CGEventTap` 截获鼠标 down/up 事件。

## 已完成的主要工作

### 1. 开源项目基础

- 整理了 README、安装脚本、卸载脚本和构建脚本。
- 增加了自定义 app 图标，构建时自动生成 `.icns`。
- 默认安装到 `/Applications/DockClickToggle.app`。
- 支持通过 `INSTALL_DIR="$HOME/Applications"` 自定义安装目录。
- GitHub 仓库已建立并推送。

### 2. 启动健康检查

之前最大的问题是：event tap 创建失败后，进程仍然可能活着，但功能已经失效。

现在已经改为：

- 启动失败时写入 `FAIL` 状态。
- event tap 创建失败后直接退出，不再假活着。
- LaunchAgent 的启动脚本会检查 `status.json`。
- 如果已有进程但状态不健康，会 kill 后重启。
- `status.json` 增加 `pid`、权限状态、event tap 状态、更新时间和错误原因。
- 增加 30 秒 heartbeat。
- launcher 会检查状态是否过期，以及 `pid` 是否匹配当前运行进程。

### 3. 安装布局修复

之前 LaunchAgent 依赖 git clone 目录里的脚本，删除仓库后会坏。

现在已经改为：

- `start-via-terminal.sh` 被复制进 app bundle：
  `DockClickToggle.app/Contents/Resources/start-via-terminal.sh`
- LaunchAgent 指向 app bundle 内的启动脚本。
- 状态文件放在：
  `~/Library/Application Support/DockClickToggle/status.json`
- 日志放在：
  `~/Library/Logs/DockClickToggle/`

### 4. 事件处理稳定性

已经修过的点：

- Command / Option / Control / Shift 点击 Dock 图标时放行，不吞 macOS 原生操作。
- mouse up 时重新确认前台 App。
- 增加点击移动距离和持续时间限制，减少误触。
- 拖动时取消 pending click，并尽量放行后续事件。
- Dock item 查找改成递归遍历，而不是依赖 Dock AX tree 的第一个 child。
- 增加 Dock item cache，减少每次点击时重复扫描 Accessibility tree。
- event tap 被系统禁用时写入 `RECOVERING` 状态，并异步恢复。
- 收到 `SIGTERM` / `SIGINT` 时写入 `STOPPED`，并清理 event tap。

### 5. 诊断和测试工具

新增：

- `scripts/diagnose.sh`
- `scripts/diagnose.sh --json`
- `docs/manual-test-matrix.md`
- GitHub Actions CI

诊断脚本会检查：

- app 是否安装
- binary 和 launcher 是否存在且可执行
- LaunchAgent 是否加载
- plist 是否合法
- 进程是否运行
- `status.json` 是否健康
- pid 是否匹配
- Accessibility / Input Monitoring / event tap 状态
- 最近错误日志

### 6. Terminal launcher 实验

当前正式启动链仍然是：

```text
LaunchAgent
-> zsh
-> osascript
-> Terminal
-> DockClickToggle
```

这个方案不优雅，因为 Terminal 可能在登录时闪一下。

已经新增实验脚本：

```bash
./scripts/test-open-launcher.sh
```

实验内容是用：

```bash
/usr/bin/open -gj /Applications/DockClickToggle.app
```

替代 Terminal launcher。

实验结果：

- `open` 本身可以启动。
- 但在当前机器上，DockClickToggle 通过这条链启动后拿不到 Accessibility / Input Monitoring 权限。
- 结果是 `event_tap_create_failed`。
- 因此不能直接把默认 launcher 换成 `open -gj`。

### 7. SMAppService 实验

新增了 `SMAppService.mainApp` 实验能力：

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --login-item-status
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --register-login-item
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --unregister-login-item
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --open-login-items-settings
```

新增实验脚本：

```bash
./scripts/test-smappservice-login-item.sh
```

已经验证：

- `SMAppService.mainApp.register()` 可以成功，状态会变成 `enabled`。
- same-session open probe 仍然失败，还是拿不到权限，表现为 `event_tap_create_failed`。
- 脚本能自动 unregister，并恢复正式 Terminal launcher。

还没验证：

- 真正的 log out / log in 后，由 `SMAppService.mainApp` 在登录阶段启动 app，是否能拿到 Input Monitoring 权限。

后续真实登录测试命令：

```bash
./scripts/test-smappservice-login-item.sh --prepare-login-test
```

测试后恢复命令：

```bash
./scripts/test-smappservice-login-item.sh --restore
```

## 当前明确限制

### 1. Terminal 闪现仍然存在

当前唯一已验证稳定的启动方案仍然是 Terminal launcher。

原因是：

- `LaunchAgent -> open -gj -> app` 在当前机器上不能继承 event tap 所需权限。
- same-session `SMAppService` open probe 也不能证明可行。
- 真正的 `SMAppService.mainApp` 登录启动还需要登出/登录测试。

所以现在不能安全替换默认启动链。

### 2. 权限必须由用户手动授权

macOS 不允许程序自动授予自己：

- Accessibility
- Input Monitoring

脚本和 app 只能提示、检测和诊断，不能绕过系统隐私控制。

当前后台启动路径不会主动弹出权限窗口。需要弹窗时，用户必须手动运行：

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --request-permissions
```

只检查权限、不弹窗时运行：

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --permission-status
```

### 3. CI 不能测试真正的 Dock 行为

GitHub Actions 可以测试：

- 构建是否成功
- app bundle 是否完整
- plist 是否合法
- 签名验证是否通过

但 CI 无法可靠测试：

- `CGEventTap` 是否能真实截获 Dock 点击
- Accessibility 是否能读 Dock item
- Input Monitoring 是否已授权
- 真实 Dock 点击最小化是否符合预期

这些只能在真实 macOS 桌面会话里手动测。

### 4. 仍然是 ad-hoc 签名

当前使用：

```bash
codesign -s -
```

这是本地 ad-hoc 签名，不是 Developer ID 签名，也没有 notarization。

陌生用户下载后，Gatekeeper 仍可能提示未知开发者。

正式分发需要：

- Apple Developer 账号
- Developer ID Application 证书
- hardened runtime
- notarization
- stapling

### 5. Accessibility window metadata 不是所有 App 都一致

不同 App 的 AX window 信息可能差异很大：

- 原生 App
- Electron App
- JetBrains IDE
- Adobe 类 App
- 多窗口 App
- 全屏窗口
- 特殊浮动面板

当前逻辑已经比最初保守，但仍可能遇到某些 App 无法完全按预期最小化。

### 6. 拖动 Dock 图标不是完全原生

DockClickToggle 为了截获“点击当前前台 App 图标”这个动作，需要吃掉 eligible click 的初始 mouse down。

因此拖动当前前台 App 的 Dock 图标时，体验可能和原生 Dock 不完全一致。

README 和手工测试矩阵已经记录这个限制。

## 当前机器上的实验结论

当前机器上已经验证：

- 正式 Terminal launcher：可用，状态 `OK`。
- `open -gj` LaunchAgent：不可用，失败于权限上下文。
- `SMAppService.mainApp` 注册：可注册为 `enabled`。
- `SMAppService` same-session open probe：不可用，失败于权限上下文。
- `SMAppService` 真正登录启动：尚未测试，需要登出/登录。

## 后续建议路线

### 优先级 1：真实 SMAppService 登录测试

在准备好重登时运行：

```bash
./scripts/test-smappservice-login-item.sh --prepare-login-test
```

然后登出/登录，检查：

```bash
./scripts/diagnose.sh --json
```

如果登录后状态是：

```text
status = OK
eventTapCreated = true
accessibilityTrusted = true
inputMonitoringGranted = true
```

才说明 `SMAppService.mainApp` 有机会替代 Terminal launcher。

### 优先级 2：如果 SMAppService 成功

可以考虑增加可选安装模式：

```bash
./scripts/install.sh --login-item
```

或者在 README 中作为实验模式说明，不马上替代默认模式。

### 优先级 3：如果 SMAppService 失败

继续保留 Terminal launcher，并把 Terminal 闪现作为已知限制。

可再研究菜单栏 App / helper app 架构，但不要再把 `open -gj` 作为默认路径。

### 优先级 4：正式发布能力

未来如果要给陌生用户安装，需要做：

- release 脚本
- Developer ID 签名
- notarization
- zip / dmg 分发包
- 更友好的权限引导 UI

## 安全和隐私边界

项目当前不做：

- 网络请求
- telemetry
- analytics
- 上传数据
- 读取键盘输入

只使用：

- mouse down / up / drag 事件判断 Dock 点击
- Accessibility 读取 Dock item 和窗口信息
- Accessibility 设置窗口最小化属性

## 重要提醒

不要在没有实验结果的情况下把默认启动方式从 Terminal launcher 换成 `open -gj` 或 `SMAppService`。

目前真正稳定可用的是 Terminal launcher。`SMAppService` 是最值得继续测试的方向，但它还没有完成真实登录验证。
