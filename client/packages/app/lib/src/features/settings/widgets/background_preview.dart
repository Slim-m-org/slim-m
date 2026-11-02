// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small mock of the shell over the chosen picture, painted with the same
/// layer, fade and pane translucency the real shell uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../background/providers/app_background_controller.dart';

class BackgroundPreview extends ConsumerWidget {
  const BackgroundPreview({super.key});

  static const Key previewKey = Key('background_preview');
  static const double height = 140;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final settings = ref.watch(appBackgroundControllerProvider);
    final picture = ref.watch(backgroundPictureProvider).valueOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        AppSpacing.s4,
      ),
      child: Semantics(
        label: 'Background preview',
        child: ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: SizedBox(
              key: previewKey,
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: tokens.surfaceBase),
                  if (picture != null)
                    AppBackgroundLayer(
                      image: picture,
                      base: tokens.surfaceBase,
                      style: settings.styleFor(tokens),
                    ),
                  AppBackgroundScope.active(child: _Shell(tokens: tokens)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 44,
        child: PaneSurface(
          color: tokens.surfaceSunken,
          child: const SizedBox.expand(),
        ),
      ),
      Expanded(
        child: PaneSurface(
          color: tokens.surfaceBase,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ada',
                  style: AppText.caption.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                Text(
                  'Text stays readable over the picture.',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
                const Spacer(),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceRaised,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: SizedBox(
                    height: 22,
                    width: double.infinity,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          'Message',
                          style: AppText.micro.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      SizedBox(
        width: 44,
        child: PaneSurface(
          color: tokens.surfaceSunken,
          child: const SizedBox.expand(),
        ),
      ),
    ],
  );
}
