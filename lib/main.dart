import 'package:flutter/material.dart';

import 'screens/startup_gate.dart';
import 'services/auth_service.dart';
import 'services/card_image_cache.dart';
import 'services/cloud_backup_service.dart';
import 'services/collection_store.dart';
import 'services/database_service.dart';
import 'services/deck_store.dart';
import 'services/group_service.dart';

/// App entry point. Constructs the shared, long-lived services and hands them to
/// the widget tree; actual database connection happens later in [StartupGate].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Prepare the on-disk card image cache (images render offline once cached).
  await CardImageCache.init();
  // The database connection is established by StartupGate so failures surface
  // as an in-app error screen with Retry rather than crashing at launch.
  final store = CollectionStore(DatabaseService.instance);
  final deckStore = DeckStore(DatabaseService.instance);
  final auth = AuthService();
  final groups = GroupService(auth);
  final backup = CloudBackupService(auth, DatabaseService.instance)
    ..attach(store, deckStore);
  runApp(MtgCollectionApp(
    store: store,
    deckStore: deckStore,
    auth: auth,
    groups: groups,
    backup: backup,
  ));
}

/// Root widget: sets up the dark Material 3 theme and hands the shared services
/// to [StartupGate], which initializes the database before showing the UI.
class MtgCollectionApp extends StatelessWidget {
  const MtgCollectionApp({
    super.key,
    required this.store,
    required this.deckStore,
    required this.auth,
    required this.groups,
    required this.backup,
  });

  /// Collection/folders state shared by the Collection and Import tabs.
  final CollectionStore store;

  /// Deck-building state for the Decks tab.
  final DeckStore deckStore;

  /// Firebase authentication (drives the sign-in button and Groups access).
  final AuthService auth;

  /// Cloud group binder service, gated behind [auth].
  final GroupService groups;

  /// Cloud backup/sync of the collection and decks (auto-push + manual).
  final CloudBackupService backup;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MTG Collection',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6A4CB5),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: StartupGate(
        store: store,
        deckStore: deckStore,
        auth: auth,
        groups: groups,
        backup: backup,
      ),
    );
  }
}
