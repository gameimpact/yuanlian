# Android 主控（模拟器）验证记录

日期：2026-10-18。范围：Flutter Android 主控 APK 连接 Windows Host 的真实画面。不是完整 Android 验收；Android 被控 Host 未实现。

## 构建

- Flutter 3.47.7 / Dart 3.13.5；Android SDK Platform 36、build-tools 36.0.0、JDK 25（Android Studio JBR）。
- 项目路径含中文，Gradle 默认拒绝；在 `client/android/gradle.properties` 设置 `android.overridePathCheck=true` 后构建成功。
- 已接受 Android SDK licenses；安装 `android-ndk-r28c` 等构建依赖。
- 构建命令（开发默认值，仅调试）：
  ```powershell
  flutter build apk --debug `
    --dart-define=YUANLIAN_AUTO_ADDRESS=10.0.2.2:24808 `
    --dart-define=YUANLIAN_AUTO_FINGERPRINT=<Host指纹> `
    --dart-define=YUANLIAN_AUTO_NAME=Android-Emulator
  ```
- 产物：debug APK 与 release APK。release 在 ASCII 路径副本构建成功（49.2 MB），安装/启动验证通过；仍使用 Flutter 模板的 debug 签名，不是生产签名。
- Manifest 已加 INTERNET / ACCESS_NETWORK_STATE；应用名“远联 YuanLian”。

## 模拟器实测

- AVD：`cx-standalone-api34`（Android 14，x86_64），已启动，adb 在线。
- Host：Windows，`--listen 127.0.0.1:24808 --allow-input --fps 5 --file-root artifacts/file-root`，3200×2000。
- APK 安装、启动成功；首页为移动端抽屉布局，连接表单可用。
- 通过 `10.0.2.2:24808` 连接：TCP、TLS 指纹固定成功；Host 记录 viewer session established。
- 工作区显示真实 Windows 桌面：状态栏实测 5 fps、RTT 5–7 ms、3200×2000；截图证据保留在本地（未入库）。
- 初版工具栏在手机宽度溢出；已改为紧凑工具栏（更多菜单）与紧凑状态栏，复测无溢出。
- 连接失败 UI：Host 忙时 TLS 超时显示“连接失败 / tls_failed”；Host 空出后点“重新连接”成功。证明重试路径可用。

## 未验证/未实现

- 触摸输入注入未在模拟器做点击验证；`Listener` 将触摸映射为鼠标左键，尚未验证双指滚动/长按/直接触控模式。
- 中文输入法、软键盘、剪贴板、SAF 文件选择、后台/电池策略未接入。
- Android 作为被控 Host（MediaProjection/Accessibility/前台服务）完全未实现；质量模式 Host 不支持。
- 未在物理 Android 设备、移动网络或跨公网测试。
- APK 为 debug 构建，未签名发布；未做 Play/侧载分发验收。
