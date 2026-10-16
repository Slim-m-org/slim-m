// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Profile's own pronouns, about and colour fields: `PATCH /me`
/// (`SlimmApi.updateMe`), the same route the display name and status text
/// already ride. Pronouns and about save on blur, the same convention
/// `MemberProfileNoteField` uses; a colour swatch saves the moment it is
/// tapped, since there is nothing to type.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/profile_draft.dart';
import '../providers/providers.dart';
import 'color_swatch_row.dart';
import 'settings_section_header.dart';

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
    } on api.ApiException {
      // Low-stakes; the field keeps the unsaved text rather than a banner.
    }
  }

  Future<void> _saveAbout() async {
    final text = _about.text.trim();
    if (text == _savedAbout) return;
    try {
      await ref.read(apiProvider).updateMe(about: text);
      _savedAbout = text;
      ref.invalidate(meProvider);
    } on api.ApiException {
      // Same tolerance as _savePronouns.
    }
  }

  Future<void> _setColor(int index) async {
    try {
      await ref.read(apiProvider).updateMe(profileColor: index);
      ref.invalidate(meProvider);
    } on api.ApiException {
      // Same tolerance as _savePronouns.
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
    final label = AppText.caption.copyWith(
      color: tokens.textPrimary,
      fontWeight: AppWeights.medium,
    );

    return SettingsSectionCard(
      flush: true,
      title: 'About you',
      children: [
        SettingsCardBlock(
          gap: 18,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text('Pronouns', style: label),
                AppInput(
                  maxLength: api.InputLimits.pronouns,
                  controller: _pronouns,
                  focusNode: _pronounsFocus,
                  enabled: _seeded,
                  placeholder: 'e.g. she/her',
                  semanticLabel: 'Pronouns',
                  onChanged: (_) => _publishDraft(),
                  onSubmitted: (_) => _pronounsFocus.unfocus(),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text('About', style: label),
                AppInput(
                  maxLength: api.InputLimits.about,
                  minLines: 3,
                  maxLines: 3,
                  controller: _about,
                  focusNode: _aboutFocus,
                  enabled: _seeded,
                  placeholder: 'Maintainer. If the build breaks, I broke it.',
                  semanticLabel: 'About',
                  onChanged: (_) => _publishDraft(),
                ),
                ValueListenableBuilder(
                  valueListenable: _about,
                  builder: (context, value, _) => Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${value.text.runes.length} / ${api.InputLimits.about}',
                      style: AppText.code.copyWith(
                        fontSize: AppText.micro.fontSize,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Profile colour', style: label),
                const SizedBox(height: 6),
                ColorSwatchRow(
                  label: 'Profile colour',
                  colors: AppCanvasColors.cursors,
                  names: _colourNames,
                  selected: me?.profileColor,
                  onSelect: me == null ? null : _setColor,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
