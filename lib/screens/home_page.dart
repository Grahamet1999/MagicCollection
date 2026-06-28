import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/collection_store.dart';
import '../services/csv_export_service.dart';
import '../services/database_service.dart';
import 'collection_tab.dart';
import 'import_tab.dart';

enum _ExportFormat { standard, moxfield }

/// The main two-tab screen shown once the database connection is established.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.store});

  final CollectionStore store;

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

  @override
  Widget build(BuildContext context) {
    final db = DatabaseService.instance;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('MTG Collection'),
          actions: [
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
                  label: Text(db.usingLocalFallback ? 'Local file' : 'SQL Server'),
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.add_box_outlined), text: 'Import'),
              Tab(icon: Icon(Icons.grid_view), text: 'Collection'),
            ],
          ),
        ),
        body: TabBarView(
          // Disable swipe so the folder sidebar's horizontal gestures work.
          physics: const NeverScrollableScrollPhysics(),
          children: [
            ImportTab(store: store),
            CollectionTab(store: store),
          ],
        ),
      ),
    );
  }
}
