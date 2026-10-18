# M4 控制服务端部署与验证记录

日期：2026-10-18。服务器：`192.168.9.66`（Ubuntu 24.04，1 核 / 1.9 GB / 根分区约 539 MB 可用）。部署对象：`yl-server 0.1.0`，仅监听 `127.0.0.1:18080`。

## 安全边界

- 未修改 nginx、防火墙、Docker 容器、Postgres/Redis/Casdoor 或 ikev2；ikev2 charon 仍在 UDP 500/4500 监听（部署后复核）。
- 服务只使用独立 `/opt/yuanlian` 目录、SQLite 数据文件和高位 TCP 18080；未做外网端口暴露。
- HTTP 仅 loopback；正式暴露前必须配置 TLS 反向代理。管理员密码不写入仓库或服务器脚本；仓库文档不保存密码。
- 服务器磁盘紧张，未安装 Rust/Docker 镜像；二进制约 4.2 MB。构建在 WSL Ubuntu 24.04 完成。

## 验证结果

| 测试 | 结果 |
|---|---|
| Rust 构建/Clippy | release 构建成功；`cargo clippy --release -- -D warnings` 通过 |
| 单元测试 | 3 项通过（Argon2 密码、指纹规范化、设备 ID 稳定性） |
| 服务启动 | systemd `active`；`GET /health` → `{"ok":true}` |
| 管理员初始化 | `/api/v1/setup` 200；`/api/v1/me` 返回 admin |
| 邀请码注册 | 创建邀请码 → 注册 smoke 用户 200 |
| 设备登记 | 200，返回设备 ID 与一次性设备令牌 |
| 心跳 | Owner Bearer 200；设备令牌 `X-Device-Token` 200；无认证 401 |
| 配对 | 创建 8 位一次性码 → 另一个用户 claim 200 |
| 连接信息 | 被授权用户 200，permissions 为 `["view","control"]` 数组 |
| 用户停用 | 200，会话撤销 |
| 管理后台 | `GET /admin` 200，包含“远联控制台” |
| 清理 | 测试设备/用户/邀请/授权/审计已从数据库删除；保留 admin |
| ikev2 复核 | charon 仍在 UDP 500/4500 运行，容器未变 |
| 现有服务 | 80/8443 nginx、8000 Casdoor、5432/6379/6400/19001 Docker 未改动 |

## 当前管理员

- 用户名：`admin`
- 密码：通过私密会话交付，不写入仓库；登录后在后台“账号安全”修改会撤销全部会话。

## 未验证/未完成

- Flutter 客户端登录/设备目录/配对 UI 未接入；配对后仍需在客户端手动使用 Host 地址+指纹。
- MFA、会话票据 Host 强制、策略/配置下发、备份恢复、HTTPS/域名、外网访问均未实现。
- 5 次失败限速只在单进程内存中，重启后归零；无多实例共享。
- SQLite 单机模式；未做并发压测和高可用。
