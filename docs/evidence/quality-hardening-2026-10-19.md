# 质量串流预览加固证据（2026-10-19）

本轮按质量审查建议修改 Windows 外部 Moonlight 预览。质量模式使用视频串流；仍不是正式质量模式，不扩大 DS 既有同机串流性能证据。没有更新生产服务器或发布安装包。

## 实现

| 项目 | 实现与边界 |
|---|---|
| 异常退出清理 | `client/windows/runner/quality_process.{h,cpp}`、`quality_native_process.dart`：创建子进程时通过 `PROC_THREAD_ATTRIBUTE_JOB_LIST` 原子加入独立、不可继承的 kill-on-close Job，再恢复执行。仅管理本次持有的进程；远联异常结束时 OS 清理子进程。不结束其他 Moonlight、Sunshine 或远端应用，不能替代 Host 撤权。原生桥不可用时拒绝启动。 |
| 有界输出与生命周期 | 串流/配对输出丢弃；只有只读应用查询允许捕获，stdout 上限 64 KiB，stderr 持续丢弃。限制继承句柄、过滤敏感/加载器相关环境变量。查询超时、取消及停止均等待退出；修复停止与自然退出竞态。 |
| 组件完整性 | `quality_integrity.dart` 使用客户端内置 `assets/quality/moonlight-6.2.0.json`，校验固定官方包的 284 个文件、大小和 SHA-256，拒绝额外文件、链接及目录越界。清单由固定 zip 摘要生成，不信任组件旁可修改的 SHA256SUMS。明确允许的 Moonlight 配对配置/日志只按文件名排除，不读取内容。此校验不证明硬解能力，也不能阻止同用户进程在校验之后替换文件。 |
| 真实应用列表 | `quality_apps.dart` 调用固定版 Moonlight `list --csv`，严格解析真实 CSV；12 秒超时、取消、最多 256 应用及输出上限。质量页提供查询/取消/选择及手动应用名称。配对仍在上游 GUI，未收集 PIN，不显示原始输出。没有实际已配对 Host 查询 E2E。 |
| 安全打包 | `packaging/quality/build-quality-preview.ps1` 在输出目录创建唯一 staging，校验固定包及 284 文件清单后生成 zip，以不覆盖方式发布；拒绝已有最终包。只清理确认过边界且无 reparse 的私有 staging，保留已有运行目录及配置。新增清单生成脚本。 |
| 控制面模式拒绝 | `server/src/main.rs` 的票据请求可带 `mode`（兼容 `engine` 别名，省略默认 `tiles`）；非 tiles 返回 HTTP 409 / `unsupported_mode`，不会签出票据。能力 API 明确质量未支持及 `host_authorization_bridge_missing`。客户端显式申请 tiles。没有因此实现 Sunshine broker 或中心撤权。 |

## 本轮实际验证

- Windows 11；Dart analyze 无问题；Flutter 全套 **69 passed**，含 1280×800 与 360dp/1.3 响应式、完整性破坏/额外文件、CSV、超时取消、原生通道及进程竞态。
- `scripts/test-quality-native.ps1`：生产 C++ helper 编译 `/W4 /WX` 通过；真实子进程参数/Unicode/引号、双输出背压、输出超限、退出码 259、合成敏感环境变量过滤均通过。真实强制终止父进程，确认私有 Job 中的子进程退出；外层 Job 仍持有，排除由测试外壳退出造成的假通过。
- `scripts/test-quality-package.ps1`：真实打包通过；合成旧运行配置保留；重复最终包拒绝覆盖且原包不变；包内清单及 staging 清理通过。未覆盖用户既有发布包。
- WSL Ubuntu 24.04 独立 server：fmt、release locked offline clippy（`-D warnings`）、test **12 passed**、build 通过。
- WSL 隔离临时 SQLite / 随机 loopback 服务：真实 setup/login/register 后，quality/moonlight/file_only 申请全部 409，数据库票据数保持 0；旧请求与显式 tiles 为 200；能力字段质量 false。未连接生产机。
- ASCII 副本 `C:\Users\Lenovo\dev\yuanlian-client-build` 的 Windows release 构建通过，包含最新 Dart、资源及原生 runner。实际打开首页及质量页，截图正常，质量串流、安全边界和新增入口可见。未以界面渲染代替串流 E2E。

## 尚不能交付的部分与原因

1. **正式质量授权与中心撤权**：固定上游 Sunshine 接受自己的配对证书，没有远联票据、权限交集、租约及防旁路 broker；简单 kill 本地 Moonlight 不阻止已有配对凭据重连。必须实现 Host 适配并实测只读/输入限制、撤权及旁路拒绝。当前保持预览，并拒签质量票据。
2. **真实协商/首帧/硬解/加密状态及 Flutter 内嵌**：当前只有 CLI 和进程状态，无可信事件接口、原生 Surface/Texture 或切换状态机，不能从 PID/请求参数猜测成功。需要上游核心集成与端到端验收。
3. **Android/Linux 质量主控**：本轮新增桥是 Windows Job API；Android 需独立解码/Surface/生命周期实现及 MuMu 多版本矩阵、真机硬解/触控；Linux 需真实 X11/Wayland 环境。没有在本轮下载 MuMu 或宣称多 Android 适配完成。
4. **性能与分发**：未重跑两物理机、10 分钟 1080p60、4K/HDR/音频、弱网/跨 NAT/两小时；兼顾档仍需实际动态呈现至少 30 fps、60 档专项。未完成对应源码材料完整复现、正式签名及新安装包/Release 对齐。

上游依据：[Moonlight 6.2.0 应用列表](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/cli/listapps.cpp)、[固定 Sunshine 授权路径](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src/nvhttp.cpp)、[Windows 进程创建属性](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute)。
