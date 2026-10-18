import 'package:flutter/services.dart';

class VkBinding {
  const VkBinding(this.vk, [this.extended = false]);
  final int vk;
  final bool extended;
}

/// Maps Flutter logical keys to Windows virtual-key codes. Letters and digits
/// use their ASCII key ids; the rest are explicit so layout changes are visible
/// in code rather than silently producing wrong characters.
VkBinding? vkFor(LogicalKeyboardKey key) {
  final id = key.keyId;
  if (id >= 0x61 && id <= 0x7a) {
    return VkBinding(0x41 + (id - 0x61));
  }
  if (id >= 0x30 && id <= 0x39) {
    return VkBinding(id);
  }

  return switch (key) {
    LogicalKeyboardKey.backspace => const VkBinding(0x08),
    LogicalKeyboardKey.tab => const VkBinding(0x09),
    LogicalKeyboardKey.enter => const VkBinding(0x0D),
    LogicalKeyboardKey.escape => const VkBinding(0x1B),
    LogicalKeyboardKey.space => const VkBinding(0x20),
    LogicalKeyboardKey.capsLock => const VkBinding(0x14),
    LogicalKeyboardKey.numLock => const VkBinding(0x90, true),
    LogicalKeyboardKey.scrollLock => const VkBinding(0x91),
    LogicalKeyboardKey.pause => const VkBinding(0x13),
    LogicalKeyboardKey.contextMenu => const VkBinding(0x5D, true),
    LogicalKeyboardKey.printScreen => const VkBinding(0x2C, true),

    LogicalKeyboardKey.shiftLeft => const VkBinding(0xA0),
    LogicalKeyboardKey.shiftRight => const VkBinding(0xA1),
    LogicalKeyboardKey.controlLeft => const VkBinding(0xA2),
    LogicalKeyboardKey.controlRight => const VkBinding(0xA3, true),
    LogicalKeyboardKey.altLeft => const VkBinding(0xA4),
    LogicalKeyboardKey.altRight => const VkBinding(0xA5, true),
    LogicalKeyboardKey.metaLeft => const VkBinding(0x5B, true),
    LogicalKeyboardKey.metaRight => const VkBinding(0x5C, true),

    LogicalKeyboardKey.arrowLeft => const VkBinding(0x25, true),
    LogicalKeyboardKey.arrowUp => const VkBinding(0x26, true),
    LogicalKeyboardKey.arrowRight => const VkBinding(0x27, true),
    LogicalKeyboardKey.arrowDown => const VkBinding(0x28, true),
    LogicalKeyboardKey.home => const VkBinding(0x24, true),
    LogicalKeyboardKey.end => const VkBinding(0x23, true),
    LogicalKeyboardKey.pageUp => const VkBinding(0x21, true),
    LogicalKeyboardKey.pageDown => const VkBinding(0x22, true),
    LogicalKeyboardKey.insert => const VkBinding(0x2D, true),
    LogicalKeyboardKey.delete => const VkBinding(0x2E, true),

    LogicalKeyboardKey.f1 => const VkBinding(0x70),
    LogicalKeyboardKey.f2 => const VkBinding(0x71),
    LogicalKeyboardKey.f3 => const VkBinding(0x72),
    LogicalKeyboardKey.f4 => const VkBinding(0x73),
    LogicalKeyboardKey.f5 => const VkBinding(0x74),
    LogicalKeyboardKey.f6 => const VkBinding(0x75),
    LogicalKeyboardKey.f7 => const VkBinding(0x76),
    LogicalKeyboardKey.f8 => const VkBinding(0x77),
    LogicalKeyboardKey.f9 => const VkBinding(0x78),
    LogicalKeyboardKey.f10 => const VkBinding(0x79),
    LogicalKeyboardKey.f11 => const VkBinding(0x7A),
    LogicalKeyboardKey.f12 => const VkBinding(0x7B),

    LogicalKeyboardKey.quoteSingle => const VkBinding(0xDE),
    LogicalKeyboardKey.backquote => const VkBinding(0xC0),
    LogicalKeyboardKey.backslash => const VkBinding(0xDC),
    LogicalKeyboardKey.comma => const VkBinding(0xBC),
    LogicalKeyboardKey.equal => const VkBinding(0xBB),
    LogicalKeyboardKey.bracketLeft => const VkBinding(0xDB),
    LogicalKeyboardKey.minus => const VkBinding(0xBD),
    LogicalKeyboardKey.period => const VkBinding(0xBE),
    LogicalKeyboardKey.bracketRight => const VkBinding(0xDD),
    LogicalKeyboardKey.semicolon => const VkBinding(0xBA),
    LogicalKeyboardKey.slash => const VkBinding(0xBF),

    LogicalKeyboardKey.numpad0 => const VkBinding(0x60),
    LogicalKeyboardKey.numpad1 => const VkBinding(0x61),
    LogicalKeyboardKey.numpad2 => const VkBinding(0x62),
    LogicalKeyboardKey.numpad3 => const VkBinding(0x63),
    LogicalKeyboardKey.numpad4 => const VkBinding(0x64),
    LogicalKeyboardKey.numpad5 => const VkBinding(0x65),
    LogicalKeyboardKey.numpad6 => const VkBinding(0x66),
    LogicalKeyboardKey.numpad7 => const VkBinding(0x67),
    LogicalKeyboardKey.numpad8 => const VkBinding(0x68),
    LogicalKeyboardKey.numpad9 => const VkBinding(0x69),
    LogicalKeyboardKey.numpadDecimal => const VkBinding(0x6E),
    LogicalKeyboardKey.numpadDivide => const VkBinding(0x6F, true),
    LogicalKeyboardKey.numpadMultiply => const VkBinding(0x6A),
    LogicalKeyboardKey.numpadSubtract => const VkBinding(0x6D),
    LogicalKeyboardKey.numpadAdd => const VkBinding(0x6B),
    LogicalKeyboardKey.numpadEnter => const VkBinding(0x0D, true),
    _ => null,
  };
}
