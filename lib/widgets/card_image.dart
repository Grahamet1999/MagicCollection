import 'package:flutter/material.dart';

/// Displays a card image from a network [url], with graceful loading and
/// fallback states so the UI never shows a broken image.
class CardImage extends StatelessWidget {
  const CardImage({super.key, required this.url, this.width, this.height});

  final String? url;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.style_outlined,
        size: (width ?? 60) * 0.4,
        color: Theme.of(context).colorScheme.outline,
      ),
    );

    final imageUrl = url;
    if (imageUrl == null || imageUrl.isEmpty) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        imageUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return SizedBox(
            width: width,
            height: height,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
        errorBuilder: (context, error, stack) => placeholder,
      ),
    );
  }
}
