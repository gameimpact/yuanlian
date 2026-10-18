# Phase 0：Codex 提示词前置基线审计

日期：2026-10-18。目的：补上 Codex 只读沙箱未能完成的源码核查，确认真实行号、测试和修复状态。状态分为“静态确认 / 测试通过 / 实机通过 / 未验证”。

## 1. 协议与连接

| 项目 | 结论 | 证据 |
|---|---|---|
| 协议字段顺序 | Rust 与 Dart 的 tiler/input/file 消息测试通过 | `crates/yl-proto/src/lib.rs`；`client/lib/src/net/protocol.dart`；`client/test/protocol_test.dart` 8 项 |
| 消息长度上限 | 4 字节长度 + 32 MiB 上限；Dart 同样拒绝非法长度 | `yl-proto` `MAX_MESSAGE_BYTES`；`remote_client.dart` `_onData` |
| TLS 指纹先于业务数据 | 握手回调只在 SHA-256 匹配时接受；握手后再次取 `peerCertificate` 校验；通过后才发送 Hello | `remote_client.dart:193-238`，Hello 在 `_socket = secure` 之后发送 |
| 错误指纹 | Windows/Android 已实测失败且不继续 | 三个 M1 证据文档；错误码 `fingerprint_mismatch` |
| 连接终态/关闭 | `_closed` 统一阻止重复关闭；dispose 幂等；socket 取消后检查 `_disposed/_closed` | `remote_client.dart:505,588-610` 及连接后置检查 |
| 未知消息 | 协议解析抛错并终止，不静默忽略 | `protocol.dart` `decodeServerMessage` |

## 2. 输入与权限

| 项目 | 结论 | 证据 |
|---|---|---|
| Host 侧输入强制 | 未授权会话在 Host 层拒绝并回 `input_denied`；已实测强制输入仍被拒绝 | `session.rs:83,187-207` |
| 按键/按钮释放 | Host 按会话记录按下的键/按钮；正常结束、错误、超时、客户端断开都调用 `release_all` | `input.rs:54-63,127-177`；`session.rs:231` |
| 客户端释放 | 失焦、路由 dispose、Android 生命周期 inactive/paused/hidden/detached 都发送 ReleaseAll；恢复默认查看模式 | `workspace_page.dart:124-148,547` |
| 隐藏测试开关 | `--force-input` 仍为隐藏测试参数，不进入 UI | `main.dart` 参数解析；本审计确认未暴露 |
| 文件权限 | 当前为 Host `--file-root` 显式单目录授权，没有独立文件权限弹窗/逐会话选择；文档必须保持此限制 | `session.rs` FileCapabilities；README/追踪表 |

## 3. 文件安全与完整性

| 项目 | 结论 | 证据 |
|---|---|---|
| 相对路径规范化 | 拒绝 `..`、绝对/盘符、UNC、NUL、非法字符；统一 `/` | `files.rs:383` `normalize_relative` |
| 根目录边界 | 已存在路径先 canonicalize 再 `starts_with(root)`；新文件先 canonicalize 父目录；列出跳过 symlink | `files.rs:254-300` |
| Windows 替换原子性 | 上传写同目录临时文件，flush/sync、长度+SHA-256 后使用 `MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)`；失败保留旧文件并清理临时文件 | `files.rs:140-210,346-374`；6 项文件测试通过 |
| 冲突 | 未选择覆盖时拒绝；覆盖需显式 overwrite | `files.rs` `resolve_new_file`/`finish_upload`；Flutter 覆盖确认 |
| 目录/续传/ACL | 未实现，仍为已知限制 | 追踪表 |
| junction/TOCTOU | canonicalize 可解决静态 junction/symlink 越界；canonicalize 与实际 open 之间仍存在本地 TOCTOU 窗口，未声称完全消除 | `files.rs`；文档明确 |

## 4. UI/平台

| 项目 | 结论 | 证据 |
|---|---|---|
| Windows 壳层 | 240/64px NavigationView、48px CommandBar、Segoe UI Variable、控件 32–36px、4/8 圆角、hover/focus、原生标题栏；Mica 请求失败时回退不透明 | `home_shell.dart`；`platform_theme.dart`；`win32_window.cpp` |
| Windows 快捷键 | Ctrl+L 聚焦地址、Ctrl+, 设置、F1 帮助 | `home_shell.dart:185` |
| Android AOSP | edge-to-edge（Flutter + MainActivity）、TopAppBar、NavigationBar、tonal surface、48dp、安全区 | `main.dart`、`MainActivity.kt`、`home_shell.dart` |
| Android 溢出 | 旧截图确认上下溢出；已改紧凑工具栏/可滚动状态栏/可换行等待卡；360dp、1.3 字体 widget 测试通过 | `workspace_page.dart`; `test/responsive_test.dart` 4 项 |
| Android 查看/缩放 | 支持查看/控制模式、缩放菜单、放大/缩小/适应、查看模式拖动平移、双指捏合（主指针限制；捏合未实机验证） | `workspace_page.dart` |
| 默认地址/端口 | Android 无历史时为空并提供模拟器建议；Windows 命令端口取自地址；Host 绑定与客户端地址区分 | `home_page.dart:49,71-85,354` |
| 文件页 | Windows 双栏 + 可拖 splitter + 列头 + CommandBar + 任务横幅详情；Android 单栏分段 + 底部动作 | `file_browser_page.dart` |
| 文件覆盖旧文件 | 旧逻辑删旧再 rename；已改为 Windows MoveFileExW 原子替换，失败保留旧文件 | `files.rs:346` |

## 5. 仍需验证/未完成

- Android 双指捏合缩放、完整 IME/中文文本注入、SAF 文件选择器未实现。
- Windows Mica 可能因 Flutter 不透明 surface 只影响标题栏/边缘；未宣称整窗透明。
- Windows/Android 键盘 E2E（同机回环）未做；映射有单元测试。
- 跨物理机/局域网、Linux、Android Host、账号/中继/质量模式仍未开始。
- 文件断点续传、目录传输、删除权限、ACL/审计未实现。
