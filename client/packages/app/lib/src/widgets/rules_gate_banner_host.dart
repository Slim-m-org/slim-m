// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts a "read and accept the rules" banner above the shell while this
/// account is waiting behind the join gate.
///
/// A banner rather than a screen, so a waiting member can still browse the
/// rules channel the gate leaves open to them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiJoinGate;
import 'package:slimm_design_system/design_system.dart';

import '../providers/join_gate_providers.dart';
import '../providers/providers.dart';
import 'banner_host_layout.dart';
import 'run_guarded.dart';

class RulesGateBannerHost extends ConsumerWidget {
  const RulesGateBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(spaceRulesProvider).valueOrNull?.pending ?? false;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return BannerHostLayout(
      banner: pending
          ? Material(
              color: tokens.surfaceBase,
              child: const SafeArea(bottom: false, child: RulesGateBanner()),
            )
          : null,
      child: child,
    );
  }
}

class RulesGateBanner extends StatelessWidget {
  const RulesGateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppCallout(
      tone: AppCalloutTone.accent,
      icon: AppIcons.shield,
      child: Wrap(
        spacing: AppSpacing.s12,
        runSpacing: AppSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Read and accept the rules to join the conversation.',
            style: TextStyle(color: tokens.textPrimary),
          ),
          AppButton(
            label: 'Read the rules',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.sm,
            onPressed: () => showAppSheet<void>(
              context,
              scrolls: true,
              builder: (_) => const RulesSheet(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rules, with Accept pinned under them.
class RulesSheet extends ConsumerStatefulWidget {
  const RulesSheet({super.key});

  @override
  ConsumerState<RulesSheet> createState() => _RulesSheetState();
}

class _RulesSheetState extends ConsumerState<RulesSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await runGuarded(
      whatFailed: 'Could not accept the rules',
      action: () => ref.read(apiProvider).acceptSpaceRules(),
    );
    if (!mounted) return;
    if (error == null) {
      ref.invalidate(spaceRulesProvider);
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final rules = ref.watch(spaceRulesProvider).valueOrNull?.rules ?? '';
    final error = _error;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Rules', style: AppText.title),
          const SizedBox(height: AppSpacing.s12),
          Flexible(
            child: SingleChildScrollView(
              child: SelectableText(
                rules,
                style: AppText.body.copyWith(color: tokens.textPrimary),
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.s12),
            AppErrorState(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          ],
          const SizedBox(height: AppSpacing.s16),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'I accept the rules',
              variant: AppButtonVariant.primary,
              busy: _busy,
              onPressed: _accept,
            ),
          ),
        ],
      ),
    );
  }
}
