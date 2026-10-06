// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts [UpdateAvailableBanner] above the app on the layouts that have
/// nowhere else to hang it.
///
/// On desktop the banner already lives in `DesktopChrome`, outside the router
/// entirely, so this hands the child straight back rather than mounting a
/// second one - two banners saying the same thing is worse than none.
///
/// Everywhere else the signed-in shell is the outermost thing there is, which
/// is why this wrapper exists at all. The banner is only ever visible when
/// `update_watch.dart` has actually found something, and only then is its
/// `SafeArea` mounted: a `SafeArea` insets its child by adding padding around
/// it whatever that child's own size is, so one wrapped around an empty banner
/// reserved a full status-bar band of nothing above the rail on every phone.
/// [BannerHostLayout] keeps [child]'s parent chain fixed either way.
/// `bannerVisibleProvider` is the one place that answers "is there really
/// something to show", shared with the banner itself.
///
/// While a banner *is* showing, its own `SafeArea` is what spends the top
/// inset - so [child] gets it stripped from its `MediaQuery`, the same way
/// [Scaffold] itself only removes the body's top padding when there is an
/// `appBar` to have already spent it. Without that, [child]'s own chrome
/// (the rail header, a compact app bar) would still think it was sitting
/// under the status bar and inset a second time underneath the banner.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../desktop/update_available_banner.dart';
import '../desktop/update_watch.dart';
import 'banner_host_layout.dart';

class UpdateBannerHost extends ConsumerWidget {
  const UpdateBannerHost({super.key, required this.child, this.ownsBanner});

  final Widget child;

  /// Whether some outer chrome already mounts the banner. The real answer is
  /// [isDesktopHost], which a test host cannot fake, so it is overridable the
  /// same way the banner's own `restartApplies` is.
  final bool? ownsBanner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ownsBanner ?? isDesktopHost) return child;
    // Kept alive here so polling continues while nothing is showing yet.
    ref.watch(updateWatcherProvider);
    return BannerHostLayout(
      banner: ref.watch(bannerVisibleProvider)
          ? const SafeArea(bottom: false, child: UpdateAvailableBanner())
          : null,
      child: child,
    );
  }
}
