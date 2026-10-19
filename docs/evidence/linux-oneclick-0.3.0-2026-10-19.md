# Linux 控制服务端 0.3.0 一键安装验证（2026-10-19）

- 源码标签：`v0.3.0`，提交 `c1b7f6c`；协议 v3。
- 发布：GitHub `v0.3.0`，本 Release 只包含 Linux x86_64 控制服务端；Windows/Android/Linux 桌面客户端安装包仍为 0.2.0 / v2。
- 服务端包：`yl-server-0.3.0-linux-x86_64.tar.gz`，SHA-256 `2527ccc5916701fe0ae68862aefeca2baeb150babb5b2c921a9d7ae03176c0b2`（以 Release 附件 `SHA256SUMS.txt` 为准）。

## 构建与测试

- WSL Ubuntu 24.04，Rust 1.99.1；服务端 `cargo fmt`、release `clippy -D warnings`、12 项测试、release 构建通过。
- 根 Rust workspace 31 项测试、Flutter 73 项测试、`dart analyze` 0 issue 通过。
- 从发布包解包运行真实 Linux 二进制：
  - `YUANLIAN_BIND=127.0.0.1:18081 YUANLIAN_DB=<临时库> ./bin/yl-server`
  - `/health` 返回 `{"ok":true,"version":"0.3.0"}`。
  - `/api/v1/server/ticket-key` 返回 Ed25519 公钥。
  - 未安装 systemd 服务，未修改 `/opt/yuanlian` 或生产服务器。

## 公开一键安装校验

公开脚本：

```text
https://raw.githubusercontent.com/gameimpact/yuanlian/v0.3.0/install.sh
```

在 WSL Ubuntu 实际执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gameimpact/yuanlian/v0.3.0/install.sh) --check
```

输出确认：

```text
远联 YuanLian 0.3.0 — Linux 控制服务端
正在下载服务端发布包 v0.3.0…
服务端发布包下载、SHA-256、目录结构与安装脚本语法校验通过；未安装。
```

## 边界

- 只提供 x86_64；需要运行 systemd 的 Ubuntu/Debian 与 glibc。
- 未在 `192.168.9.66` 或其它生产机执行完整安装/升级；systemd 安装、备份恢复和 Docker 定义未实测。
- 0.2.0 桌面/Android 安装包不能与 0.3.0 服务端混装。
