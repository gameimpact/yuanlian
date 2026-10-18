# 打包与安装验证（0.2.0）

本文记录可复制的构建步骤、实际产物与验证边界。产物在 `dist/0.2.0/`（gitignore）。

## 1. 版本与源码状态

- 应用/服务端版本：0.2.0；协议 v2；Flutter build number 2；Android versionCode 2。
- 构建时工作区存在未提交改动（见 `build-manifest.json.source_dirty`）；这不是“干净源码最终发布”证明。
- 依赖锁：根 `Cargo.lock`、`server/Cargo.lock`、`client/pubspec.lock` 均提交。

## 2. Windows x64

### 前置

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked
cargo test --workspace --locked
cargo build --release --locked -p yl-host -p yl-viewer
```

Flutter（本机 VS 未装 CMake 组件，SDK 已补丁支持 `FLUTTER_CMAKE_PATH`）：

```powershell
$env:FLUTTER_CMAKE_PATH = "C:/Users/Lenovo/dev/cmake/cmake-4.4.4-windows-x86_64/bin/cmake.exe"
# 中文路径会让 MSBuild/AOT 路径乱码；在 ASCII 副本构建
robocopy client C:\Users\Lenovo\dev\yuanlian-client-build /MIR /XD build .dart_tool
cd C:\Users\Lenovo\dev\yuanlian-client-build
flutter pub get --offline
flutter build windows --release --no-pub
```

### 生成安装器/便携包

```powershell
$env:FLUTTER_CMAKE_PATH = "C:/Users/Lenovo/dev/cmake/cmake-4.4.4-windows-x86_64/bin/cmake.exe"
& packaging\windows\build.ps1 `
  -Version 0.2.0 `
  -ClientRelease C:\Users\Lenovo\dev\yuanlian-client-build\build\windows\x64\runner\Release `
  -Nsis C:\Users\Lenovo\dev\nsis\nsis-3.11\makensis.exe
```

脚本：复制 Flutter Release、Host/Viewer、文档；写 VERSION（revision/dirty/build time）；压缩 zip；用 UTF-8 BOM 的 NSIS 脚本生成 per-user 安装器（`RequestExecutionLevel user`，默认不启动 Host/不放开防火墙/不勾选登录启动）。

### 已执行的安装验证

| 步骤 | 结果 |
|---|---|
| `/S /D=...\YuanLianTest` 静默安装 | 成功；client/bin/docs/许可/卸载器齐全 |
| 再次安装（覆盖升级） | 成功；`%APPDATA%\YuanLian` 标记文件保留 |
| 从安装目录启动客户端 | 成功，窗口标题“远联 YuanLian” |
| 静默卸载 | 程序目录删除；卸载注册项删除；用户数据默认保留 |
| 便携包解压到 `C:\Users\Lenovo\dev\远联 便携 测试` | 成功；从含空格/中文路径启动客户端成功 |

**未做**：Windows 代码签名（无证书，系统显示未知发布者）；安装器 GUI 逐页点击（本轮用静默安装验证文件/注册表/卸载）。

## 3. Android arm64

签名配置在仓库外：

```bash
# C:/Users/Lenovo/dev/yuanlian-keys/key.properties
# storePassword/keyPassword/keyAlias/storeFile; storeFile 用正斜杠
export YUANLIAN_KEY_PROPERTIES="C:/Users/Lenovo/dev/yuanlian-keys/key.properties"
cd C:/Users/Lenovo/dev/yuanlian-client-build
flutter build apk --release --no-pub --target-platform android-arm64   # arm64
flutter build apk --release --no-pub                                 # universal (含 x86_64 模拟器)
```

- arm64 APK：17.7 MB；minSdk 24；target 36；证书 `CN=YuanLian Preview`，SHA-256 `e95efd397b72854472545bc490aaa72726cb5a70cc3490757dc64a2490859512`；**预览签名，非正式发布**。
- universal APK：51.0 MB；arm64-v8a/armeabi-v7a/x86_64；同签名；用于 x86_64 模拟器安装测试。
- 模拟器（x86_64，Android 14）安装 universal APK 成功、启动无 FATAL；arm64 APK 在 x86_64 上按预期 `INSTALL_FAILED_NO_MATCHING_ABIS`，未在 arm64 实机安装。
- 账号页在模拟器打开并渲染服务端地址/登录/邀请注册表单；未完成真实服务端登录（输入法与布局交互问题，见证据/已知问题）。

## 4. Linux x86_64 客户端

在 WSL Ubuntu 24.04 安装 Flutter Linux 3.47.7 与 `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`，从 `client/lib` 生成 linux runner 后：

```bash
cd /home/ubuntu/yuanlian-client-linux
flutter pub get
flutter build linux --release
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u root -- bash \
  packaging/linux/build-deb.sh \
  /home/ubuntu/yuanlian-client-linux/build/linux/x64/release/bundle \
  /mnt/c/.../dist/0.2.0/linux-x86_64/yuanlian.png \
  /mnt/c/.../dist/0.2.0/linux-x86_64
```

产物：`yuanlian-client_0.2.0_amd64.deb`（8.0 MB）、`YuanLian-0.2.0-linux-x86_64-portable.tar.gz`（9.8 MB）。`.deb` 声明 GTK/Wayland/EGL 等运行依赖，包含 `/usr/bin/yuanlian`、desktop 文件和 48×48 图标；`dpkg-deb --info/--contents` 检查通过，`ldd` 无缺失库。Xvfb 下可启动到 Flutter Impeller，但 WSL 无桌面/真实显示，**不能标记 Linux 实机通过**；安装/升级/卸载未在干净桌面系统执行。

## 5. 控制服务端 Linux x86_64

```bash
cd server
cargo fmt -- --check
cargo clippy --release --locked -- -D warnings
cargo test --release --locked
cargo build --release --locked
```

包内容：`bin/yl-server`、systemd 单元（专用 `yuanlian` 用户、loopback）、`config/server.env.example`、`install.sh`/`backup.sh`/`restore.sh`、Dockerfile/compose（**未验证**，本机无 Docker）、中文 README、LICENSE。`install.sh` 需要 root，安装后运行健康检查。

本次未在 `192.168.9.66` 或其它生产服务器安装；tar.gz 只做内容与本地二进制健康检查。

## 6. 产物清单

见 `dist/0.2.0/build-manifest.json`、`SHA256SUMS.txt`。所有哈希从最终文件重新计算。
