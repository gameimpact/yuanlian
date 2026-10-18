# M2 文件传输（基础）验证记录

日期：2026-10-18。范围：Windows Host 授权目录 ↔ Flutter Windows 客户端单文件上传/下载。不是完整文件验收。

## 实现

- Host `--file-root <DIR>` 显式授权单个目录；未配置时文件能力关闭。
- 远端目录浏览、文件下载、单文件上传、覆盖确认、SHA-256 校验、临时文件提交。
- Flutter 双栏文件页：远端/本地目录导航、文件选择、上传/下载按钮、进度与结果、错误重试。
- 限制：无目录传输、无拖放、无断点续传、无服务端审计、无细粒度文件权限。上传覆盖已改为 Windows MoveFileExW 原子替换；旧文件在替换失败时的保留尚未做故障注入实测。

## 自动化测试

Rust 单元测试（`cargo test -p yl-host`，6 项文件测试）：

- 路径规范化/`..`/盘符/反斜杠逃逸拒绝；
- 列出目录、跳过符号链接；
- 上传块偏移校验、大小/哈希、提交；
- 已存在目标未允许覆盖时拒绝，允许后覆盖；
- 越界上传拒绝；
- 取消清理临时文件。

Dart 协议测试新增文件消息布局（能力、列表、块、完成、错误、上传开始/块/完成），8 项全部通过。

## UI 实测

Host：`yl-host --listen 127.0.0.1:24806 --allow-input --fps 5 --file-root artifacts/file-root`。

1. **下载**：在 Flutter 文件页选中远端 `hello.txt` 并点击下载。
   - 本地生成 `C:\Users\Lenovo\hello.txt`；
   - 内容：`hello from Host` + 中文行；
   - SHA-256：`7166d1fa92079a84a6313b41373fb5b77b68102a96c719fe868841a950907c76`，与 Host 源文件一致。
2. **上传**：`YUANLIAN_LOCAL_DIR=artifacts/local-upload` 启动客户端，选中 `upload-test.txt` 上传。
   - Host 根目录出现 `upload-test.txt`（33 B），远端列表刷新显示；
   - SHA-256：`926eb3249f7c189f71e24771235f18c89fabee134daf1b930374f4b1b6c77640`，与本地一致；
   - UI 显示“上传完成”和完整哈希。
3. 截图：`artifacts/m1/file-page.png`、`upload-done.png`（本地，未入库）。

## 未验证

目录上传/下载、多文件批量、4 GiB、一万小文件、断网/进程重启续传、传输中撤权、冲突矩阵、磁盘不足、目标文件被占用、macOS/Linux/Android SAF、中继下的大文件干扰。M2 基础功能通过，不等于文件专项验收完成。
