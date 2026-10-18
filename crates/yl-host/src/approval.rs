//! Local, human confirmation for an inbound session.
//!
//! The control-plane ticket proves who is asking; it does not override the
//! person at the Host. This module shows a native dialog on the interactive
//! desktop. If no interactive desktop is available (for example a Session 0
//! service) MessageBox fails and the request is denied.

use std::net::SocketAddr;

use tracing::warn;
use windows::core::PCWSTR;
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, IDYES, MB_ICONWARNING, MB_SETFOREGROUND, MB_TOPMOST, MB_YESNO,
};

use yl_proto::permission_summary;

pub fn request(peer: SocketAddr, account: Option<&str>, permissions: u32) -> bool {
    let who = account
        .map(|name| format!("账号：{name}"))
        .unwrap_or_else(|| "匿名开发连接（未经账号/配对授权）".to_string());
    let text = format!(
        "远联收到一个远程控制请求。\n\n\
         来源：{peer}\n\
         {who}\n\
         请求权限：{}\n\n\
         只有在信任此来源时才允许。允许仅对本次会话有效。",
        permission_summary(permissions)
    );
    let title = "远联 - 本机连接授权";
    let text_wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    let title_wide: Vec<u16> = title.encode_utf16().chain(Some(0)).collect();
    let result = unsafe {
        MessageBoxW(
            None,
            PCWSTR(text_wide.as_ptr()),
            PCWSTR(title_wide.as_ptr()),
            MB_YESNO | MB_ICONWARNING | MB_TOPMOST | MB_SETFOREGROUND,
        )
    };
    if result.0 == 0 {
        warn!("local authorization dialog could not be shown; denying session");
        return false;
    }
    result == IDYES
}
