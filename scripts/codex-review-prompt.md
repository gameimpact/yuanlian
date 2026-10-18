你是独立交叉验证负责人，同时具备资深产品经理、Flutter/Windows/Android 客户端架构师、交互设计师、视觉设计师和提示词工程师能力。你当前使用 gpt-6.1-sol + ultra 推理。请对工作区中的“远联 YuanLian”项目做只读审查，不修改任何文件，不执行破坏性命令。

项目根目录：C:/Users/Lenovo/Desktop/远程控制软件

## 用户的核心诉求

1. 对当前成品做交叉验证：功能是否真实、文档/需求追踪是否夸大、是否存在明显 bug、安全边界是否成立、UI/UX 是否达到可交付水平。
2. Windows 客户端 UI 要接近原生 Windows App（WinUI 3 / Fluent Design / Windows 11 观感），不要像把移动端 Material 页面直接搬到桌面。
3. Android 客户端 UI 要接近 AOSP / Pixel 的 Material 3 体验，包括边到边、系统栏、触摸尺寸、返回手势、对话框/底部面板、键盘与 IME 行为。
4. 在审查后，输出一份足够详细的、可直接交给另一个 GPT-6.1 Sol Ultra 代码代理执行的改造提示词；该提示词必须自包含、具体到文件、组件、设计 token、交互和验收，不允许停留在“优化一下 UI”这种空话。
5. 后续会严格按你输出的提示词进行代码修改，因此提示词范围必须可控、可分阶段、可在当前仓库落地，并且不能伪造功能或破坏已验证的 Host/协议。

## 必读资料

请先阅读（按需搜索/读取，不必一次读完）：

- `README.md`、`AGENTS.md`
- `docs/requirements-traceability.md`（唯一事实来源）
- `docs/protocol.md`
- `docs/roadmap.md`
- `docs/design/flutter-rust-bridge.md`
- `docs/evidence/m0-results.md`、`m1-flutter-client.md`、`m1-android-client.md`、`m2-file-transfer.md`
- `crates/yl-proto/src/lib.rs`
- `crates/yl-host/src/`（main/session/capture/input/files/tls）
- `crates/yl-tiles/src/lib.rs`
- `crates/yl-viewer/src/`（仅诊断工具，确认其定位）
- `client/lib/` 全部 Dart 代码，重点：
  - `src/ui/theme.dart`
  - `src/ui/home_shell.dart`
  - `src/ui/home_page.dart`
  - `src/ui/connection_progress_page.dart`
  - `src/ui/workspace_page.dart`
  - `src/ui/file_browser_page.dart`
  - `src/ui/settings_page.dart`
  - `src/net/protocol.dart`、`remote_client.dart`
- `client/windows/runner/`（窗口尺寸、标题栏、最小尺寸、DPI）
- `client/android/`（manifest、主题、启动画面）
- `dist/README.txt`、`dist/SHA256SUMS`
- 原始需求文档 `远程控制软件_完整开发提示词.md`（只提取与当前 UI/客户端/安全/验收相关部分，不要复制其全部内容）。

## 视觉证据（请结合以下截图判断，不要只看代码）

- `artifacts/m1/windows-home.png`：Windows 客户端首页（release，完整 3200×2000 桌面截图；应用是 1280×800 逻辑窗口，系统 200% DPI）
- `artifacts/m1/release-windows.png`：Windows 远控工作区（递归镜像，属同机测试预期）
- `artifacts/m1/upload-done.png`：Windows 双栏文件页，上传成功/哈希状态
- `artifacts/m1/wrongfp-full.png`：Windows 连接失败页
- `artifacts/m1/android-home.png`：Android 首页（1080×2400 模拟器）
- `artifacts/m1/android-workspace.png`：Android 远控工作区（修复移动端溢出后）
- `artifacts/m1/android-error.png`：Android 连接失败页

注意：Windows 截图里的桌面镜像/递归不是 bug，是同机测试；审查 UI 时聚焦应用窗口本身的层级、排版、控件、状态表达和 Windows 原生感。Android 远控画面在竖屏手机上很小、上下留黑，这是待审查的真实问题之一。

## 任务 A：功能与事实交叉验证

以证据为准，逐项给出结论：

