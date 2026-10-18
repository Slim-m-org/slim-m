// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Profile's own pronouns, about and colour fields: `PATCH /me`
/// (`SlimmApi.updateMe`), the same route the display name and status text
/// already ride. Pronouns and about save on blur, the same convention
/// `MemberProfileNoteField` uses; a colour swatch saves the moment it is
/// tapped, since there is nothing to type; the Custom swatch saves once the picker does.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/profile_draft.dart';
import 'profile_colour.dart';
import '../../../providers/providers.dart';
import '../../../widgets/color_swatch_row.dart';
import '../../settings/widgets/settings_section_header.dart';

/// Spoken names for [AppCanvasColors.cursors], in the same order.
const _colourNames = ['Pink', 'Purple', 'Blue', 'Orange', 'Green', 'Magenta'];

class ProfileFieldsSection extends ConsumerStatefulWidget {
  const ProfileFieldsSection({super.key});

  @override
  ConsumerState<ProfileFieldsSection> createState() =>
      _ProfileFieldsSectionState();
}

class _ProfileFieldsSectionState extends ConsumerState<ProfileFieldsSection> {
  final _pronouns = TextEditingController();
  final _about = TextEditingController();
  final _pronounsFocus = FocusNode();
  final _aboutFocus = FocusNode();
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _pronounsFocus.addListener(() => _onBlur(_pronounsFocus, _savePronouns));
    _aboutFocus.addListener(() => _onBlur(_aboutFocus, _saveAbout));
  }

  @override
  void dispose() {
    _pronounsFocus.dispose();
    _aboutFocus.dispose();
    _pronouns.dispose();
    _about.dispose();
    super.dispose();
  }

  /// What the server last accepted, so a blur with nothing changed sends nothing.
  String? _savedPronouns;
  String? _savedAbout;

  /// Why the last save of each field was refused, shown under it until the
  /// text changes; a refusal used to vanish and leave the text silently unsaved.
  String? _pronounsError;
  String? _aboutError;
  String? _colourError;

  void _seed(api.Me me) {
    if (_seeded) return;
    _seeded = true;
    _pronouns.text = _savedPronouns = me.pronouns ?? '';
    _about.text = _savedAbout = me.about ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(profileDraftProvider);
    });
  }

  void _onBlur(FocusNode node, Future<void> Function() save) {
    if (node.hasFocus) return;
    unawaited(save());
  }

  Future<void> _savePronouns() async {
    final text = _pronouns.text.trim();
    if (text == _savedPronouns) return;
    try {
      await ref.read(apiProvider).updateMe(pronouns: text);
      _savedPronouns = text;
      ref.invalidate(meProvider);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save pronouns', e, stack);
      if (mounted) setState(() => _pronounsError = 'Not saved: ${e.message}');
    }
  }

  Future<void> _saveAbout() async {
    final text = _about.text.trim();
    if (text == _savedAbout) return;
    try {
      await ref.read(apiProvider).updateMe(about: text);
      _savedAbout = text;
      ref.invalidate(meProvider);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save about', e, stack);
      if (mounted) setState(() => _aboutError = 'Not saved: ${e.message}');
    }
  }

  /// A preset sends only the index, which clears any custom colour server-side.
  Future<void> _setColor(int index) =>
      _saveColour(() => ref.read(apiProvider).updateMe(profileColor: index));

  /// The nearest preset rides along so older clients still draw something close.
  Future<void> _setCustomColour(Color colour) => _saveColour(
    () => ref
        .read(apiProvider)
        .updateMe(
          profileColor: nearestColourIndex(colour, AppCanvasColors.cursors),
          profileColorRgb: rgbOf(colour),
        ),
  );

  Future<void> _pickCustomColour(api.Me me) async {
    final colour = await showAppColourPicker(
      context,
      initial:
          profileColourOf(index: me.profileColor, rgb: me.profileColorRgb) ??
          AppCanvasColors.cursors.first,
    );
    if (colour != null) await _setCustomColour(colour);
  }

  Future<void> _saveColour(Future<Object?> Function() save) async {
    setState(() => _colourError = null);
    try {
      await save();
      ref.invalidate(meProvider);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save colour', e, stack);
      if (mounted) setState(() => _colourError = 'Not saved: ${e.message}');
    }
  }

  void _publishDraft() {
    ref.read(profileDraftProvider.notifier).state = (
      pronouns: _pronouns.text,
      about: _about.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider).valueOrNull;
    if (me != null) _seed(me);

    final pronounsField = _Labelled(
      label: 'Pronouns',
      child: AppInput(
        maxLength: api.InputLimits.pronouns,
        controller: _pronouns,
        focusNode: _pronounsFocus,
        enabled: _seeded,
        placeholder: 'e.g. she/her',
        semanticLabel: 'Pronouns',
        errorText: _pronounsError,
        onChanged: (_) {
          if (_pronounsError != null) setState(() => _pronounsError = null);
          _publishDraft();
        },
        onSubmitted: (_) => _pronounsFocus.unfocus(),
      ),
    );
    final colourField = _Labelled(
      label: 'Profile colour',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ColorSwatchRow(
            label: 'Profile colour',
            colors: AppCanvasColors.cursors,
            names: _colourNames,
            selected: me?.profileColorRgb == null ? me?.profileColor : null,
            onSelect: me == null ? null : _setColor,
            custom: CustomSwatch(
              label: 'Custom',
              colour: me?.profileColorRgb == null
                  ? null
                  : profileColourOf(rgb: me!.profileColorRgb),
              onTap: me == null ? null : () => _pickCustomColour(me),
            ),
          ),
          if (_colourError != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(
              message: _colourError!,
              onDismiss: () => setState(() => _colourError = null),
            ),
          ],
        ],
      ),
    );

    return SettingsSectionCard(
      title: 'About you',
      topGap: kDenseSectionTopGap,
      children: [
        SettingsCardBlock(
          gap: 12,
          children: [
            ProfileFieldPair(first: pronounsField, second: colourField),
            _Labelled(
              label: 'About',
              trailing: ValueListenableBuilder(
                valueListenable: _about,
                builder: (context, value, _) => Text(
                  '${value.text.runes.length} / ${api.InputLimits.about}',
                  style: AppText.code.copyWith(
                    fontSize: AppText.micro.fontSize,
                    color: tokens.textSecondary,
                  ),
                ),
              ),
              child: AppInput(
                maxLength: api.InputLimits.about,
                minLines: 3,
                maxLines: 3,
                controller: _about,
                focusNode: _aboutFocus,
                enabled: _seeded,
                placeholder: 'Maintainer. If the build breaks, I broke it.',
                semanticLabel: 'About',
                errorText: _aboutError,
                onChanged: (_) {
                  if (_aboutError != null) setState(() => _aboutError = null);
                  _publishDraft();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Two fields side by side where there is room, stacked below [kPairMinWidth].
class ProfileFieldPair extends StatelessWidget {
  const ProfileFieldPair({
    super.key,
    required this.first,
    required this.second,
  });

  /// Wide enough that each half fits seven 36px colour swatches on one row.
  static const double kPairMinWidth = 560;

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < kPairMinWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [first, second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s16,
        children: [
          Expanded(child: first),
          Expanded(child: second),
        ],
      );
    },
  );
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child, this.trailing});

  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.caption.copyWith(
      color: tokens.textPrimary,
      fontWeight: AppWeights.medium,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: style)),
            ?trailing,
          ],
        ),
        child,
      ],
    );
  }
}
