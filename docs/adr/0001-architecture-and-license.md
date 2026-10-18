# ADR-0001：架构基线与许可证策略

- 状态：已接受（2026-10-18）
- 决策者：项目组
- 关联：`docs/roadmap.md`、`docs/protocol.md`

## 背景

需求要求 Windows/Linux/Android 主控、Windows/Linux/Android（有人值守）被控、三种画面模式、账号/设备/授权服务、NAT 穿透与中继、Web 管理后台。质量模式明确基于 Moonlight + Sunshine；兼顾/流畅模式要求自研非连续视频图块通道。候选路径：

1. 直接 fork RustDesk，在现有 Flutter/Rust 工程上改造；
2. 独立产品，集成成熟上游模块（Sunshine、moonlight-common-c）并自研会话/授权/图块引擎。

## 决策

**选择 2：独立产品，Rust 核心 + Flutter 产品 UI，按阶段集成上游模块。**

理由：

- 三种模式的引擎边界、唯一输入注入路径、会话代际、权限撤销必须由本产品统一控制；RustDesk 的现有编解码与中继模型不能直接满足“非视频图块模式”和受控 Sunshine 生命周期。
- RustDesk 代码库体量大且为 AGPL，fork 后长期合并上游成本高。参考其模块划分与 Flutter/Rust 集成方式，但不把其代码作为基线。
- Sunshine 以独立受控进程/适配层集成，锁定版本并维护补丁；moonlight-common-c 仅作为质量模式协议核心，严格锁定其定制 ENet 子模块。
- 服务端独立实现，避免把 hbbr/hbbs 或 TURN 误当作能转发全部 Moonlight 通道的中继。

前端：Flutter 共享 Windows/Linux/Android 产品 UI；Rust 核心通过稳定 FFI 暴露能力、会话、输入、文件与诊断接口。画面不走“逐帧复制为 Dart 大对象”，使用原生纹理/GPU 路径（Flutter 端通过 platform texture 或 FFI 纹理注册；M0 先用原生查看器验证引擎）。

传输：M0 使用 TCP + TLS 1.3 验证端到端加密与指纹固定；正式版本增加 QUIC 可靠流/数据报，禁 UDP 环境回退 TLS。控制面 API 使用 HTTPS；中继仅转发密文会话数据。会话票据绑定主控/Host/权限/模式/过期时间并防重放。

服务端：Rust 异步服务，PostgreSQL 为默认数据库；提供单机 SQLite 演示模式并明确并发限制。管理后台 TypeScript Web 应用。

## 许可证

项目整体采用 **AGPL-3.0-or-later**。原因：

- 后续将链接/集成 Sunshine（GPL-3.0）与 moonlight-common-c（GPL-3.0）；AGPL 与 GPLv3 兼容。
- 若参考或复用 RustDesk（AGPL-3.0）代码，AGPL 保持合规。
- 所有上游版本、许可证、NOTICE、源码获取方式与修改记录进入 `THIRD_PARTY.md` 与发布材料；不删除上游声明。
- 闭源商业发行需单独法律评估与上游商业许可，不得默认假设可行。
- 进程隔离不自动消除许可证义务；对 Sunshine 的修改与分发同样提供源码。

## 后果

- 需要自行实现会话、权限、图块协议与服务端，短期工作量大于 fork；换来三模式与授权的可控性。
- Flutter 与 Rust 的 FFI/纹理桥是后续关键风险，需在阶段 1 早期做技术验证。
- M0 原生查看器只作为引擎验证工具，不是最终产品界面；不得把它冒充交付 UI。
