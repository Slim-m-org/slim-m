// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a pasted image, on the platforms that let a Flutter app see one
/// at all.
///
/// `package:flutter/services.dart`'s own [Clipboard] carries plain text
/// only; there is no image variant on any target this client ships to,
/// short of a browser API or a native plugin. Confirmed against the engine
/// itself, not just the Dart docs: `EditableText.pasteText()` only ever
/// calls `Clipboard.getData(Clipboard.kTextPlain)`, `FlutterPlatformPlugin`'s
/// `getClipboardData:` on iOS reads `pasteboard.string` alone with no image
/// branch, and `FlutterTextInputPlugin`'s `canPerformAction:` deliberately
/// returns `hasStrings` for the system Paste action - "Forbid pasting
/// images, memojis, or other non-string content," in the engine's own
/// comment. So the system Paste item is a dead end on every platform through
/// Flutter's own text-editing path, not merely unimplemented on this one.
///
/// [startClipboardImagePaste]/[stopClipboardImagePaste] are the event-driven
/// half of this seam: a real, working `paste` DOM listener on web, and on
/// iOS a real, prompt-free route of its own - `ClipboardPasteBridge.m`
/// swizzles Flutter's private text input view so the long-press edit menu's
/// Paste item works for an image directly, and hands the bytes to this pair
/// rather than through Dart polling anything. A no-op on Android, Linux,
/// Windows and macOS, so Ctrl+V there keeps its ordinary text-only
/// behaviour rather than silently swallowing a keystroke nothing backs.
///
/// [hasClipboardImage]/[readClipboardImage] are the older poll-and-tap
/// half, real on iOS, Android and Linux desktop through a hand-written
/// platform channel (see `composer_clipboard_image_stub.dart`) and a no-op
/// on web, Windows and macOS. A composer offers a "Paste image" action
/// rather than a keystroke there, because none of the three has an
/// equivalent of iOS's edit-menu swizzle: Android's `ClipboardManager`
/// reaches a Flutter app only when deliberately invoked, and Linux has no
/// framework hook into GTK's own context menu the way the swizzle reaches
/// iOS's. It is offered unconditionally on every platform the channel
/// answers whenever the clipboard holds an image - see
/// `composer_clipboard_paste.dart`'s doc comment for why the swizzle above
/// installing is not evidence it is redundant.
library;

export 'composer_clipboard_image_stub.dart'
    if (dart.library.js_interop) 'composer_clipboard_image_web.dart';
