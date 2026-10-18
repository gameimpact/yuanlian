# 0.2.0 打包与安装验证证据（2026-10-18）

产物目录：`dist/0.2.0/`。最终哈希、大小与签名状态以 `build-manifest.json` / `SHA256SUMS.txt` 为准。构建时工作区有未提交改动（revision `9d473aa` + dirty）。

## Windows x64

| 检查 | 结果 |
|---|---|
| NSIS 安装器构建 | 成功；约 11.5 MB；`RequestExecutionLevel user`；开始菜单/卸载项/可选 Host/可选登录启动 |
| 静默安装 `/S /D=...\YuanLianTest` | 成功；客户端、Host、Viewer、文档、卸载器齐全 |
| 覆盖升级（第二次安装） | 成功；`%APPDATA%\YuanLian` 标记文件保留 |
| 安装目录启动客户端 | 成功；窗口标题“远联 YuanLian” |
| 静默卸载 | 成功；程序目录与卸载注册项删除；用户数据默认保留 |
| 便携 zip 解压到 `C:\Users\Lenovo\dev\远联 便携 测试` | 成功；含空格/中文路径；客户端启动成功 |
| Authenticode | `NotSigned`（无证书） |
| 最终票据连接 | 用 ASCII 构建的同一源码 Flutter 0.2.0 连接 Host 0.2.0，账号 admin/权限 31，真实出画 |
| 最终撤权 | 0.603 s 内 Host 结束会话；Flutter 显示“授权已被…撤销” |

说明：安装器内的客户端没有单独发起票据连接（连接 E2E 使用同一 Release 构建），故 manifest 将 `remote_connect_from_installer` 标为 `not_run`。

## Android

| 检查 | 结果 |
|---|---|
| arm64-v8a release APK | 17.7 MB；minSdk 24；target 36；`apksigner` 通过；`CN=YuanLian Preview` |
| universal release APK | 51.0 MB；arm64-v8a/armeabi-v7a/x86_64；同签名 |
| arm64 APK 安装到 x86_64 模拟器 | 预期失败 `INSTALL_FAILED_NO_MATCHING_ABIS` |
| universal APK 安装到 x86_64 模拟器 | 成功 |
| 启动/首屏 | 成功；无 FATAL；截图 `artifacts/android-release.png` |
| 账号页 | 打开成功；截图 `artifacts/android-account.png`；显示地址/登录/邀请注册 |
| 真实登录 E2E | 未完成：键盘/分段按钮交互导致本轮未提交登录；见 KNOWN-ISSUES |
| 数据/升级 | 同签名覆盖安装未测试；未在 arm64 真机安装 |

## Linux x86_64 客户端

在 WSL Ubuntu 24.04 安装 Flutter Linux 3.47.7、GTK/CMake/Ninja 依赖，生成 Linux runner 后：

- `flutter build linux --release` 成功。
- `yuanlian-client_0.2.0_amd64.deb`：8.0 MB；`dpkg-deb --info/--contents` 通过；`ldd` 无 `not found`；包含 `/usr/bin/yuanlian`、desktop、48×48 图标和 GTK/Wayland/EGL 依赖声明。
- `YuanLian-0.2.0-linux-x86_64-portable.tar.gz`：9.8 MB。
- Xvfb 下启动到 Flutter Impeller，出现无 GPU/光标主题警告；无真实 X11/Wayland 桌面，未做安装/升级/卸载与显示验收。

## 控制服务端

- 包：`yl-server-0.2.0-linux-x86_64.tar.gz`（2.3 MB）；包含 systemd 单元（专用 `yuanlian` 用户、loopback）、env 示例、install/backup/restore、Dockerfile/compose（未验证）、README。
- 从 tar.gz 解压运行：`/health` 返回 `{"ok":true,"version":"0.2.0"}`；`/api/v1/server/ticket-key` 返回 Ed25519 公钥。
- 未在 `192.168.9.66` 或其它主机安装；systemd 安装/备份恢复/Docker 未执行。
- 服务端测试 10 项、WSL fmt/clippy/build 通过；包含 R1–R6/票据状态/租约/迁移测试。WebUI 已做管理员登录/设备/详情/会话/网络浏览器检查，P2P 仍明确未实现。

## 构建环境

- Windows 11 26H2 build 26300；Rust 1.99.1 MSVC；Flutter 3.47.7/Dart 3.13.5；便携 CMake 4.4.4；NSIS 3.11。
- WSL Ubuntu 24.04：Rust 1.99.1、Flutter Linux 3.47.7、GTK3。
- Android SDK 36/build-tools 36.0.0；模拟器 x86_64 Android 14。

截图/日志在 `artifacts/`（gitignore），不提交仓库；本文件与 manifest 记录结果与限制。
