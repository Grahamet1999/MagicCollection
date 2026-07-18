/// Firebase project settings for the cloud "group binder" feature.
///
/// These values are compiled into the app, so the packaged build is
/// self-contained (no extra config file to ship). The Web API key is safe to
/// embed — it is not a secret; access is controlled by Realtime Database
/// security rules, and the key is API-restricted in Google Cloud. See
/// docs/firebase_setup.md.
///
/// Leave the values blank to disable the cloud/Groups features (the rest of the
/// app then works purely on local storage).
class FirebaseConfig {
  static const String apiKey = 'AIzaSyDHsnxCAgq4sl30NL59EG8woxiKMoge578';
  static const String projectId = 'mtgcollection-1add3';
  static const String databaseUrl =
      'https://mtgcollection-1add3-default-rtdb.firebaseio.com';

  static bool get isConfigured => apiKey.isNotEmpty && databaseUrl.isNotEmpty;
}
