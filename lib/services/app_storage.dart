import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Per-workspace storage under the app support directory, e.g.
/// `<support>/rag_index/<hash>.json` or `<support>/chat_history/<hash>.json`.
class AppStorage {
  static Future<File> workspaceFile(String bucket, String rootPath) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, bucket));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '${workspaceKey(rootPath)}.json'));
  }

  /// Stable FNV-1a hash of the normalized workspace path.
  static String workspaceKey(String rootPath) {
    var normalized = p.normalize(rootPath);
    if (Platform.isWindows || Platform.isMacOS) {
      normalized = normalized.toLowerCase();
    }
    var hash = 0x811c9dc5;
    for (final unit in normalized.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final name = p.basename(normalized).replaceAll(RegExp(r'[^\w.-]'), '_');
    return '${name}_${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Write via a temp file so a crash mid-write never corrupts the store.
  static Future<void> writeAtomic(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}
