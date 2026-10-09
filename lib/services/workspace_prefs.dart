import 'package:shared_preferences/shared_preferences.dart';

class WorkspacePrefs {
  static const _lastFolderKey = 'last_folder_path';

  static Future<String?> loadLastFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_lastFolderKey);
    if (path == null || path.isEmpty) return null;
    return path;
  }

  static Future<void> saveLastFolder(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastFolderKey, path);
  }

  static Future<void> clearLastFolder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastFolderKey);
  }
}
