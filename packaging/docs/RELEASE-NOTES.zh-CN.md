# 远联 0.2.0 发布说明（开发预览）

日期：2026-10-18。协议 v2。源码 revision 记录在 `build-manifest.json`；构建时工作区有未提交改动，本版本不是“干净源码构建”的最终发布候选。

## 新增

### 安全与授权

- Host 持久 TLS 身份：`host-cert.der`/`host-key.der` 保存在身份目录，重启不改变指纹/设备 ID；半缺失身份报错而不是静默换身份。
- 控制服务端签发 Ed25519 短时会话票据：绑定设备、用户、连接 nonce、用途、权限、`jti`、签发/过期时间。
- Host 离线验签、防重放缓存、过期/跨设备/nonce 校验；票据模式默认拒绝匿名连接。
- 本机 MessageBox 授权；票据不能绕过本机拒绝。`--auto-approve` 仅显式测试。
- 有效权限 = 票据权限 ∩ Host 本地策略；文件读/写逐条校验；输入需 `CONTROL` 与 `--allow-input`。
- 中心撤权：Host 每秒心跳，撤销后实测 0.86–1.17 秒结束会话并释放输入；断联 30 秒租约失效。
- Flutter 登录/邀请注册/设备目录/配对/登记设备/撤销设备/活动会话/撤销会话页面；Windows DPAPI、Android Keystore 存储会话令牌。
- 原生查看器支持 `--ticket/--nonce` 诊断。

### 审计修复

- 输入事件不再写入键码/按钮/坐标日志。
- 解码改为有界队列（帧/字节/像素/缓存上限）；溢出请求全量帧；新代际必须全量；核验 JPEG 实际尺寸；损坏首帧不显示成功。
- Host 下载取消真正停止读/发；取消/断开/撤权有终态。
- Host 上传无覆盖提交使用平台原子无覆盖语义，失败保留旧文件；所有失败出口清理临时文件。
- 客户端下载使用无覆盖原子提交，不再先删除目标；同名冲突自动选名。
- 响应式测试显式覆盖 Windows 1280×800 与 Android 360dp/1.3 字体，含 HomeShell、已连接工作区、传输中/失败状态。
- 服务端补齐 `Cargo.lock`、格式化、独立构建；UI 颜色迁移到 design tokens；文档/追踪表纠偏。

### WebUI 与会话状态

- 管理后台新增概览、所有设备、在线设备、当前会话、设备详情、网络能力、用户/邀请和审计页；数据来自真实 API，在线只由设备 agent 心跳证明。
- 会话状态区分 active/unknown/stale/revoking/ended，显示 Host 实例、票据/最终权限、请求/实际输入和真实路径；撤权先显示“请求已接受”，Host 上报结束才显示“已确认”。
- 修复 R1–R6：待用票据随用户/设备/分享撤权；跨设备 session 绑定；租约与清理；撤销设备后允许受限结束确认；Host 开始确认失败即关闭；登录 Argon2 移出数据库锁。

## 验证摘要

- Rust 28 项、Flutter 40 项、服务端 6 项测试通过；fmt/clippy/analyze 通过。
- 票据 API 闭环、真实 Host 出画、防重放、匿名拒绝、撤权时延均在本机实测，详见 `docs/evidence/b-auth-ticket-2026-10-18.md`。
- Windows 便携包解压启动、安装器安装/升级/卸载结果见 `build-manifest.json` 与 KNOWN-ISSUES；Android APK 签名与安装结果见清单。

## 产物

- Windows x64：per-user 安装器 + 便携 zip（未代码签名）。
- Android：arm64-v8a 与 universal 预览签名 APK（非正式发布密钥）。
- Linux x86_64：客户端 deb + 便携 tar.gz（WSL 构建/Xvfb 检查，未真实桌面验收）；服务端 tar.gz（systemd + 脚本 + Docker 定义）。
- `SHA256SUMS.txt`、`build-manifest.json`、安装/已知问题/第三方声明。

## 未包含

Android Host、质量/兼顾/流畅三模式、Sunshine/Moonlight、NAT/中继/E2EE、音频/剪贴板/手柄、MFA/恢复码、完整后台策略/备份、跨物理机/公网/2 小时/4 GiB 文件验收；Linux 实机与 Docker 未验证。
