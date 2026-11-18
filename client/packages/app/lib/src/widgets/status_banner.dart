// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one in-flow status banner: a [StatusPill] with a lifetime its severity decides.
///
/// A banner pushes content and never overlays it (docs/design/desktop-vs-mobile.md,
/// rule 6). It is a compact pill, not a full-width box, so a notice does not
/// take a band of the call stage. Only [BannerSeverity.error] outlives its own
/// moment: it stays until dismissed or until the caller stops building it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'status_pill.dart';

export 'status_pill.dart' show BannerSeverity, kStatusBannerMaxWidth;

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

  /// For a banner bound to a live condition: no timer and no close button, so the caller owns its lifetime.
  final bool sticky;

  /// Outside space that collapses with the banner, so a hidden one reserves none.
  final EdgeInsetsGeometry margin;

  /// The close button, for a caller's test to find inside its own banner.
  static const dismissKey = StatusPill.dismissKey;

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
    if (old.message == widget.message && old.severity == widget.severity) {
      return;
    }
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
    final dismissible =
        !widget.sticky &&
        (widget.severity != BannerSeverity.error || widget.onDismiss != null);
    return AnimatedSize(
      duration: AppMotion.reducedSize(context, AppMotion.base),
      alignment: Alignment.topCenter,
      child: _closed
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: widget.margin,
              child: Align(
                alignment: Alignment.center,
                child: StatusPill(
                  message: widget.message,
                  severity: widget.severity,
                  icon: widget.icon,
                  action: widget.action,
                  onDismiss: dismissible ? _close : null,
                ),
              ),
            ),
    );
  }
}