1. 当前真正可用的功能（Windows Host、Flutter Windows 主控、Android 主控、文件传输、TLS 指纹、输入授权、错误处理等）。
2. 文档/追踪表/README 与实际代码是否一致；是否存在夸大、遗漏、状态标错、测试证据无法复现的问题。引用文件与关键行号。
3. 你发现的实际 bug、竞态、协议错误、内存/资源泄漏、路径越权、断线/重连、输入卡键、文件传输完整性、Android 生命周期问题。按 P0/P1/P2 分级，给出证据和最小修复方向。不要凭空猜测；无法确认的写“需验证”。
4. 用户明确要求的 Windows/AOSP UI 目标，与当前实现的主要差距（具体到页面和控件）。

## 任务 B：UI/UX 审查基准

- Windows：对照 WinUI 3 / Fluent Design / Windows 11 常见应用（Settings、Explorer、Teams 等）的观感：Segoe UI Variable、Mica/Acrylic 或至少原生表面层级、NavigationView/CommandBar、窗口标题栏与拖拽区、原生滚动条、键盘焦点与 Tab 顺序、密度、窗口最小尺寸、深浅主题、右键/快捷键、非移动端导航。判断当前 Material 3 页面哪些地方“不像 Windows”。
- Android：对照 AOSP/Pixel Material 3：edge-to-edge、系统状态/导航栏、TopAppBar、NavigationBar/NavigationRail、Material 3 tonal surfaces、48dp 触摸目标、ripple、返回手势、Scaffold/Dialog/BottomSheet、IME 与安全区、横竖屏。判断当前页面哪些地方不像 AOSP。
- 明确哪些改动能用纯 Flutter 完成，哪些需要 Windows runner/原生插件（Mica、自定义标题栏、原生文件选择器等），并给出低风险替代方案。
- 关注可用性：首次连接是否易懂、错误是否可操作、状态是否真实、输入是否可发现（放大/缩小、触摸/鼠标模式、键盘、文件、断开）、手机远控画面是否可读/可操作。

## 任务 C：输出要求

最终回复必须包含两部分，且完整、可直接使用：

### Part A：交叉验证报告

- 结论摘要（最多 10 条）
- 功能真伪与文档偏差（表格）
- P0/P1/P2 缺陷清单（带文件/行号/证据）
- Windows UI 差距清单（按页面）
- Android UI 差距清单（按页面）
- 不可声称/必须继续保持诚实的事项

### Part B：给 GPT-6.1 Sol Ultra 的实施提示词

用清晰分隔线包裹，输出一份中文提示词，要求：

- 角色与目标；
- 当前已验收基线（只列实际已实现并实测的，不夸大）；
- 本轮范围与非目标（重点：Windows/AOSP 平台化 UI + 已发现功能/安全缺陷修复；账号/中继/质量模式/Linux/Android Host 等未实现项不要在本轮假装实现；可列为后续 backlog）；
- 不可违背约束（不伪造、不破坏 yuanlian/1 协议兼容、Host 侧权限强制、不引入逐帧 Dart 大对象、不删除测试、更新需求追踪表）；
- 平台自适应设计系统：Windows Fluent/WinUI 3 风格与 Android AOSP Material 3 的 token（字体、字号、字重、颜色、表面层级、圆角、间距、控件高度、动效、图标、焦点/悬停/按下状态、暗色主题），给出具体数值和映射方式；
- 逐页规格：至少覆盖 Windows 首页/连接进度/授权（若有）/远控工作区/文件双栏/设置/关于，Android 首页/连接/远控/文件/权限中心（未实现部分明确“占位且有真实原因”的范围）；每页写组件层级、布局、交互、空/加载/错误/离线状态、键盘/触摸行为；
- 逐文件改动清单：精确到 `client/lib/...`、`client/windows/runner/...`、`client/android/...`、必要的 Rust 文件；说明为什么改、预期结果；
- 分阶段执行顺序（第一阶段可独立验收），每阶段有验证命令和截图要求；
- 测试与验收矩阵：单元/协议/实机/UI 截图/尺寸（Windows 1280×800 逻辑、200% DPI；Android 1080×2400）、键盘操作、Android 返回手势/安全区、错误路径、文件 transfer 等；
- 完成标准（Definition of Done）和禁止事项；
- 提示词必须自包含：另一个代理即使看不到本审查报告，也能按提示词执行；不要写“根据上述审查”之类的指代；
- 避免泛泛而谈，所有颜色/字号/间距/组件/交互尽量给出可执行细节；允许合理取舍，但必须说明理由。

最后再检查一次：Part B 是否足够详细、无自相矛盾、范围可落地。不要修改仓库文件。
