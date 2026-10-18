// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Builds and rebuilds the tray icon's context menu, and routes its items to
/// the window port, the running call, the caller's own presence, or the
/// settings route.
///
/// This is the one file in the desktop shell that talks to `tray_manager`'s
/// real singleton directly rather than through a seam: the icon and menu are
/// themselves a native singleton resource the same way `window_manager`'s
/// window is, and `tray_menu_actions.dart` already carries the one piece of
/// this that is worth testing headlessly - which rows appear at all.
///
/// `tray_manager` 0.5.3 dispatches a menu click by looping over its
/// registered [TrayListener]s and calling `menuItem.onClick` from inside that
/// loop; with zero listeners registered, the loop body never runs and every
/// `onClick` callback below is dead code. Mixing in [TrayListener] here (and
/// registering/removing `this`) exists purely to give that loop one
/// iteration. `onClick` stays the authoritative handler; the mixin's own
/// `onTrayMenuItemClick` hook is left at its default no-op so a click is not
/// handled twice.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart' show AppPresence;
import 'package:slimm_platform/platform.dart' show isWindowsHost;
import 'package:slimm_rtc/rtc.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../features/accounts/providers/account_host.dart';
import '../../features/members/providers/presence_controller.dart';
import '../../features/members/providers/presence_view.dart';
import '../../providers/providers.dart';
import '../../features/voice/providers/voice_controller.dart';
import '../../features/voice/providers/voice_flags.dart';
import '../../routing/router.dart';
import '../../routing/routes.dart';
import '../../features/members/widgets/presence_menu.dart' show presenceOptions;
import '../../widgets/run_guarded.dart';
import '../desktop_window_port.dart';
import '../desktop_window_shell.dart' show DesktopWindowShell;
import 'tray_menu_actions.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const trayIconAssetPath = 'assets/icons/tray_icon.png';

/// tray_manager's Windows plugin loads the icon with LoadImage, which reads only .ico.
const trayIconWindowsAssetPath = 'assets/icons/tray_icon.ico';

String trayIconPathFor({required bool windows}) =>
    windows ? trayIconWindowsAssetPath : trayIconAssetPath;

class DesktopTrayController with TrayListener {
  DesktopTrayController({
    required this.port,
    required this.container,
    this.host,
  });

  final DesktopWindowPort port;

  /// The container used when there is no [host] to say which account is current.
  final ProviderContainer container;
  final AccountHost? host;

  /// Call controls act on the account in a call, the rest on the one on screen.
  ProviderContainer get _callContainer =>
      host?.callRuntime?.container ?? _screenContainer;
  ProviderContainer get _screenContainer =>
      host?.active?.container ?? container;

  ProviderContainer? _boundCall;
  ProviderContainer? _boundScreen;

  ProviderSubscription<(VoiceSessionState, bool, bool)>? _voiceSubscription;
  ProviderSubscription<AppPresence>? _presenceSubscription;

  Future<void> start() async {
    TrayManager.instance.addListener(this);
    await _setIcon();
    await _setToolTip();
    await _rebuildMenu();
    _bind();
    host?.addListener(_onHostChanged);
  }

  void _onHostChanged() {
    if (_callContainer == _boundCall && _screenContainer == _boundScreen) {
      return;
    }
    _bind();
    unawaited(_rebuildMenu());
  }

  void _bind() {
    _voiceSubscription?.close();
    _presenceSubscription?.close();
    _boundCall = _callContainer;
    _boundScreen = _screenContainer;
    // Selected to the three flags this menu draws, so a roster change never fires it.
    _voiceSubscription = _boundCall!.listen(
      voiceFlagsProvider.select(
        (f) => (f.state, f.microphoneEnabled, f.deafened),
      ),
      (previous, next) => _rebuildMenu(),
    );
    _presenceSubscription = _boundScreen!.listen<AppPresence>(
      ownPresenceProvider,
      (previous, next) {
        if (previous == next) return;
        _rebuildMenu();
      },
    );
  }

  void dispose() {
    host?.removeListener(_onHostChanged);
    TrayManager.instance.removeListener(this);
    _voiceSubscription?.close();
    _presenceSubscription?.close();
  }

