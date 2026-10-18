# 阶段 B 证据：票据、Host 二次校验与撤权（2026-10-18）

版本：0.2.0，协议 v2。环境：Windows 11 26H2（build 26300）、Flutter 3.47.7/Dart 3.13.5、Rust 1.99.1；控制服务端在 WSL Ubuntu 24.04 本机构建并监听 `127.0.0.1:18080`（隔离测试库 `/tmp/yl-b-test.db`），未操作 `192.168.9.66` 或任何生产服务。

## 1. 自动化检查

| 检查 | 结果 |
|---|---|
| 根 Rust `cargo fmt --all -- --check` | 通过 |
| 根 Rust `cargo clippy --workspace --all-targets --locked` | 通过，0 warning |
| 根 Rust `cargo test --workspace --locked` | 28 passed（Host 15、proto 7、tiles 5、viewer 1） |
| 服务端 WSL `cargo fmt -- --check` / `clippy --release --locked -- -D warnings` | 通过 |
| 服务端 WSL `cargo test --release --locked` | 6 passed |
| Flutter `dart analyze lib test` | No issues found |
| Flutter `flutter test --no-pub` | 40 passed |
| Android release 构建 | 成功；17.7 MB；arm64-v8a；minSdk 24；target 36 |
| APK `apksigner verify --print-certs` | 通过；`CN=YuanLian Preview`，SHA-256 `e95efd39…09512`；**预览签名，非正式发布密钥** |

## 2. 持久身份

命令：

```powershell
target\release\yl-host.exe --print-identity --identity-dir artifacts/e2e-identity
```

输出（两次一致）：

```
远联 Host 设备 ID: yl-679d7561a6e2d8f6
TLS SHA-256 指纹: 7F2477944060AC23C27BD064AD6DCB041C4BA638D73A8091E07629A87AC8B697
```

单元测试 `tls::tests::identity_is_stable_across_restarts` 与 `incomplete_identity_is_reported_not_regenerated` 通过。

## 3. 服务端 API 闭环

Node 脚本（测试临时文件，未入库）调用：

```
POST /api/v1/setup                         200
POST /api/v1/devices                       200  -> device_id yl-679d7561a6e2d8f6
GET  /api/v1/server/ticket-key             200  -> kid 28312bf2b4a5cce0
POST /api/v1/devices/{id}/session-ticket   200  -> ticket/session_id/permissions 31
POST /api/v1/devices/{id}/heartbeat        200  -> owner_active=true, revoked_sessions=[]
POST /api/v1/devices/{id}/sessions         200  -> 上报 session
GET  /api/v1/devices/{id}/sessions         200  -> 活动会话列表
POST /api/v1/devices/{id}/sessions/revoke  200  -> revoked=1
POST /api/v1/devices/{id}/heartbeat        200  -> revoked_sessions=[session]
```

票据 claims（base64 解码）：

```json
{"v":1,"kid":"28312bf2b4a5cce0","aud":"yl-679d7561a6e2d8f6","sub":1,"user":"admin",
 "jti":"af129254e12514f0259d43b82b2c61e2","purpose":"remote_session",
 "nonce_sha256":"3985dac9…bde2c","permissions":31,"iat":1792326663,"exp":1792330263}
```

## 4. 原生查看器票据连接

Host 启动（本机测试，显式自动确认）：

```
yl-host --listen 127.0.0.1:24900 --server-url http://127.0.0.1:18080 \
  --device-token <一次性令牌> --allow-input --file-root artifacts/e2e-files \
  --auto-approve --identity-dir artifacts/e2e-identity
```

查看器：

```
yl-viewer --connect 127.0.0.1:24900 --fingerprint 7F2477…B697 \
  --ticket "<session-ticket>" --nonce "<64 hex>"
```

输出与 Host 日志：

```
已连接 LENOVO（Host ID yl-679d7561a6e2d8f6），屏幕 3200x2000，模式 tiles，
授权：账号 admin / ticket，输入：允许
viewer session established authenticated=true account="admin"
permissions=查看、控制、读取文件、写入文件 input_allowed=true file_read=true file_write=true
```

截图：`artifacts/e2e-viewer.png`（真实桌面 + 递归查看器窗口）。

## 5. 撤权时延

| 事件 | 时间 |
|---|---|
| API 撤销返回 | 2026-10-18T12:39:45.617Z |
| Host 结束会话 / 查看器断开 | 2026-10-18T12:39:46.788Z |
| 差值 | **1.171 s** |

Host 向查看器发送 `Error(Revoked, 授权已被账号、设备或管理员撤销)` 与 `Bye`；查看器日志记录 `Host reported an error code=Revoked`，随后断开。第二次 Flutter 会话撤销：

| API 撤销 | Host 结束 |
|---|---|
| 12:45:05.133Z | 12:45:05.991Z |
| 差值 | **0.858 s** |

最终 0.2.0 产物回归（Flutter 0.2.0 + Host 0.2.0）：

| API 撤销 | Host 结束 |
|---|---|
| 13:21:58.693Z | 13:21:59.296Z |
| 差值 | **0.603 s** |

Flutter 截图 `artifacts/e2e-flutter-final-revoked.png` 显示“连接中断 / 授权已被账号、设备或管理员撤销”。

## 6. 防重放与匿名拒绝

- 已用票据再次连接：`Error: Host rejected the connection [TicketReplay]: 会话票据已被使用（防重放拒绝）`。
- 票据模式 Host + 无票据：`[Unauthorized]: 需要账号/配对签发的会话票据；Host 未允许匿名直连`。

### 匿名开发直连回归

显式 `--allow-anonymous --auto-approve` 启动 Host（无服务端），原生查看器无票据连接：

```
authenticated=false account="-" permissions=查看、控制 input_allowed=true
file_read=false file_write=false
窗口：远联 | LENOVO | 3200x2000 | 10 fps | 可控制 | TLS 已固定
```

说明显式匿名开发路径仍可用；未加 `--allow-anonymous` 时同一连接被拒绝。

## 7. Flutter 票据连接

Flutter Windows release（0.2.0）使用诊断参数 `--auto-connect-ticket/--auto-connect-nonce` 连接同一 Host；Host 日志：

```
client=YuanLian Flutter authenticated=true account="admin"
permissions=查看、控制、读取文件、写入文件 width=3200 height=2000
```

截图 `artifacts/e2e-flutter.png`：真实远端桌面、工具栏“图块模式/可控制”。这不是账号 UI 点击登录的 E2E；账号页由 HTTP mock + 组件测试覆盖，真实点击登录待补。

## 8. 未覆盖/限制

- 本机 MessageBox 人工点击未自动化；E2E 使用 `--auto-approve`（启动日志有告警）。
- 未做跨物理机、公网、网络分区 30 s 租约、时钟偏差、密钥轮换在线验证。
- Flutter 服务端会话令牌写入 DPAPI/Keystore 的代码已实现，但未在真实登录流程中读取验证。
- 未更新 `192.168.9.66` 的已部署服务端；本地服务端与仓库 0.2.0 一致。
- 截图/日志在 `artifacts/`，不提交仓库；本文件只记录可复核的时间、字段与结果。
