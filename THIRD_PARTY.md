# 第三方组件与许可证清单（M0）

本清单覆盖当前仓库实际构建进 Windows 二进制的直接依赖与主要传递依赖。发布前必须用构建产物做完整 SBOM/许可证文本核对，并补充所有 NOTICE 与源码获取方式。项目自身采用 AGPL-3.0-or-later。

## 直接依赖

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| xcap | 0.9.8 | Apache-2.0 | Windows GDI 屏幕采集（M0） |
| minifb | 0.29.0 | MIT | 原生测试查看器窗口 |
| image | 0.25.10 | MIT OR Apache-2.0 | JPEG 编解码、截图保存 |
| jpeg-encoder | 0.7.1（未使用，可移除） | MIT | 曾评估，当前由 image 编码 |
| blake3 | 1.8.7 | CC0-1.0 OR Apache-2.0 | 图块哈希 |
| xxhash-rust | 0.8.19 | BSL-1.0 | 依赖声明；当前实现使用 blake3 |
| rustls | 0.23.46 | Apache-2.0 OR ISC OR MIT | TLS |
| tokio-rustls | 0.26.6 | MIT OR Apache-2.0 | Tokio TLS 适配 |
| rcgen | 0.13.2 | MIT OR Apache-2.0 | 自签名开发证书 |
| ring | 0.17.14 | Apache-2.0 AND ISC | TLS 密码学 |
| aws-lc-rs | 1.18.2 | ISC AND (Apache-2.0 OR ISC) | rustls 默认特性带入的密码学后端（可切换为仅 ring） |
| tokio | 1.53.3 | MIT | 异步运行时/网络 |
| windows | 0.62.2 | MIT OR Apache-2.0 | SendInput、DPI、光标 API |
| clap | 4.6.7 | MIT OR Apache-2.0 | CLI |
| tracing / tracing-subscriber | 0.1.44 / 0.3.23 | MIT | 日志 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 | 错误上下文 |
| serde | 1.0.229 | MIT OR Apache-2.0 | 协议序列化 |
| bincode | 1.3.3 | MIT | 协议帧序列化 |
| sha2 | 0.11.1 | MIT OR Apache-2.0 | 指纹 |
| hex | 0.4.3 | MIT OR Apache-2.0 | 指纹显示/解析 |
| zune-jpeg（传递） | 0.5.15 | MIT OR Apache-2.0 OR Zlib | JPEG 解码 |
| miniz_oxide（传递） | 0.8/0.9 | MIT OR Zlib OR Apache-2.0 | PNG/zlib |

## 控制服务端（server/）

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| axum | 0.8 | MIT | HTTP API |
| tokio | 1.x | MIT | 异步运行时 |
| rusqlite | 0.37 (bundled SQLite) | MIT / SQLite 公有领域 | 单机数据库 |
| argon2 | 0.5 | MIT OR Apache-2.0 | Argon2id 密码哈希 |
| rand / sha2 / hex | 0.8 / 0.10 / 0.4 | MIT OR Apache-2.0 | 令牌、摘要 |
| serde / serde_json | 1.x | MIT OR Apache-2.0 | API 序列化 |
| tracing | 0.1 | MIT | 日志 |

## 尚未集成但已确定方向

| 组件 | 许可证 | 计划 |
|---|---|---|
| Sunshine | GPL-3.0 | 质量模式 Host，锁定版本/子模块，独立进程适配，提供源码与修改 |
| moonlight-common-c | GPL-3.0 | 质量模式协议核心，锁定定制 ENet，不替换系统库 |
| RustDesk（仅参考） | AGPL-3.0 | 不 fork；参考模块划分与 Flutter/Rust 交互 |

## 分发要求

1. 发布包内附本清单、AGPL 许可证全文、上游 NOTICE 与对应源码/获取方式。
2. 不删除上游版权声明；修改 Sunshine/moonlight-common-c 时提供补丁与构建脚本。
3. 进程隔离不自动消除 GPL/AGPL 义务；闭源商业发行需单独法律评估。
4. M0 的 `aws-lc-rs` 由 rustls/tokio-rustls 默认特性引入，正式版本将改为仅 `ring` 或明确保留并纳入声明。
