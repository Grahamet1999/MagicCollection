import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/mtg_card.dart';
import '../services/collection_store.dart';
import '../services/scryfall_service.dart';
import '../widgets/card_image.dart';

/// Camera-based card scanner (Android/iOS only).
///
/// Text-first detection: instead of trying to find the card's edges (fragile
/// with black borders, dark tables, glare), every frame is OCR'd in full and
/// the recognized lines are pattern-matched for the collector line printed on
/// modern cards ("0234/0303" + "MH3 • EN"), which resolves an exact printing
/// via Scryfall. Cards without a collector line fall back to matching the
/// title line by fuzzy name lookup. A match must repeat on two consecutive
/// frames before it's resolved, which filters out glare/blur misreads.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.store});

  final CollectionStore store;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

/// Scanner lifecycle: streaming frames → resolving a match via Scryfall →
/// waiting for the user to confirm the candidate card.
enum _Phase { scanning, resolving, confirming }

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _scryfall = ScryfallService();

  _Phase _phase = _Phase.scanning;
  bool _busy = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  /// Detection awaiting confirmation by a second consecutive frame.
  _Detection? _pending;

  /// Scryfall card json for the match currently shown for confirmation.
  Map<String, dynamic>? _candidate;
  bool _candidateFoil = false;
  int _candidateQty = 1;

  /// How the current candidate was found, shown in the confirm bar.
  String _matchSource = '';

  /// Cards added this session (shown in the app bar).
  int _addedCount = 0;

  /// Transient status message (e.g. "No match for XYZ #12").
  String? _hint;
  Timer? _hintTimer;

  bool _torchOn = false;
  String? _cameraError;

  /// Device-orientation → rotation degrees, for ML Kit rotation compensation.
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    _controller?.dispose();
    _recognizer.close();
    _scryfall.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera when backgrounded; reacquire on return.
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // High resolution so the tiny collector line has enough pixels to OCR.
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller = controller;
      await controller.startImageStream(_onFrame);
      setState(() => _cameraError = null);
    } catch (e) {
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  // ---- Frame pipeline ------------------------------------------------------

  Future<void> _onFrame(CameraImage image) async {
    // One frame at a time, ~3/s, and only while actively scanning.
    if (_busy || _phase != _Phase.scanning) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) <
        const Duration(milliseconds: 350)) {
      return;
    }
    _busy = true;
    _lastProcessed = now;
    try {
      final input = _inputImageFrom(image);
      if (input == null) return;
      final recognized = await _recognizer.processImage(input);
      var det = _parse(recognized, _uprightSize(input));
      // Tilted card (lying in a pile): if the upright pass found nothing but
      // saw tilted text, deskew the frame to that text's angle and retry.
      det ??= await _tryDeskewed(image, input, recognized);
      if (det == null) {
        _pending = null;
        return;
      }
      // Stability rule: the same detection must appear on two consecutive
      // processed frames before we act on it.
      if (_pending != null && _pending!.key == det.key) {
        _pending = null;
        await _resolve(det);
      } else {
        _pending = det;
      }
    } catch (_) {
      // Per-frame failures (rotation hiccups, recognizer errors) are dropped;
      // the next frame simply tries again.
    } finally {
      _busy = false;
    }
  }

  /// Converts a camera frame to an ML Kit [InputImage], following the standard
  /// camera→mlkit recipe (nv21 single-plane on Android, bgra8888 on iOS).
  InputImage? _inputImageFrom(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;
    final camera = controller.description;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    } else {
      var compensation = _orientations[controller.value.deviceOrientation];
      if (compensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        compensation = (camera.sensorOrientation + compensation) % 360;
      } else {
        compensation =
            (camera.sensorOrientation - compensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(compensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null || image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// Frame size in the upright (post-rotation) coordinate space ML Kit
  /// reports bounding boxes in.
  Size _uprightSize(InputImage input) {
    final meta = input.metadata!;
    final rotated = meta.rotation == InputImageRotation.rotation90deg ||
        meta.rotation == InputImageRotation.rotation270deg;
    return rotated
        ? Size(meta.size.height, meta.size.width)
        : meta.size;
  }

  // ---- Tilt recovery -------------------------------------------------------

  /// Recovers a card lying at an angle: measures the baseline tilt of the most
  /// prominent text ML Kit saw, resamples the frame's luma rotated to level
  /// that text, and re-runs OCR on the deskewed image. Region filtering is
  /// relaxed on the retry (the deskewed card no longer sits where the guide
  /// says) — safe because neighboring cards at *other* angles stay unreadable
  /// in an image leveled to this card's angle.
  Future<_Detection?> _tryDeskewed(
    CameraImage image,
    InputImage input,
    RecognizedText base,
  ) async {
    // The tallest tilted line with real text — on a card that's almost always
    // the title.
    TextLine? pick;
    double bestHeight = 0;
    for (final block in base.blocks) {
      for (final line in block.lines) {
        if (line.text.trim().length < 4) continue;
        if (line.cornerPoints.length < 2) continue;
        if (line.boundingBox.height > bestHeight) {
          bestHeight = line.boundingBox.height;
          pick = line;
        }
      }
    }
    if (pick == null) return null;
    final p0 = pick.cornerPoints[0];
    final p1 = pick.cornerPoints[1];
    final theta = math.atan2(
      (p1.y - p0.y).toDouble(),
      (p1.x - p0.x).toDouble(),
    );
    final degrees = theta.abs() * 180 / math.pi;
    // Nearly level (the upright pass already had its chance) or beyond
    // correction (upside down / sideways-mirrored) — skip.
    if (degrees < 8 || degrees > 85) return null;

    final deskewed = _deskewedInputImage(image, input, theta);
    if (deskewed == null) return null;
    final recognized = await _recognizer.processImage(deskewed.$1);
    return _parse(recognized, deskewed.$2, relaxed: true);
  }

  /// Builds an upright, deskewed grayscale NV21 image from a camera frame:
  /// each output pixel inverse-maps through the deskew rotation ([theta],
  /// measured in upright coordinates) and then through the sensor rotation
  /// into the raw luma buffer. Chroma is filled neutral — OCR only reads luma.
  (InputImage, Size)? _deskewedInputImage(
    CameraImage image,
    InputImage input,
    double theta,
  ) {
    final meta = input.metadata!;
    final deg = switch (meta.rotation) {
      InputImageRotation.rotation0deg => 0,
      InputImageRotation.rotation90deg => 90,
      InputImageRotation.rotation180deg => 180,
      InputImageRotation.rotation270deg => 270,
    };
    final wb = image.width;
    final hb = image.height;
    final plane = image.planes.first;
    final stride = plane.bytesPerRow;
    final src = plane.bytes;
    final swap = deg == 90 || deg == 270;
    final w = swap ? hb : wb;
    final h = swap ? wb : hb;

    final out = Uint8List(w * h + (w * h) ~/ 2);
    out.fillRange(w * h, out.length, 128); // neutral chroma
    final cx = (w - 1) / 2;
    final cy = (h - 1) / 2;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    var i = 0;
    for (var y = 0; y < h; y++) {
      final dy = y - cy;
      for (var x = 0; x < w; x++, i++) {
        final dx = x - cx;
        // Deskew inverse map in upright coordinates.
        final ux = (cosT * dx - sinT * dy + cx).round();
        final uy = (sinT * dx + cosT * dy + cy).round();
        if (ux < 0 || ux >= w || uy < 0 || uy >= h) {
          out[i] = 128;
          continue;
        }
        // Upright → raw buffer coordinates (inverse of the CW sensor
        // rotation that makes the buffer upright).
        final int bx;
        final int by;
        switch (deg) {
          case 90:
            bx = uy;
            by = hb - 1 - ux;
          case 180:
            bx = wb - 1 - ux;
            by = hb - 1 - uy;
          case 270:
            bx = wb - 1 - uy;
            by = ux;
          default:
            bx = ux;
            by = uy;
        }
        out[i] = src[by * stride + bx];
      }
    }

    final size = Size(w.toDouble(), h.toDouble());
    return (
      InputImage.fromBytes(
        bytes: out,
        metadata: InputImageMetadata(
          size: size,
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: w,
        ),
      ),
      size,
    );
  }

  // ---- Text parsing --------------------------------------------------------

  /// Two-letter language codes that appear on the collector line. Requiring
  /// one of these keeps ALL-CAPS name text from being mistaken for a set line.
  static const _langs = {
    'EN', 'ES', 'FR', 'DE', 'IT', 'PT', 'JA', 'JP', 'KO', 'RU', 'CS', 'CT',
    'PH', 'LA',
  };

  /// Collector number line: optional rarity letter, digits, optional "/total",
  /// optional promo star — e.g. "0234/0303", "U 0234", "234", "123★".
  static final _numRe =
      RegExp(r'^(?:[A-Z]\s+)?0*(\d{1,4})(?:\s*/\s*(\d{1,4}))?\s*[★†]?$');

  /// Set line: set code + separator + language — e.g. "MH3 • EN", "MH3-EN".
  /// Foil printings use a star as the separator ("ECL ★ EN"), which both
  /// matches here and marks the card as foil.
  static final _setRe =
      RegExp(r'^([A-Z0-9]{3,6})\s*([•·∙・.\-★☆✶]?)\s*([A-Z]{2})\b');

  /// Both parts merged into a single OCR line — e.g. "0234/0303 MH3 • EN".
  static final _combinedRe = RegExp(
      r'^(?:[A-Z]\s+)?0*(\d{1,4})(?:\s*/\s*(\d{1,4}))?\s*[★†]?\s+'
      r'([A-Z0-9]{3,6})\s*([•·∙・.\-★☆✶]?)\s*([A-Z]{2})\b');

  /// True when a matched separator is the foil star.
  static bool _isFoilSep(String? sep) =>
      sep != null && RegExp(r'[★☆✶]').hasMatch(sep);

  /// Rejects power/toughness boxes ("1/1", "3/4") masquerading as collector
  /// numbers: a real "number/total" collector line has a total that's at
  /// least the number itself and at least 10 (no set is smaller).
  static bool _plausibleTotal(String? number, String? total) {
    if (total == null) return true; // no slash part — nothing to check
    final n = int.tryParse(number ?? '') ?? 0;
    final t = int.tryParse(total) ?? 0;
    return t >= 10 && t >= n;
  }

  /// Plausible card-name line for the title fallback.
  static final _nameRe = RegExp(r"^[A-Za-z][A-Za-z'\-,. ]{2,40}$");

  _Detection? _parse(RecognizedText text, Size frame, {bool relaxed = false}) {
    final lines = <TextLine>[
      for (final block in text.blocks) ...block.lines,
    ];

    String? setCode;
    String? number;

    // Only text inside the on-screen guide box counts, so neighboring cards
    // in frame (a box of cards, a binder page) can't hijack the match. The
    // guide is centered and spans roughly the middle half of the frame
    // vertically; the bands below approximate its regions with margin.
    // [relaxed] (the deskewed-retry path) widens the bands, since a card that
    // was lying at an angle no longer sits where the guide says.
    final w = frame.width;
    final h = frame.height;
    bool centered(TextLine l) {
      final cx = l.boundingBox.center.dx;
      final margin = relaxed ? 0.03 : 0.10;
      return cx > w * margin && cx < w * (1 - margin);
    }

    // Collector line: the bottom edge of the guide card — below its midpoint
    // but not beneath the guide (where another card on the table could sit).
    bool inBottom(TextLine l) {
      final cy = l.boundingBox.center.dy;
      if (relaxed) return centered(l) && cy >= h * 0.35;
      return centered(l) && cy >= h * 0.50 && cy <= h * 0.85;
    }

    // Title: the upper band of the guide card — below the guide's top edge,
    // so a second card peeking above the guide is excluded.
    bool inTitleBand(TextLine l) {
      final cy = l.boundingBox.center.dy;
      if (relaxed) return centered(l) && cy <= h * 0.65;
      return centered(l) && cy >= h * 0.27 && cy <= h * 0.52;
    }

    var foil = false;

    // Pass 1: both parts merged into one line.
    for (final l in lines) {
      if (!inBottom(l)) continue;
      final m = _combinedRe.firstMatch(l.text.trim().toUpperCase());
      if (m != null &&
          _langs.contains(m.group(5)) &&
          _plausibleTotal(m.group(1), m.group(2))) {
        number = m.group(1);
        setCode = m.group(3);
        foil = _isFoilSep(m.group(4));
        break;
      }
    }

    // Pass 2: number line + set line as separate, vertically adjacent lines.
    if (number == null) {
      final numLines = <TextLine>[];
      final setLines = <(TextLine, String, bool)>[];
      for (final l in lines) {
        if (!inBottom(l)) continue;
        final t = l.text.trim().toUpperCase();
        final nm = _numRe.firstMatch(t);
        if (nm != null && _plausibleTotal(nm.group(1), nm.group(2))) {
          numLines.add(l);
        }
        final m = _setRe.firstMatch(t);
        if (m != null && _langs.contains(m.group(3))) {
          setLines.add((l, m.group(1)!, _isFoilSep(m.group(2))));
        }
      }
      double best = double.infinity;
      for (final n in numLines) {
        for (final (s, code, starred) in setLines) {
          final dy = (s.boundingBox.top - n.boundingBox.top).abs();
          final dx = (s.boundingBox.left - n.boundingBox.left).abs();
          final h = n.boundingBox.height;
          // Stacked directly (dy small) and left-aligned (dx small).
          if (dy < h * 4 && dx < frame.width * 0.3 && dy < best) {
            best = dy;
            number = _numRe
                .firstMatch(n.text.trim().toUpperCase())!
                .group(1);
            setCode = code;
            foil = starred;
          }
        }
      }
    }

    // Title fallback: the tallest plausible name line in the guide's title
    // band.
    String? name;
    double nameHeight = 0;
    for (final l in lines) {
      if (!inTitleBand(l)) continue;
      final t = l.text.trim();
      if (!_nameRe.hasMatch(t)) continue;
      if (!RegExp(r'[aeiouAEIOU]').hasMatch(t)) continue;
      if (l.boundingBox.height > nameHeight) {
        nameHeight = l.boundingBox.height;
        name = t;
      }
    }

    if (number != null && setCode != null) {
      return _Detection(
          setCode: setCode, number: number, name: name, foil: foil);
    }
    if (name != null && name.length >= 4) {
      return _Detection(name: name);
    }
    return null;
  }

  // ---- Resolution + confirmation -------------------------------------------

  Future<void> _resolve(_Detection det) async {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.resolving;
      _hint = null;
    });
    try {
      Map<String, dynamic>? json;
      String source = '';
      if (det.setCode != null && det.number != null) {
        json = await _scryfall.getBySetAndNumber(det.setCode!, det.number!);
        source = 'Collector line: ${det.setCode} #${det.number}';
      }
      // Collector line unreadable/unmatched → try the title.
      if (json == null && det.name != null) {
        json = await _scryfall.getByFuzzyName(det.name!);
        source = 'Name match: "${det.name}"';
      }
      if (!mounted) return;
      if (json == null) {
        _showHint('No match — hold the card flatter or closer.');
        setState(() => _phase = _Phase.scanning);
        return;
      }
      setState(() {
        _candidate = json;
        // Foil printings mark their collector line with a ★ separator, so the
        // toggle can be pre-set from the scan (still user-adjustable).
        _candidateFoil = det.foil;
        _candidateQty = 1;
        _matchSource = source;
        _phase = _Phase.confirming;
      });
    } catch (e) {
      if (!mounted) return;
      _showHint('Lookup failed: $e');
      setState(() => _phase = _Phase.scanning);
    }
  }

  void _showHint(String message) {
    _hintTimer?.cancel();
    setState(() => _hint = message);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  Future<void> _addCandidate() async {
    final json = _candidate;
    if (json == null) return;
    final card = MtgCard.fromScryfall(
      json,
      foil: _candidateFoil,
      quantity: _candidateQty,
    );
    final result = await widget.store.addCard(card);
    if (!mounted) return;
    setState(() {
      _addedCount += _candidateQty;
      _candidate = null;
      _phase = _Phase.scanning;
    });
    final label = '${card.name} (${card.setCode} #${card.collectorNumber})';
    _showHint(result.merged
        ? 'Updated $label — now ${result.quantity} owned.'
        : 'Added ${card.quantity}× $label.');
  }

  void _dismissCandidate() {
    setState(() {
      _candidate = null;
      _phase = _Phase.scanning;
    });
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller
          .setFlashMode(_torchOn ? FlashMode.off : FlashMode.torch);
      setState(() => _torchOn = !_torchOn);
    } catch (_) {
      _showHint('Torch not available on this device.');
    }
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_addedCount == 0 ? 'Scan cards' : 'Scan cards — $_addedCount added'),
        actions: [
          IconButton(
            tooltip: _torchOn ? 'Torch off' : 'Torch on',
            icon: Icon(_torchOn ? Icons.flash_off : Icons.flash_on),
            onPressed: _toggleTorch,
          ),
        ],
      ),
      body: _cameraError != null
          ? _buildCameraError()
          : Stack(
              fit: StackFit.expand,
              children: [
                if (_controller != null && _controller!.value.isInitialized)
                  CameraPreview(_controller!)
                else
                  const Center(child: CircularProgressIndicator()),
                _buildGuide(),
                if (_hint != null) _buildHint(),
                if (_phase == _Phase.resolving) _buildResolving(),
                if (_phase == _Phase.confirming && _candidate != null)
                  _buildConfirmBar(),
              ],
            ),
    );
  }

  Widget _buildCameraError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 48),
            const SizedBox(height: 16),
            Text(
              'Camera unavailable:\n$_cameraError',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initCamera,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  /// Card-shaped framing guide. Purely ergonomic — detection runs on the
  /// whole frame — but it puts the card at a distance where the collector
  /// line is large enough to OCR.
  Widget _buildGuide() {
    return IgnorePointer(
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.8,
          child: AspectRatio(
            // Magic card aspect ratio (63mm × 88mm).
            aspectRatio: 63 / 88,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.6),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHint() {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _hint!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildResolving() {
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Looking up…', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom overlay showing the matched card for one-tap confirmation.
  /// Showing the actual printing's artwork makes a wrong match obvious at a
  /// glance and one tap to reject.
  Widget _buildConfirmBar() {
    final json = _candidate!;
    final preview = MtgCard.fromScryfall(
      json,
      foil: _candidateFoil,
      quantity: _candidateQty,
    );
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CardImage(
                      url: preview.imageUrl,
                      width: 80,
                      height: 112,
                      enlargeOnHover: false,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preview.name,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${preview.setCode} #${preview.collectorNumber}'
                            '${preview.priceUsd != null ? ' • \$${preview.priceUsd!.toStringAsFixed(2)}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _matchSource,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.outline),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Not this card',
                      icon: const Icon(Icons.close),
                      onPressed: _dismissCandidate,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Foil toggle
                    FilterChip(
                      label: const Text('Foil'),
                      selected: _candidateFoil,
                      onSelected: (v) =>
                          setState(() => _candidateFoil = v),
                    ),
                    const SizedBox(width: 12),
                    // Quantity stepper
                    IconButton(
                      icon: const Icon(Icons.remove),
                      onPressed: _candidateQty > 1
                          ? () => setState(() => _candidateQty--)
                          : null,
                    ),
                    Text('$_candidateQty',
                        style: Theme.of(context).textTheme.titleMedium),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () => setState(() => _candidateQty++),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _addCandidate,
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One frame's parsed identification: an exact printing (set + collector
/// number) when the collector line was readable, otherwise a title-text name
/// candidate. [key] is what must repeat across frames for stability.
class _Detection {
  _Detection({this.setCode, this.number, this.name, this.foil = false});

  final String? setCode;
  final String? number;
  final String? name;

  /// True when the collector line's ★ separator marked a foil printing.
  final bool foil;

  String get key => setCode != null ? '$setCode/$number' : 'name:$name';
}
