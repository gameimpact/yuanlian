你是独立交叉验证负责人，具备资深 Flutter/Windows/Android 客户端架构、产品设计与交互设计能力。请对“远联 YuanLian”当前 M0/M1 开发版做只读审查，并输出一份可执行改造提示词。不要修改文件，不要运行构建/测试或任何写操作；只做静态阅读和判断。

项目：C:/Users/Lenovo/Desktop/远程控制软件

## 用户目标

- Windows 客户端观感要接近原生 Windows 11 / WinUI 3 / Fluent 应用，而不是把移动端 Material 页面搬到桌面。
- Android 客户端观感要接近 AOSP/Pixel Material 3：edge-to-edge、安全区、系统栏、48dp、ripple、返回手势、IME。
- 先验证当前功能与文档是否一致、找出真实缺陷；再给出足够详细的改造提示词。
- 改造提示词将交给 gpt-6.1-sol ultra 代码代理执行；必须自包含、具体到页面/组件/文件/设计 token/交互/验收，禁止空泛。
- 本轮范围：Windows/Android 平台化 UI + 已发现功能/安全问题修复；账号/中继/质量模式/Linux/Android Host 不在本轮实现，只列入 backlog。不得伪造未实现能力。

## 只读检查范围（优先级）

1. `README.md`、`docs/requirements-traceability.md`、`docs/protocol.md`、`docs/evidence/*`、`docs/design/flutter-rust-bridge.md`
2. `client/lib/src/ui/theme.dart`、`home_shell.dart`、`home_page.dart`、`connection_progress_page.dart`、`workspace_page.dart`、`file_browser_page.dart`、`settings_page.dart`
3. `client/lib/src/net/protocol.dart`、`remote_client.dart`；`client/windows/runner/`；`client/android/` 的 manifest / styles / build 配置
4. 必要的 Rust 安全边界：`crates/yl-host/src/session.rs`、`files.rs`、`input.rs`；`crates/yl-proto/src/lib.rs` 的协议顺序
5. 截图（已附）：
   - Windows 首页：`artifacts/m1/windows-home.png`
   - Windows 文件页：`artifacts/m1/upload-done.png`
   - Android 首页：`artifacts/m1/android-home.png`
   - Android 远控工作区：`artifacts/m1/android-workspace.png`

不要阅读与 UI/当前缺陷无关的大段上游文档。不要复述整篇需求。

## Part A：交叉验证报告（简洁但有证据）

1. 结论摘要 ≤8 条。
2. 文档/测试声明与代码不一致项（表格，引用文件与关键行）。
3. P0/P1/P2 缺陷：真实 bug、竞态、安全边界、断线/输入卡键、文件传输完整性、Android 生命周期；无法确认的写“需验证”。不要编造。
4. Windows UI 差距：按当前页面（首页、进度、工作区、文件、设置）列出“不像 Windows 原生”的具体点。
5. Android UI 差距：按首页、进度、工作区、文件/其他列出“不像 AOSP”的具体点。
6. 明确哪些改造纯 Flutter 可做，哪些需要 Windows runner/原生插件，给出低风险替代。

## Part B：给 gpt-6.1-sol ultra 的详细执行提示词

用清晰分隔线包裹，中文，必须包含：

- 角色、背景、已验收真实基线（不夸大）、本轮目标/非目标/backlog。
- 不可违背约束：不伪造、协议兼容、Host 侧权限、安全路径、不得删除测试、更新追踪表、不得引入逐帧 Dart 大对象。
- 平台设计系统：
  - Windows Fluent/WinUI 3：字体（Segoe UI Variable/替代）、字号/字重、表面层级/Mica/Acrylic 低风险实现、标题栏/拖拽区、NavigationView/CommandBar、控件高度、圆角、间距、颜色 light/dark、焦点/悬停/按下、滚动条、窗口最小尺寸、键盘快捷键。
  - Android AOSP/Pixel M3：edge-to-edge、状态/导航栏、TopAppBar/NavigationBar、tonal surfaces、48dp、ripple、返回手势、安全区、IME、对话框/底部面板、横竖屏。
  - 两平台共用的语义 token 与平台覆盖映射，给出具体数值。
- 逐页规格（组件层级、布局、交互、空/加载/错误/离线、键盘/触摸）：
  - Windows：首页/连接、进度、错误、远控工作区、文件双栏、设置、关于。
  - Android：首页、连接/进度、远控工作区（触摸/键盘/缩放）、文件、权限/未实现状态。
- 逐文件改动清单：精确到 `client/lib/...`、Windows runner、Android 资源、必要时 Rust 文件；写清改什么、为什么、验收结果。
- 分阶段执行（每阶段独立可验收）、验证命令、截图尺寸（Windows 1280×800 逻辑/200% DPI；Android 1080×2400）、键盘/返回手势/安全区/错误路径/文件传输测试。
- 完成标准（DoD）与禁止事项；提示词必须自包含，不能引用“上面的报告”。
- 具体、可执行、无自相矛盾；控制在可落地范围。

请先完成 Part A，再输出 Part B；最后自检 Part B 是否足够详细、可直接交给代码代理执行。不要修改仓库。
