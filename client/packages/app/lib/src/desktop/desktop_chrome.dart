// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one wrapper `main.dart`'s `appChromeBuilder` adds for the desktop
/// window shell: the frameless title bar, once it is actually active, the
/// first-run tray notice banner, and the update-available banner, all
/// mounted above the routed content rather than deep inside
/// `home_shell.dart`, so every screen gets them with no change to any of
/// them.
///
/// It carries its own [Material]. This sits in `MaterialApp`'s `builder`,
/// above the Navigator, so nothing here has a `Scaffold` - and without a
/// `Material` the title bar and banner inherit the fallback `DefaultTextStyle`,
/// which is a debug colour and an underline. That is the yellow underline the
/// title shipped with. The title bar's own tests wrap it in a `Scaffold` and
/// so never rendered it the way the real chrome does.
///
/// It also carries its own [Overlay]. The title bar's window menu opens through
/// an `OverlayPortal`, and being above the Navigator the title bar has no
/// `Overlay` ancestor of its own: the routed `child`'s Navigator has one, but
/// the title bar is that Navigator's sibling, not its descendant, so the menu
/// found no overlay and rendered as a stray band instead of a menu. This
/// overlay spans the whole window, so the menu opens below the title bar over
/// the content. Theme and media changes reach the content through it the way
/// any inherited value does, because [Overlay.wrap] rebuilds its single entry
/// from the current `child` whenever this widget rebuilds. A plain
/// `initialEntries` list is read once, so the first `MediaQuery` would stay in
/// place for the whole session and a resize or a reduce-motion change would
/// never reach the routed app.
library;

import 'package:flutter/material.dart';

import 'close_behavior.dart';
import 'desktop_window_shell.dart';
import 'first_run_tray_notice_banner.dart';
import 'title_bar.dart';
import 'self_update/self_update_failure_banner.dart';
import 'update_available_banner.dart';
import 'window_resize_frame.dart';

class DesktopChrome extends StatelessWidget {
  const DesktopChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindowShell.active) return child;

    // Transparent so each piece keeps its own surface; the library doc says why a Material and an Overlay are both here.
    return Material(
      type: MaterialType.transparency,
      child: Overlay.wrap(
        // expand: the resize frame below needs the whole window, not just the Column's content size.
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                // frameless is only ever set true on the Linux branch below.
                if (DesktopWindowShell.frameless)
                  TitleBar(
                    port: DesktopWindowShell.port,
                    platform: DesktopPlatform.linux,
                    onRequestClose: DesktopWindowShell.requestClose,
                  ),
                const FirstRunTrayNoticeBanner(),
                // The frameless title bar carries the compact update chip instead.
                if (!DesktopWindowShell.frameless)
                  const UpdateAvailableBanner(),
                const SelfUpdateFailureBanner(),
                Expanded(child: child),
              ],
            ),
            if (DesktopWindowShell.frameless)
              WindowResizeFrame(port: DesktopWindowShell.port),
          ],
        ),
      ),
    );
  }
}
