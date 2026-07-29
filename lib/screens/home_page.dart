import 'dart:async' show unawaited;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/card_image_cache.dart';
import '../services/cloud_backup_service.dart';
import '../services/collection_store.dart';
import '../services/csv_export_service.dart';
import '../services/database_service.dart';
import '../services/deck_store.dart';
import '../services/firebase_config.dart';
import '../services/group_service.dart';
import 'auth_dialog.dart';
import 'collection_tab.dart';
import 'decks_tab.dart';
import 'groups_screen.dart';
import 'import_tab.dart';

/// CSV export flavors offered in the download menu.
enum _ExportFormat { standard, moxfield }

/// Entries in the compact (phone) top-bar overflow menu.
enum _OverflowAction {
  refreshPrices,
  exportStandard,
  exportMoxfield,
  backupNow,
  restoreCloud,
  about,
}

/// Entries in the wide layout's cloud menu.
enum _CloudAction { backupNow, restoreCloud }

/// The main three-tab screen shown once the database connection is established.
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.store,
    required this.deckStore,
    required this.auth,
    required this.groups,
    required this.backup,
  });

  // Shared services used across the tabs and top-bar actions.
  final CollectionStore store;
  final DeckStore deckStore;
  final AuthService auth;
  final GroupService groups;
  final CloudBackupService backup;

  /// Manually pushes a snapshot to the cloud, reporting via SnackBar.
  Future<void> _backupNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!auth.isSignedIn) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Sign in first to back up.')),
      );
      return;
    }
    try {
      await backup.push(force: true);
      messenger.showSnackBar(
        const SnackBar(content: Text('Collection backed up to the cloud.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  /// Confirms and restores the cloud snapshot, replacing this device's data.
  Future<void> _restoreFromCloud(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!auth.isSignedIn) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Sign in first to restore.')),
      );
      return;
    }
    try {
      final meta = await backup.fetchMeta();
      if (meta == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No cloud backup exists yet.')),
        );
        return;
      }
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore from cloud?'),
          content: Text(
            'Cloud backup from ${meta.device}: ${meta.cards} cards, '
            '${meta.decks} decks.\n\nThis replaces the collection, folders, '
            'and decks on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (go != true) return;
      await backup.restore();
      await store.load();
      await deckStore.load();
      // The restored cards may be new to this device — fetch their images in
      // the background so the collection renders offline later.
      unawaited(CardImageCache.warm(DatabaseService.instance));
      messenger.showSnackBar(
        const SnackBar(content: Text('Restored from cloud backup.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  /// Builds the CSV for [format], prompts for a save location, and writes it,
  /// reporting success/failure via a SnackBar. No-op if the collection is empty
  /// or the save dialog is cancelled.
  Future<void> _export(BuildContext context, _ExportFormat format) async {
    final messenger = ScaffoldMessenger.of(context);
    final db = DatabaseService.instance;
    final cards = await db.getCards();
    if (cards.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Your collection is empty.')),
      );
      return;
    }
    final folders = {for (final f in await db.getFolders()) f.id!: f.name};

    final csv = switch (format) {
      _ExportFormat.standard => CsvExportService.standard(cards, folders),
      _ExportFormat.moxfield => CsvExportService.moxfield(cards),
    };
    final defaultName = switch (format) {
      _ExportFormat.standard => 'mtg_collection.csv',
      _ExportFormat.moxfield => 'moxfield_collection.csv',
    };

    final path = await FilePicker.saveFile(
      dialogTitle: 'Export collection',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (path == null) return; // cancelled
    final finalPath = path.toLowerCase().endsWith('.csv') ? path : '$path.csv';

    try {
      await File(finalPath).writeAsString(csv);
      messenger.showSnackBar(
        SnackBar(content: Text('Exported ${cards.length} entries to $finalPath')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  /// Shows a blocking progress dialog while [CollectionStore.refreshPrices]
  /// re-fetches prices from Scryfall, then reports how many changed.
  Future<void> _refreshPrices(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Text('Refreshing prices from Scryfall…'),
          ],
        ),
      ),
    );
    try {
      final result = await store.refreshPrices();
      navigator.pop(); // close the progress dialog
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.total == 0
              ? 'No cards to update.'
              : 'Updated ${result.updated} of ${result.total} card prices.'),
        ),
      );
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Price refresh failed: $e')),
      );
    }
  }

  /// Opens the Groups screen, or the sign-in dialog first if not signed in.
  void _openGroups(BuildContext context) {
    if (!auth.isSignedIn) {
      showAuthDialog(context, auth);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GroupsScreen(auth: auth, groups: groups, store: store),
    ));
  }

  /// Builds the top-bar account control, rebuilding on auth changes: a single
  /// "Groups — Sign in" button when signed out, or a Groups button plus an
  /// account menu (email + Sign out) when signed in. In [compact] (phone)
  /// layouts the labeled buttons shrink to plain icons to fit the app bar.
  Widget _buildAccountAction(BuildContext context, {required bool compact}) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.isSignedIn) {
          if (compact) {
            return IconButton(
              tooltip: 'Groups — Sign in',
              icon: const Icon(Icons.groups),
              onPressed: () => showAuthDialog(context, auth),
            );
          }
          // A single clear entry point: opens sign-in, which then leads to Groups.
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilledButton.tonalIcon(
              onPressed: () => showAuthDialog(context, auth),
              icon: const Icon(Icons.groups),
              label: const Text('Groups — Sign in'),
            ),
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (compact)
              IconButton(
                tooltip: 'Groups',
                icon: const Icon(Icons.groups),
                onPressed: () => _openGroups(context),
              )
            else
              FilledButton.tonalIcon(
                onPressed: () => _openGroups(context),
                icon: const Icon(Icons.groups),
                label: const Text('Groups'),
              ),
            PopupMenuButton<String>(
              tooltip: auth.currentUser!.email,
              icon: const Icon(Icons.account_circle),
              onSelected: (v) {
                if (v == 'signout') auth.signOut();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    enabled: false, child: Text(auth.currentUser!.email)),
                const PopupMenuItem(value: 'signout', child: Text('Sign out')),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Shows the standard About dialog (shared by the wide and compact top bars).
  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'MTG Collection',
      applicationVersion: '1.0.0',
      applicationIcon: const Icon(Icons.style_outlined, size: 40),
      applicationLegalese: '© 2026 @oosshh\nReleased under the MIT License.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = DatabaseService.instance;
    // On phone-width screens the labeled buttons and chip can't all fit, so the
    // secondary actions collapse into a single overflow menu.
    final compact = MediaQuery.sizeOf(context).width < 600;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('MTG Collection'),
          actions: [
            if (FirebaseConfig.isConfigured)
              _buildAccountAction(context, compact: compact),
            if (compact)
              PopupMenuButton<_OverflowAction>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onSelected: (a) {
                  switch (a) {
                    case _OverflowAction.refreshPrices:
                      _refreshPrices(context);
                    case _OverflowAction.exportStandard:
                      _export(context, _ExportFormat.standard);
                    case _OverflowAction.exportMoxfield:
                      _export(context, _ExportFormat.moxfield);
                    case _OverflowAction.backupNow:
                      _backupNow(context);
                    case _OverflowAction.restoreCloud:
                      _restoreFromCloud(context);
                    case _OverflowAction.about:
                      _showAbout(context);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _OverflowAction.refreshPrices,
                    child: Text('Refresh prices'),
                  ),
                  const PopupMenuItem(
                    value: _OverflowAction.exportStandard,
                    child: Text('Export to CSV'),
                  ),
                  const PopupMenuItem(
                    value: _OverflowAction.exportMoxfield,
                    child: Text('Export to Moxfield CSV'),
                  ),
                  if (FirebaseConfig.isConfigured) ...[
                    const PopupMenuItem(
                      value: _OverflowAction.backupNow,
                      child: Text('Back up to cloud'),
                    ),
                    const PopupMenuItem(
                      value: _OverflowAction.restoreCloud,
                      child: Text('Restore from cloud…'),
                    ),
                  ],
                  const PopupMenuItem(
                    value: _OverflowAction.about,
                    child: Text('About'),
                  ),
                  // Storage indicator (informational, not tappable).
                  PopupMenuItem(
                    enabled: false,
                    child: Text('Storage: ${db.backendDescription}'),
                  ),
                ],
              )
            else ...[
              IconButton(
                tooltip: 'Refresh prices from Scryfall',
                icon: const Icon(Icons.refresh),
                onPressed: () => _refreshPrices(context),
              ),
              IconButton(
                tooltip: 'About',
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showAbout(context),
              ),
              PopupMenuButton<_ExportFormat>(
                tooltip: 'Export collection',
                icon: const Icon(Icons.download),
                onSelected: (f) => _export(context, f),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _ExportFormat.standard,
                    child: Text('Export to CSV'),
                  ),
                  PopupMenuItem(
                    value: _ExportFormat.moxfield,
                    child: Text('Export to Moxfield CSV'),
                  ),
                ],
              ),
              if (FirebaseConfig.isConfigured)
                PopupMenuButton<_CloudAction>(
                  tooltip: 'Cloud backup',
                  icon: const Icon(Icons.cloud_sync),
                  onSelected: (a) {
                    switch (a) {
                      case _CloudAction.backupNow:
                        _backupNow(context);
                      case _CloudAction.restoreCloud:
                        _restoreFromCloud(context);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _CloudAction.backupNow,
                      child: Text('Back up to cloud'),
                    ),
                    PopupMenuItem(
                      value: _CloudAction.restoreCloud,
                      child: Text('Restore from cloud…'),
                    ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: db.usingLocalFallback
                      ? 'SQL Server not detected — using a local file on this PC.\n'
                          '${db.backendDescription}'
                      : 'Connected to ${db.backendDescription}',
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      db.usingLocalFallback ? Icons.sd_storage : Icons.dns,
                      size: 16,
                    ),
                    label:
                        Text(db.usingLocalFallback ? 'Local file' : 'SQL Server'),
                  ),
                ),
              ),
            ],
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.add_box_outlined), text: 'Import'),
              Tab(icon: Icon(Icons.grid_view), text: 'Collection'),
              Tab(icon: Icon(Icons.dashboard_customize), text: 'Decks'),
            ],
          ),
        ),
        body: TabBarView(
          // Disable swipe so the folder sidebar's horizontal gestures work.
          physics: const NeverScrollableScrollPhysics(),
          children: [
            ImportTab(store: store),
            CollectionTab(store: store, deckStore: deckStore),
            DecksTab(store: deckStore, auth: auth),
          ],
        ),
      ),
    );
  }
}
