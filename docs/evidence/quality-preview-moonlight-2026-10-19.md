# 质量档社区预览：Moonlight + Sunshine 实测（2026-10-19）

## 结论

本轮按用户要求直接使用上游 **Moonlight-qt 6.2.0** 与 **Sunshine 2026.914.233613**
构建了可运行的**社区、非商用质量预览**，并在本机完成真实 1920x1080 60 fps HEVC 串流
约 5 分钟。质量预览包、启动页、版本/哈希/许可证/源码说明已落地。

这不是“远联自有质量模式完成”，也不是“嵌入 Flutter 的质量模式”：

- 视频采集、编码、传输、解码和呈现由 Moonlight/Sunshine 完成，远联只提供 Windows
  启动入口与检测/参数校验；
- 该会话使用 Moonlight 自己的配对和加密，**不经过**远联账号、短时票据、Host 本机确认
  和中心撤权；远联撤权不能结束它；
- 仅限社区、非商用；GPL-3.0 本身不禁止商用，商用必须另行评估，不能沿用本声明。

## 固定上游

| 组件 | 版本 | 来源 | 资产 SHA-256 |
|---|---|---|---|
| Moonlight-qt | 6.2.0 | <https://github.com/moonlight-stream/moonlight-qt/releases/tag/v6.2.0>，commit `de2467e433821664cdd2224aad8c89a625be1ad9` | `6f91d268b41ed5ca8066d9d7578dc403b8db190991ff48f00b1700465f8f7ebf` |
| Sunshine | 2026.914.233613 | <https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613>，commit `63d35f702ee9e362e43263742981836ec0710384` | `233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b` |

两者均为 GPL-3.0；Qt 6 运行库 LGPL-3.0。远联未修改上游二进制。许可证全文、NOTICE 和
源码获取方式随预览包分发，仓库内位于 `packaging/quality/`。

## 测试环境

- Windows 11 build 26300，Lenovo RTX 5060 Laptop GPU（8 GB 显存），驱动 32.0.15.7301；
- 显示源 3200x2000 @ 165 Hz，Per-Monitor-V2；
- Sunshine 使用 NVIDIA `hevc_nvenc`，请求 60 fps，码率 20000 Kbps；
- Moonlight 使用 D3D11VA 硬件解码、窗口模式，目标 1920x1080；
- **同机回环 127.0.0.1**，不是两台物理设备，也不是跨 NAT。

## 实际步骤

1. 从官方 zip 解压到 ASCII 路径运行 Sunshine（中文路径会触发
   `sunshine_state.json: cannot open file`）。测试完成后已停止 Sunshine/Moonlight，
   并清理了测试配对状态；测试凭据不在仓库、日志或本文档中。
2. 通过 Sunshine WebUI 的 PIN 流程完成 Moonlight 首次配对，`Moonlight.exe list
   127.0.0.1` 返回真实应用列表 `Desktop`、`Steam Big Picture`。
3. 第一次启动使用 `--display windowed` 被 Moonlight 拒绝（未知选项，退出码 1）；
   改为官方 CLI 的 `--display-mode windowed` 后成功。
4. 启动命令：

```powershell
Moonlight.exe --resolution 1920x1080 --fps 60 --bitrate 20000 `
  --display-mode windowed stream 127.0.0.1 "Desktop"
