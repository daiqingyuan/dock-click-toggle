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

这个方案不优雅，因为 Terminal 可能在登录时闪一下。当前启动脚本会在启动完后台进程后，尝试只关闭自己新开的 Terminal 窗口，不会隐藏或关闭用户原本正在使用的 Terminal 窗口。

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
- same-session open probe 已经不再作为失败条件。
- 测试脚本现在会准备真实登出/登录测试，并把 Terminal LaunchAgent plist 改名为 `.disabled`，避免两条启动链同时启动。
- 真正 log out / log in 后，`SMAppService.mainApp` 会尝试启动 DockClickToggle，但启动后的进程仍然拿不到 Accessibility 和 Input Monitoring，状态为 `FAIL`，错误是 `accessibility_not_granted+input_monitoring_not_granted`。
- 切换到本机稳定签名后，重新清理 TCC 并再次测试真实登录启动，结果仍然相同：`SMAppService.mainApp` 启动出来的进程拿不到 Accessibility 和 Input Monitoring。

复现实验命令：

```bash
./scripts/test-smappservice-login-item.sh
```

如果登录测试失败，或者想回到原来的 Terminal launcher，运行：

```bash
./scripts/test-smappservice-login-item.sh --restore
```

### 8. 专用 LoginItem helper app 实验

已经新增专用 helper bundle：

```text
DockClickToggle.app
└── Contents/Library/LoginItems/DockClickToggleAgent.app
```

主 app 新增命令：

```bash
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --agent-login-item-status
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --register-agent-login-item
/Applications/DockClickToggle.app/Contents/MacOS/DockClickToggle --unregister-agent-login-item
```

新增实验脚本：

```bash
./scripts/test-agent-login-item.sh
```

脚本行为：

- 临时禁用并改名 Terminal LaunchAgent。
- 停止当前 `DockClickToggle` / `DockClickToggleAgent` 进程。
- 注册 `DockClickToggleAgent.app`。
- 确认 `agentLoginItemStatus=enabled`。
- 不做 same-session probe，等待真实 log out / log in 验证。

已经验证：

- `.app` bundle 内已经包含 `DockClickToggleAgent.app`。
- helper binary 可执行。
- 主 app 可以把 helper login item 注册到 `enabled`。
- 当前安装状态下，helper binary 手动运行 `--permission-status` 显示 Accessibility / Input Monitoring 都是 `true`，但这只能说明当前 shell/Terminal 启动上下文可用，不能证明 LoginItem 启动上下文可用。
- 真实 log out / log in 后，`DockClickToggleAgent.app` 会被登录项尝试启动，但它写入 `accessibilityTrusted=false`、`inputMonitoringGranted=false`、`eventTapCreated=false`，然后退出。
- 测试脚本可以 `--restore` 回 Terminal launcher。
- restore 后当前机器回到 `OK`，`eventTapCreated=true`。

当前结论：

- 专用 LoginItem helper 这条路在当前机器上仍然不能替代 Terminal launcher。
- 失败点仍然是登录启动上下文里的 TCC / 隐私授权，不是 app bundle 不存在、注册失败或签名不稳定。

因为 helper 使用独立 bundle id，权限可能不沿用主 app。可以检查或请求 helper 自己的权限：

```bash
/Applications/DockClickToggle.app/Contents/Library/LoginItems/DockClickToggleAgent.app/Contents/MacOS/DockClickToggleAgent --permission-status
/Applications/DockClickToggle.app/Contents/Library/LoginItems/DockClickToggleAgent.app/Contents/MacOS/DockClickToggleAgent --request-permissions
```

## 当前明确限制

### 1. Terminal 启动链仍然存在

当前唯一已验证稳定的启动方案仍然是 Terminal launcher。

原因是：

- `LaunchAgent -> open -gj -> app` 在当前机器上不能继承 event tap 所需权限。
- same-session `SMAppService` open probe 不能证明真实登录启动是否可行。
- 真正的 `SMAppService.mainApp` 登录启动已经测试过，仍然拿不到 Accessibility / Input Monitoring。

所以现在不能安全替换默认启动链。

