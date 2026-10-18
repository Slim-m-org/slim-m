// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space-wide photo compression controls on the retention and limits pane:
/// whether uploads are shrunk, which file types, what happens to their
/// metadata, and whether the original is kept.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_search.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_segmented_row.dart';
import '../../widgets/settings_select_row.dart';
import '../../widgets/settings_toggle_row.dart';

const _metadataChoices = <SettingsChoice<String>>[
  SettingsChoice(value: 'keep', label: 'Keep all'),
  SettingsChoice(value: 'remove_location', label: 'No location'),
  SettingsChoice(value: 'remove_all', label: 'None'),
];

/// The extensions typed into the field, in order, without blanks.
List<String> parseExtensions(String text) => [
  for (final part in text.split(RegExp(r'[\s,;]+')))
    if (part.isNotEmpty) part,
];

class MediaCompressionSection extends ConsumerStatefulWidget {
  const MediaCompressionSection({super.key});

  @override
  ConsumerState<MediaCompressionSection> createState() =>
      _MediaCompressionSectionState();
}

class _MediaCompressionSectionState
    extends ConsumerState<MediaCompressionSection>
    with
        GuardedActionState<MediaCompressionSection>,
        OptimisticSettingState<
          MediaCompressionSection,
          api.SpaceMediaCompression
        > {
  final _types = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _types.dispose();
    super.dispose();
  }

  Future<void> _save(
    api.SpaceMediaCompression next, {
    bool? enabled,
    List<String>? extensions,
    String? metadata,
    bool? keepOriginal,
  }) => saveOptimistic(
    next,
    whatFailed: 'change photo compression',
    action: () async {
      final saved = await ref
          .read(apiProvider)
          .setSpaceMediaCompression(
            enabled: enabled,
            extensions: extensions,
            metadata: metadata,
            keepOriginal: keepOriginal,
          );
      if (mounted) _types.text = saved.extensions.join(', ');
    },
    refresh: spaceMediaCompressionProvider,
  );

  bool _typesDiffer(api.SpaceMediaCompression current) {
    final typed = parseExtensions(_types.text.toLowerCase());
    return typed.join(',') != current.extensions.join(',');
  }

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(spaceMediaCompressionProvider);
    ref.listen(
      spaceMediaCompressionProvider,
      (_, next) => retireOptimistic(next),
    );
    final current = optimistic ?? setting.valueOrNull;
    if (current != null && !_seeded) {
      _seeded = true;
      _types.text = current.extensions.join(', ');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Photo compression',
          description: 'Shrink photos when they are uploaded.',
          children: [
            SettingsToggleRow(
              label: 'Compress photos',
              description: 'Large photos are resized and saved smaller.',
              value: current?.enabled ?? false,
              semanticLabel: 'Compress photos for the whole Space',
              onChanged: current == null || saving
                  ? null
                  : (on) => _save(current.copyWith(enabled: on), enabled: on),
            ),
            if (current != null && current.enabled) ..._options(current),
            if (setting.hasError && current == null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: 'Could not load the current setting.',
                    onRetry: () =>
                        ref.invalidate(spaceMediaCompressionProvider),
                  ),
                ],
              ),
          ],
        ),
        SettingsSaveFeedback(
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }

  List<Widget> _options(api.SpaceMediaCompression current) {
    return [
      _fileTypes(current),
      SettingsSegmentedRow<String>(
        label: 'Photo metadata',
        description: 'Details stored inside a photo file.',
        value: current.metadata,
        choices: _metadataChoices,
        onChanged: (mode) => saving
            ? null
            : _save(current.copyWith(metadata: mode), metadata: mode),
      ),
      SettingsToggleRow(
        label: 'Keep originals',
        description: 'Also store each photo as sent, offered as a download.',
        value: current.keepOriginal,
        semanticLabel: 'Keep the original of compressed photos',
        onChanged: saving
            ? null
            : (keep) => _save(
                current.copyWith(keepOriginal: keep),
                keepOriginal: keep,
              ),
      ),
    ];
  }

  Widget _fileTypes(api.SpaceMediaCompression current) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final isDefault =
        current.extensions.join(',') == current.defaultExtensions.join(',');
    return SettingsHighlightTarget(
      label: 'File types',
      child: SettingsCardBlock(
        gap: AppSpacing.s8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(
                'File types',
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
              Text(
                'Photo formats that get compressed.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
          ListenableBuilder(
            listenable: _types,
            builder: (context, _) => AppInput(
              controller: _types,
              mono: true,
              minLines: 1,
              maxLines: 3,
              placeholder: 'jpg, png, heic',
              semanticLabel: 'File types to compress',
              enabled: !saving,
              onSubmitted: (_) => _submitTypes(current),
            ),
          ),
          ListenableBuilder(
            listenable: _types,
            builder: (context, _) => Wrap(
              spacing: AppSpacing.s8,
              children: [
                if (_typesDiffer(current))
                  AppButton(
                    label: 'Save types',
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.sm,
                    disabled: saving,
                    onPressed: () => _submitTypes(current),
                  ),
                if (!isDefault)
                  AppButton(
                    label: 'Restore defaults',
                    variant: AppButtonVariant.ghost,
                    size: AppButtonSize.sm,
                    disabled: saving,
                    onPressed: () => _save(
                      current.copyWith(extensions: current.defaultExtensions),
                      extensions: const [],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submitTypes(api.SpaceMediaCompression current) {
    final typed = parseExtensions(_types.text);
    return _save(current.copyWith(extensions: typed), extensions: typed);
  }
}
