/// Firebase project settings for the cloud "group binder" feature.
///
/// Paste these from your Firebase console (Project settings → your Web app
/// config, and Realtime Database → the database URL). The Web API key is safe to
/// embed — it is not a secret; access is controlled by Realtime Database
/// security rules (see docs/firebase_setup.md).
///
/// While these are blank, [isConfigured] is false and the cloud/Groups features
/// are hidden; the rest of the app works normally on local storage.
class FirebaseConfig {
  /// Web API key, e.g. "AIzaSy...".
  static const String apiKey = 'AIzaSyA0W52Tw4GBJ_bbWW4iSs_eb687AXMEe8A';

  /// Project id, e.g. "my-mtg-app".
  static const String projectId = 'mtgcollection-1add3';

  /// Realtime Database URL, e.g.
  /// "https://my-mtg-app-default-rtdb.firebaseio.com".
  static const String databaseUrl =
      'https://mtgcollection-1add3-default-rtdb.firebaseio.com';

  static bool get isConfigured => apiKey.isNotEmpty && databaseUrl.isNotEmpty;
}
