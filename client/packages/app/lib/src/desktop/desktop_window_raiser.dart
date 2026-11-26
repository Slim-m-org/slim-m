// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bringing the window forward: for a second launch the runners turned away and for a notification click.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'close_behavior.dart';
import 'desktop_window_port.dart';
import 'linux_window_presenter.dart';
import 'second_instance_channel.dart';

/// Raises the window on demand, with the per-platform steps each host needs.
class DesktopWindowRaiser {
  DesktopWindowRaiser({
    required this.port,
    required LinuxWindowPresenter presenter,
    required SecondInstanceChannel secondInstances,
    required DesktopPlatform? Function() platform,
  }) : _presenter = presenter,
       _secondInstances = secondInstances,
       _platform = platform;

  final DesktopWindowPort port;
  final LinuxWindowPresenter _presenter;
  final SecondInstanceChannel _secondInstances;

  /// Which platform's rules apply; null means the host's own.
  final DesktopPlatform? Function() _platform;

  /// Starts listening for a second launch handing over to this process.
  void register() {
    final platform = currentDesktopPlatform();
    if (platform == null) return;
    if (platform == DesktopPlatform.linux) _presenter.start();
    _secondInstances.register(raise);
  }

  /// Fires each time another launch hands over to this running instance.
  Stream<void> get launches => _secondInstances.launches;

  /// The `slimm://` links later launches handed to this instance.
  Stream<Uri> get links => _secondInstances.links;

  /// Shows the window and restores a minimised one.
  ///
  /// show() un-hides a tray-hidden window; restore() raises a minimised one.
  /// On Linux the window is first presented under the banner's activation token, which Wayland needs.
  /// On Windows restore() also un-maximizes, and show() already brings the
  /// window forward there, so only a minimised window is restored.
  Future<void> raise() async {
    final platform = _platform() ?? currentDesktopPlatform();
    if (currentDesktopPlatform() == null) return;
    try {
      if (platform == DesktopPlatform.linux) await _presenter.present();
      await port.show();
      if (platform != DesktopPlatform.windows || await port.isMinimized()) {
        await port.restore();
      }
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not bring the window to the front',
        error,
        stack,
      );
    }
  }
}
