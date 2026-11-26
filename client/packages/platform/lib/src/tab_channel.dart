// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message line between the tabs of one browser profile; a no-op where one process is the whole session.
library;

import 'tab_channel_io.dart' if (dart.library.js_interop) 'tab_channel_web.dart'
    as impl;

abstract interface class TabChannel {
  /// The channel every tab of this profile shares under [name].
  factory TabChannel(String name) => impl.createTabChannel(name);

  /// What the other tabs post; a tab never hears itself.
  Stream<String> get messages;

  void post(String message);
}
