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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../desktop/desktop_window_shell.dart';
import '../providers/dm_call_ring_controller.dart';
import '../providers/user_profiles.dart';
import '../routing/router.dart';
import '../screens/voice_call_controls.dart' show CallDockButton;
import 'floating_dock_card.dart';
import 'user_avatar.dart';

part 'incoming_call_overlay_surfaces.dart';

class IncomingCallOverlay extends ConsumerWidget {
  const IncomingCallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only a new ring should steal the window back; see this file's own library doc.
    ref.listen(dmCallRingControllerProvider.select((s) => s.visibleIncoming), (
      previous,
      next,
    ) {
      if (previous == null && next != null) unawaited(_raiseWindow());
    });

    final ring = ref.watch(
      dmCallRingControllerProvider.select((s) => s.visibleIncoming),
    );
    if (ring == null) return const SizedBox.shrink();

    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final content = compact
        ? _CompactIncomingCall(ring: ring)
        : Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              minimum: const EdgeInsets.only(top: AppSpacing.s12),
              child: _ExpandedIncomingCall(ring: ring),
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
Future<void> _raiseWindow() async {
  if (!DesktopWindowShell.active) return;
  try {
    final port = DesktopWindowShell.port;
    await port.show();
    await port.focus();
  } catch (_) {
    // Best-effort; see this function's own doc.
  }
}

void _acceptRing(WidgetRef ref, IncomingDmCallRing ring) =>
    unawaited(ref.read(dmCallRingControllerProvider.notifier).accept(ring));

void _declineRing(WidgetRef ref, IncomingDmCallRing ring) =>
    unawaited(ref.read(dmCallRingControllerProvider.notifier).decline(ring));

/// Escape declines rather than merely dismissing to a lesser state: the ring
/// keeps going on the caller's own side either way (`dm_call_ring_controller.dart`'s
/// own doc), so silently hiding this without telling the caller would leave
/// them waiting on an answer that already happened.
///
/// Requests focus explicitly on mount rather than relying on `autofocus`:
/// the routed tree's own page already holds focus in its `ModalRoute`'s own
/// scope by the time a ring can ever arrive, and passive `autofocus` only
/// claims a node when its enclosing scope holds none at all - it defers
/// rather than contesting a focus a sibling scope already has. An explicit
/// [FocusNode.requestFocus] call has no such deference, which is exactly
/// what "steal focus" means here - with no tab stop needed to reach it first.
class _RingShortcuts extends ConsumerStatefulWidget {
  const _RingShortcuts({required this.ring, required this.child});

  final IncomingDmCallRing ring;
  final Widget child;

  @override
  ConsumerState<_RingShortcuts> createState() => _RingShortcutsState();
}

class _RingShortcutsState extends ConsumerState<_RingShortcuts> {
  final _focusNode = FocusNode(debugLabel: 'IncomingCallOverlay');

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _declineRing(ref, widget.ring),
    },
    child: Focus(focusNode: _focusNode, child: widget.child),
  );
}
