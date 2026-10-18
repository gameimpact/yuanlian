# Codex 交叉验证报告与实施提示词

> 执行说明（2026-10-18）：Codex CLI 配置为 gpt-6.1-sol + ultra，但当前 ChatGPT 账户不支持该模型；实际审查由 gpt-5.6-sol + ultra 完成。只读沙箱无法启动 PowerShell/读取源码文本，因此 Part A 的源码级结论主要基于截图、文档和项目约束，Codex 自己也明确标注了“需静态确认”。随后由本仓库执行代理完成 Phase 0 源码核查，见 baseline-audit.md。Part B 仍是按用户要求生成的、面向 gpt-6.1-sol ultra 的详细改造提示词。

---

先说明证据边界：本轮只读沙箱允许读取图片，但拒绝启动 PowerShell（`CreateProcessAsUserW failed: 5`），也没有可用的本地文本读取接口。因此我不能诚实地声称已经完成源码逐行核查，也不会虚构行号。下面将“截图/项目约束已确认”和“必须由执行代理静态确认”的项目严格分开；Part B 已把源码核查设为实施前置门禁。

# Part A：交叉验证报告

## 1. 结论摘要

1. M1 已有真实 Windows/Android Flutter 界面和真实远程画面，不是假页面；但 Android 工作区在标准手机宽度发生明确的顶部、底部 `RenderFlex overflow`，属于当前最直接的阻断缺陷。
2. Windows 首页仍是放大后的 Material 卡片布局：密度、控件高度、导航、标题栏和命令组织均不像 WinUI 3。
3. Android 首页接近 Material 风格，但没有完成 Pixel 式 edge-to-edge、系统栏配色、紧凑响应式布局和移动端任务优先级。
4. Windows 首页填写 `127.0.0.1:24808`，同屏 Host 启动提示却写 `24800`；应让命令提示使用当前输入端口，或明确说明二者并非同一实例。
5. Android 首页默认 `127.0.0.1:24800` 指向模拟器/手机自身；跨设备连接时这是误导性默认值。Debug 模拟器可提示 `10.0.2.2`，正式版应为空并解释局域网地址。
6. 文件页证明了单文件上传和 SHA-256 结果展示；但项目约束已明确 Windows 覆盖写入不是原子操作，不能把“上传完成”扩大解释成崩溃安全。
7. 输入释放、TLS 指纹校验时机、路径重解析点逃逸、socket 关闭竞态、Android 生命周期等不能从截图确认，必须在指定源码中逐项验证。
8. 账号、配对服务端、中继、Moonlight/Sunshine 质量模式、Linux、Android Host、Unicode/IME 完整注入继续留在 backlog，界面只能明确显示“未实现”。

证据截图：

- [Windows 首页](</C:/Users/Lenovo/Desktop/远程控制软件/artifacts/m1/windows-home.png>)
- [Windows 文件页](</C:/Users/Lenovo/Desktop/远程控制软件/artifacts/m1/upload-done.png>)
- [Android 首页](</C:/Users/Lenovo/Desktop/远程控制软件/artifacts/m1/android-home.png>)
- [Android 工作区](</C:/Users/Lenovo/Desktop/远程控制软件/artifacts/m1/android-workspace.png>)

## 2. 声明与现有证据的不一致

| 状态 | 声明/界面 | 现有证据 | 判断 |
|---|---|---|---|
| 已确认 | Windows 当前连接地址为 `127.0.0.1:24808` | 同页 Host 命令仍为 `yl-host --listen 0.0.0.0:24800` | 界面内部不一致；复制命令可能启动错误端口 |
| 已确认 | Android 默认地址可直接用于连接 Host | 首页为 `127.0.0.1:24800`，实际工作区使用 `10.0.2.2:24808` | Android loopback 指向本机/模拟器，不应作为跨设备默认 |
| 已确认 | Android 工作区可在手机上正常布局 | 顶部显示 `OVERFLOWED BY 1...`，底部显示 `OVERFLOWED BY 75 PIXELS` | 标准手机宽度下布局失败；release 会裁剪而非显示警示条 |
| 已确认 | 文件页显示“上传完成”和 SHA-256 | 项目约束同时注明 Windows 覆盖写入非原子 | 摘要校验不等于崩溃安全；覆盖过程中断仍可能破坏旧文件 |
| 需静态确认 | 追踪表中各项“已实现/已实测”是否与实现吻合 | 本轮无法读取追踪表、证据文档和测试源码 | 执行代理必须逐条给出文件、测试和环境证据，不得沿用旧勾选 |
| 需静态确认 | 协议顺序及权限检查与文档一致 | 需比对 `protocol.dart`、`remote_client.dart`、`yl-proto`、`session.rs` | 未完成比对，不能宣称一致 |
| 需静态确认 | Flutter/Rust FFI 或纹理桥完成 | 项目约束仅称其为 M1 阶段目标 | 除非代码与运行证据齐全，否则不得写成已完成 |

