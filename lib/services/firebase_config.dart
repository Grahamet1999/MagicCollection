import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Firebase project settings for the cloud "group binder" feature.
///
/// Values are loaded at runtime from a `firebase_config.json` file that is kept
/// OUT of source control (gitignored), so the API key is never committed. The
/// file is looked up next to the executable first, then in the app-support
/// directory. See docs/firebase_setup.md for its shape and how to create it.
///
/// Until the file is present with values, [isConfigured] is false and the
/// cloud/Groups features are hidden; the rest of the app works on local storage.
class FirebaseConfig {
  static String apiKey = '';
  static String projectId = '';
  static String databaseUrl = '';

  static bool get isConfigured => apiKey.isNotEmpty && databaseUrl.isNotEmpty;

  /// Loads settings from `firebase_config.json`. Call once at startup before
  /// reading [isConfigured]. Missing/invalid file simply leaves the cloud
  /// features disabled.
  static Future<void> load() async {
    for (final path in await _candidatePaths()) {
      final file = File(path);
      if (await file.exists()) {
        try {
          final json =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          apiKey = json['apiKey'] as String? ?? '';
          projectId = json['projectId'] as String? ?? '';
          databaseUrl = json['databaseUrl'] as String? ?? '';
          if (isConfigured) return;
        } catch (_) {
          // Ignore malformed files; try the next candidate.
        }
      }
    }
  }

  static Future<List<String>> _candidatePaths() async {
    const name = 'firebase_config.json';
    final beside =
        p.join(File(Platform.resolvedExecutable).parent.path, name);
    String? appDir;
    try {
      appDir = p.join((await getApplicationSupportDirectory()).path, name);
    } catch (_) {
      appDir = null;
    }
    return [beside, if (appDir != null) appDir];
  }
}
