// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the canvas has dropped its surrounding chrome to show only the surface.
/// Hides the identity strip, channel rail and member pane but keeps the dock, so the call can always be muted or left.
/// Entering switches to the pan tool (restored on exit) because a one-finger drag would otherwise draw; keyed on the channel id like `canvasOpenProvider`, so switching channels leaves it behind.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The channel whose canvas is currently fullscreen, or null.
final canvasFullscreenProvider = StateProvider<String?>((ref) => null);

/// The call tile (a presence key such as `screen:<identity>`) shown filling
/// one channel's canvas under the ink, or null. Keyed on the channel for the
/// reason [canvasFullscreenProvider] is.
final canvasFocusedTileProvider =
    StateProvider<({String channelId, String tileKey})?>((ref) => null);

/// The channel whose fullscreen was entered by focusing a tile, so ending the
/// focus puts the chrome back. In a provider so a remounted pane remembers it.
final canvasFullscreenFromFocusProvider = StateProvider<String?>((ref) => null);

/// The channel whose focused tile was opened by following someone, so the camera there is the fit and not a pan to follow.
final canvasFocusFromFollowProvider = StateProvider<String?>((ref) => null);

/// The tile key [focus] names when it is on [channelId], else null.
String? focusedTileOf(
  ({String channelId, String tileKey})? focus,
  String channelId,
) => focus?.channelId == channelId ? focus!.tileKey : null;

/// Tells [set] which tile is full screen on [channelId], now and on every change.
void mirrorFocusedTile(Ref ref, String channelId, void Function(String?) set) =>
    ref.listen(
      canvasFocusedTileProvider,
      (_, focus) => set(focusedTileOf(focus, channelId)),
      fireImmediately: true,
    );
