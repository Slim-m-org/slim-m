// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin's controls for the invite landing card: a short description, a
/// banner, and a live preview of the card a visitor will see.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_preferences.dart';
import '../providers/member_presence.dart';
import '../providers/providers.dart';
import 'attachment_picker.dart';
import 'invite_landing_card.dart';
import 'join_policy_row.dart';
import 'run_guarded.dart';
import 'settings_section_header.dart';

/// Matches the server's cap on a description.
const int kInviteDescriptionMaxChars = 280;

final _spaceNameProvider = FutureProvider.autoDispose<String>(
  (ref) async => (await ref.watch(apiProvider).version()).name,
);

final _bannerBytesProvider = FutureProvider.autoDispose.family<Uint8List, int>(
  (ref, updatedAt) async =>
      (await ref.watch(apiProvider).fetchSpaceBanner()).bytes,
);

class InviteLandingSection extends ConsumerStatefulWidget {
  const InviteLandingSection({super.key});

  @override
  ConsumerState<InviteLandingSection> createState() =>
      _InviteLandingSectionState();
}

class _InviteLandingSectionState extends ConsumerState<InviteLandingSection>
    with GuardedActionState<InviteLandingSection> {
  final _description = TextEditingController();
  String _saved = '';
  bool _seeded = false;
  bool _busy = false;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  void _seed(api.SpaceSettings settings) {
    if (_seeded) return;
    _seeded = true;
    _saved = settings.description;
    _description.text = settings.description;
  }

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    setState(() => _busy = true);
    clearActionError();
    final ok = await guard(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(spaceSettingsProvider);
  }

  Future<void> _saveDescription() async {
    final text = _description.text.trim();
    await _run('save the description', () async {
      final updated = await ref
          .read(apiProvider)
          .setSpaceSettings(description: text);
      _saved = updated.description;
      _description.text = updated.description;
    });
  }

  Future<void> _chooseBanner() async {
    final file = await ref.read(
      attachmentPickerProvider(AttachmentSource.photoLibrary),
    )();
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    await _run(
      'upload the banner',
      () => ref.read(apiProvider).uploadSpaceBanner(bytes),
    );
  }

  Widget? _banner(int? updatedAt) {
    if (updatedAt == null) return null;
    final bytes = ref.watch(_bannerBytesProvider(updatedAt)).valueOrNull;
    if (bytes == null) {
      return ColoredBox(
        color: Theme.of(context).extension<AppTokens>()!.surfaceSunken,
      );
    }
    return Image.memory(bytes, fit: BoxFit.cover);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    return SettingsSectionCard(
      title: 'Landing page',
      description: 'What an invite link shows before sign-in.',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        settings.when(
          loading: () => const SizedBox(height: AppSpacing.s48),
          error: (_, _) => AppErrorState(
            message: 'Could not load the landing page.',
            onRetry: () => ref.invalidate(spaceSettingsProvider),
          ),
          data: (loaded) {
            _seed(loaded);
            return _body(loaded);
          },
        ),
      ],
    );
  }

  Widget _body(api.SpaceSettings loaded) {
    final changed = _description.text.trim() != _saved;
    final bannerSet = loaded.bannerUpdatedAt != null;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppInput(
            controller: _description,
            placeholder: 'Short description',
            semanticLabel: 'Description',
            enabled: !_busy,
            inputFormatters: [
              LengthLimitingTextInputFormatter(kInviteDescriptionMaxChars),
            ],
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_saveDescription()),
          ),
          const SizedBox(height: AppSpacing.s12),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: [
              AppButton(
                label: 'Save description',
                variant: AppButtonVariant.primary,
                disabled: _busy || !changed,
                onPressed: _saveDescription,
              ),
              AppButton(
                label: bannerSet ? 'Replace banner' : 'Choose banner',
                variant: AppButtonVariant.secondary,
                disabled: _busy,
                onPressed: _chooseBanner,
              ),
              if (bannerSet)
                AppButton(
                  label: 'Remove banner',
                  variant: AppButtonVariant.ghost,
                  disabled: _busy,
                  onPressed: () => _run(
                    'remove the banner',
                    () => ref.read(apiProvider).deleteSpaceBanner(),
                  ),
                ),
            ],
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s12),
            AppErrorState(message: actionError!, onDismiss: clearActionError),
          ],
          const SizedBox(height: AppSpacing.s16),
          // The width the join sheet gives it, so the preview is not larger than the real thing.
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: InviteLandingCard(
                name: ref.watch(_spaceNameProvider).valueOrNull ?? 'Your Space',
                memberCount:
                    ref.watch(membersProvider).valueOrNull?.length ?? 0,
                description: _description.text.trim(),
                banner: _banner(loaded.bannerUpdatedAt),
                use24Hour: watchUse24Hour(ref, context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
