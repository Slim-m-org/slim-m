// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pictures stamped on the caller's shared screen (decision 0121).
library;

/// One picture a viewer stamped on the caller's screen, kept for a day so it can
/// be reported after it faded. [id] is what a [ReportSubject.screenStamp] report names.
class ReceivedScreenStamp {
  const ReceivedScreenStamp({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.attachmentId,
    required this.createdAt,
    required this.reported,
  });

  final String id;
  final String channelId;
  final String senderId;

  /// Fetched like any attachment, by the caller, for a day.
  final String attachmentId;

  /// Unix milliseconds.
  final int createdAt;

  /// Whether the caller has reported it.
  final bool reported;

  factory ReceivedScreenStamp.fromJson(Map<String, dynamic> json) =>
      ReceivedScreenStamp(
        id: json['id'] as String,
        channelId: json['channel_id'] as String,
        senderId: json['sender_id'] as String,
        attachmentId: json['attachment_id'] as String,
        createdAt: json['created_at'] as int,
        reported: json['reported'] == true,
      );
}

/// Someone who stamped pictures on the caller's screen in the last day, by
/// their [latest] picture. A report naming [latest]'s id is about them and
/// takes every picture of theirs from that day.
class ScreenStampSender {
  const ScreenStampSender({
    required this.senderId,
    required this.count,
    required this.reported,
    required this.latest,
  });

  final String senderId;

  /// How many pictures they stamped in the last day.
  final int count;

  /// Whether the caller's report holds every one of them.
  final bool reported;

  final ReceivedScreenStamp latest;

  factory ScreenStampSender.fromJson(Map<String, dynamic> json) =>
      ScreenStampSender(
        senderId: json['sender_id'] as String,
        count: json['count'] as int,
        reported: json['reported'] == true,
        latest: ReceivedScreenStamp.fromJson(
          json['latest'] as Map<String, dynamic>,
        ),
      );
}
