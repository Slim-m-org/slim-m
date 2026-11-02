// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one in-flow status banner, and the severity that decides how long it stays.
///
/// A banner pushes content and never overlays it (docs/design/desktop-vs-mobile.md,
/// rule 6). It is a compact pill, not a full-width box, so a notice does not
/// take a band of the call stage. Only [BannerSeverity.error] outlives its own
/// moment: it stays until dismissed or until the caller stops building it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// How a banner looks and how long it stays. Error has no timer by design.
enum BannerSeverity {
  info(Duration(seconds: 6)),
  success(Duration(seconds: 6)),
  warning(Duration(seconds: 15)),
  error(null);

  const BannerSeverity(this.autoDismiss);

  /// Null means the banner stays until dismissed or removed by its caller.
  final Duration? autoDismiss;
}

/// The widest a banner grows, so a long message wraps instead of spanning the stage.
const double kStatusBannerMaxWidth = 560;

class StatusBanner extends StatefulWidget {
  const StatusBanner({
    super.key,
    required this.message,
    this.severity = BannerSeverity.info,
    this.icon,
    this.action,
    this.onDismiss,
    this.sticky = false,
    this.margin = EdgeInsets.zero,
  });

  final String message;
  final BannerSeverity severity;
  final IconData? icon;

  /// One compact control that sits before the close button.
  final Widget? action;

  /// Called once the banner closes, by the close button or its timer.
  final VoidCallback? onDismiss;

  /// Skips the severity timer, for a banner that is the only way back to something.
  final bool sticky;

  /// Outside space that collapses with the banner, so a hidden one reserves none.
  final EdgeInsetsGeometry margin;

  @override
  State<StatusBanner> createState() => _StatusBannerState();
}

class _StatusBannerState extends State<StatusBanner> {
  Timer? _timer;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(StatusBanner old) {
    super.didUpdateWidget(old);
    if (old.message == widget.message && old.severity == widget.severity)
      return;
    _closed = false;
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    final after = widget.sticky ? null : widget.severity.autoDismiss;
    if (after != null) _timer = Timer(after, _close);
  }

  void _close() {
    _timer?.cancel();
    if (!mounted || _closed) return;
    setState(() => _closed = true);
    widget.onDismiss?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (icon, tone) = switch (widget.severity) {
      BannerSeverity.info => (AppIcons.info, tokens.textSecondary),
      BannerSeverity.success => (AppIcons.check, tokens.accent),
      BannerSeverity.warning => (AppIcons.warning, tokens.warnText),
      BannerSeverity.error => (AppIcons.failed, tokens.dangerText),
    };
    final border = switch (widget.severity) {
      BannerSeverity.info => tokens.borderSubtle,
      BannerSeverity.success => tokens.accentFill,
      BannerSeverity.warning => tokens.warnText,
      BannerSeverity.error => tokens.dangerBorder,
    };
    final dismissible =
        widget.severity != BannerSeverity.error || widget.onDismiss != null;

    final pill = Container(
      constraints: const BoxConstraints(maxWidth: kStatusBannerMaxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          Icon(widget.icon ?? icon, size: AppSizes.icon16, color: tone),
          Flexible(
            child: Text(
              widget.message,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ),
          if (widget.action != null) widget.action!,
          if (dismissible)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Dismiss',
              size: AppIconButtonSize.sm,
              onPressed: _close,
            ),
        ],
      ),
    );

    return AnimatedSize(
      duration: AppMotion.reduced(context, AppMotion.base),
      alignment: Alignment.topCenter,
      child: _closed
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: widget.margin,
              child: Align(
                alignment: Alignment.center,
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: pill,
                ),
              ),
            ),
    );
  }
}
