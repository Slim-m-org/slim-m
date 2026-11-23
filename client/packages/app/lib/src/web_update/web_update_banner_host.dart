// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Docks the "new version" notice into the signed-in shell's banner stack, so
/// it sits in the column with the other banners instead of floating over the
/// offline banner, the topic or the first message line.
///
/// While this is mounted it claims the notice from the top-centre [WebUpdatePill]
/// overlay, which still serves the screens that have no banner stack.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../widgets/banner_host_layout.dart';
import 'web_page.dart';
import 'web_update_watch.dart';

class WebUpdateBannerHost extends ConsumerStatefulWidget {
  const WebUpdateBannerHost({
    super.key,
    required this.child,
    this.onReload = reloadPage,
  });

  final Widget child;
  final VoidCallback onReload;

  @override
  ConsumerState<WebUpdateBannerHost> createState() =>
      _WebUpdateBannerHostState();
}

class _WebUpdateBannerHostState extends ConsumerState<WebUpdateBannerHost> {
  late final _docked = ref.read(webUpdateDockedProvider.notifier);

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (_docked.mounted) _docked.state = true;
    });
  }

  @override
  void dispose() {
    Future.microtask(() {
      if (_docked.mounted) _docked.state = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(webUpdateSupportedProvider)) return widget.child;
    ref.watch(webUpdateWatcherProvider);
    return BannerHostLayout(
      banner: ref.watch(webUpdateAvailableProvider)
          ? SafeArea(
              bottom: false,
              child: _WebUpdateBanner(
                onReload: widget.onReload,
                onDismiss: () =>
                    ref.read(dismissedWebBuildProvider.notifier).state = ref
                        .read(liveWebBuildProvider),
              ),
            )
          : null,
      child: widget.child,
    );
  }
}

class _WebUpdateBanner extends StatelessWidget {
  const _WebUpdateBanner({required this.onReload, required this.onDismiss});

  final VoidCallback onReload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    child: AppCallout(
      tone: AppCalloutTone.accent,
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'New version available',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          AppButton(
            label: 'Reload',
            variant: AppButtonVariant.soft,
            size: AppButtonSize.sm,
            onPressed: onReload,
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Dismiss',
            size: AppIconButtonSize.sm,
            onPressed: onDismiss,
          ),
        ],
      ),
    ),
  );
}
