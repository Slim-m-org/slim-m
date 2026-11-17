// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the forward and share pickers group their targets.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/destination_sections.dart';
import 'package:slimm_app/src/features/messages/providers/forward_targets.dart';

ForwardTarget _dm(String id, String label) =>
    ForwardTarget(channelId: id, label: label, isDm: true, userId: id);

final _targets = [
  const ForwardTarget(channelId: 'c1', label: 'general', isDm: false),
  const ForwardTarget(channelId: 'c2', label: 'random', isDm: false),
  const ForwardTarget(
    channelId: 'n1',
    label: 'Notes',
    isDm: true,
    isPersonalSpace: true,
  ),
  _dm('d1', 'Priya'),
  _dm('d2', 'Sam'),
  _dm('d3', 'Lee'),
  _dm('d4', 'Ana'),
  const ForwardTarget(
    channelId: 'g1',
    label: 'Priya and Sam',
    isDm: true,
    groupMemberIds: ['d1', 'd2'],
  ),
];

Map<String, List<String>> _shape(List<DestinationSection> sections) => {
  for (final s in sections) s.title: [for (final t in s.targets) t.channelId],
};

void main() {
  test('suggests here, Notes and the newest conversations, once each', () {
    final sections = destinationSections(
      _targets,
      search: '',
      currentChannelId: 'c1',
    );

    expect(_shape(sections), {
      'Suggested': ['c1', 'n1', 'd1', 'd2', 'd3'],
      'Channels': ['c2'],
      'Direct messages': ['d4'],
      'Groups': ['g1'],
    });
  });

  test('a search drops the suggestions and keeps every section', () {
    final sections = destinationSections(
      _targets,
      search: ' A ',
      currentChannelId: 'c1',
    );

    expect(_shape(sections), {
      'Channels': ['c1', 'c2'],
      'Direct messages': ['d1', 'd2', 'd4'],
      'Groups': ['g1'],
    });
    expect(_shape(destinationSections(_targets, search: 'notes')), {
      'Notes': ['n1'],
    });
  });
}