  /// `tray_manager`'s Linux backend (`tray_manager_plugin.cc`) never handles
  /// the `setToolTip` platform channel call - only `setTitle`, which draws a
  /// persistent label in the panel rather than a hover tip - so this threw a
  /// `MissingPluginException` on every Linux launch. Unguarded, that
  /// exception aborted [start] before [_rebuildMenu] ever ran, leaving the
  /// tray icon bound to the empty placeholder menu the plugin's own `setIcon`
  /// handler creates: an icon with no options, for the rest of the session.
  /// A missing hover tip is a fair trade for a menu that actually works.
  Future<void> _setToolTip() async {
    try {
      await TrayManager.instance.setToolTip('slim-m');
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.platform,
        'Best-effort: see the doc comment above',
        error,
        stack,
      );
    }
  }

  /// Contained for the reason [_setToolTip] is, and it was not: the guard was
  /// written for the one call known to fail, when the thing worth protecting
  /// is [_rebuildMenu] running at all. Anything that throws ahead of it leaves
  /// the icon on the plugin's own empty placeholder menu for the session -
  /// which is the bug as a person meets it, whichever call actually threw.
  Future<void> _setIcon() async {
    try {
      await TrayManager.instance.setIcon(
        trayIconPathFor(windows: isWindowsHost),
      );
    } catch (error, stack) {
      // A default icon is a worse tray; a menu-less one is no tray at all.
      AppLog.warning(
        LogTag.platform,
        'tray icon failed, continuing to the menu',
        error: error,
        stack: stack,
      );
    }
  }

  /// Never throws: a menu that cannot be built must not take the rest of
  /// [start] with it, and this also runs from two provider listeners where
  /// nothing is awaiting it to catch anything.
  Future<void> _rebuildMenu() async {
    try {
      await _setContextMenu();
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'could not build the context menu',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _setContextMenu() async {
    final voiceFlags = _callContainer.read(voiceFlagsProvider);
    final inCall = voiceFlags.state == VoiceSessionState.connected;
    final selected = _screenContainer.read(ownPresenceProvider);
    final items = trayMenuActions(inCall: inCall)
        .map((kind) => _itemFor(kind, voiceFlags, selected))
        .toList(growable: false);
    await TrayManager.instance.setContextMenu(Menu(items: items));
  }

  MenuItem _itemFor(
    TrayMenuActionKind kind,
    VoiceFlags voiceState,
    AppPresence selected,
  ) => switch (kind) {
    TrayMenuActionKind.showHide => MenuItem(
      label: 'Show/Hide slim-m',
      onClick: (_) => _toggleVisibility(),
    ),
    TrayMenuActionKind.presenceStatus => MenuItem.submenu(
      label: 'Status',
      submenu: Menu(
        items: [
          for (final (visibility, label, presence) in presenceOptions)
            MenuItem.checkbox(
              label: label,
              checked: presence == selected,
              onClick: (_) => _setPresence(visibility),
            ),
        ],
      ),
    ),
    TrayMenuActionKind.muteMicrophone => MenuItem(
      label: voiceState.microphoneEnabled
          ? 'Mute microphone'
          : 'Unmute microphone',
      onClick: (_) => _callContainer
          .read(voiceControllerProvider.notifier)
          .toggleMicrophone(),
    ),
    TrayMenuActionKind.toggleDeafen => MenuItem(
      label: voiceState.deafened ? 'Undeafen' : 'Deafen',
      onClick: (_) =>
          _callContainer.read(voiceControllerProvider.notifier).toggleDeafen(),
    ),
    TrayMenuActionKind.leaveCall => MenuItem(
      label: 'Leave call',
      onClick: (_) =>
          _callContainer.read(voiceControllerProvider.notifier).leave(),
    ),
    TrayMenuActionKind.settings => MenuItem(
      label: 'Preferences',
      onClick: (_) => _openSettings(),
    ),
    TrayMenuActionKind.quit => MenuItem(
      label: 'Quit slim-m',
      onClick: (_) => unawaited(DesktopWindowShell.quit(port)),
    ),
  };

  Future<void> _toggleVisibility() async {
    if (await port.isVisible()) {
      await port.hide();
    } else {
      await port.show();
    }
  }

  Future<void> _openSettings() async {
    await port.show();
    unawaited(
      _screenContainer.read(routerProvider).push(Routes.personalSettings),
    );
  }

  /// Sets the caller's own visibility from the tray, echoing it locally and
  /// putting that echo back on a refusal - the same shape as the rail
  /// footer's own status menu, minus its widget-bound error state: the tray
  /// has no surface to render a failure on, so a refusal is corrected
  /// silently, the way a failed presence refresh already is elsewhere.
  Future<void> _setPresence(api.PresenceVisibility visibility) async {
    final screen = _screenContainer;
    final notifier = screen.read(presenceVisibilityDisplayProvider.notifier);
    final previous = notifier.state;
    notifier.state = visibility;
    final failure = await runGuarded(
      whatFailed: 'update your status',
      action: () => screen.read(apiProvider).setPresenceVisibility(visibility),
    );
    if (failure != null) notifier.state = previous;
  }
}
