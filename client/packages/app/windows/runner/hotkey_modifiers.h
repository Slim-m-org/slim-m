#ifndef RUNNER_HOTKEY_MODIFIERS_H_
#define RUNNER_HOTKEY_MODIFIERS_H_

#include <cstdint>

/// The hotkey hook's key logic, free of Windows headers so a plain compiler
/// can test it (scripts/lib/test_windows_runner_logic.py).
namespace slimm {

// The winuser.h key codes; global_hotkeys_channel.cpp asserts they match.
constexpr uint32_t kVkShift = 0x10;
constexpr uint32_t kVkLeftShift = 0xA0;
constexpr uint32_t kVkRightShift = 0xA1;
constexpr uint32_t kVkControl = 0x11;
constexpr uint32_t kVkLeftControl = 0xA2;
constexpr uint32_t kVkRightControl = 0xA3;
constexpr uint32_t kVkMenu = 0x12;
constexpr uint32_t kVkLeftMenu = 0xA4;
constexpr uint32_t kVkRightMenu = 0xA5;
constexpr uint32_t kVkLeftWin = 0x5B;
constexpr uint32_t kVkRightWin = 0x5C;

struct Modifiers {
  bool ctrl = false;
  bool alt = false;
  bool shift = false;
  bool meta = false;
};

/// Exact on every modifier, so Ctrl+M and Ctrl+Shift+M never both fire; a
/// hold-to-talk key sets `shift_optional` to ignore Shift, as in the window.
struct Chord {
  Modifiers wanted;
  bool shift_optional = false;
};

constexpr bool IsShiftKey(uint32_t vk) {
  return vk == kVkShift || vk == kVkLeftShift || vk == kVkRightShift;
}

constexpr bool IsCtrlKey(uint32_t vk) {
  return vk == kVkControl || vk == kVkLeftControl || vk == kVkRightControl;
}

constexpr bool IsAltKey(uint32_t vk) {
  return vk == kVkMenu || vk == kVkLeftMenu || vk == kVkRightMenu;
}

constexpr bool IsMetaKey(uint32_t vk) {
  return vk == kVkLeftWin || vk == kVkRightWin;
}

/// A modifier that is the bound key itself is skipped: the keyboard state does
/// not show a key as held until the hook has reported it.
constexpr bool ModifiersMatch(uint32_t vk, const Chord& chord,
                              const Modifiers& held) {
  const Modifiers& wanted = chord.wanted;
  if (!IsCtrlKey(vk) && held.ctrl != wanted.ctrl) return false;
  if (!IsAltKey(vk) && held.alt != wanted.alt) return false;
  if (!IsMetaKey(vk) && held.meta != wanted.meta) return false;
  if (IsShiftKey(vk)) return true;
  if (chord.shift_optional) return held.shift || !wanted.shift;
  return held.shift == wanted.shift;
}

// A key event the hook thread hands to the platform thread in one word.
struct KeyEvent {
  bool down = false;
  Modifiers held;
};

constexpr uint32_t PackKeyEvent(const KeyEvent& event) {
  return (event.down ? 1u : 0u) | (event.held.ctrl ? 2u : 0u) |
         (event.held.alt ? 4u : 0u) | (event.held.shift ? 8u : 0u) |
         (event.held.meta ? 16u : 0u);
}

constexpr KeyEvent UnpackKeyEvent(uint32_t packed) {
  KeyEvent event;
  event.down = (packed & 1u) != 0;
  event.held.ctrl = (packed & 2u) != 0;
  event.held.alt = (packed & 4u) != 0;
  event.held.shift = (packed & 8u) != 0;
  event.held.meta = (packed & 16u) != 0;
  return event;
}

}  // namespace slimm

#endif  // RUNNER_HOTKEY_MODIFIERS_H_