```

5. 在 Moonlight 窗口内用 `Ctrl+Alt+Shift+S` 打开官方性能浮层，约 5 分钟后再次读取。
6. Sunshine 日志记录 `New streaming session started`、`CLIENT CONNECTED`、
   `hevc_nvenc`、`Requested frame rate [60fps]`，采集为 3200x2000 后按请求缩放编码。

## 结果（官方性能浮层）

约 5 分钟时截图：`docs/evidence/assets/quality-preview-stats-5min.png`

| 指标 | 读数 |
|---|---|
| Video stream | `1920x1080 60.05 FPS (Codec: HEVC)` |
| Incoming frame rate | `60.05 FPS` |
| Decoding frame rate | `60.05 FPS` |
| Rendering frame rate | `60.05 FPS` |
| Host processing latency | `1.7 / 4.6 / 2.0 ms`（min/max/avg） |
| Frames dropped (network / jitter) | 约 `0.002%` |
| Average network latency | `1 ms`（variance `0 ms`） |
| Average decoding time | `0.34 ms` |
| Average frame queue delay | `0.01 ms` |
| Average rendering time | `0.21 ms` |

启动初期另一次读数：60.03 FPS，Host 处理延迟 `1.7/4.9/2.0 ms`，丢帧约 0.002%。
两次读数均来自 Moonlight 自己的统计浮层，不是本地动画或伪造数值。

画面是当前 Windows 桌面的真实镜像（窗口内出现桌面应用和递归镜像），不是静态测试图。
原始首张截图：`artifacts/moonlight-quality-stream.png`（本机未提交，可按需重跑）。

这证明该上游质量路径在 1080p60、20 Mbps、单机回环下**能真实跑到 60 fps**；但 5 分钟
不是完整 10 分钟验收，也不是两台物理设备或 1440p/4K 验收。

## 远联侧启动入口

Windows 客户端新增“质量模式（Moonlight 社区预览）”页面：

- `client/lib/src/platform/quality_preview.dart`：路径定位、参数校验、CLI 参数构建；
- `client/lib/src/ui/quality_preview_page.dart`：组件检测、连接参数、警告、归属与许可；
- `client/lib/src/ui/home_page.dart`：模式与开发计划中的入口；
- 启动使用 `ProcessStartMode.detached`，避免未读取子进程 stdout/stderr 导致 Moonlight
  卡死；第一次测试正是非 detached 模式卡死，修正后 `Responding=True`；
- 页面明确写出“不经过远联票据/撤权”“仅社区、非商用”。

验证截图：`docs/evidence/assets/quality-preview-page.png`（Windows 1280x800 逻辑窗口）。

测试：

- `dart analyze lib test`：0 issue；
- `flutter test --no-pub`：48 个测试通过，包含质量预览参数/定位测试和 1280x800、
  360dp + 1.3 字体响应式测试；
- Windows release 构建通过：`C:\Users\Lenovo\dev\yuanlian-client-build\...\yuanlian_client.exe`；
- UI 实测：打开入口 → 自动检测 Moonlight/Sunshine → 点击“启动 Moonlight 串流” →
  子进程 PID 真实启动且响应；串流指标由上面的 CLI 测试取得。

## 质量预览包

`dist/0.2.0/quality-preview/yuanlian-quality-preview-0.2.0-windows-x64.zip`

- SHA-256 `632105e5dc5e0bbb09c5aef32e8ddbccc868105a91819cecd5ceb413a72ead25`；
- 约 73 MB（解压约 198 MB），zip 根为 `windows-x64/`；
- 内含 `moonlight/`、`sunshine/`、`licenses/`、`README.zh-CN.md`、
  `THIRD-PARTY-NOTICES.txt`、`SOURCE-OFFER.txt`、`SHA256SUMS.txt`；
- 打包脚本：`packaging/quality/build-quality-preview.ps1`；
- 校验：拒绝运行期 `Moonlight.ini`、`sunshine_state.json`、`credentials`，
  并校验版本与上游 zip 哈希；
- 主安装器不包含这些 GPL 二进制，避免把可选社区组件混进主安装包；
- 标准安装路径实测：安装 0.2.0 setup → 解压到
  `%LOCALAPPDATA%\Programs\YuanLian\quality-preview`（得到
  `quality-preview\windows-x64\moonlight\Moonlight.exe`）→ 不设置环境变量启动客户端，
  页面自动检测 Moonlight/Sunshine → 静默卸载后安装目录（含 quality-preview）被删除。

## 未验证 / 限制

- 两台物理设备、跨 NAT、弱网、UDP 阻断、强制 TURN：未测；
- 1440p/4K、10 分钟以上、HDR、音频、手柄、输入延迟：未测；
- Android/Linux 客户端、Android/Linux Host：未测；
- 未做嵌入 Flutter 的 Moonlight 渲染；当前是外部进程启动；
- 未接入远联账号/票据/Host 授权/撤权；不能把这条路径算作远联安全闭环；
- 未做代码签名，Windows 安装器仍为预览；质量预览包也未签名；
- 本机回环不能代表真实局域网/公网编码器和网络路径。

## 不能声称

不能宣称：

- “远联质量模式已完成并集成”；
- “质量模式已通过远联票据/撤权验收”；
- “跨设备/跨 NAT 60 fps 通过”；
- “1440p/4K/10 分钟/音频/HDR 通过”；
- “商用可用”。

只能宣称：**使用上游 Moonlight/Sunshine 的社区、非商用质量预览，在本机回环
1080p60 下实测约 60 fps，UI 启动入口真实可用；安全闭环和完整验收未完成。**
