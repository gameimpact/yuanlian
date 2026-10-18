# 远联控制服务（yl-server）

状态：开发版，已部署到内网服务器 `192.168.9.66`，仅监听 `127.0.0.1:18080`。提供账号、邀请码注册、登录会话、设备目录、设备令牌、配对码/授权、审计和 Web 管理后台。**不是中继，不转发屏幕/输入/文件内容。**

## 当前部署

- 服务器：Ubuntu 24.04，1 核 / 1.9 GB 内存；根分区剩余空间很小，因此不安装 Rust、不新增 Docker 镜像。
- 二进制：`/opt/yuanlian/yl-server`（约 4.2 MB，静态依赖 SQLite）。
- 数据：`/opt/yuanlian/data/yuanlian.db`（SQLite WAL）。
- systemd：`yuanlian-server.service`，仅绑定 loopback。
- 管理后台：`http://127.0.0.1:18080/admin`。通过 SSH 隧道访问：
  ```bash
  ssh -L 18080:127.0.0.1:18080 root@192.168.9.66
  # 浏览器打开 http://127.0.0.1:18080/admin
  ```
- 初始管理员用户名：`admin`。密码只通过当面/私密渠道交付，不在仓库或日志中保存；登录后可在“账号安全”中修改，修改会撤销全部会话。

**尚未修改** nginx、防火墙、Docker 容器或 ikev2（charon UDP 500/4500）。在没有 TLS 反向代理前不要把 18080 暴露到外网；当前服务只提供 HTTP。

## 功能与 API

| 方法/路径 | 权限 | 说明 |
|---|---|---|
| `GET /health` | 公开 | 数据库健康、版本 |
| `GET /api/v1/server/info` | 公开 | 名称、版本、是否初始化、能力 |
| `POST /api/v1/setup` | 仅 loopback，未初始化 | 创建首个管理员 |
| `POST /api/v1/auth/login` | 公开 | 用户名密码 → Bearer 会话 |
| `POST /api/v1/auth/logout` | 登录 | 撤销当前会话 |
| `POST /api/v1/auth/refresh` | 登录 | 轮换会话令牌 |
| `POST /api/v1/auth/password` | 登录 | 修改密码并撤销全部会话 |
| `POST /api/v1/auth/register` | 邀请码 | 邀请码注册 |
| `GET /api/v1/me` | 登录 | 当前用户 |
| `POST /api/v1/invites` | 管理员 | 创建邀请码 |
| `GET /api/v1/users` | 管理员 | 用户列表（无密码） |
| `POST /api/v1/users/{id}/status` | 管理员 | 停用/恢复用户并撤销会话 |
| `GET /api/v1/devices` | 登录 | 自己拥有或被分享的设备 |
| `POST /api/v1/devices` | 登录 | 登记/更新设备，返回一次性设备令牌 |
| `POST /api/v1/devices/{id}/heartbeat` | Owner/管理员或设备令牌 | 更新在线时间 |
| `POST /api/v1/devices/{id}/revoke` | Owner/管理员 | 撤销设备授权 |
| `GET /api/v1/devices/{id}/connect-info` | Owner/被授权者 | 返回地址与 TLS 指纹 |
| `POST /api/v1/devices/{id}/pairing-code` | Owner/管理员 | 生成 10 分钟一次性配对码 |
| `POST /api/v1/pairing/claim` | 登录 | 使用配对码获得 7 天 view/control 授权 |
| `GET /api/v1/devices/{id}/grants` | Owner/管理员 | 查看分享授权 |
| `GET /api/v1/audit` | 管理员 | 最近 200 条审计 |
| `GET /admin` | 浏览器 | 管理后台 |

- 密码使用 Argon2id；会话令牌只保存 SHA-256 摘要；登录失败有简单限速（5 次/60 秒窗口）。
- 设备令牌只返回一次，服务端只存摘要；Host 代理后续用 `X-Device-Token` 心跳。
- 审计不保存密码、令牌、按键、剪贴板或文件内容。

## 构建与部署

在 WSL/Ubuntu 构建（服务器无 Rust 工具链）：

```bash
cd server
cargo fmt
cargo clippy --release -- -D warnings
cargo test --release
cargo build --release
```

上传 `target/release/yl-server` 到 `/opt/yuanlian/yl-server`，使用
`server/deploy/yuanlian-server.service` 安装 systemd 单元。默认绑定 loopback；
不要在没有 TLS 的情况下改成 `0.0.0.0`。

## 未完成

- Flutter 客户端登录/设备目录/配对 UI 尚未接入；当前通过 API 或后台登记设备。
- 没有 MFA/TOTP、会话票据的 Host 端强制、策略下发/回滚、中继/穿透、备份恢复。
- 配对授权目前是目录级授权，Host/Viewer 仍按 TLS 指纹直连；Host 尚未验证服务端票据。
- 管理后台是单页开发版；无 CSRF 表单（Bearer token 在 sessionStorage，不使用 Cookie）。
- 尚未配置 HTTPS/域名；暴露前必须加反向代理与证书。
