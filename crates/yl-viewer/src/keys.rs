//! Maps minifb key identities to Windows virtual-key codes.

use minifb::Key;

/// Returns `(virtual_key, extended)` for a physical key. `None` means the key
/// is not forwarded yet (media keys, unknown keys).
pub fn to_windows_vk(key: Key) -> Option<(u16, bool)> {
    use Key::*;
    let mapped = match key {
        Key0 => (0x30, false),
        Key1 => (0x31, false),
        Key2 => (0x32, false),
        Key3 => (0x33, false),
        Key4 => (0x34, false),
        Key5 => (0x35, false),
        Key6 => (0x36, false),
        Key7 => (0x37, false),
        Key8 => (0x38, false),
        Key9 => (0x39, false),

        A => (0x41, false),
        B => (0x42, false),
        C => (0x43, false),
        D => (0x44, false),
        E => (0x45, false),
        F => (0x46, false),
        G => (0x47, false),
        H => (0x48, false),
        I => (0x49, false),
        J => (0x4A, false),
        K => (0x4B, false),
        L => (0x4C, false),
        M => (0x4D, false),
        N => (0x4E, false),
        O => (0x4F, false),
        P => (0x50, false),
        Q => (0x51, false),
        R => (0x52, false),
        S => (0x53, false),
        T => (0x54, false),
        U => (0x55, false),
        V => (0x56, false),
        W => (0x57, false),
        X => (0x58, false),
        Y => (0x59, false),
        Z => (0x5A, false),

        F1 => (0x70, false),
        F2 => (0x71, false),
        F3 => (0x72, false),
        F4 => (0x73, false),
        F5 => (0x74, false),
        F6 => (0x75, false),
        F7 => (0x76, false),
        F8 => (0x77, false),
        F9 => (0x78, false),
        F10 => (0x79, false),
        F11 => (0x7A, false),
        F12 => (0x7B, false),
        F13 => (0x7C, false),
        F14 => (0x7D, false),
        F15 => (0x7E, false),

        Down => (0x28, true),
        Left => (0x25, true),
        Right => (0x27, true),
        Up => (0x26, true),
        Apostrophe => (0xDE, false),
        Backquote => (0xC0, false),
        Backslash => (0xDC, false),
        Comma => (0xBC, false),
        Equal => (0xBB, false),
        LeftBracket => (0xDB, false),
        Minus => (0xBD, false),
        Period => (0xBE, false),
        RightBracket => (0xDD, false),
        Semicolon => (0xBA, false),
        Slash => (0xBF, false),

        Backspace => (0x08, false),
        Delete => (0x2E, true),
        End => (0x23, true),
        Enter => (0x0D, false),
        Escape => (0x1B, false),
        Home => (0x24, true),
        Insert => (0x2D, true),
        Menu => (0x5D, true),
        PageDown => (0x22, true),
        PageUp => (0x21, true),
        Pause => (0x13, false),
        Space => (0x20, false),
        Tab => (0x09, false),
        NumLock => (0x90, true),
        CapsLock => (0x14, false),
        ScrollLock => (0x91, false),

        LeftShift => (0xA0, false),
        RightShift => (0xA1, false),
        LeftCtrl => (0xA2, false),
        RightCtrl => (0xA3, true),
        LeftAlt => (0xA4, false),
        RightAlt => (0xA5, true),
        LeftSuper => (0x5B, true),
        RightSuper => (0x5C, true),

        NumPad0 => (0x60, false),
        NumPad1 => (0x61, false),
        NumPad2 => (0x62, false),
        NumPad3 => (0x63, false),
        NumPad4 => (0x64, false),
        NumPad5 => (0x65, false),
        NumPad6 => (0x66, false),
        NumPad7 => (0x67, false),
        NumPad8 => (0x68, false),
        NumPad9 => (0x69, false),
        NumPadDot => (0x6E, false),
        NumPadSlash => (0x6F, true),
        NumPadAsterisk => (0x6A, false),
        NumPadMinus => (0x6D, false),
        NumPadPlus => (0x6B, false),
        NumPadEnter => (0x0D, true),

        Unknown | Count => return None,
    };
    Some(mapped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_letters_and_navigation() {
        assert_eq!(to_windows_vk(Key::A), Some((0x41, false)));
        assert_eq!(to_windows_vk(Key::Left), Some((0x25, true)));
        assert_eq!(to_windows_vk(Key::NumPadEnter), Some((0x0D, true)));
        assert_eq!(to_windows_vk(Key::Unknown), None);
    }
}
