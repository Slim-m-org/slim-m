// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app-wide incoming-DM-call overlay.
///
/// Mounted once by `appChromeBuilder`, above the routed tree and above every
/// dialog and sheet it can ever hold - not in flow the way this feature
/// first shipped (PR #993, as `IncomingCallBanner`). That in-flow banner
/// cited `docs/design/desktop-vs-mobile.md` rule 6 ("status the user did not
/// ask for -> banner"), which was a misclassification rather than a design
/// this overrides: rule 6's own examples (offline, retrying, a degraded
/// call) are ambient conditions with nothing to decide, while a ring is a
/// time-limited prompt (`spawn_ring_sweep`'s 30-second server timeout) that
/// disappears on its own unless answered or declined - missing it loses the
/// call. That is rule 7 now, the one this overlay follows.
///
/// Two more things a caller-visible position in the app cannot do:
///
/// - **Raise and focus the desktop window.** [IncomingCallOverlay.build]'s
///   `ref.listen` calls [DesktopWindowPort.show] then [DesktopWindowPort.focus]
///   the instant a ring arrives, so it reaches the user even if this app is
///   minimized or sitting behind another window - the literal ask ("in
///   front of everything and take focus, exactly like discord does").
/// - **Actually take the user to the call.** The in-flow banner's own accept
///   only set `dmCallOpenProvider`, which shows nothing unless the DM
///   already happens to be the selected channel - every other place that
///   flag is set (`dm_row.dart`, `rail_call_summary.dart`) pairs it with a
///   route change, and accepting a ring is the same "open this DM's call"
///   action, so it now navigates too, through [routerProvider] rather than
///   `context.go` - this overlay is a sibling of the routed tree, not a
///   descendant of it, so there is no `GoRouter` to find from its own
///   context (the same reason `notification_tap_router.dart` reaches the
///   router that way).
///
/// Reaches every pane and every width the same way `VoiceStripIndicator`
/// reaches an ongoing call elsewhere: a ring is a `VIEW_CHANNEL`-gated live
/// frame for a DM this account is already a party to, so nothing here needs
/// to know which screen is active to be allowed to show it.
///
/// [IncomingCallOverlay.build] wraps its content in its own [Material] and
/// [Overlay] for the identical reason `desktop_chrome.dart`'s own doc states
/// for its title bar: sitting above the Navigator rather than inside it means
/// inheriting neither. `CallDockButton`'s own `Tooltip` needs the `Overlay`
/// to find, and undecorated `Text`/`Icon` need the `Material` or they fall
/// back to the debug style (a yellow underline) instead of the real theme.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../desktop/desktop_window_shell.dart';
import '../providers/dm_call_ring_controller.dart';
import '../../../routing/router.dart';
import 'compact_incoming_call.dart';
import 'expanded_incoming_call.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

class IncomingCallOverlay extends ConsumerWidget {
  const IncomingCallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only a new ring should steal the window back; see this file's own library doc.
    ref.listen(dmCallRingControllerProvider.select((s) => s.visibleIncoming), (
      previous,
      next,
    ) {
      if (previous != null || next == null) return;
      unawaited(_raiseWindow(ref.read(desktopWindowShellProvider)));
    });

    final ring = ref.watch(
      dmCallRingControllerProvider.select((s) => s.visibleIncoming),
    );
    if (ring == null) return const SizedBox.shrink();

    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final content = compact
        ? CompactIncomingCall(ring: ring)
        : Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              minimum: const EdgeInsets.only(top: AppSpacing.s12),
              child: ExpandedIncomingCall(ring: ring),
            ),
          );

    // A Material and an Overlay of its own; see this file's own library doc.
    return Material(
      type: MaterialType.transparency,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) =>
                AppFadeIn(key: ValueKey('ring-${ring.ringId}'), child: content),
          ),
        ],
      ),
    );
  }
}

/// Best-effort: a window call failing here (an unsupported platform call, an
/// odd compositor) must never stop the ring itself from showing, which
/// already happened by the time this runs.
Future<void> _raiseWindow(DesktopWindowShell shell) async {
  if (!shell.active) return;
  try {
    final port = shell.port;
    await port.show();
    await port.focus();
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.voice,
      'Could not bring the window forward for the incoming call',
      error,
      stack,
    );
  }
}
