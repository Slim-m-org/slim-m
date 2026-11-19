// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which monitor a Linux portal share covers, followed by name across monitor layout changes.
/// The portal's position holds only in the layout it was reported in; decision 0096 says why.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show OverlayMonitor;
import 'package:slimm_rtc/rtc.dart' show PortalMonitor;

class PortalScreen {
  PortalScreen(this._ask);

  final Future<PortalMonitor?> Function() _ask;
  PortalMonitor? _reported;
  String? _name;
  bool _moved = false;

  /// The shared monitor's index in [monitors], the layout now, or null when the portal did not say or it cannot be found.
  Future<int?> find(List<OverlayMonitor> monitors) async {
    if (!await _current()) return null;
    if (!_moved) return _pinAt(monitors);
    final name = _name;
    final named = [
      for (var i = 0; i < monitors.length; i++)
        if (name != null && monitors[i].name == name) i,
    ];
    if (named.length == 1) return named.single;
    AppLog.info(
      LogTag.platform,
      'The shared screen (${name ?? 'no name'}) is not one monitor of the new layout; guessing it by shape',
    );
    return null;
  }

  /// Called with the layout [before] a change, while the portal's position still names the shared monitor in it.
  Future<void> layoutChanging(List<OverlayMonitor> before) async {
    if (await _current() && !_moved) _pinAt(before);
    _moved = true;
  }

  /// The share ended; the next one reports its own monitor.
  void forget() {
    _reported = null;
    _name = null;
    _moved = false;
  }

  /// Asks the portal again; a different answer is a different share, which starts over.
  Future<bool> _current() async {
    final portal = await _ask();
    if (portal != _reported) {
      _reported = portal;
      _name = null;
      _moved = false;
    }
    return portal != null;
  }

  int? _pinAt(List<OverlayMonitor> monitors) {
    final portal = _reported!;
    final at = monitors.indexWhere((m) => m.x == portal.x && m.y == portal.y);
    if (at < 0) return null;
    _name ??= monitors[at].name;
    return at;
  }
}
