# M3 平台化 UI 改造记录

日期：2026-10-18。依据：Codex 交叉验证 Part B（`docs/review/codex-cross-review.md`）+ Phase 0 审计（`docs/review/baseline-audit.md`）。范围：Windows Fluent 风格、Android AOSP/Pixel M3 风格、已确认的功能/安全修复。不是完整 M3，账号/中继/质量模式等仍未实现。

## 改动摘要

- 新增 `client/lib/src/ui/design_tokens.dart` 与 `platform_theme.dart`：Windows 采用 Segoe UI Variable、32–36px 控件、4/8px 圆角、紧凑密度、中性 Fluent 表面；Android 采用 Material 3 tonal surface、16dp 页面边距、48dp 触摸目标、56dp 输入框、动态系统栏。
- Windows：240/64px NavigationView、48px CommandBar、Ctrl+L/Ctrl+,/F1 快捷键、原生标题栏与最小 960×640、DWM dark caption + Windows 11 Mica 请求（失败回退不透明）。
- Android：Flutter edge-to-edge + MainActivity WindowCompat、透明系统栏、TopAppBar + NavigationBar、SafeArea、底部导航；连接页默认地址留空并提供模拟器宿主建议。
- 连接首页：地址/端口联动 Host 启动命令；未实现模式收进“模式与开发计划”；指纹粘贴/清空；连接按钮仅在合法输入时可用；Windows 版本显示修复（Windows 11 · build）。
- 远控工作区：查看/控制模式、放大/缩小/适应、查看模式拖动平移；缩放百分比状态；Android 生命周期后台自动释放输入并要求显式“恢复控制”；360dp/1.3 字体无 overflow。
- 文件页：Windows CommandBar + 可拖 splitter + 列头 + 详情横幅；Android 单栏分段 + 底部操作；完成提示缩短，完整路径/哈希放入详情。
- Host：Windows 上传提交改为同目录临时文件 + flush/sync + SHA-256 + `MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)`；失败保留旧文件并清理临时文件。
- 新增 4 项 Flutter 响应式/overflow 测试；Rust 文件测试仍 6 项通过；Dart 协议 8 项通过。

## 截图证据（本地，未入库）

- Windows 首页（最终 release）：`artifacts/review/windows-home-release-final.png`
- Windows 工作区：`artifacts/review/windows-new-workspace.png`
- Windows 文件页：`artifacts/review/windows-file-final.png`
- Android 首页：`artifacts/review/android-home-final.png`
- Android 工作区 100%：`artifacts/review/android-workspace-100.png`
- Android 工作区 200%：`artifacts/review/android-workspace-200.png`
- Android 文件页：`artifacts/review/android-file-final.png`

## 验证

- `dart analyze`：0 issue；`flutter test`：协议 8 + 响应式 4 全部通过。
- Windows debug/release 实际连接 Host，画面、输入自检 (10,10)、文件页可打开；release 首页显示 Windows 11 · build 26300。
- Android 14 模拟器安装 debug APK，自动连接 10.0.2.2:24808；首页、工作区 100%/200%、文件页均真实渲染，无 RenderFlex overflow。
- 360dp、1.3 字体布局测试通过；等待首帧卡、工具栏、状态栏均不再溢出。

## Unicode/中文文本提交

- 新增协议 `TextInput`（UTF-16，最多 4096 单元）和客户端“发送文本…”菜单。
- Windows Host 用 `SendInput(KEYEVENTF_UNICODE)` 注入，受 Host 输入权限与 4096 单元上限约束；不记录文本内容。
- 实测：Flutter 客户端（隐藏 `YUANLIAN_TEXT_SELF_TEST`）发送“远联 Unicode 😀 测试”；Host 日志记录 `viewer text input injected units=16`，前台 Windows 文本框显示完整中文与 emoji。
- 截图：`artifacts/review/text-target-screen.png`。
- 限制：这是本地文本提交，不是远端输入法组合/候选窗；不支持按键级 IME 交互。

## 未完成/限制

- Android 双指捏合已实现（缩放菜单/查看模式平移仍保留）；模拟器未做多点触控手势实测，仅验证构建与布局。
- 中文/emoji 文本提交已实测；完整远端 IME 组合输入仍未实现。
- Android IME/中文输入、SAF 文件选择器、predictive back 全量验证未完成。
- Windows Mica 受 Flutter 不透明 surface 限制，不能宣称整窗材质；仅发出真实 DWM 请求并提供不透明回退。
- 文件覆盖“失败保留旧文件”有 MoveFileExW 代码路径，但删除/占满/锁文件等故障注入未实机验证。
- 账号、中继、质量模式、Linux、Android Host、音频、剪贴板、无人值守、管理后台仍未实现。
