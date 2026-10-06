// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title bar's app-level menu: update when one is waiting, restart, and
/// the one guaranteed quit path, reachable with no tray host at all.
///
/// `close_behavior.dart`'s [CloseAction.minimizeToTaskbar] exists so a
/// Linux desktop with no `org.kde.StatusNotifierWatcher` never gets a
/// window hidden with nothing to bring it back - but the only place a real
/// quit ever lived was the tray menu's own "Quit slim-m" item, and that
/// menu does not exist without a tray host either. The X button and Alt+F4
/// both resolve to minimise on such a desktop, forever, with no affordance
/// anywhere in the running app that actually ends the process.
///
/// This button is unconditional, mounted regardless of whether a tray is
/// reachable right now: probing live and hiding the button when a tray is
/// found would only move the trap rather than close it, since the probe
/// answers differently across the session (decision 0012's own note that a
/// tray host can appear or disappear mid-session) and a control that
/// vanishes out from under a keyboard user mid-navigation is its own bug.
///
/// Update appears only while `update_watch.dart` knows a newer version, so
/// it never sits there doing nothing; `update_action.dart` says what it does.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../widgets/context_menu_focus.dart';
import 'desktop_window_port.dart';
import 'self_update/self_update_controller.dart';
import 'update_action.dart';
import 'update_check.dart';
import 'update_watch.dart';

export 'update_action.dart' show UpdateMenuAction, updateMenuAction;

class WindowMenuButton extends ConsumerStatefulWidget {
  const WindowMenuButton({super.key, required this.port});

  final DesktopWindowPort port;

  @override
  ConsumerState<WindowMenuButton> createState() => _WindowMenuButtonState();
}

class _WindowMenuButtonState extends ConsumerState<WindowMenuButton> {
  final _controller = OverlayPortalController();
  final _link = LayerLink();
  // The kebab shares the menu's group so a click on it is not an outside tap.
  final _group = Object();

  @override
  Widget build(BuildContext context) {
    final update = ref.watch(inSessionUpdateProvider);
    final action = ref.watch(updateActionProvider);
    final installing = ref.watch(selfUpdateInstallingProvider);
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _controller,
        // Positioned so the follower sizes to its content, not the screen.
        overlayChildBuilder: (context) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            // A right-edge trigger opens leftward, or it runs off the window.
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 4),
            child: TapRegion(
              groupId: _group,
              onTapOutside: (_) => _controller.hide(),
              // Escape closes it and Tab reaches every item once open.
              child: ContextMenuKeyboardScope(
                onDismiss: _controller.hide,
                child: AppMenu(
                  width: 220,
                  children: [
                    if (update != null && action != null)
                      _updateItem(
                        update,
                        action: action,
                        installing: installing,
                      ),
                    if (widget.port.canRelaunch)
                      AppMenuItem(
                        label: 'Restart slim-m',
                        leading: AppIcons.retry,
                        onTap: () {
                          _controller.hide();
                          unawaited(widget.port.relaunch());
                        },
                      ),
                    AppMenuItem(
                      label: 'Quit slim-m',
                      leading: AppIcons.windowQuit,
                      onTap: () {
                        _controller.hide();
                        widget.port.destroy();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        child: TapRegion(
          groupId: _group,
          child: AppIconButton(
            icon: AppIcons.moreVertical,
            semanticLabel: 'Window menu',
            size: AppIconButtonSize.sm,
            onPressed: _controller.toggle,
          ),
        ),
      ),
    );
  }

  Widget _updateItem(
    ClientUpdate update, {
    required UpdateMenuAction action,
    required bool installing,
  }) {
    return AppMenuItem(
      label: updateActionLabel(update, action, installing: installing),
      leading: AppIcons.download,
      onTap: installing
          ? null
          : () {
              _controller.hide();
              unawaited(
                runUpdateAction(
                  ref,
                  port: widget.port,
                  update: update,
                  action: action,
                  context: context,
                  isMounted: () => mounted,
                ),
              );
            },
    );
  }
}
