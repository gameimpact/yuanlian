# 固定上游审查副本

本目录 cpp 文件来自以下固定上游，不是新写的远联代码，也不是可独立构建的完整源包。保留上游声明，适用 GPL-3.0（全文见本目录 LICENSE）。

- Sunshine commit `63d35f702ee9e362e43263742981836ec0710384`：config.cpp、nvhttp.cpp、confighttp.cpp、httpcommon.cpp、main.cpp、rtsp.cpp。
- Moonlight-qt commit `de2467e433821664cdd2224aad8c89a625be1ad9`：pair.cpp、identitymanager.cpp、computermanager.cpp、nvcomputer.cpp、moonlight-main.cpp、moonlight-nvhttp.cpp、moonlight-session.cpp、ffmpeg.cpp。

完整对应源码与递归子模块位于相邻 `source-checkouts/`（不提交重复源码/大型依赖），可用仓库 `packaging/quality/fetch-corresponding-source.ps1` 重新获取；递归锁定记录归档为 upstream-recursive-pins.json。远联适配源码位于 crates/yl-runtime、yl-host/src/quality.rs、yl-viewer/src/quality.rs 和 Flutter quality_broker_page.dart，没有修改这些上游二进制。
