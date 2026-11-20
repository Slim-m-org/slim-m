// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a tapped YouTube preview plays. A platform check for capability,
/// never for shape (docs/design/desktop-vs-mobile.md, the one rule): each
/// platform has a different way to put the official player in a message.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import 'native_video_host.dart';

enum VideoHostKind {
  /// In the message itself, through a player the message owns: the web
  /// build's iframe, a phone's webview.
  inline,

  /// In the message itself, through the desktop's one shared player, which
  /// moves to the panel beside the chat when its message leaves the screen.
  desktop,

  /// No player here (no webview library at run time): the system browser.
  external,
}

final nativeVideoHostProvider = Provider<NativeVideoHost>(
  (ref) => NativeVideoHost(),
);

final videoHostKindProvider = FutureProvider<VideoHostKind>((ref) async {
  if (kIsWeb || isAndroidHost || isIOSHost) return VideoHostKind.inline;
  if (!isLinuxHost && !isWindowsHost) return VideoHostKind.external;
  final available = await ref.read(nativeVideoHostProvider).probe();
  return available ? VideoHostKind.desktop : VideoHostKind.external;
});
