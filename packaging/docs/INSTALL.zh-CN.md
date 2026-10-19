# 远联 0.2.0 安装与验证

> 这是开发预览版，不是完整产品。Windows 安装器未做代码签名；Android APK 使用独立预览签名；Linux 客户端已构建 deb/便携包，但只做了 WSL 构建与 Xvfb 启动检查，未在真实 Linux 桌面安装验收。

## Windows x64

### 安装器

1. 双击 `YuanLian-0.2.0-windows-x64-setup.exe`。
2. 按当前用户安装到 `%LOCALAPPDATA%\Programs\YuanLian`，不需要管理员权限。
3. 组件：主控客户端必需；被控 Host/诊断查看器、文档、开始菜单、登录启动可选。登录启动默认不勾选。
4. 安装器不启动 Host、不开放防火墙、不配置无人值守。
5. 升级：再次运行新版本安装器覆盖同一目录；设备身份/登录凭据保存在 `%LOCALAPPDATA%\YuanLian`，不会被安装器清空。
6. 卸载：开始菜单“卸载远联”，或设置→应用。卸载会删除程序文件；是否删除设备身份/登录令牌/配置由卸载对话框明确选择，默认保留。

### 便携包

解压 `YuanLian-0.2.0-windows-x64-portable.zip` 到任意可写目录（支持空格/中文路径），运行 `client\yuanlian_client.exe`；Host/Viewer 在 `bin\`。不需要源码目录或开发工具。

### Host 配置（票据模式）

1. 在控制服务端 Web/客户端登录，登记设备：填写 `bin\yl-host.exe --print-identity` 打印的指纹和监听地址。
2. 客户端只显示一次设备令牌；通过本机安全方式交给 Host（推荐环境变量，避免 shell 历史）：
   ```powershell
   $env:YUANLIAN_DEVICE_TOKEN = "<令牌>"
   .\bin\yl-host.exe --listen 0.0.0.0:24800 --server-url http://<服务端>:18080 `
     --allow-input --file-root "C:\授权目录"
   ```
3. Host 会拉取票据公钥、校验设备注册、在每次连接时弹本机确认框。默认只查看；`--allow-input` 才允许键鼠；`--file-root` 才允许文件；`--file-read-only` 只允许读取。
4. 控制面必须可访问；默认心跳 1 秒，断联 30 秒后会话租约失效。生产环境应在服务端前加 TLS 反向代理。

开发期匿名直连（仅隔离测试）：

```powershell
.\bin\yl-host.exe --listen 127.0.0.1:24800 --allow-anonymous --auto-approve --allow-input
```

未显式 `--allow-anonymous` 时，无票据连接会被拒绝。`--auto-approve` 会跳过本机授权对话框并打印告警，不得用于普通用户环境。

## Android arm64

- 文件：`YuanLian-0.2.0-arm64-v8a-preview.apk`，arm64-v8a，minSdk 24。
- 签名：CN=YuanLian Preview，**预览签名，不是正式发布密钥**。正式升级链需要用户自己的密钥；不要把它当作正式签名。
- 安装：允许未知来源后安装；首次启动授予网络权限。账号登录需要服务端地址（模拟器访问宿主机用 `http://10.0.2.2:18080`；真机用局域网/HTTPS 地址）。
- 升级：同签名 APK 可直接覆盖安装并保留数据；签名变化不能静默卸载清数据。
- 未实现/未验收：双指捏合实机手势、完整 IME、SAF 文件选择器、实体触控、后台长期会话、Android Host。

## Linux 客户端 x86_64

- `yuanlian-client_0.2.0_amd64.deb`：`sudo dpkg -i` 安装；依赖 GTK3/Wayland/EGL；提供 `/usr/bin/yuanlian` 和桌面项。卸载 `sudo dpkg -r yuanlian-client`。
- `YuanLian-0.2.0-linux-x86_64-portable.tar.gz`：解压后运行 `yuanlian`。
- 本轮只在 WSL 构建、`ldd` 检查与 Xvfb 启动到 Flutter Impeller；没有真实 Linux 桌面/显示服务验证，不能标记 Linux 实机通过。

## Linux 服务端 x86_64

**这是控制服务端**，提供账号、设备、授权与 Web 管理后台。适用于运行 systemd 的 Ubuntu/Debian x86_64；Linux 桌面客户端另行安装，Linux 被控 Host 尚未实现。

在线一键安装（Linux 控制服务端）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gameimpact/yuanlian/main/install.sh)
```

脚本下载 v0.2.0 服务端包、校验 SHA-256、安装并检查服务。加 `--check` 可只下载校验；已有部署请先备份并手动升级。

离线安装：将 `server-linux-x86_64/yl-server-0.2.0-linux-x86_64.tar.gz` 复制到 Linux 当前目录，一键解压并安装：

```bash
tar -xzf yl-server-0.2.0-linux-x86_64.tar.gz && sudo bash ./yl-server-0.2.0-linux-x86_64/scripts/install.sh
```

无需安装 Rust/Flutter/Docker。脚本创建 `yuanlian` 用户、复制二进制与 systemd 单元、设置 `YUANLIAN_DB`/`YUANLIAN_BIND`。默认只监听 `127.0.0.1:18080`；通过 SSH 隧道访问 `/admin`，对外访问必须配置 TLS 反向代理。执行 `curl --fail http://127.0.0.1:18080/health` 验证服务。

## 最小验证

1. Windows：启动客户端 → 账号登录 → 设备列表出现 Host → 连接 → Host 本机确认 → 画面出图 → 断开；中心撤销后 ≤2 秒断开。
2. Android：安装后启动无崩溃；登录/设备页可打开；有可用 Host 时尝试连接并记录结果。
3. 服务端：`curl http://127.0.0.1:18080/health` 返回 `{"ok":true,...}`；`/api/v1/server/ticket-key` 返回公钥。
4. 不要用源码目录运行 `flutter`/`cargo` 作为安装验证。
