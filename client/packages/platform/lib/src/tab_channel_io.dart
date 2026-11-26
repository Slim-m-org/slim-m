// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'tab_channel.dart';

TabChannel createTabChannel(String name) => _NoTabs();

class _NoTabs implements TabChannel {
  @override
  Stream<String> get messages => const Stream.empty();

  @override
  void post(String message) {}
}
