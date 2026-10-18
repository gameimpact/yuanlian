# M1 Flutter Windows 客户端验证记录

日期：2026-10-18。范围：**Windows 主控 Flutter 产品壳接入现有 M0 Rust Host**。不是完整 M1；账号、服务端、文件、Linux/Android、质量模式未完成。

## 构建环境

- Flutter 3.47.7 stable，Dart 3.13.5。
- Windows 10.0.26300 x64，VS2022 Build Tools（v143），Windows SDK 10.0.26100。
- 本机 VS 未安装 “C++ CMake tools” 组件且无管理员权限；使用便携 CMake 4.4.4，并对本机 Flutter SDK 做了两处仅开发环境补丁：
  1. VS 检查不再要求 `Microsoft.VisualStudio.Component.VC.CMake.Project`；
  2. `cmakePath` 支持 `FLUTTER_CMAKE_PATH` 覆盖。
- Windows release 在中文路径下 AOT/MSBuild 报 `.dart_tool` 读文件失败；将项目源码复制到 ASCII 路径（当前 `C:/Users/Lenovo/dev/yuanlian-client-build`）后 `flutter build windows --release` 成功，release 客户端已连接 Host 验证。
- 构建命令：
  ```powershell
  $env:PATH = "C:\Users\Lenovo\dev\cmake\cmake-4.4.4-windows-x86_64\bin;$env:PATH"
  $env:FLUTTER_CMAKE_PATH = "C:\Users\Lenovo\dev\cmake\cmake-4.4.4-windows-x86_64\bin\cmake.exe"
  flutter build windows --debug
  ```

`flutter analyze` 在该中文路径下会因分析服务器 JSON 编码崩溃；使用 `dart analyze` 代替（当前 0 issue）。

## 自动化与静态检查

```
dart analyze          -> No issues found
flutter test          -> 6 passed（Welcome/Frame/Error/Hello/Input/framing/指纹）
flutter build windows --debug -> 成功
```

## 真实端到端

Host：`yl-host --listen 127.0.0.1:24804 --allow-input --fps 5`，3200×2000 主显示器。

Flutter 客户端通过 `--auto-connect-address/--auto-connect-fingerprint` 自动连接：

- TLS 握手成功，SHA-256 指纹固定；Host 记录 `viewer session established`，输入允许。
- 首帧后客户端请求全量帧，窗口显示真实桌面（同机测试出现递归镜像，属预期）。
- 状态栏实测约 5 fps、0.7 MiB/s、RTT 1 ms（3200×2000，JPEG 图块，Host 目标 5 fps）。
- 截图：`artifacts/m1/flutter-title.png`（本地，未入库）。

### 输入链路

1. 客户端内自检 `--input-self-test` 直接发送远端 (10,10)，Host 光标实测 `(10,10)`，误差 0。
2. 真实指针事件：用相对鼠标事件将本机指针移到 Flutter 画面内，客户端调试日志：
   `local=(598.5,370.0) viewport=(90.7,0)-(1176.3,678.5) scale=0.33925`
   Host 收到 `MouseMove { x: 1496, y: 1090 }`；下一次 `local=(731.5,450.0)` → Host `(1888,1326)`。与视口映射计算一致。
3. 说明：`SetCursorPos` / 绝对 `mouse_event` 没有触发 Flutter hover；改用相对鼠标事件后正常。真实用户输入是相对事件，不受影响。

### TLS 错误处理

用全 `AA` 指纹连接：客户端显示“连接失败”，步骤“TLS 握手与证书指纹校验”标红，错误“Host 证书指纹不匹配，连接已拒绝”，错误码 `fingerprint_mismatch`；Host 记录握手失败。截图 `artifacts/m1/wrongfp-full.png`。

## 当前 UI 实现状态

- 已实现真实页面：连接首页（地址/指纹/模式卡/最近连接）、连接进度、远控工作区（画面、状态栏、断开、请求全量帧、会话详情）、设置（主题、清除地址簿、关于）。
- 模式：三张卡固定；只有“兼顾”可用（图块引擎），“质量”“流畅”明确禁用并显示原因。
- 不可用导航（设备/文件/活动）显示“未接入”，点击说明原因；不使用假数据。
- 未实现：账号/登录、设备目录、文件、剪贴板、音频、全屏、多显示器、无人值守；Flutter 端直接实现 Dart 协议 + JPEG 图块合成，是临时方案，正式版必须替换为 Rust 核心 + native texture。

## 已知问题

- 同机键盘 E2E 会形成输入回环，未做真实按键验证；映射单元测试通过。
- 没有跨物理机/局域网测试。
- 3200×2000 下 JPEG 图块在 Dart 侧解码/绘制 CPU 开销明显；不是最终媒体架构。
- Flutter 窗口为 1280×800 逻辑尺寸，在 200% DPI 下物理 2560×1600；截图需 DPI 感知，否则会裁切。
- 主机窗口标题已修正为“远联 YuanLian”。
