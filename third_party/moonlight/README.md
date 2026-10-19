# Moonlight / Sunshine 上游组件（质量预览）

本目录只保留上游发行包的校验信息与说明；`*.zip` 和运行解压目录不提交到 Git。
旧的独立质量预览是社区、非商用功能，不进入远联账号/票据/撤权安全闭环。
0.3.0 新增的账号授权质量入口已接入 Host 票据与撤权，仍使用外部 Moonlight 窗口；实现与实测边界见 [Host 授权质量串流证据](../../docs/evidence/quality-host-flow-2026-10-19.md)。

## 固定版本

| 组件 | 版本 | 源码 | 发行资产 SHA-256 |
|---|---|---|---|
| Moonlight-qt | 6.2.0 | tag `v6.2.0` / commit `de2467e433821664cdd2224aad8c89a625be1ad9` | `MoonlightPortable-x64-6.2.0.zip`<br>`6f91d268b41ed5ca8066d9d7578dc403b8db190991ff48f00b1700465f8f7ebf` |
| Sunshine | 2026.914.233613 | tag `v2026.914.233613` / commit `63d35f702ee9e362e43263742981836ec0710384` | `Sunshine-Windows-AMD64-lite.zip`<br>`233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b` |

下载地址：

- <https://github.com/moonlight-stream/moonlight-qt/releases/download/v6.2.0/MoonlightPortable-x64-6.2.0.zip>
- <https://github.com/LizardByte/Sunshine/releases/download/v2026.914.233613/Sunshine-Windows-AMD64-lite.zip>

把两个 zip 放在本目录，运行 `packaging/quality/build-quality-preview.ps1` 生成质量预览包。
脚本会重新校验 SHA-256，不信任本目录中已解压的文件。

## 许可证

Moonlight-qt、Sunshine 均为 GPL-3.0；随 Moonlight 分发的 Qt 6 为 LGPL-3.0。
许可证全文、NOTICE 与源码获取说明在 `packaging/quality/`，最终包内也会附带。

## 不要提交

- `Moonlight.ini`：便携版运行后会写入客户端私钥、已配对 Host 证书和 PIN 状态。
- `Sunshine/config/credentials`、`sunshine_state.json`：Host 配对凭据和状态。
- `sunshine.log`、`Moonlight.log` 等运行日志。
- 任何 zip/exe/dll 二进制（体积大且应由固定版本资产重新下载）。

仓库 `.gitignore` 已排除 `*.zip`、`moonlight/` 和 `sunshine/`。
