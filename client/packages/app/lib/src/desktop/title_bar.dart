// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The custom title bar, decision 0012: one widget, branched once at the
/// place window-control layout actually differs per platform, rather than
/// three separate widgets duplicating the shared drag region and height.
///
/// Ships for Linux only in this change - the only platform with a runner
/// scaffolded at all (`docs/os_backlog/windows_backlog.md`,
/// `docs/os_backlog/macos_backlog.md`) - with the macOS traffic-lights
/// branch and the Windows controls-right branch left as the seam to fill
/// once each platform is actually built, not as dead code nobody can prove
/// works. [DesktopWindowShell] only ever hides the native frame on Linux, so
/// this widget is unreachable on the other two branches in this build.
///
/// The name line shows the Space's name, its connection state, and this
/// build's own version, rather than the static literal `slim-m` this bar
/// shipped with, which never changed no matter which deployment was open or
/// whether it was still reachable. `AppInfoSection` (Personal settings > App)
/// is the one place every platform, with or without this bar, reads the
/// version now.
///
/// Carries no Space menu and no connection dot any more. Design review note
/// 22 had moved both here and hidden `RailHeader` on the frameless desktop to
/// avoid two copies 40px apart; the owner then found a Space menu jammed
/// beside the window quit kebab read as window chrome. So the rail header
/// keeps the Space's identity and its menu on every platform (the Slack and
/// Discord shape), and this bar is the window's own title: name, version,
/// window menu, window controls. The name appears in both places on purpose,
/// once as a window title and once as the Space header - different jobs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart' show appInfoProvider;
import '../widgets/channel_rail_frame.dart' show serverInfoProvider;
import 'close_behavior.dart';
import 'desktop_window_port.dart';
import 'update_chip.dart';
import 'window_maximized_tracker.dart';
import 'window_menu_button.dart';

/// The proposed height, a step on the 4dp grid and a real reduction from a
/// native GNOME header bar's roughly 46-48dp - not yet measured against the
/// owner's own GTK theme; see decision 0012's own "what is unsure" list.
const double titleBarHeight = AppSpacing.s40;

/// macOS's own traffic-light inset, left as a named constant rather than a
/// literal so the seam is easy to find once macOS is actually scaffolded and
/// this number can be checked against a real window.
const double _macOSTrafficLightInset = 78;

class TitleBar extends ConsumerStatefulWidget {
  const TitleBar({
    super.key,
    required this.port,
    required this.platform,
    required this.onRequestClose,
  });

  final DesktopWindowPort port;
  final DesktopPlatform platform;

  /// Routes through [DesktopWindowController.requestClose] rather than
  /// [DesktopWindowPort.hide] directly - the close button drawn here has no
  /// native close/delete-event of its own to trigger the tray-availability
  /// fallback, so it has to ask for the same decision explicitly.
  final Future<void> Function() onRequestClose;

  @override
  ConsumerState<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends ConsumerState<TitleBar> {
  late final WindowMaximizedTracker _maximized = WindowMaximizedTracker(
    widget.port,
  );

  @override
  void dispose() {
    _maximized.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final platform = widget.platform;
    final tokens = Theme.of(context).extension<AppTokens>() ?? AppTokens.dark;
    final isMac = platform == DesktopPlatform.macOS;

    // `/version` needs no session, same as `ClientTooOldGate`'s own read of it.
    final server = ref.watch(serverInfoProvider);
    final appVersion = ref.watch(appInfoProvider).valueOrNull?.version;
    final name = server.valueOrNull?.name ?? 'slim-m';

    // Touch density (rule 2, width not platform) grows the bar to the 44 floor.
    final height = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : titleBarHeight;
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceBase,
          border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
        ),
        child: Row(
          children: [
            if (isMac) const SizedBox(width: _macOSTrafficLightInset),
            const SizedBox(width: AppSpacing.s12),
            AppBrandMark(size: AppSizes.icon20, color: tokens.accent),
            const SizedBox(width: AppSpacing.s8),
            // The one flex child - a second one here split the leftover width and stranded the controls mid-bar.
            Expanded(
              child: _DragRegion(
                port: widget.port,
                onToggleMaximize: _maximized.toggle,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: AppText.ui.copyWith(color: tokens.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (appVersion != null) ...[
                      const SizedBox(width: AppSpacing.s8),
                      Text(
                        'v$appVersion',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.micro.copyWith(
                          color: tokens.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!isMac)
              _WindowControls(
                port: widget.port,
                maximized: _maximized,
                onRequestClose: widget.onRequestClose,
              ),
          ],
        ),
      ),
    );
  }
}

/// Dragging moves the window, and a double-tap toggles maximized the way a
/// native title bar already does for free - `window_manager` gives neither
/// back once the frame is gone. [child], the name and version, sits inside
/// rather than beside this so dragging the text itself also moves the window,
/// the same as a native bar's own title.
class _DragRegion extends StatelessWidget {
  const _DragRegion({
    required this.port,
    required this.onToggleMaximize,
    this.child,
  });

  final DesktopWindowPort port;
  final Future<void> Function() onToggleMaximize;
  final Widget? child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => port.startDragging(),
    onDoubleTap: onToggleMaximize,
    child: SizedBox.expand(child: child),
  );
}

class _WindowControls extends StatelessWidget {
  const _WindowControls({
    required this.port,
    required this.maximized,
    required this.onRequestClose,
  });

  final DesktopWindowPort port;
  final WindowMaximizedTracker maximized;
  final Future<void> Function() onRequestClose;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: maximized, builder: (context, _) => _row());

  Widget _row() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      UpdateChip(port: port),
      WindowMenuButton(port: port),
      const SizedBox(width: AppSpacing.s4),
      AppIconButton(
        icon: AppIcons.windowMinimize,
        semanticLabel: 'Minimize',
        size: AppIconButtonSize.sm,
        onPressed: port.minimize,
      ),
      AppIconButton(
        icon: maximized.maximized
            ? AppIcons.windowRestore
            : AppIcons.windowMaximize,
        semanticLabel: maximized.maximized ? 'Restore' : 'Maximize',
        size: AppIconButtonSize.sm,
        onPressed: maximized.toggle,
      ),
      AppIconButton(
        icon: AppIcons.windowClose,
        semanticLabel: 'Close',
        size: AppIconButtonSize.sm,
        variant: AppIconButtonVariant.dangerGhost,
        onPressed: onRequestClose,
      ),
      const SizedBox(width: AppSpacing.s4),
    ],
  );
}
