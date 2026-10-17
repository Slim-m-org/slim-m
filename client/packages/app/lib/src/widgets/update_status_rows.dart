// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What Settings > About says about the build and its updates: the app's name
/// and version, whether an update is waiting, and a way to ask again without
/// relaunching.
///
/// Both numbers, deliberately. The owner's complaint that led to decision
/// 0025 was that a prompt naming one version could not be triaged from a
/// screenshot - "0.79.0 is available" says nothing about whether the person
/// reporting it is one release behind or nine. "0.79.0 is available. You have
/// 0.78.0." answers that in the same glance.
///
/// The manual check runs the same [checkForClientUpdate] the splash and the
/// six-hourly watcher run, and writes the same [inSessionUpdateProvider], so
/// there is one place a find lives and no second polling path. It differs from
/// the watcher in one way on purpose: it ignores the dismissal the banner
/// records. Somebody who presses "Check for updates" is asking, and answering
/// "you are up to date" because they waved the banner away earlier would be a
/// lie.
///
/// Absent entirely where the check cannot run - iOS has TestFlight, a store
/// build updates itself, and `SLIMM_NO_UPDATE_CHECK` switches the whole thing
/// off - because a control that can never find anything is worse than no
/// control. That is the same [updateWatchShouldRun] the watcher gates on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_design_system/design_system.dart';

import '../desktop/startup_screen.dart';
import '../desktop/update_check.dart';
import '../desktop/update_watch.dart';
import '../providers/providers.dart';

class UpdateStatusRows extends ConsumerStatefulWidget {
  const UpdateStatusRows({
    super.key,
    this.check = checkForClientUpdate,
    this.shouldRun = updateWatchShouldRun,
  });

  /// Injected the way [UpdateWatcher] takes its own: the real one reaches the
  /// network, which a widget test must not.
  final CheckForClientUpdate check;

  /// Whether this build ever checks at all; see the library doc.
  final bool Function() shouldRun;

  @override
  ConsumerState<UpdateStatusRows> createState() => _UpdateStatusRowsState();
}

class _UpdateStatusRowsState extends ConsumerState<UpdateStatusRows> {
  bool _checking = false;

  /// What the last manual check found, shown until the next one. Null before
  /// any check, and cleared while one is running so a stale answer cannot sit
  /// under a spinner.
  String? _result;

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    try {
      final info = await ref.read(appInfoProvider.future);
      final update = await widget.check(currentVersion: info.version);
      if (!mounted) return;
      if (update != null) {
        ref.read(inSessionUpdateProvider.notifier).state = update;
      }
      setState(() {
        _result = update == null
            ? 'You are on the latest version.'
            : 'Version ${update.version} is available.';
      });
    } catch (_) {
      // Best-effort, like every path in decision 0025: no error surfaced.
      if (mounted) setState(() => _result = 'Could not check just now.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _identity(
    AppTokens tokens,
    AsyncValue<PackageInfo> info,
    List<String> status,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text(
          'slim-m',
          style: AppText.body.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        Text(
          info.when(
            data: _versionLabel,
            loading: () => 'Loading…',
            error: (e, _) => 'Version unknown',
          ),
          style: AppText.caption.copyWith(
            color: tokens.textSecondary,
            fontFamily: AppFonts.mono,
          ),
        ),
        for (final line in status)
          Text(
            line,
            style: AppText.caption.copyWith(color: tokens.textPrimary),
          ),
      ],
    );
  }

  String _versionLabel(PackageInfo i) => i.buildNumber.isEmpty
      ? 'Version ${i.version}'
      : 'Version ${i.version} (${i.buildNumber})';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final update = widget.shouldRun()
        ? ref.watch(inSessionUpdateProvider)
        : null;
    final info = ref.watch(appInfoProvider);
    final installed = info.valueOrNull?.version;
    final status = [
      if (update != null && installed != null)
        '${update.version} is available. You have $installed. '
            '${updateActionHint(update.format)}',
      ?_result,
    ];

    final identity = _identity(tokens, info, status);
    final button = widget.shouldRun()
        ? AppButton(
            label: _checking ? 'Checking…' : 'Check for updates',
            onPressed: _checking ? null : () => unawaited(_checkNow()),
          )
        : null;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s20),
      child: LayoutBuilder(
        builder: (context, box) {
          // Below this the button would squeeze the name out of its own row.
          final stacked = box.maxWidth < 420;
          final head = Row(
            spacing: AppSpacing.s16,
            children: [
              const AppIconTile(),
              Expanded(child: identity),
              if (button != null && !stacked) button,
            ],
          );
          if (button == null || !stacked) return head;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AppSpacing.s16,
            children: [head, button],
          );
        },
      ),
    );
  }
}

/// The app's mark: three grey dots and an accent square on a dark tile.
class AppIconTile extends StatelessWidget {
  const AppIconTile({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    Widget dot(double x, double y) => Positioned(
      left: x,
      top: y,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tokens.textSecondary,
        ),
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          border: Border.all(color: tokens.borderStrong),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Stack(
          children: [
            dot(11, 11),
            dot(20, 11),
            dot(11, 20),
            Positioned(
              left: 23,
              top: 23,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: tokens.accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
