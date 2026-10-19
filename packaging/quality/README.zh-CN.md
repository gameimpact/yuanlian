# 远联质量预览（Moonlight 社区版）

**质量模式使用视频串流**，画面在独立 Moonlight 窗口中显示；远联的兼顾档仍使用图块更新。以下启动器改进已在源码中完成，既有已打包 zip 不会自动包含新客户端，使用前确认客户端版本与构建来源。

本目录不是远联自有视频引擎，也不属于远联账号 / 票据 / Host 授权 / 中心撤权闭环。它把上游
**Moonlight-qt 6.2.0** 与 **Sunshine 2026.914.233613** 的官方 Windows x64 二进制按固定
版本和 SHA-256 打包，作为质量档的**社区、非商用预览**。

- Moonlight Game Streaming Project：<https://github.com/moonlight-stream/moonlight-qt>
- Sunshine（LizardByte）：<https://github.com/LizardByte/Sunshine>
- 两者均为 GPL-3.0；Qt 6 运行库为 LGPL-3.0。许可证全文在 `licenses/`。
- 远联未修改上游二进制。对应源码 tag/commit 与获取方式见 `SOURCE-OFFER.txt`。
- 项目方将本预览限定为社区、非商用。GPL-3.0 本身不禁止商业使用；商用必须另行完成
  许可证、签名、审计和支持评估，不能沿用本预览声明。

## 安装

1. 解压 `yuanlian-quality-preview-<version>-windows-x64.zip` 到远联安装目录下的
   `quality-preview`，即：
   `%LOCALAPPDATA%\Programs\YuanLian\quality-preview\windows-x64\...`
2. 打开远联客户端 → 首页 → **模式与开发计划** → **质量模式（Moonlight 社区预览）** →
   **打开预览**。客户端会自动检测 `quality-preview\windows-x64\moonlight\Moonlight.exe`。
3. 也可以设置环境变量 `YUANLIAN_QUALITY_PREVIEW` 指向 `quality-preview\windows-x64`，
   或在页面里手动填写 Moonlight 路径。
4. 阅读并勾选外部串流边界后，可打开 Moonlight 配对/应用列表；配对成功后关闭该窗口，再从远联输入被控机实际地址与应用名称启动串流。
5. 每次启动按客户端内置的固定版 284 文件清单校验 Moonlight 及依赖；失败时从官方固定版本归档重新解压到新目录，不修改清单绕过。配对后可读取真实 Host 应用列表，支持取消/超时，失败仍可手动填写已确认的应用名称。校验不证明硬解或远端授权。
6. 编码、解码、窗口、分辨率/FPS/码率都是请求值；实际结果看 Moonlight 性能浮层。远联尚未读取实际首帧/硬解/各通道加密策略，不会把进程运行当成正常出画。

主安装器不包含这些 GPL 二进制，质量预览必须单独下载。

## 被控端（Sunshine）

1. 在要被控制的 Windows 电脑上运行 `quality-preview\windows-x64\sunshine\sunshine.exe`。
2. 首次启动打开 `https://localhost:47990`（自签名证书），设置本地管理员账号。
3. 在 Moonlight 客户端添加 Host，首次连接会显示 PIN；在 Sunshine WebUI 的 PIN 页面输入
   同一个 PIN 完成配对。
4. Sunshine 默认使用 47984/TCP、47989/TCP、47990/TCP、48010/TCP。只在可信局域网放行
   这些端口，不要把 Sunshine 暴露到公网，也不要修改远联现有的 nginx/防火墙。
5. Sunshine 与 Moonlight 直接协商视频编码（H.264/HEVC/AV1）和加密。它不会读取远联的
   设备身份、票据或权限。

## 已验证

2026-10-19，本机 Windows 11、RTX 5060 Laptop、Sunshine 2026.914.233613 + Moonlight-qt
6.2.0，同一台机器回环：

- Moonlight 性能浮层：`Video stream: 1920x1080 60.05 FPS (Codec: HEVC)`，
  `Incoming/Decoding/Rendering ~60.05 FPS`，`Host processing latency 1.7/4.6/2.0 ms`
  （min/max/avg），网络/抖动丢帧约 `0.002%`，码率 20 Mbps。
- 持续约 5 分钟后再次读取，仍为约 60.05 FPS，并非只看首帧。
- 画面是当前 Windows 桌面的真实镜像（窗口内出现桌面与递归镜像），不是静态测试图。
- 证据与限制：`docs/evidence/quality-preview-moonlight-2026-10-19.md`。

**未验证**：两台物理设备、跨 NAT、1440p/4K、10 分钟以上、HDR、音频、手柄、输入延迟、
Android/Linux 客户端、弱网。不要把这些写成已通过。

## 安全边界（必须保留）

这条路径**不经过**远联的：

- 账号登录、设备目录、配对和短时 Ed25519 票据；
- Host 本机 MessageBox 确认与读写/输入权限交集；
- 心跳租约和中心撤权（远联撤权不会关闭 Moonlight 会话）；
- 远联审计日志与文件权限。

因此质量预览：

- 不是“已集成、已通过安全验收”的质量模式；
- 不能用于生产远控、不受信任网络或需要中心撤权的场景；
- 可关闭 Moonlight 窗口，或结束远联本页启动的客户端；正常返回会提示结束。新版 Windows 原生 Job 在远联异常退出时清理受管子进程，不关闭其他 Moonlight、Sunshine 或远端应用，也不代替 Host 中心撤权；被控端不再使用时仍需关闭 Sunshine；
- 不要把 Moonlight/Sunshine 的配对私钥、PIN、日志或账号写入仓库或远联日志。

## 重新打包

```powershell
# 需要先准备两个官方 zip（见 third_party/moonlight/README.md 的 URL 和哈希）
powershell -ExecutionPolicy Bypass -File packaging/quality/build-quality-preview.ps1 -Version 0.2.0
```

脚本会校验 zip 的 SHA-256、检查二进制版本、拒绝把运行期 `Moonlight.ini`、
`sunshine_state.json` 或 `credentials` 打进包，并核对内置组件清单、生成 `SHA256SUMS.txt` 与最终 zip。采用输出目录下唯一私有 staging，保留既有 `windows-x64` 运行目录，拒绝覆盖同名最终 zip。新版客户端的清单资源由 `update-component-manifest.ps1` 从固定 SHA-256 官方归档生成；不可用运行目录生成可信清单。已有发布包不会自动更新。
