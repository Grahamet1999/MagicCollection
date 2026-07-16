import 'package:flutter/material.dart';

/// Reusable single-field name-entry dialog. Returns the trimmed text, or null
/// if cancelled/empty.
Future<String?> promptForName(
  BuildContext context, {
  required String title,
  String label = 'Name',
  String? initial,
}) {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
