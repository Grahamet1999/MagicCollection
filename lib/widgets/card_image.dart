import 'package:flutter/material.dart';

import '../services/card_image_cache.dart';

/// Displays a card image from a network [url], with graceful loading and
/// fallback states so the UI never shows a broken image. Images read through
/// [CardImageCache]: once fetched they render from disk, so the collection
/// stays visible offline and when Scryfall is down.
///
/// On desktop, hovering the image pops a large floating preview of the full
/// (uncropped) card — handy for the small thumbnails in lists and grids. Turn
/// this off with [enlargeOnHover] where the image is already shown large.
class CardImage extends StatefulWidget {
  const CardImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.enlargeOnHover = true,
  });

  /// Image URL to load; a null/empty value shows the placeholder.
  final String? url;

  /// Optional fixed width; null lets the parent size it.
  final double? width;

  /// Optional fixed height; null lets the parent size it.
  final double? height;

  /// Whether hovering pops an enlarged floating preview (desktop only). No-op
  /// when there is no image to show.
  final bool enlargeOnHover;

  @override
  State<CardImage> createState() => _CardImageState();
}

class _CardImageState extends State<CardImage> {
  OverlayEntry? _preview;

  bool get _hasImage => widget.url != null && widget.url!.isNotEmpty;

  @override
  void dispose() {
    _removePreview();
    super.dispose();
  }

  /// Inserts the floating enlarged preview next to this thumbnail.
  void _showPreview() {
    if (_preview != null || !_hasImage || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final anchor = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorSize = box.size;
    final screen = overlayBox.size;

    // A 5:7 Magic card, sized to the available height with a margin.
    const margin = 12.0;
    final double previewH =
        (screen.height - 2 * margin).clamp(180.0, 460.0).toDouble();
    final double previewW = previewH * 5 / 7;

    // Prefer to the right of the thumbnail; fall back to the left if it would
    // run off-screen.
    var left = anchor.dx + anchorSize.width + margin;
    if (left + previewW + margin > screen.width) {
      left = anchor.dx - previewW - margin;
    }
    left = left.clamp(margin, screen.width - previewW - margin).toDouble();

    // Vertically centered on the thumbnail, clamped on-screen.
    var top = anchor.dy + anchorSize.height / 2 - previewH / 2;
    top = top.clamp(margin, screen.height - previewH - margin).toDouble();

    _preview = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        // IgnorePointer so the preview never intercepts the hover that spawned
        // it (which would otherwise flicker enter/exit).
        child: IgnorePointer(
          child: Container(
            width: previewW,
            height: previewH,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 18, spreadRadius: 2),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image(
                // By hover time the thumbnail has usually cached the file;
                // fall back to the network if not.
                image: CardImageCache.cachedProviderSync(widget.url!) ??
                    NetworkImage(widget.url!),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_preview!);
  }

  void _removePreview() {
    _preview?.remove();
    _preview = null;
  }

  @override
  Widget build(BuildContext context) {
    final image = _buildImage(context);
    if (!widget.enlargeOnHover || !_hasImage) return image;
    return MouseRegion(
      onEnter: (_) => _showPreview(),
      onExit: (_) => _removePreview(),
      child: image,
    );
  }

  Widget _buildImage(BuildContext context) {
    final placeholder = Container(
      width: widget.width,
      height: widget.height,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.style_outlined,
        size: (widget.width ?? 60) * 0.4,
        color: Theme.of(context).colorScheme.outline,
      ),
    );

    if (!_hasImage) return placeholder;

    final loading = SizedBox(
      width: widget.width,
      height: widget.height,
      child: const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );

    // Fast path: already on disk — render synchronously, no spinner frame.
    final cached = CardImageCache.cachedProviderSync(widget.url!);
    if (cached != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image(
          image: cached,
          width: widget.width,
          height: widget.height,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) => placeholder,
        ),
      );
    }

    // Slow path: fetch through the cache (downloads and stores the file the
    // first time this printing is ever displayed on this device).
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: FutureBuilder<ImageProvider>(
        future: CardImageCache.resolve(widget.url!),
        builder: (context, snapshot) {
          if (snapshot.hasError) return placeholder;
          final provider = snapshot.data;
          if (provider == null) return loading;
          return Image(
            image: provider,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) => placeholder,
          );
        },
      ),
    );
  }
}
