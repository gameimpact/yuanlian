# 远联控制服务端 0.3.0（Linux x86_64）

本包为 0.3.0 控制服务端（协议 v3），提供账号、邀请注册、设备目录、一次性设备令牌、配对、Ed25519 会话票据、活动会话撤销、审计与 Web 后台。**它不是中继，不转发屏幕/输入/文件内容。**

## Linux 服务端一键安装（Ubuntu/Debian x86_64）

**安装角色：控制服务端（账号、设备、授权与 Web 管理后台）。** Linux 桌面客户端另有安装包；Linux 被控 Host 尚未实现。

在线一键安装（Linux 控制服务端）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gameimpact/yuanlian/v0.3.0/install.sh)
```

下载固定 v0.3.0 服务端包并校验发布清单 SHA-256，再安装并检查服务；需要时调用 sudo。已有部署会拒绝覆盖，请先备份并手动升级。命令末尾加 `--check` 可只下载并校验，不安装。v0.3.0 Release 目前只提供 Linux 控制服务端；桌面客户端安装包仍为 v0.2.0。

离线安装：将可信来源的 `yl-server-0.3.0-linux-x86_64.tar.gz` 放到当前目录后，执行一行命令：

```bash
tar -xzf yl-server-0.3.0-linux-x86_64.tar.gz && sudo bash ./yl-server-0.3.0-linux-x86_64/scripts/install.sh
```

需要运行 systemd 的 Ubuntu/Debian x86_64、glibc 与 sudo/root 权限；无需安装 Rust、Flutter 或 Docker。

也可分步执行：

```bash
tar xzf yl-server-0.3.0-linux-x86_64.tar.gz
cd yl-server-0.3.0-linux-x86_64
sudo bash ./scripts/install.sh
curl http://127.0.0.1:18080/health
```

`install.sh` 创建系统用户 `yuanlian`、安装到 `/opt/yuanlian`、数据目录 `/var/lib/yuanlian`、配置 `/etc/yuanlian/server.env`，安装并启动 systemd 单元。服务默认只监听 `127.0.0.1:18080`。

首次初始化只允许 loopback：通过 SSH 隧道访问 `http://127.0.0.1:18080/admin`，或在本机执行：

```bash
curl -X POST http://127.0.0.1:18080/api/v1/setup \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"<强密码>","server_name":"YuanLian"}'
```

密码只在私密渠道交付；不要写进仓库、脚本或日志。

## TLS 与暴露

必须在前面配置 TLS 反向代理（nginx/Caddy），只代理到 `127.0.0.1:18080`。没有 TLS 时不要绑定 `0.0.0.0` 或暴露公网。

## 票据与撤权

- `GET /api/v1/server/ticket-key`：Host 启动时拉取 Ed25519 公钥。
- `POST /api/v1/devices/{id}/session-ticket`：登录用户为一次连接申请 1 小时票据（绑定 nonce）。
- `POST /api/v1/devices/{id}/sessions`：Host 用设备令牌上报活动会话。
- `POST /api/v1/devices/{id}/sessions/revoke`：Owner/管理员撤销全部或单个会话；Host 每秒心跳，实测 ≤2 秒停止。
- 轮换票据密钥：`/etc/yuanlian/server.env` 临时设 `YUANLIAN_ROTATE_TICKET_KEY=1`，重启一次后移除。旧票据在过期前仍可验证；需要立即失效请用撤权。
- 私钥存储在 SQLite `ticket_keys` 表；请保护数据库备份（`backup.sh` 使用 0600）。

## 备份与恢复

```bash
sudo ./backup.sh /var/backups/yuanlian-$(date +%F-%H%M%S).db
sudo ./restore.sh /var/backups/yuanlian-....db
```

有 `sqlite3` 时使用 `.backup` 在线备份；否则脚本短暂停止服务做一致性复制并自动启动。恢复脚本会保留恢复前的数据库副本并做健康检查。

## Docker Compose（未在本机验证）

`docker/Dockerfile` 与 `docker/docker-compose.yml` 从仓库根构建镜像，端口只映射到 `127.0.0.1:18080`，数据放命名卷。当前开发机没有 Docker，因此本包未实际构建/运行 compose；不要把它当作已验证产物。

## WebUI 与会话状态

- `/admin` 提供概览、所有设备、在线设备、当前会话、设备详情、用户/邀请、审计和网络状态页；使用 1–2 秒受控轮询。
- 在线只由设备令牌 agent 心跳证明；会话状态区分 active/unknown/stale/revoking/ended，Host 开始确认后才显示 active。
- 待用票据、活动会话和分享授权可分别撤销；撤销后有效设备令牌仍可确认自己的会话结束。
- **P2P/ICE/STUN/TURN/中继未实现。** 网络页显示真实 `p2p=false, turn=false`，不提供假测试按钮。跨 NAT、TURN 和媒体 E2EE 需要独立环境与依赖锁定。

## 迁移

数据库 schema 由服务启动时 `CREATE TABLE IF NOT EXISTS` 建立；0.2.0 新增 `ticket_keys` 与 `active_sessions` 表，对 0.1.0 数据库向后兼容。升级前请先备份；旧数据库会保留原有账号/设备/配对，新票据密钥自动生成。

## 验证

```bash
curl http://127.0.0.1:18080/health
curl http://127.0.0.1:18080/api/v1/server/info
curl http://127.0.0.1:18080/api/v1/server/ticket-key
systemctl status yuanlian-server.service
```

二进制为 Linux x86_64，动态依赖 glibc；如目标系统过旧，请在相同发行版重新构建。
