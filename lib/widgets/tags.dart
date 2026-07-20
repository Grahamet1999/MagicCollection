import 'package:flutter/material.dart';

/// Suggested trade tags offered in the tag editor and filters.
const List<String> kTradeTags = ['Trade', 'Want', 'Keep'];

/// A stable-ish color for a tag chip (presets get fixed colors).
Color tagColor(String tag) {
  switch (tag) {
    case 'Trade':
      return const Color(0xFF9BD3AE); // green
    case 'Want':
      return const Color(0xFFAAE0FA); // blue
    case 'Keep':
      return const Color(0xFFCBC2BF); // grey
    default:
      return const Color(0xFFE3D4F5); // purple-ish for custom
  }
}

/// Small colored chip used to display a tag.
Widget tagChip(String tag) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: tagColor(tag),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      tag,
      style: const TextStyle(
          color: Colors.black87, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );
}

/// Shows the multi-select tag editor (presets + custom). Returns the chosen tags
/// or null if cancelled.
Future<List<String>?> showTagEditor(
  BuildContext context,
  List<String> initial,
) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _TagEditorDialog(initial: initial),
  );
}

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({required this.initial});
  final List<String> initial;

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  late final Set<String> _selected = {...widget.initial};
  final _customController = TextEditingController();

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = <String>{...kTradeTags, ..._selected}.toList();
    return AlertDialog(
      title: const Text('Edit tags'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final tag in options)
                FilterChip(
                  label: Text(tag),
                  selected: _selected.contains(tag),
                  onSelected: (v) => setState(
                      () => v ? _selected.add(tag) : _selected.remove(tag)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customController,
                  decoration: const InputDecoration(
                    labelText: 'Add custom tag',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addCustom(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.add), onPressed: _addCustom),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: const Text('Save'),
        ),
      ],
    );
  }

  /// Adds the typed custom tag to the selection and clears the field.
  void _addCustom() {
    final t = _customController.text.trim();
    if (t.isNotEmpty) {
      setState(() {
        _selected.add(t);
        _customController.clear();
      });
    }
  }
}