由于源码读取受阻，上表没有伪造“关键行”。执行代理必须在改动前补出真实行号并更新 [requirements-traceability.md](</C:/Users/Lenovo/Desktop/远程控制软件/docs/requirements-traceability.md>)。

## 3. 缺陷分级

| 级别 | 缺陷 | 证据与处置 |
|---|---|---|
| P0 | Android 工作区上下工具栏溢出、操作项被裁剪 | 截图直接确认。必须改为可收缩标题、横向溢出菜单和安全区内底栏 |
| P0 需验证 | 断线、路由退出、指针取消后是否释放所有按键和鼠标按钮 | 检查 Dart 输入状态与 Host session teardown；若无统一 release-all，立即修复 |
| P0 需验证 | Host 是否对每条输入/文件消息再次校验会话权限 | 设备 ID、客户端 UI 状态不得替代 Host 权限；检查 `session.rs/files.rs/input.rs` |
| P1 | Windows 覆盖上传非原子 | 已知边界。改用同目录临时文件、长度/摘要校验、flush 后原子提交；提交失败保留旧文件 |
| P1 | Android 默认 loopback 地址误导 | 正式版默认留空；debug 模拟器仅提供可点击建议，不静默写入 |
| P1 | Windows 当前端口与 Host 命令提示不一致 | 命令由表单当前值生成，并区分 bind address 与 connect address |
| P1 需验证 | TLS 是否在发送业务数据前完成证书指纹匹配 | 不得用永久返回 `true` 的 `badCertificateCallback` 后置补救 |
| P1 需验证 | 文件根目录对 `..`、绝对路径、UNC、符号链接、junction/reparse point 是否均防逃逸 | 添加 Windows 重解析点及 TOCTOU 测试；Host 为最终裁决方 |
| P1 需验证 | 接收循环、手动关闭、生命周期关闭是否可能重复完成 stream/completer 或 `setState` after dispose | 建立幂等连接状态机和单一关闭路径 |
| P1 需验证 | Android pause/detach 后连接与输入状态如何处理 | 至少立即停止注入并释放输入；恢复时不自动恢复“可控制” |
| P2 | Windows 系统信息显示 `"Windows 10 Pro"`，但 Build 26300 属于新版本系 | 用 runner 的版本 API 做展示映射；不影响协议 |
| P2 | 文件完成横幅长期占据整行、裸露完整本地路径和长摘要 | 改成通知条/详情展开；默认只显示文件名、方向、大小和校验成功 |
| P2 | 首页未实现能力占据大量首屏空间 | 改成禁用项或“开发计划”区域，不能与当前主要连接任务竞争 |

## 4. Windows UI 差距

- 首页：超大圆角卡片、56px 级输入框、移动端式主按钮和大量空白；左侧导航不像 `NavigationView`，未体现 hover、pressed、keyboard focus、compact mode。未实现能力看起来像半可用功能。
- 进度/错误：本轮无截图，必须确认不是阻塞式整页 spinner；应有可取消阶段列表、当前动作、可复制的安全错误码和“返回修改”。
- 工作区：本轮无 Windows 截图。应采用沉浸画布 + 紧凑 CommandBar，不能复制手机顶部胶囊布局；失焦、最小化和断线时必须释放输入。
- 文件页：缺少 Fluent CommandBar、列标题、可调整分栏、键盘选择、右键菜单、冲突处理及任务队列；中央上传/下载大按钮像平板界面。
- 设置：本轮无截图。应采用分组 SettingsPage、32–40px 行高、系统主题/强调色、危险操作说明和禁用原因。
- 关于：应展示版本、协议版本、许可证与第三方声明、构建信息；不能混入未实现功能宣传。

## 5. Android UI 差距

