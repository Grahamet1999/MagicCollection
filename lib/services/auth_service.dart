import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_config.dart';

/// A signed-in Firebase user.
class AppUser {
  AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
  });

  final String uid;
  final String email;
  final String displayName;
}

/// Email/password authentication against the Firebase Auth REST API (Identity
/// Toolkit). Pure-Dart over [http] so it works on Windows desktop with no
/// FlutterFire plugins. Persists the session via [SharedPreferences] so login
/// survives restarts, and refreshes the id token on demand.
class AuthService extends ChangeNotifier {
  AuthService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _kUid = 'auth_uid';
  static const _kEmail = 'auth_email';
  static const _kName = 'auth_name';
  static const _kIdToken = 'auth_id_token';
  static const _kRefreshToken = 'auth_refresh_token';
  static const _kExpiry = 'auth_expiry_ms';

  AppUser? _currentUser;
  String? _idToken;
  String? _refreshToken;
  DateTime _expiry = DateTime.fromMillisecondsSinceEpoch(0);

  AppUser? get currentUser => _currentUser;
  bool get isSignedIn => _currentUser != null;

  static const _identityBase =
      'https://identitytoolkit.googleapis.com/v1/accounts';
  static const _tokenBase = 'https://securetoken.googleapis.com/v1/token';

  /// Restores a persisted session, if any.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString(_kUid);
    _idToken = prefs.getString(_kIdToken);
    _refreshToken = prefs.getString(_kRefreshToken);
    _expiry = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_kExpiry) ?? 0);
    if (uid != null && _refreshToken != null) {
      _currentUser = AppUser(
        uid: uid,
        email: prefs.getString(_kEmail) ?? '',
        displayName: prefs.getString(_kName) ?? '',
      );
      notifyListeners();
    }
  }

  Future<void> signUp(
    String email,
    String password,
    String displayName,
  ) async {
    final res = await _post('$_identityBase:signUp?key=${FirebaseConfig.apiKey}', {
      'email': email,
      'password': password,
      'returnSecureToken': true,
    });
    // Set the display name, then finalize the session.
    await _post('$_identityBase:update?key=${FirebaseConfig.apiKey}', {
      'idToken': res['idToken'],
      'displayName': displayName,
      'returnSecureToken': true,
    });
    await _apply(res, emailFallback: email, nameFallback: displayName);
  }

  Future<void> signIn(String email, String password) async {
    final res =
        await _post('$_identityBase:signInWithPassword?key=${FirebaseConfig.apiKey}', {
      'email': email,
      'password': password,
      'returnSecureToken': true,
    });
    await _apply(res,
        emailFallback: email, nameFallback: res['displayName'] as String? ?? '');
  }

  Future<void> signOut() async {
    _currentUser = null;
    _idToken = null;
    _refreshToken = null;
    _expiry = DateTime.fromMillisecondsSinceEpoch(0);
    final prefs = await SharedPreferences.getInstance();
    for (final k in [_kUid, _kEmail, _kName, _kIdToken, _kRefreshToken, _kExpiry]) {
      await prefs.remove(k);
    }
    notifyListeners();
  }

  /// Returns a currently-valid id token, refreshing it if expired. Throws if not
  /// signed in.
  Future<String> idToken() async {
    if (_refreshToken == null) {
      throw StateError('Not signed in.');
    }
    if (DateTime.now().isBefore(_expiry) && _idToken != null) {
      return _idToken!;
    }
    final res = await _post('$_tokenBase?key=${FirebaseConfig.apiKey}', {
      'grant_type': 'refresh_token',
      'refresh_token': _refreshToken,
    });
    _idToken = res['id_token'] as String;
    _refreshToken = res['refresh_token'] as String;
    _expiry = DateTime.now()
        .add(Duration(seconds: int.tryParse('${res['expires_in']}') ?? 3600));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIdToken, _idToken!);
    await prefs.setString(_kRefreshToken, _refreshToken!);
    await prefs.setInt(_kExpiry, _expiry.millisecondsSinceEpoch);
    return _idToken!;
  }

  Future<void> _apply(
    Map<String, dynamic> res, {
    required String emailFallback,
    required String nameFallback,
  }) async {
    final uid = res['localId'] as String;
    _idToken = res['idToken'] as String;
    _refreshToken = res['refreshToken'] as String;
    _expiry = DateTime.now()
        .add(Duration(seconds: int.tryParse('${res['expiresIn']}') ?? 3600));
    _currentUser = AppUser(
      uid: uid,
      email: res['email'] as String? ?? emailFallback,
      displayName: nameFallback,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUid, uid);
    await prefs.setString(_kEmail, _currentUser!.email);
    await prefs.setString(_kName, _currentUser!.displayName);
    await prefs.setString(_kIdToken, _idToken!);
    await prefs.setString(_kRefreshToken, _refreshToken!);
    await prefs.setInt(_kExpiry, _expiry.millisecondsSinceEpoch);
    notifyListeners();
  }

  Future<Map<String, dynamic>> _post(String url, Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      final message = (json['error'] as Map<String, dynamic>?)?['message'] ??
          'Request failed (${res.statusCode}).';
      throw AuthException(_friendly(message.toString()));
    }
    return json;
  }

  /// Maps common Firebase error codes to readable messages.
  String _friendly(String code) {
    switch (code) {
      case 'EMAIL_EXISTS':
        return 'That email is already registered.';
      case 'EMAIL_NOT_FOUND':
      case 'INVALID_PASSWORD':
      case 'INVALID_LOGIN_CREDENTIALS':
        return 'Wrong email or password.';
      case 'WEAK_PASSWORD : Password should be at least 6 characters':
        return 'Password must be at least 6 characters.';
      default:
        return code;
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
