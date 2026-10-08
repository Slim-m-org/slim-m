// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a picked zip's decoded entries into the emoji uploads they plan,
/// before any network request happens.
///
/// Split from the widget that drives it (`emoji_bulk_upload_card.dart`) so
/// the derivation is checkable on its own: directories and non-images
/// skipped, a name taken from the file's stem and sanitized through the same
/// [normalizeEmojiName]/[isUsableEmojiName] rules typing one by one already
/// goes through, and a collision refused rather than silently overwriting an
/// earlier entry in the same zip.
library;

import 'package:archive/archive.dart';

import 'emoji_name.dart';

/// The extensions the server actually stores an emoji as: the inline subset
/// of `media::ALLOWED_TYPES` in `crates/slimm-server/src/media.rs`.
const acceptedEmojiExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];

/// Most entries one zip may hold before it is refused unread, so a zip bomb
/// of a million empty names costs a header count rather than a decode.
const int maxZipEntries = 2000;

/// Most uncompressed bytes of images one zip may declare before any is inflated.
const int maxZipUncompressedBytes = 64 * 1024 * 1024;

/// A zip refused unread for being over [maxZipEntries] or [maxZipUncompressedBytes].
class ZipTooLargeException implements Exception {
  const ZipTooLargeException();
}

/// One entry decoded from a zip, narrowed from `archive`'s own `ArchiveFile`
/// to the three fields [planEmojiZip] needs, so a test can hand it a
/// synthetic list without decoding real zip bytes.
class ZipEntryData {
  const ZipEntryData({
    required this.path,
    required this.bytes,
    this.isFile = true,
    this.declaredSize,
  });

  /// The entry's full path inside the archive, `/`-separated regardless of
  /// the platform that wrote it.
  final String path;
  final List<int> bytes;

  /// False for a directory entry, which carries no bytes worth planning.
  final bool isFile;

  /// The entry's uncompressed size when [bytes] was left empty rather than
  /// inflated, so an oversized image is still reported as one.
  final int? declaredSize;

  int get size => declaredSize ?? bytes.length;
}

/// Decodes [zipBytes] into its entries.
///
/// Only an entry [planEmojiZip] could queue is inflated: a non-image, or an
/// image already over [maxPlannedEmojiBytes] by its declared size, keeps empty
/// bytes, so a zip bomb costs a header read rather than its inflated size.
///
/// `ZipDecoder` is lenient: bytes that are not a zip at all decode to an
/// empty list rather than throwing, which [planEmojiZip] then reports as
/// "nothing to upload" - still a refusal, never a crash. A handful of
/// malformed-but-zip-shaped inputs can still throw (an [ArchiveException] or
/// a [FormatException]); callers catch those the same way.
List<ZipEntryData> decodeEmojiZipEntries(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  if (archive.length > maxZipEntries) throw const ZipTooLargeException();
  var declared = 0;
  for (final file in archive) {
    if (_wanted(file)) declared += file.size;
  }
  if (declared > maxZipUncompressedBytes) throw const ZipTooLargeException();
  return [for (final file in archive) _entryFor(file)];
}

bool _wanted(ArchiveFile file) =>
    file.isFile &&
    acceptedEmojiExtensions.contains(_extension(_baseName(file.name))) &&
    file.size <= maxPlannedEmojiBytes;

ZipEntryData _entryFor(ArchiveFile file) {
  if (!_wanted(file)) {
    return ZipEntryData(
      path: file.name,
      bytes: const [],
      isFile: file.isFile,
      declaredSize: file.size,
    );
  }
  return ZipEntryData(path: file.name, bytes: file.content);
}

/// One image [planEmojiZip] queues for upload.
class PlannedEmojiUpload {
  const PlannedEmojiUpload({
    required this.fileName,
    required this.name,
    required this.bytes,
  });

  /// The entry's own file name (no directory), shown in progress and in any
  /// failure the server later reports against it.
  final String fileName;

  /// The sanitized name the upload will ask the server for.
  final String name;
  final List<int> bytes;
}

/// One entry [planEmojiZip] refused before any request was made, and why.
class SkippedZipEntry {
  const SkippedZipEntry({required this.fileName, required this.reason});
  final String fileName;
  final String reason;
}

/// What a zip turned into: what will be uploaded, and what already could
/// not be, without a single request having been made yet.
class EmojiZipPlan {
  const EmojiZipPlan({required this.uploads, required this.skipped});
  final List<PlannedEmojiUpload> uploads;
  final List<SkippedZipEntry> skipped;
}

/// The largest single image this plans to upload, matching the server's own
/// `MAX_IMAGE_BYTES` (`crates/slimm-server/src/emoji.rs`) so an oversized
/// file is refused here rather than after a wasted round trip.
const int maxPlannedEmojiBytes = 1024 * 1024;

/// The most images one zip will queue, so a pathological archive cannot turn
/// one pick into thousands of sequential uploads.
const int maxPlannedEmojiCount = 200;

