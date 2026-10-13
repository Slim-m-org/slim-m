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

import '../providers/providers.dart';
import 'color_swatch_row.dart';
import 'settings_section_header.dart';

const int _pronounsMaxChars = 40;
const int _aboutMaxChars = 190;

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

  void _seed(api.Me me) {
    if (_seeded) return;
    _seeded = true;
    _pronouns.text = me.pronouns ?? '';
    _about.text = me.about ?? '';
  }

  void _onBlur(FocusNode node, Future<void> Function() save) {
    if (node.hasFocus) return;
    unawaited(save());
  }

  Future<void> _savePronouns() async {
    try {
      await ref.read(apiProvider).updateMe(pronouns: _pronouns.text.trim());
      ref.invalidate(meProvider);
    } on api.ApiException {
      // Low-stakes; the field keeps the unsaved text rather than a banner.
    }
  }

  Future<void> _saveAbout() async {
    try {
      await ref.read(apiProvider).updateMe(about: _about.text.trim());
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

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider).valueOrNull;
    final touch = AppTouchTargets.of(context);
    if (me != null) _seed(me);

    return SettingsSectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Pronouns',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s4),
              AppInput(
                controller: _pronouns,
                focusNode: _pronounsFocus,
                enabled: _seeded,
                placeholder: 'she/her',
                semanticLabel: 'Pronouns',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _pronounsFocus.unfocus(),
              ),
              _counter(tokens, _pronouns.text.trim().length, _pronounsMaxChars),
              const SizedBox(height: AppSpacing.s12),
              Text(
                'About',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s4),
              AppInput(
                controller: _about,
                focusNode: _aboutFocus,
                enabled: _seeded,
                placeholder: 'Maintainer. If the build breaks, I broke it.',
                semanticLabel: 'About',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _aboutFocus.unfocus(),
              ),
              _counter(tokens, _about.text.trim().length, _aboutMaxChars),
              const SizedBox(height: AppSpacing.s12),
              Text(
                'Profile colour',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              SizedBox(height: touch ? 0 : AppSpacing.s8),
              ColorSwatchRow(
                label: 'Profile colour',
                colors: AppCanvasColors.cursors,
                names: _colourNames,
                selected: me?.profileColor,
                onSelect: me == null ? null : _setColor,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _counter(AppTokens tokens, int length, int max) => Align(
    alignment: Alignment.centerRight,
    child: Text(
      '$length/$max',
      style: AppText.micro.copyWith(
        color: length > max ? tokens.dangerText : tokens.textSecondary,
      ),
    ),
  );
}