- 首页：未真正 edge-to-edge；系统栏与应用栏像两个分离色块。页面把桌面信息卡直接纵向堆叠，连接任务被设备说明挤压。`127.0.0.1` 默认错误。
- 进度：无截图；需使用 Material 3 top app bar、阶段式进度、取消/重试、离线说明，并支持系统返回。
- 工作区：顶部和底部明确 overflow；状态栏前景色与深色工具栏不匹配；控件横向硬排；远程画面只居中 contain，产生巨大黑区且缺少明确的适配/缩放/平移控制。
- 文件/其他：无 Android 文件页截图。不能把 Windows 双栏强塞进手机，应采用单栏当前目录、选择模式、底部操作面板和系统文件选择器。
- 交互风险：截图无法证明 48dp、ripple、TalkBack、predictive back、IME 与指针取消行为，必须实机验证。

## 6. 改造边界

纯 Flutter 可完成：

- 双平台 token、排版、导航、响应式布局、空/加载/错误/离线状态。
- Windows hover/pressed/focus、快捷键、CommandBar、可调分栏。
- Android Material 3、SafeArea/sliver、ripple、预测返回的 Flutter 接入、手势与缩放变换。
- 连接状态机 UI、输入状态跟踪、幂等 dispose。
- `SystemChrome` 系统栏样式和大部分 edge-to-edge 表现。

需要 runner/原生插件：

- Windows Mica/backdrop、原生标题栏拖拽区、最小窗口尺寸、可靠系统版本名称。
- Android 启动主题、原生 edge-to-edge flags、导航栏对比度和特定 IME/predictive-back 配置。
- 原生文件选择器仍可使用成熟 Flutter 插件，不应自行重写。

需要 Rust：

- 原子文件提交、根目录/重解析点边界、会话权限复核、断线释放输入。
- 若协议需要新增 `ReleaseAllInputs`，必须升协议版本并保持明确的兼容错误。

低风险替代：

- Windows 先保留系统原生标题栏，只启用 Mica 和最小尺寸；不要第一阶段自绘 caption buttons。
- Mica 不可用时回退到不透明 `surface`，禁止用半透明 Flutter 容器伪装系统材质。
- 若暂不增加协议消息，则以“关闭连接触发 Host 释放全部输入”作为最低安全保障，并为此添加测试。

# Part B：交给 gpt-6.1-sol ultra 的执行提示词

---

