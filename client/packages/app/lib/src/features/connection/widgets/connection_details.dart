// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How this device reaches the Space, leg by leg: a popover on a wide window,
/// a sheet on a compact one (`docs/design/desktop-vs-mobile.md`, rule 3).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/anchored_popover_or_sheet.dart';
import '../connection_route.dart';
import '../providers/connection_report.dart';

const double _popoverWidth = 320;

Future<void> showConnectionDetails(BuildContext anchor) =>
    showAnchoredPopoverOrSheet<void>(
      anchor,
      semanticLabel: 'Connection details',
      sheetBuilder: (_) => const Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.s16,
          AppSpacing.s8,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: ConnectionDetailsBody(),
      ),
      popoverBuilder: (_) => const AppMenu(
        width: _popoverWidth,
        padding: EdgeInsets.all(AppSpacing.s12),
        children: [ConnectionDetailsBody()],
      ),
    );

/// The legs, the concern when there is one, and how fresh it all is; measures the server leg on open.
class ConnectionDetailsBody extends ConsumerStatefulWidget {
  const ConnectionDetailsBody({super.key, this.inline = false});

  /// True inside a settings row, which names it already and is on screen
  /// whenever the pane is, so showing it costs no request.
  final bool inline;

  @override
  ConsumerState<ConnectionDetailsBody> createState() =>
      _ConnectionDetailsBodyState();
}

class _ConnectionDetailsBodyState extends ConsumerState<ConnectionDetailsBody> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (!widget.inline) {
      unawaited(ref.read(connectionStatusProvider.notifier).refresh());
    }
    // Keeps "Checked N s ago" honest while it stays open.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final status = ref.watch(connectionStatusProvider);
    final checked = checkedLine(status.report.checkedAt, DateTime.now());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: widget.inline ? AppSpacing.s4 : AppSpacing.s8,
      children: [
        if (!widget.inline)
          Semantics(
            header: true,
            child: Text(
              'Connection',
              style: AppText.ui.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
        for (final leg in connectionLegs(status.report)) _LegLine(leg),
        if (status.concern case final concern?) _Concern(concern),
        if (checked != null)
          Text(
            checked,
            style: AppText.micro.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
  }
}

/// One leg: its name, then how it travels and how long a round trip takes.
class _LegLine extends StatelessWidget {
  const _LegLine(this.leg);

  final ConnectionLeg leg;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      container: true,
      label: '${leg.label}: ${leg.value}',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.s12,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                leg.label,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
            Expanded(
              child: Text(
                leg.value,
                style: AppText.caption.copyWith(
                  color: leg.warn ? tokens.warnText : tokens.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Concern extends StatelessWidget {
  const _Concern(this.concern);

  final RouteConcern concern;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s8,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            AppIcons.warning,
            size: AppSizes.icon16,
            color: tokens.warnText,
          ),
        ),
        Expanded(
          child: Text(
            concern.message,
            style: AppText.caption.copyWith(color: tokens.warnText),
          ),
        ),
      ],
    );
  }
}
