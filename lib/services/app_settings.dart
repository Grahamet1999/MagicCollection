import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level user settings persisted locally. Currently holds the Anthropic API
/// key used by the AI deck advisor — stored on-device (never compiled into the
/// binary, so sharing the packaged app doesn't leak it), and the user supplies
/// their own.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _kAnthropicKey = 'anthropic_api_key';

  String? _anthropicKey;

  /// The user's Anthropic API key, or null if not set.
  String? get anthropicKey => _anthropicKey;

  /// True when an Anthropic key is configured.
  bool get hasAnthropicKey => (_anthropicKey ?? '').isNotEmpty;

  /// Loads persisted settings. Call once at startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _anthropicKey = prefs.getString(_kAnthropicKey);
  }

  /// Stores (or clears, when null/blank) the Anthropic key and notifies.
  Future<void> setAnthropicKey(String? key) async {
    final prefs = await SharedPreferences.getInstance();
    final value = (key ?? '').trim();
    if (value.isEmpty) {
      await prefs.remove(_kAnthropicKey);
      _anthropicKey = null;
    } else {
      await prefs.setString(_kAnthropicKey, value);
      _anthropicKey = value;
    }
    notifyListeners();
  }
}
