// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a settings or administration screen is presented.
///
/// On a phone it is the whole window, because a phone has room for one thing
/// at a time and taking it over is the point. On a desktop window it floats
/// over the app instead: the rail and the conversation stay where they were,
/// the panel is only as big as it needs to be, and clicking beside it or
/// pressing Escape puts it away. A screen that swallows a monitor to show
/// eight rows is the phone layout wearing a desktop's clothes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_controller.dart';

/// How large the floating panel is allowed to get.
///
/// Tall rather than square: these are lists, and a short wide panel wastes the
/// height a monitor has most of.
const double kModalMaxWidth = 860;
const double kModalMaxHeight = 720;

/// Space settings' own panel, bigger than the shared one: its panes are the
/// busiest in the app (roles, permissions, emoji), see decision 0061.
const double kSpaceSettingsModalMaxWidth = 1100;
const double kSpaceSettingsModalMaxHeight = 800;

/// The dim behind anything modal. One value, so a palette and a settings
/// panel do not darken the app by different amounts.
const Color kScrimColor = Color(0x99000000);

/// The page for a route that is a screen on a phone and a modal on a desktop.
///
/// [child] is the screen itself, unchanged: it keeps its own app bar, which
/// becomes the panel's title bar, so neither the screen nor its tests need to
/// know which of the two it is being shown as.
///
/// One page type at every width: a different page per layout made the
/// navigator replace the route when a window crossed [kCompactWidth], which
/// threw away whatever the screen and any sheet over it were holding.
/// [_ModalSurface] re-lays the same [child] out instead, and the transition
/// follows the width the same way.
Page<void> modalPage(
  BuildContext context,
  Widget child, {
  double maxWidth = kModalMaxWidth,
  double maxHeight = kModalMaxHeight,
}) {
  // The motion spec's one 280ms moment: scrim and panel enter together, the
  // panel rising 16px; the exit runs faster (180ms, ease-in) because leaving
  // should always feel quicker than arriving.
  return CustomTransitionPage<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: kScrimColor,
    barrierLabel: 'Dismiss',
    transitionDuration: AppMotion.reduced(context, AppMotion.slow),
    reverseTransitionDuration: AppMotion.reduced(context, AppMotion.base),
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.sizeOf(context).width < kCompactWidth) {
        return Theme.of(context).pageTransitionsTheme.buildTransitions<void>(
          ModalRoute.of(context)! as PageRoute<void>,
          context,
          animation,
          secondary,
          child,
        );
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.entrance,
        reverseCurve: AppMotion.exit,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - curved.value) * 16),
            child: child,
          ),
          child: child,
        ),
      );
    },
    child: _ModalSurface(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      child: child,
    ),
  );
}

/// The whole window on a phone, the floating panel on a desktop, around one
/// [child] whose state moves with it when the window crosses the width.
class _ModalSurface extends StatefulWidget {
  const _ModalSurface({
    required this.child,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeight;

  @override
  State<_ModalSurface> createState() => _ModalSurfaceState();
}

class _ModalSurfaceState extends State<_ModalSurface> {
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    if (MediaQuery.sizeOf(context).width >= kCompactWidth) {
      return _ModalPanel(
        maxWidth: widget.maxWidth,
        maxHeight: widget.maxHeight,
        child: content,
      );
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ColoredBox(
      color: tokens.surfaceBase,
      child: Column(
        children: [
          const _ActiveCallReminder(),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// A phone-width settings/admin screen takes the whole window, so an active
/// call has nowhere left visible the way it stays dimly in view beside the
/// desktop's floating panel. This is the compact equivalent: a banner
/// (desktop-vs-mobile.md rule 6, status the user did not ask for) that
/// pushes the screen down rather than floats over it, carrying the two
/// controls a call must never leave unreachable, mute and leave.
class _ActiveCallReminder extends ConsumerWidget {
  const _ActiveCallReminder();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceControllerProvider);
    if (voice.channelId == null || voice.connectedAt == null) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(voiceControllerProvider.notifier);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s12,
          AppSpacing.s8,
          AppSpacing.s12,
          0,
        ),
        child: AppCallout(
          tone: AppCalloutTone.accent,
          icon: AppIcons.startCall,
          child: Row(
            children: [
              const Expanded(child: Text('Voice call in progress.')),
              AppIconButton(
                icon: voice.microphoneEnabled ? AppIcons.mic : AppIcons.micOff,
                semanticLabel: voice.microphoneEnabled ? 'Mute' : 'Unmute',
                tooltip: voice.microphoneEnabled ? 'Mute' : 'Unmute',
                size: AppIconButtonSize.touch,
                onPressed: controller.toggleMicrophone,
              ),
              AppIconButton(
                icon: AppIcons.leaveCall,
                semanticLabel: 'Leave call',
                tooltip: 'Leave call',
                variant: AppIconButtonVariant.danger,
                size: AppIconButtonSize.touch,
                onPressed: controller.leave,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModalPanel extends StatelessWidget {
  const _ModalPanel({
    required this.child,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Nothing underneath means this was opened cold, from a pasted URL rather
    // than from inside the app, and a transparent route would show the void
    // behind it. The app's own background stands in for the shell that would
    // otherwise be there.
    final floating = Navigator.of(context).canPop();
    final size = MediaQuery.sizeOf(context);

    // Floating over the dimmed app, the barrier already separates the panel
    // and a shadow completes it. Opened cold there is no barrier and the
    // ground is the panel's own colour, where a hairline border disappears
    // in light theme and the content read as loose text on a blank window;
    // a sunken backdrop separates the two by contrast instead.
    final panel = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: size.height * 0.86 < maxHeight
              ? size.height * 0.86
              : maxHeight,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.card),
            boxShadow: floating ? AppShadows.float : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.card),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceBase,
                border: Border.all(color: tokens.borderSubtle),
                borderRadius: BorderRadius.circular(AppRadii.card),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );

    if (floating) return panel;
    return ColoredBox(color: tokens.surfaceSunken, child: panel);
  }
}
