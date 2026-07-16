import 'package:flutter/material.dart';

import 'screens/startup_gate.dart';
import 'services/collection_store.dart';
import 'services/database_service.dart';
import 'services/deck_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The database connection is established by StartupGate so failures surface
  // as an in-app error screen with Retry rather than crashing at launch.
  final store = CollectionStore(DatabaseService.instance);
  final deckStore = DeckStore(DatabaseService.instance);
  runApp(MtgCollectionApp(store: store, deckStore: deckStore));
}

class MtgCollectionApp extends StatelessWidget {
  const MtgCollectionApp({
    super.key,
    required this.store,
    required this.deckStore,
  });

  final CollectionStore store;
  final DeckStore deckStore;

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
      home: StartupGate(store: store, deckStore: deckStore),
    );
  }
}
