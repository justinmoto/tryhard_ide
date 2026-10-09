import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FolderPicker {
  /// Opens a native folder dialog and returns the absolute path, or null if canceled.
  static Future<String?> pick({String? initialDirectory}) async {
    if (kIsWeb) return null;

    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Open Folder',
        initialDirectory: initialDirectory,
      );
      if (path != null && path.isNotEmpty) return path;
    } on MissingPluginException {
      // Hot-restart without native rebuild — fall through.
    } catch (_) {
      // Fall through to platform-specific picker.
    }

    if (Platform.isMacOS) {
      return _pickWithOsascript(initialDirectory);
    }
    return null;
  }

  static Future<String?> _pickWithOsascript(String? initialDirectory) async {
    final script = StringBuffer('try\n');
    if (initialDirectory != null && initialDirectory.isNotEmpty) {
      script.writeln(
        'set defaultFolder to POSIX file ${AppleScript.string(initialDirectory)} as alias',
      );
      script.writeln(
        'set chosen to choose folder with prompt "Open Folder" default location defaultFolder',
      );
    } else {
      script.writeln('set chosen to choose folder with prompt "Open Folder"');
    }
    script.writeln('return POSIX path of chosen');
    script.writeln('on error');
    script.writeln('return ""');
    script.writeln('end try');

    try {
      final result = await Process.run('osascript', ['-e', script.toString()]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      if (path.isEmpty) return null;
      return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    } catch (_) {
      return null;
    }
  }
}

abstract final class AppleScript {
  static String string(String value) {
    final escaped = value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '"$escaped"';
  }
}
