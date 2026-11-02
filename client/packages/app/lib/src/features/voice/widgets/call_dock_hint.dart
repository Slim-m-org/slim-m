// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A short bubble over a dock control, shown once: which microphone a call
/// opened, and that the share button holds options on a phone.
///
/// The bubble floats in the overlay and ignores pointers, so it never changes
/// the dock's size, what its hairlines measure, or who gets a tap. It names what it is
/// about in words, so it carries no information a tooltip would have held
/// (docs/design/desktop-vs-mobile.md, never a tooltip on touch).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../providers/call_dock_hint.dart';

/// How long a hint stays before it is remembered as seen.
const dockHintDuration = Duration(seconds: 8);

class DockHintAnchor extends ConsumerStatefulWidget {
  const DockHintAnchor({
    super.key,
    required this.target,
    required this.child,
    this.enabled = true,
  });

  final DockHintTarget target;
  final Widget child;

  /// False while the control it points at cannot be used, so it is never pointed at.
  final bool enabled;

  @override
  ConsumerState<DockHintAnchor> createState() => _DockHintAnchorState();
}

class _DockHintAnchorState extends ConsumerState<DockHintAnchor> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  Timer? _timer;
  DockHint? _hint;
  DockHint? _shown;
  bool _touch = false;
  bool _started = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final touch = AppTouchTargets.of(context);
    if (_started && touch == _touch) return;
    _started = true;
    _touch = touch;
    unawaited(_resolve());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final generation = ++_generation;
    final hint = await resolveDockHint(container, touch: _touch);
    if (mounted && generation == _generation) setState(() => _hint = hint);
  }

  void _sync(DockHint? wanted) {
    if (wanted?.seenKey == _shown?.seenKey &&
        wanted?.seenValue == _shown?.seenValue) {
      return;
    }
    _timer?.cancel();
    _shown = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_shown == null) {
        if (_portal.isShowing) _portal.hide();
        return;
      }
      if (!_portal.isShowing) _portal.show();
    });
    if (wanted != null) {
      _timer = Timer(dockHintDuration, () => unawaited(_dismiss(wanted)));
    }
  }

  Future<void> _dismiss(DockHint hint) async {
    final prefs = await ref.read(preferencesProvider.future);
    await hint.remember(prefs);
    if (!mounted) return;
    ref.read(dockHintEpochProvider.notifier).state++;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dockHintEpochProvider, (_, _) => unawaited(_resolve()));
    final hint = widget.enabled ? _hint : null;
    _sync(hint?.target == widget.target ? hint : null);
    final left = widget.target == DockHintTarget.mic;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _link,
        targetAnchor: left ? Alignment.topLeft : Alignment.topRight,
        followerAnchor: left ? Alignment.bottomLeft : Alignment.bottomRight,
        offset: const Offset(0, -AppSpacing.s8),
        child: Align(
          alignment: left ? Alignment.bottomLeft : Alignment.bottomRight,
          child: _Bubble(text: _shown?.text ?? ''),
        ),
      ),
      child: CompositedTransformTarget(link: _link, child: widget.child),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: tokens.borderSubtle),
              boxShadow: AppShadows.canvasTile,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s12,
                vertical: AppSpacing.s8,
              ),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