```text
你是“远联 YuanLian”资深 Flutter/Windows/Android/Rust 客户端工程师。请在以下仓库内完成平台化 UI 与已确认的功能/安全修复：

C:\Users\Lenovo\Desktop\远程控制软件

这是一次真实产品改造，不是静态原型。先阅读并遵守：
- AGENTS.md
- README.md
- docs/requirements-traceability.md
- docs/protocol.md
- docs/roadmap.md
- docs/evidence/*
- docs/design/flutter-rust-bridge.md

一、真实基线与证据纪律

1. M0 仅指已经实机验证过的 Windows 垂直切片：真实采集、图块差分/静止精修、TLS 证书指纹固定、SendInput、原生查看器。不得扩大成完整产品。
2. 当前已有 Flutter Windows/Android 客户端界面；现有截图证明：
   - Windows 连接首页可以输入地址和指纹；
   - Windows 单文件上传页面显示 SHA-256 结果；
   - Android 能进入远控工作区并显示真实 Windows 画面；
   - Android 工作区目前存在顶部约 1px、底部约 75px 的 RenderFlex overflow。
3. 截图不等同于协议、安全、生命周期或实机验收证据。任何“已完成并实测”必须分别记录：
   - 静态实现；
   - 构建通过；
   - 自动测试通过；
   - Windows 实机通过；
   - Android 模拟器或实机通过。
4. 开始修改前，先输出一份“基线审计表”，逐项引用真实文件和行号。若追踪表与代码不一致，先把结论记为“待修复/待验证”，不得沿用旧勾选。

二、本轮目标

1. Windows 客户端达到接近 Windows 11 / WinUI 3 / Fluent 的桌面观感和交互：
   - 桌面密度、NavigationView、CommandBar、键盘焦点、hover/pressed、滚动条、原生标题栏和窗口行为。
2. Android 客户端达到接近 AOSP/Pixel Material 3：
   - edge-to-edge、正确系统栏、安全区、48dp 目标、ripple、predictive back、IME、横竖屏和生命周期。
3. 修复已确认问题：
   - Android 工作区上下栏 overflow；
   - Android 正式版不再默认使用 127.0.0.1；
   - Windows 当前连接端口与 Host 命令提示保持一致；
   - Windows 文件覆盖写入改为崩溃安全的提交路径；
   - 连接关闭、页面退出、生命周期切换和 pointer cancel 不得产生卡键/卡鼠标；
   - 对权限、路径和 TLS 指纹校验进行静态核查，发现缺口则修复。
4. 保持现有 M0 协议及真实远控能力，不用新 UI 替换工作引擎。

三、非目标和 backlog

本轮不实现：
- 账号、设备云同步、配对服务端、会话票据；
- 中继/NAT 穿透；
- Moonlight/Sunshine 质量模式及预算控制；
- Linux 客户端；
- Android 被控 Host；
- 音频、剪贴板、无人值守、完整管理后台；
- 目录传输、拖放、续传、完整 ACL/审计；
- 完整 Unicode/中文 IME 远程注入，除非现有协议已真实支持。

这些内容只能进入 backlog，UI 中显示“未实现/需要服务端”，不得出现可点击后假成功、假登录、假进度或假设备。

四、不可违背约束

1. 不得伪造功能、设备、连接结果、延迟、吞吐、文件进度或成功状态。
2. 设备 ID 不是认证凭据；Host 必须对每条输入、读取、写入、删除请求二次校验权限。
3. 日志不得记录按键内容、剪贴板、文件内容、私钥、令牌或完整敏感路径。
4. 保持现有协议兼容。若必须新增消息：
   - 升协议版本；
   - 同步 docs/protocol.md；
   - 新旧端明确返回不兼容原因；
   - 为长度、解压尺寸、缓存和队列设置上限。
5. 不得删除、跳过或放宽现有测试；修复应增加回归测试。
6. 更新 docs/requirements-traceability.md，写清实现文件、测试环境、结果和剩余问题。
7. 禁止逐帧在 Dart 堆创建整帧 RGBA/JPEG 大对象、反复 decode/encode 或无界队列。保留现有引擎路径；纹理桥未完成时只做接口隔离和明确记录。
8. 不得把 Mica/Acrylic 做成整窗高透明效果；不可用时使用不透明表面回退。
9. 不要在 Android 上依赖 release 模式隐藏 overflow；必须消除约束错误。
10. 保留 Sunshine/moonlight-common-c 的许可证义务和上游声明；本轮不擅自集成新视频栈。

五、先完成代码级风险核查

逐项检查并把结果加入基线审计表：

1. client/lib/src/net/protocol.dart 与 crates/yl-proto/src/lib.rs：
   - magic/version/消息类型/字段顺序/大小端；
   - 最大消息长度；
   - 文件流与画面流的合法顺序；
   - 未知消息和版本不兼容处理。
2. client/lib/src/net/remote_client.dart：
   - TLS 指纹必须在发送认证或业务数据前验证；
   - 不允许无条件信任证书；
   - connect/cancel/error/disconnect 只有一个终态；
   - close/dispose 幂等；
   - 接收循环结束后不再 setState/写已关闭 stream；
   - 输入发送优先级不能被画面或文件传输饿死。
3. crates/yl-host/src/session.rs、input.rs：
   - 每个会话单独跟踪按下的键和鼠标按钮；
   - 正常断开、错误、超时、客户端退出时全部释放；
   - 重复 key-up/mouse-up 安全；
   - 未授权/文件模式会话不能注入输入；
   - 隐藏测试开关不得暴露为产品功能。
4. crates/yl-host/src/files.rs：
   - 拒绝绝对路径、..、UNC、设备路径、ADS；
   - 防止 symlink/junction/reparse point 逃出 file-root；
   - 检查 TOCTOU；
   - 大小、单文件上限和摘要；
   - 上传先写同目录随机临时文件，校验长度和 SHA-256，flush/sync 后提交；
   - 目标已存在时默认返回冲突，不可直接破坏旧文件；
   - 用户明确选择替换时，Windows 使用可靠的原子替换 API；失败必须保留旧文件并清理临时文件；
   - 删除权限不得由写入权限隐式获得。
5. Android 生命周期：
   - paused/inactive/detached 时停止输入并释放本地 pressed set；
   - 必要时主动关闭会话，让 Host teardown 释放输入；
   - resumed 后不得自动恢复“可控制”，需用户明确重新进入；
   - pointer cancel、手势竞争、系统返回均释放临时输入状态。

若现有实现已经正确，不要为了“看起来改了代码”而重写；用测试和追踪表证明即可。

六、设计 token

建立共用语义层和平台覆盖层，不要让页面直接散落颜色/半径。

建议文件：
- client/lib/src/ui/design_tokens.dart
- client/lib/src/ui/platform_theme.dart
- client/lib/src/ui/components/windows/*
- client/lib/src/ui/components/android/*

共用语义 token：
- spacing: 4, 8, 12, 16, 20, 24, 32, 40
- icon: 16, 20, 24
- semantic colors: primary/onPrimary、surface/onSurface、surfaceContainer、outline、error、warning、success、offline、focus
- motion: fast 100ms、normal 160ms、page 220ms；尊重 disableAnimations/reduced motion
- 最低正文对比度 4.5:1；大字和非文本状态按适用标准检查
- 状态不能只用颜色表达，必须同时有图标和文字

Windows 覆盖：
- 字体：Segoe UI Variable Text；回退 Segoe UI、Microsoft YaHei UI、sans-serif
- caption 12/400；body 14/400；bodyStrong 14/600；subtitle 20/600；title 28/600
- 控件圆角 4；卡片/菜单 8；对话框 8–12
- 普通控件高 32；主要按钮 36；导航项 40；触控友好场景最低 40
- 页面边距 24；卡片内距 16–20；字段间距 12
- focus ring 2px，使用系统 accent；必须清晰可见
- hover 使用轻微 overlay；pressed 比 hover 更深；disabled 降低对比但仍可读
- light/dark 跟随系统；系统 accent 可用时采用，失败回退当前品牌蓝
- 滚动条默认细，hover 扩展；不得永久显示移动端粗滚动条

Android 覆盖：
- 使用 Material 3 ColorScheme；Android 12+ 支持动态色，品牌蓝作为回退 seed
- bodySmall 12/16、bodyMedium 14/20、bodyLarge 16/24
- titleMedium 16/24/500、titleLarge 22/28、headlineMedium 28/36
- 输入框高 56dp；按钮和所有点击目标至少 48×48dp
- 普通圆角 12dp；卡片 16dp；FAB/胶囊 20–28dp
- 页面水平边距手机 16dp、平板 24dp
- 使用 tonal surface，不用大量纯白描边卡片
- InkWell/Material 提供真实 ripple，禁用状态仍解释原因
- 系统字体和 font scaling 至少测试 1.0、1.3、2.0

七、Windows 页面规格

1. HomeShell
- >=1000 logical px：展开 NavigationView，宽 240–280。
- 720–999：compact rail，宽 56–64。
- <720：顶部菜单按钮 + drawer。
- 导航项只包含已存在页面；设备、活动记录等未实现项可显示锁定图标和“尚未接入”，点击只打开说明，不进入假页面。
- 顶部保留面包屑和全局状态，但收紧到 48–52px。
- 支持 Alt+Left 返回、Ctrl+L 聚焦 Host 地址、Ctrl+, 设置、F1 帮助、Esc 取消当前非破坏操作。

2. 首页/连接
- 主列最大宽 720–760；右侧设备摘要 280–320，仅在足够宽时出现。
- 字段改成 Windows 32–36px 密度；指纹用等宽字体分组显示，支持粘贴、清空、复制和格式错误。
- Android/Windows 正式版地址默认留空；可显示示例 `192.168.1.20:24800`。
- Host 启动命令必须根据当前端口生成：
  - connect host 与 bind host 分开解释；
  - 用户连接 127.0.0.1:24808 时，示例命令端口同步为 24808；
  - 不把 0.0.0.0 当作客户端可连接地址。
- 主按钮仅在地址和 64 位十六进制指纹合法时启用。
- 未实现质量模式移入“开发计划”，不占首屏主任务。

3. 连接进度
- 阶段：解析地址、建立 TCP、TLS 握手、验证指纹、协议协商、等待首帧。
- 只能显示真实已到达阶段；未知时显示不确定进度，禁止伪造百分比。
- 提供“取消”；取消必须关闭 socket 并回到可重试状态。
- 超时、指纹不匹配、版本不兼容、Host 拒绝权限分别展示不同文案。

4. 错误页/错误面板
- 给出用户可执行的下一步；
- 默认隐藏堆栈；
- 提供复制安全诊断信息，但过滤令牌、指纹之外的敏感内容和完整本地路径；
- 按钮顺序：重试、返回修改、复制诊断。

5. Windows 远控工作区
- 远程画面是主区域，CommandBar 高约 40–44。
- 命令：返回、适应窗口、100%、缩放、查看/控制状态、断开、更多。
- 窗口失焦、最小化、断开和路由退出均释放本地输入状态。
- 使用 InteractiveViewer 或等价变换层时，输入坐标必须使用同一矩阵的逆变换并 clamp 到远端像素边界。
- 禁止在 letterbox 区域发送点击。
- 支持 Esc 退出捕获；Ctrl+Alt+Shift 等系统保留组合需明确策略。
- 无首帧显示等待状态；断线保留最后一帧但覆盖“连接已断开”，禁止继续输入。

6. Windows 文件页
- 使用 CommandBar：选择本地文件、上传、下载、刷新、返回上级、取消任务。
- 桌面宽度足够时双栏；中间是可拖动 splitter，不是宽灰色操作柱。
- 两栏均有列标题：名称、大小、修改时间；支持键盘上下移动、Enter 打开、Backspace 上级、F5 刷新、Delete 仅在有删除权限时出现。
- 右键菜单必须与实际能力一致。
- 上传/下载进入底部任务队列，显示真实字节数、速度、摘要校验状态和取消。
- 冲突弹窗：保留两者/替换/取消；未实现安全替换前禁用“替换”并解释原因。
- 完成通知默认显示文件名、方向、大小和“SHA-256 已验证”；完整路径和摘要放在可展开详情。
- 空目录、加载、断线、权限拒绝、摘要失败均有独立状态。

7. 设置
- 分组：外观、连接、安全、输入、文件、诊断。
- 未实现设置显示禁用和原因，不得保存无效值。
- 主题支持系统/浅色/深色。
- 诊断日志开关明确隐私范围；不得记录按键、文件内容或令牌。
- 危险或实验开关不得把 `--force-input` 暴露出来。

8. 关于
- 应用版本、构建号、协议版本、引擎状态；
- 第三方许可证及 Sunshine/moonlight-common-c 声明入口；
- 明确标注“开发版 M0/M1”，不宣传未实现能力。

八、Android 页面规格

1. 全局
- 在 Android 原生层和 Flutter 同时启用 edge-to-edge；
- 状态栏、导航栏透明，图标明暗随当前 surface；
- 所有页面使用安全区和 MediaQuery.viewPadding/viewInsets；
- 使用 PopScope 支持 predictive back；连接中返回先停止输入，再按真实状态决定是否确认断开；
- 键盘弹出时字段和主操作可见，不产生 overflow。

2. 首页
- 使用 Material 3 TopAppBar；手机不显示桌面侧栏。
- 首屏只保留连接任务；设备能力和开发状态放到折叠区或后续页面。
- 正式版地址默认空；debug 模拟器可以提供“使用模拟器宿主 10.0.2.2”的 suggestion chip，但不得静默写入。
- 地址、指纹输入支持粘贴、清空、IME next/done 和明确校验。
- 主按钮纵向优先；窄屏时“连接 Host”和“仅传文件”不得硬排导致低于 48dp。

3. 连接/进度/错误
- 使用 TopAppBar + 真实阶段列表；
- 支持取消、系统返回和重新连接；
- snackbar 只用于短消息，关键错误保留在页面；
- 指纹不匹配必须阻止继续并明确显示期望/收到的安全摘要，不提供“仍然连接”。

4. Android 远控工作区
- 修复当前顶部和底部 RenderFlex overflow，要求 360dp 宽、字体 1.3 下仍无黄黑条或裁剪。
- 顶栏结构：
  - 返回 48dp；
  - 设备名可 ellipsis；
  - 地址作为次级文本；
  - 查看/控制作为一个状态控件；
  - 适应模式、断开等收进 overflow menu。
- 画布支持：
  - 默认 fit；
  - 双击在 fit 与 100% 间切换；
  - 双指缩放和平移；
  - 单指远程输入只在“控制”状态生效；
  - letterbox 不发送输入；
  - 缩放后使用逆矩阵映射远端坐标。
- pointer up/cancel、三指系统手势竞争、路由退出均释放按下状态。
- 底栏放入安全区，只显示必要指标：画面状态、分辨率、fps、RTT；带宽和高级信息进入详情面板。
- 软件键盘入口使用 bottom sheet；若协议只支持虚拟键码，明确写“暂不支持中文/Unicode 文本输入”，不得伪装成功。
- 旋转时保存缩放模式但重新计算变换；不得继续使用旧尺寸坐标。
- 后台/锁屏时立即停止远程输入，恢复后默认查看模式。

5. Android 文件
- 单栏目录浏览，不复制 Windows 双栏。
- 顶栏显示当前目录；文件使用 ListTile，点击目录进入，长按进入选择模式。
- 上传调用系统文件选择器；下载调用系统保存位置或应用明确授权目录。
- 操作放到底部 action sheet；所有目标至少 48dp。
- 显示真实任务进度、取消、摘要校验、冲突和离线状态。
- 不申请广泛存储权限；优先 Storage Access Framework。

6. 权限和未实现状态
- 只在实际需要时请求权限；
- 拒绝后显示设置入口和不授权时的可用范围；
- 账号、配对、中继、Android Host 等显示 backlog 说明，不出现假开关。

九、逐文件改动清单

必须先根据仓库实际内容校正类名，不要盲目覆盖用户已有实现。

Flutter：
- client/lib/src/ui/theme.dart
  - 拆分共用语义 token 与 Windows/Android ThemeData；
  - 配置 typography、focus、hover、pressed、scrollbar、Material 3。
- client/lib/src/ui/home_shell.dart
  - Windows 响应式 NavigationView；
  - Android TopAppBar/NavigationBar 或 drawer；
  - 快捷键、焦点顺序、返回语义。
- client/lib/src/ui/home_page.dart
  - 平台化连接表单；
  - 修正地址默认和 Host 命令端口；
  - 收起未实现质量模式。
- client/lib/src/ui/connection_progress_page.dart
  - 真实阶段状态机、取消、错误分类和重试。
- client/lib/src/ui/workspace_page.dart
  - 消除 Android overflow；
  - fit/zoom/pan 和统一坐标变换；
  - pressed input 生命周期；
  - Windows CommandBar、Android 自适应工具栏。
- client/lib/src/ui/file_browser_page.dart
  - Windows 双栏 Fluent 文件管理；
  - Android 单栏 M3；
  - 任务队列、冲突、摘要和错误状态。
- client/lib/src/ui/settings_page.dart
  - 平台化设置分组、主题、诊断隐私和禁用原因。
- 新增或补齐 about_page.dart
  - 版本、协议、许可证、开发版边界。
- client/lib/src/net/protocol.dart
  - 只在核查发现不一致或需要 ReleaseAllInputs 时修改；
  - 同步版本与文档。
- client/lib/src/net/remote_client.dart
  - TLS 前置校验、幂等连接状态机、统一关闭、输入优先级和生命周期接口。
- Flutter 测试目录
  - 添加 360dp/1280px 响应式 golden/widget tests；
  - 状态机、dispose、错误映射、坐标变换、地址校验测试。

Windows runner：
- client/windows/runner/flutter_window.cpp
- client/windows/runner/win32_window.cpp/.h
- client/windows/runner/main.cpp
- client/windows/runner/Runner.rc
- client/windows/runner/runner.exe.manifest
  - 保留原生 caption buttons；
  - 设置最小内容尺寸，建议 960×640 logical；
  - Windows 11 启用 Mica 和暗色 caption，旧系统回退不透明 surface；
  - 若扩展内容到标题栏，必须实现正确 hit-test、DPI 和拖拽区；第一阶段可不扩展；
  - 用可靠 Windows API显示系统版本；
  - 不引入需要大规模 runner 重写的窗口插件，除非现有工程已使用。

Android：
- client/android/app/src/main/AndroidManifest.xml
- client/android/app/src/main/kotlin/.../MainActivity.kt
- client/android/app/src/main/res/values/styles.xml
- client/android/app/src/main/res/values-night/styles.xml
- client/android/app/build.gradle 或 build.gradle.kts
  - edge-to-edge、透明系统栏、启动主题；
  - predictive back 与现有 target SDK 匹配；
  - 不新增不必要权限；
  - 检查方向变化和 configChanges；
  - debug/release 不共享误导性的 loopback 默认配置。

Rust：
- crates/yl-host/src/session.rs
  - 权限复核、session teardown、release-all。
- crates/yl-host/src/input.rs
  - pressed set、幂等释放和测试。
- crates/yl-host/src/files.rs
  - 路径边界、重解析点、同目录临时文件、摘要、冲突和原子提交。
- crates/yl-proto/src/lib.rs
  - 仅在确需协议变化时升级并补测试。
- docs/protocol.md
  - 同步任何协议变化。
- docs/requirements-traceability.md
  - 每阶段都更新证据，不在最后一次性补写。

十、分阶段执行与独立验收

Phase 0：只读基线
- 输出文档/代码/截图差异表和真实行号。
- 不修改协议前先确定是否必要。

Phase 1：安全和状态机
- 修复输入释放、TLS、文件原子提交、路径边界、幂等关闭。
- 单元测试先通过。
- 此阶段不做大规模视觉重构。

Phase 2：设计系统和壳层
- 完成 token、双平台 theme、Windows NavigationView、Android edge-to-edge。
- 页面功能保持不变。
- 截图确认 light/dark 和响应式。

Phase 3：连接/进度/错误
- 修正地址默认、端口命令、真实进度和错误恢复。
- 验证取消、超时、指纹错误、Host 拒绝。

Phase 4：工作区
- 修复 Android overflow；
- 实现 fit/zoom/pan、输入坐标与生命周期；
- Windows CommandBar。
- 做真机/模拟器输入与断线验证。

Phase 5：文件/设置/关于
- 平台化文件 UI；
- 完成安全替换和冲突流；
- 设置、隐私说明、许可证。

Phase 6：回归和证据
- 构建、测试、截图；
- 更新追踪表；
- 列出仍未实机验证的项目。

十一、验证命令

按仓库真实工具链执行，避免无意义全量重建：

Rust：
cargo fmt --all -- --check
cargo clippy --workspace --all-targets
cargo test --workspace
cargo build --release -p yl-host -p yl-viewer

Flutter：
C:\Users\Lenovo\dev\flutter\bin\flutter.bat analyze
C:\Users\Lenovo\dev\flutter\bin\flutter.bat test
C:\Users\Lenovo\dev\flutter\bin\flutter.bat build windows
C:\Users\Lenovo\dev\flutter\bin\flutter.bat build apk --debug

实机专项：
- Windows 1280×800 logical，100% 和 200% DPI；另测最小窗口 960×640。
- Android 截图 1080×2400，至少覆盖约 360dp 宽手机；字体 1.0、1.3、2.0。
- Windows light/dark；Android light/dark 和手势导航。
- 键盘：Tab、Shift+Tab、Enter、Space、Esc、Alt+Left、Ctrl+L、Ctrl+,。
- Android：predictive back、旋转、IME 展开/收起、后台/前台、锁屏恢复、pointer cancel。
- 错误路径：地址错误、连接拒绝、TLS 指纹不符、协议版本不符、首帧超时、传输中断、摘要失败、磁盘满、权限拒绝、同名冲突。
- 文件：上传/下载分别验证 0B、小文件、2MiB 以上文件、中文名、长文件名；比较客户端和 Host SHA-256。
- 输入：断网时按住鼠标或键盘，确认 Host 最终收到释放；同机键盘不得用作 E2E 结论。
- Android 工作区截图不得出现任何 RenderFlex overflow 或被安全区遮挡。

截图交付：
- Windows 首页、连接进度、指纹错误、工作区、文件页、设置、关于：
  1280×800 logical；关键页补 200% DPI。
- Android 首页、连接进度、错误、工作区 fit、工作区 zoom、文件、权限拒绝：
  1080×2400；至少一组横屏工作区。
- 截图必须来自真实运行状态，不能用静态 mock 替代。

十二、完成标准 DoD

1. 四个已有证据页面全部完成平台化，Android 工作区零 overflow。
2. Windows 在鼠标、键盘、DPI、light/dark 下像桌面应用；Android 在手势导航、安全区、IME、旋转下像 Pixel M3 应用。
3. 已实现按钮均有真实行为；未实现功能明确禁用并说明原因。
4. TLS 指纹、Host 权限、路径边界、断线输入释放和文件摘要均有测试。
5. Windows 覆盖上传失败不破坏旧文件。
6. 连接取消/断线/dispose 幂等，无 setState after dispose、closed sink 或未处理异步异常。
7. 没有新增逐帧 Dart 大对象、无界队列或 UI 线程解码回归。
8. 所有验证结果和剩余缺口写入 requirements-traceability.md。
9. 最终报告区分“构建通过、测试通过、模拟器通过、Windows 实机通过、Android 实机通过”。
10. 不得把 backlog 宣称为本轮实现。

禁止事项：
- 禁止假登录、假设备、假进度、假吞吐和假成功。
- 禁止仅删除 overflow 警告或使用 ClipRect 隐藏布局错误。
- 禁止关闭证书验证。
- 禁止客户端校验替代 Host 权限检查。
- 禁止以 canonicalize 一次就宣称完全防止 Windows junction/TOCTOU。
- 禁止自绘加密算法。
- 禁止删除测试、降低断言或跳过失败测试。
- 禁止为了视觉改造替换已经验证的 M0 引擎。
```

---

## Part B 自检

- 自包含：是，包含基线、范围、非目标、约束、token、逐页、逐文件、阶段、验证和 DoD。
- 可直接执行：是，但执行代理必须先完成 Phase 0 并补出本轮因沙箱限制未能提供的源码行号。
- 未夸大：账号、中继、质量模式、Linux、Android Host、完整 IME 等均保留为 backlog。
- 安全边界：覆盖 TLS、Host 权限、路径、原子文件提交、断线释放和日志隐私。
- 平台差异：Windows 与 Android 分别定义，不再使用一套放大的 Material 页面。