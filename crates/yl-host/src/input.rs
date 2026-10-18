//! Windows input injection through SendInput.
//!
//! The viewer sends monitor-local pixel coordinates; this module converts them
//! to absolute virtual-desktop coordinates. Input is only reachable after the
//! Host has explicitly enabled it (`--allow-input`) and the session granted it.

use std::collections::HashSet;
use std::thread::sleep;
use std::time::Duration;

use anyhow::{bail, Result};
use tracing::{debug, warn};
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
    MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT,
    MOUSE_EVENT_FLAGS, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN,
};

use yl_proto::{InputEvent, MouseButton};

#[derive(Debug, Clone, Copy)]
pub struct ScreenGeometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// Per-monitor-v2 awareness keeps capture pixels and SendInput coordinates in
/// the same physical coordinate space on mixed-DPI desktops. Failure (for
/// example because the manifest already set awareness) is not fatal.
pub fn ensure_dpi_awareness() {
    if let Err(error) =
        unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
    {
        debug!(%error, "SetProcessDpiAwarenessContext was not applied");
    }
}

#[derive(Debug)]
pub struct InputInjector {
    geometry: ScreenGeometry,
    pressed_keys: HashSet<(u16, bool)>,
    pressed_buttons: HashSet<u8>,
}

impl InputInjector {
    pub fn new(geometry: ScreenGeometry) -> Self {
        Self {
            geometry,
            pressed_keys: HashSet::new(),
            pressed_buttons: HashSet::new(),
        }
    }

    pub fn handle(&mut self, event: &InputEvent) -> Result<()> {
        match event {
            InputEvent::MouseMove { x, y } => self.mouse_move(*x, *y),
            InputEvent::MouseButton { button, down } => self.button(*button, *down),
            InputEvent::Wheel {
                vertical,
                horizontal,
            } => self.wheel(*vertical, *horizontal),
            InputEvent::Key { vk, down, extended } => self.key(*vk, *down, *extended),
            InputEvent::ReleaseAll => {
                self.release_all();
                Ok(())
            }
        }
    }

    pub fn mouse_move(&mut self, local_x: i32, local_y: i32) -> Result<()> {
        let (dx, dy) = absolute_virtual(
            self.geometry.x.saturating_add(local_x),
            self.geometry.y.saturating_add(local_y),
        );
        send_mouse(
            MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
            dx,
            dy,
            0,
        )
    }

    fn button(&mut self, button: MouseButton, down: bool) -> Result<()> {
        let (code, down_flag, up_flag, data) = match button {
            MouseButton::Left => (1u8, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, 0),
            MouseButton::Right => (2u8, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, 0),
            MouseButton::Middle => (3u8, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0),
            MouseButton::Back => (4u8, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 1),
            MouseButton::Forward => (5u8, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 2),
        };
        if down {
            if !self.pressed_buttons.insert(code) {
                return Ok(());
            }
            send_mouse(down_flag, 0, 0, data)
        } else {
            if !self.pressed_buttons.remove(&code) {
                return Ok(());
            }
            send_mouse(up_flag, 0, 0, data)
        }
    }

    fn wheel(&mut self, vertical: i32, horizontal: i32) -> Result<()> {
        if vertical != 0 {
            send_mouse(MOUSEEVENTF_WHEEL, 0, 0, vertical as u32)?;
        }
        if horizontal != 0 {
            send_mouse(MOUSEEVENTF_HWHEEL, 0, 0, horizontal as u32)?;
        }
        Ok(())
    }

    pub fn key(&mut self, vk: u16, down: bool, extended: bool) -> Result<()> {
        if down {
            self.pressed_keys.insert((vk, extended));
            send_key(vk, down, extended)
        } else if self.pressed_keys.remove(&(vk, extended)) {
            // A release may arrive without the extended bit matching; fall back
            // to the recorded state rather than leaving a key stuck.
            send_key(vk, down, extended)
        } else {
            let recorded = self
                .pressed_keys
                .iter()
                .find(|(pressed_vk, _)| *pressed_vk == vk)
                .copied();
            if let Some((_, recorded_extended)) = recorded {
                self.pressed_keys.remove(&(vk, recorded_extended));
                send_key(vk, down, recorded_extended)
            } else {
                debug!("ignoring key-up for a key we never pressed");
                Ok(())
            }
        }
    }