当前已经做过缓解：Terminal launcher 启动后台进程后，会尝试关闭自己创建的那一个启动窗口，避免每天留下很多 shell 窗口。

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

### 4. 仍然不是正式 Developer ID 签名

当前机器上已经建立本机稳定签名身份：

```text
DockClickToggle Local Code Signing
```

如果该 identity 存在，构建和安装脚本会自动使用它；否则 fallback 到 ad-hoc 签名。

这个本机签名有助于稳定 TCC 身份，但它仍然不是 Developer ID 签名，也没有 notarization。

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
- `SMAppService` same-session open probe：不可用，但不再作为失败判定。
- `SMAppService` 真正登录启动：会启动 app，但 app 仍然拿不到 Accessibility / Input Monitoring，最终退出并写入 `FAIL`。
- 本机稳定签名：已生效，但没有修复 `SMAppService.mainApp` 登录启动权限问题。
- 专用 `DockClickToggleAgent.app`：已实现、已构建、可注册为 `enabled`；真实 log out / log in 后仍然拿不到 Accessibility / Input Monitoring。

## 后续建议路线

### 优先级 1：恢复稳定启动链

```bash
./scripts/test-smappservice-login-item.sh --restore
```

目前应继续使用 Terminal launcher，保证工具可用。

### 优先级 2：尝试稳定代码签名

当前 app 是 ad-hoc 签名，macOS TCC 可能把不同启动路径或重新签名后的 app 当成不同身份。

已经新增本机稳定签名脚本：

```bash
./scripts/create-local-signing-identity.sh
```

它会创建：

```text
DockClickToggle Local Code Signing
```

如果这个 identity 存在，`scripts/build.sh` 和 `scripts/install.sh` 会自动使用它；否则才 fallback 到 ad-hoc 签名。也可以显式指定：

```bash
SIGN_IDENTITY="DockClickToggle Local Code Signing" ./scripts/install.sh
```

本机实测安装后的签名已经从：

```text
Signature=adhoc
designated => cdhash ...
```

变成：

```text
Authority=DockClickToggle Local Code Signing
Authority=DockClickToggle Local Root CA
designated => identifier "local.dock-click-toggle" and certificate leaf = ...
```

这有助于减少 TCC 把每次重签后的 app 当成新身份的问题。

但后续真实测试已经确认：即使使用本机稳定签名，并清理旧 TCC 记录后重新测试，`SMAppService.mainApp` 登录启动仍然拿不到 Accessibility / Input Monitoring。

后续还可以尝试：

- Developer ID 签名。
- 只给 `/Applications/DockClickToggle.app` 这个固定身份授权后，再配合专用 helper app 测试。

### 优先级 3：继续研究 TCC 归因或接受 Terminal launcher

稳定签名后 `SMAppService.mainApp` 仍然不行，所以已经实现：

```text
DockClickToggle.app
└── Contents/Library/LoginItems/DockClickToggleAgent.app
```

主 app 负责设置、权限引导和注册登录项；`DockClickToggleAgent.app` 作为真正后台常驻进程创建 `CGEventTap`。

真实测试已经确认 helper 登录项在当前机器上仍然失败。下一步如果继续研究，重点不再是 bundle 结构，而是 macOS TCC 对登录项进程的授权归因。

可能方向：

- 研究 helper 是否必须由一个常规主 app UI 引导用户把 `Dock Click Toggle Agent` 显式加入 Accessibility / Input Monitoring。
- 研究 Developer ID 签名和 notarization 是否改变 TCC 对 LoginItem helper 的归因。
- 暂时接受 Terminal launcher 是当前唯一稳定方案。

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

不要把默认启动方式从 Terminal launcher 换成 `open -gj` 或 `SMAppService.mainApp`。

目前真正稳定可用的是 Terminal launcher。`SMAppService.mainApp` 已经完成真实登录验证，并且在 ad-hoc 和本机稳定签名条件下都失败。专用 LoginItem helper app 也已经完成真实登录验证，同样失败于登录启动上下文里的 Accessibility / Input Monitoring 授权。