/// Most images one `POST /emoji/bulk` request may carry, matching the
/// server's own `MAX_BULK_IMAGES` (`crates/slimm-server/src/emoji/bulk.rs`).
const int maxBulkRequestCount = 50;

/// Most decoded bytes one `POST /emoji/bulk` request's images may total,
/// matching the server's own `MAX_BULK_TOTAL_BYTES`.
const int maxBulkRequestBytes = 20 * 1024 * 1024;

/// Splits [uploads] into the requests the server will accept: at most
/// [maxBulkRequestCount] images and at most [maxBulkRequestBytes] decoded
/// bytes in any one chunk.
///
/// This is why a 200-image pack (over [maxBulkRequestCount]) still imports:
/// it becomes a handful of `POST /emoji/bulk` calls instead of one call per
/// image, each charged once against the upload rate limit rather than once
/// per image - the actual defect a 200-image pack used to hit. Every planned
/// upload already passed [maxPlannedEmojiBytes] (1 MB, well under the 20 MB
/// per-chunk cap), so no image is ever dropped by this split, only grouped.
List<List<PlannedEmojiUpload>> chunkPlannedEmojiUploads(
  List<PlannedEmojiUpload> uploads,
) {
  final chunks = <List<PlannedEmojiUpload>>[];
  var current = <PlannedEmojiUpload>[];
  var currentBytes = 0;

  for (final upload in uploads) {
    final size = upload.bytes.length;
    final overCount = current.length >= maxBulkRequestCount;
    final overBytes =
        current.isNotEmpty && currentBytes + size > maxBulkRequestBytes;
    if (overCount || overBytes) {
      chunks.add(current);
      current = <PlannedEmojiUpload>[];
      currentBytes = 0;
    }
    current.add(upload);
    currentBytes += size;
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// Turns decoded zip [entries] into what will be uploaded and what is
/// already refused, without making any request.
///
/// [existingNames] seeds the collision check with names the deployment
/// already holds - already-normalised, the same shape [PlannedEmojiUpload.name]
/// is in - so a zip that repeats an existing emoji's name is reported once
/// here rather than failing with a 409 partway through the sequential
/// upload.
EmojiZipPlan planEmojiZip(
  List<ZipEntryData> entries, {
  Set<String> existingNames = const {},
}) {
  final uploads = <PlannedEmojiUpload>[];
  final skipped = <SkippedZipEntry>[];
  final usedNames = {...existingNames};

  for (final entry in entries) {
    if (!entry.isFile) continue;
    if (_isMacosJunk(entry.path)) continue;

    final fileName = _baseName(entry.path);
    if (fileName.isEmpty || fileName.startsWith('.')) continue;

    final ext = _extension(fileName);
    if (!acceptedEmojiExtensions.contains(ext)) {
      skipped.add(
        SkippedZipEntry(
          fileName: fileName,
          reason: 'not a PNG, JPEG, GIF or WEBP image',
        ),
      );
      continue;
    }

    if (uploads.length >= maxPlannedEmojiCount) {
      skipped.add(
        SkippedZipEntry(
          fileName: fileName,
          reason: 'more than $maxPlannedEmojiCount images at once',
        ),
      );
      continue;
    }
    if (entry.size == 0) {
      skipped.add(
        SkippedZipEntry(fileName: fileName, reason: 'the file is empty'),
      );
      continue;
    }
    if (entry.size > maxPlannedEmojiBytes) {
      skipped.add(
        SkippedZipEntry(fileName: fileName, reason: 'larger than 1 MB'),
      );
      continue;
    }

    final name = normalizeEmojiName(_stem(fileName));
    if (!isUsableEmojiName(name)) {
      skipped.add(
        SkippedZipEntry(
          fileName: fileName,
          reason: 'no usable name after sanitizing',
        ),
      );
      continue;
    }
    if (!usedNames.add(name)) {
      skipped.add(
        SkippedZipEntry(
          fileName: fileName,
          reason: '${emojiShortcode(name)} is already used',
        ),
      );
      continue;
    }

    uploads.add(
      PlannedEmojiUpload(fileName: fileName, name: name, bytes: entry.bytes),
    );
  }
  return EmojiZipPlan(uploads: uploads, skipped: skipped);
}

/// Whether [path] is macOS's own AppleDouble sidecar junk (`__MACOSX/` and
/// its `._name` shadow files), which a zip built on macOS carries alongside
/// every real entry and which decode as garbage if sniffed as images.
bool _isMacosJunk(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.startsWith('__MACOSX/') ||
      normalized.contains('/__MACOSX/');
}

/// The path's final segment: a zip entry may sit inside a folder
/// (`icons/party_blob.gif`), and only the file name names the emoji.
String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

/// The lowercase extension without its dot, or the empty string if there is
/// none.
String _extension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

/// The file name with its extension stripped: the part Discord-style naming
/// takes the emoji's name from (`party_blob.gif` -> `party_blob`).
String _stem(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}