    /// Injects committed Unicode text via SendInput. This is a local text
    /// submission path: it does not drive a remote IME composition window.
    pub fn send_text(&mut self, text: &str) -> Result<()> {
        let units: Vec<u16> = text.encode_utf16().collect();
        if units.is_empty() {
            return Ok(());
        }
        for chunk in units.chunks(64) {
            let mut inputs = Vec::with_capacity(chunk.len() * 2);
            for &unit in chunk {
                inputs.push(unicode_input(unit, false));
                inputs.push(unicode_input(unit, true));
            }
            send_inputs(&inputs)?;
        }
        Ok(())
    }

    /// Releases every key and button currently held by this injector. Called
    /// on disconnect, focus loss and process shutdown so nothing stays stuck.
    pub fn release_all(&mut self) {
        for (vk, extended) in self.pressed_keys.drain() {
            if let Err(error) = send_key(vk, false, extended) {
                warn!(%error, "failed to release a held key");
            }
        }
        let buttons: Vec<u8> = self.pressed_buttons.drain().collect();
        for code in buttons {
            let (up_flag, data) = match code {
                1 => (MOUSEEVENTF_LEFTUP, 0),
                2 => (MOUSEEVENTF_RIGHTUP, 0),
                3 => (MOUSEEVENTF_MIDDLEUP, 0),
                4 => (MOUSEEVENTF_XUP, 1),
                5 => (MOUSEEVENTF_XUP, 2),
                _ => continue,
            };
            if let Err(error) = send_mouse(up_flag, 0, 0, data) {
                warn!(%error, "failed to release a held mouse button");
            }
        }
    }
}

fn send_inputs(inputs: &[INPUT]) -> Result<()> {
    let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent != inputs.len() as u32 {
        bail!(
            "SendInput injected {sent} of {} events (last error {:?})",
            inputs.len(),
            std::io::Error::last_os_error()
        );
    }
    Ok(())
}

fn send_mouse(flags: MOUSE_EVENT_FLAGS, dx: i32, dy: i32, data: u32) -> Result<()> {
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    send_inputs(&[input])
}

fn send_key(vk: u16, up: bool, extended: bool) -> Result<()> {
    let mut flags = KEYBD_EVENT_FLAGS::default();
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    if extended {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    send_inputs(&[input])
}

fn unicode_input(unit: u16, up: bool) -> INPUT {
    let mut flags = KEYEVENTF_UNICODE;
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

#[cfg(test)]
fn text_units(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

fn absolute_virtual(screen_x: i32, screen_y: i32) -> (i32, i32) {
    let (vx, vy, vw, vh) = unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        )
    };
    let vw = vw.max(2);
    let vh = vh.max(2);
    let ax = ((screen_x - vx) as f64 / (vw - 1) as f64 * 65_535.0).round();
    let ay = ((screen_y - vy) as f64 / (vh - 1) as f64 * 65_535.0).round();
    (
        ax.clamp(0.0, 65_535.0) as i32,
        ay.clamp(0.0, 65_535.0) as i32,
    )
}

pub fn cursor_position() -> Option<(i32, i32)> {
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point).ok()? };
    Some((point.x, point.y))
}

/// Moves the real cursor to the monitor centre, verifies the reported position
/// and restores it. Used by `yl-host --test-input`; never click or type here.
pub fn verify_mouse_injection(geometry: ScreenGeometry) -> Result<()> {
    ensure_dpi_awareness();
    let mut original = POINT::default();
    unsafe { GetCursorPos(&mut original)? };
    let target_x = geometry.x + geometry.width as i32 / 2;
    let target_y = geometry.y + geometry.height as i32 / 2;
    let mut injector = InputInjector::new(geometry);
    injector.mouse_move(geometry.width as i32 / 2, geometry.height as i32 / 2)?;
    sleep(Duration::from_millis(150));
    let mut current = POINT::default();
    unsafe { GetCursorPos(&mut current)? };
    // Restore using absolute virtual coordinates even if the monitor origin is
    // not at (0, 0).
    send_mouse(
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        absolute_virtual(original.x, original.y).0,
        absolute_virtual(original.x, original.y).1,
        0,
    )?;
    let error_x = (current.x - target_x).abs();
    let error_y = (current.y - target_y).abs();
    if error_x > 2 || error_y > 2 {
        bail!(
            "cursor injection mismatch: wanted ({target_x},{target_y}), got ({},{})",
            current.x,
            current.y
        );
    }
    println!(
        "SendInput OK: cursor moved to ({},{}), error {}x{} px, restored to ({},{})",
        current.x, current.y, error_x, error_y, original.x, original.y
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_text_keeps_surrogate_pairs() {
        let units = text_units("A😀");
        assert_eq!(units, vec![0x0041, 0xD83D, 0xDE00]);
    }
}
