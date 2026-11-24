// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'browser_attention.dart';

BrowserAttention createBrowserAttention() => _NoBrowser();

class _NoBrowser implements BrowserAttention {
  @override
  void setUnread(int unread) {}

  @override
  void notify(
    String title,
    String body, {
    required String tag,
    void Function()? onClick,
  }) {}
}
