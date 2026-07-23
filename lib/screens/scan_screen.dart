import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// One-shot log of the actual analysis-stream resolution (diagnostics).
  bool _frameLogged = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  /// Detection awaiting confirmation by a second consecutive frame.
  _Detection? _pending;

  /// Scryfall card json for the match currently shown for confirmation.
  Map<String, dynamic>? _candidate;
  bool _candidateFoil = false;
  int _candidateQty = 1;

  /// Detection key of the shown candidate, so adding/dismissing it can block
  /// an immediate re-detection of the same card still in frame.
  String? _candidateKey;

  /// How the current candidate was found, shown in the confirm bar.
  String _matchSource = '';

  /// Cards added this session (shown in the app bar).
  int _addedCount = 0;

  /// Transient status message (e.g. "No match for XYZ #12").
  String? _hint;
  Timer? _hintTimer;

  bool _torchOn = false;
  String? _cameraError;

  /// Focus/exposure lock for scanner rigs (phone mounted above a tray at a
  /// fixed distance): once locked, cards land already in focus with no AF
  /// hunting between feeds.
  bool _afLocked = false;

  /// Movable/resizable guide box: normalized center and width (fractions of
  /// the preview). Detection bands follow the guide, so the user can drag it
  /// over a card in a box instead of bringing the card to the center.
  /// Persisted across sessions.
  Offset _guideCenter = const Offset(0.5, 0.5);
  double _guideWidthFactor = 0.8;
  static const _guidePrefX = 'scan_guide_cx';
  static const _guidePrefY = 'scan_guide_cy';
  static const _guidePrefW = 'scan_guide_w';

  /// The guide rect in normalized (0..1) preview coordinates, recomputed on
  /// layout; the frame parser uses it to place the title/collector bands.
  Rect _guideRectNorm = const Rect.fromLTWH(0.1, 0.25, 0.8, 0.5);

  /// Gesture-start width, for pinch resizing.
  double _scaleStartWidth = 0.8;

  /// Auto-add mode: collector-line (exact printing) matches are added without
  /// the confirm tap. Name-fallback matches always confirm — fuzzy matches
  /// deserve a human glance. Persisted across sessions.
  bool _autoAdd = false;
  static const _autoAddPrefKey = 'scan_auto_add';

  /// End of the pause after an auto-add, giving the user time to swap cards
  /// before scanning resumes.
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// The last auto-added detection key. The same card can't auto-add again
  /// until a processed frame shows no card at all (i.e. it was removed or
  /// covered) — so a lingering card doesn't double-add, but scanning several
  /// copies of the same printing still works: each swap blanks the frame.
  String? _lastAutoKey;

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
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _autoAdd = prefs.getBool(_autoAddPrefKey) ?? false;
          _guideCenter = Offset(
            (prefs.getDouble(_guidePrefX) ?? 0.5).clamp(0.1, 0.9),
            (prefs.getDouble(_guidePrefY) ?? 0.5).clamp(0.1, 0.9),
          );
          _guideWidthFactor =
              (prefs.getDouble(_guidePrefW) ?? 0.8).clamp(0.4, 0.95);
        });
      }
    });
  }

  Future<void> _saveGuide() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_guidePrefX, _guideCenter.dx);
    await prefs.setDouble(_guidePrefY, _guideCenter.dy);
    await prefs.setDouble(_guidePrefW, _guideWidthFactor);
  }

  Future<void> _setAutoAdd(bool value) async {
    setState(() => _autoAdd = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoAddPrefKey, value);
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
      // Maximum resolution so the tiny collector line has enough pixels to
      // OCR even when the card is small in frame (the plugin negotiates down
      // on devices that can't stream this large).
      final controller = CameraController(
        back,
        ResolutionPreset.ultraHigh,
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
      // Aim autofocus/metering at the guide box rather than the whole scene
      // (a dark deck box or rig tray otherwise skews both).
      await _applyFocusPoint();
      if (_afLocked) await _applyAfLock(true);
      setState(() => _cameraError = null);
    } catch (e) {
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  /// Points focus + exposure metering at the center of the guide box.
  Future<void> _applyFocusPoint() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final p = Offset(
        _guideRectNorm.center.dx.clamp(0.05, 0.95),
        _guideRectNorm.center.dy.clamp(0.05, 0.95),
      );
      await controller.setFocusPoint(p);
      await controller.setExposurePoint(p);
    } catch (_) {
      // Not supported on every device — autofocus still works, just unaimed.
    }
  }

  Future<void> _applyAfLock(bool lock) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.setFocusMode(lock ? FocusMode.locked : FocusMode.auto);
    await controller
        .setExposureMode(lock ? ExposureMode.locked : ExposureMode.auto);
  }

  Future<void> _toggleAfLock() async {
    try {
      await _applyAfLock(!_afLocked);
      setState(() => _afLocked = !_afLocked);
      _showHint(_afLocked
          ? 'Focus & exposure locked — great for mounted scanning.'
          : 'Focus & exposure back to automatic.');
    } catch (_) {
      _showHint('Focus lock not supported on this device.');
    }
  }

  // ---- Frame pipeline ------------------------------------------------------

  Future<void> _onFrame(CameraImage image) async {
    // One frame at a time, ~3/s, and only while actively scanning.
    if (_busy || _phase != _Phase.scanning) return;
    final now = DateTime.now();
    // Post-auto-add pause: give the user time to swap cards.
    if (now.isBefore(_cooldownUntil)) return;
    if (now.difference(_lastProcessed) <
        const Duration(milliseconds: 350)) {
      return;
    }
    _busy = true;
    _lastProcessed = now;
    try {
      final input = _inputImageFrom(image);
      if (input == null) return;
      if (!_frameLogged) {
        _frameLogged = true;
        debugPrint('scan: analysis frame ${image.width}x${image.height}');
      }
      final recognized = await _recognizer.processImage(input);
      var det = _parse(recognized, _uprightSize(input));
      final sawAnyText = recognized.blocks.isNotEmpty;
      // The exact printing (collector line) always gets its best shot before
      // a name-only result is accepted: ML Kit downscales full frames
      // internally, which crushes the tiny collector print, so the zoomed
      // guide-crop pass runs both to *upgrade* a name-only detection and to
      // rescue a frame with no detection at all.
      if (det?.setCode == null && sawAnyText) {
        final zoomed = await _tryZoomed(image, input);
        if (zoomed != null) {
          det = _Detection(
            setCode: zoomed.setCode,
            number: zoomed.number,
            name: det?.name ?? zoomed.name,
            foil: zoomed.foil,
          );
        }
      }
      // Card fed upside down (ramp rigs): re-OCR the guide region rotated
      // 180°. Runs even when no text was seen — upside-down text is often
      // invisible to the recognizer entirely.
      det ??= await _tryFlipped(image, input);
      // Tilted card (lying in a pile): if the upright pass found nothing but
      // saw tilted text, deskew the frame to that text's angle and retry.
      det ??= await _tryDeskewed(image, input, recognized);
      if (det == null) {
        _pending = null;
        // The frame is empty — the auto-added card was removed, so the same
        // printing may auto-add again (next copy of a playset).
        _lastAutoKey = null;
        return;
      }
      // The just-auto-added card is still in frame — ignore it until it
      // leaves, so it can't double-add.
      if (det.key == _lastAutoKey) {
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

  // ---- Zoom recovery -------------------------------------------------------

  /// Recovers a card whose collector line is too small for the full-frame
  /// pass (ML Kit downscales large inputs internally, crushing tiny print):
  /// crops the guide region out of the frame's luma, upscales it, and re-runs
  /// OCR on just that. Collector-only: a stray rules-text line in the crop
  /// must never be mistaken for a card name.
  Future<_Detection?> _tryZoomed(CameraImage image, InputImage input) async {
    final zoomed = _zoomedInputImage(image, input, _guideRectNorm);
    if (zoomed == null) return null;
    final recognized = await _recognizer.processImage(zoomed.$1);
    return _parse(recognized, zoomed.$2, relaxed: true, collectorOnly: true);
  }

  /// Recovers a card fed upside down (common with ramp-style scanner rigs):
  /// re-OCRs the whole guide region rotated 180°. The crop enforces the
  /// guide region, so the parse runs relaxed.
  Future<_Detection?> _tryFlipped(CameraImage image, InputImage input) async {
    final flipped =
        _zoomedInputImage(image, input, _guideRectNorm, flip: true);
    if (flipped == null) return null;
    final recognized = await _recognizer.processImage(flipped.$1);
    return _parse(recognized, flipped.$2, relaxed: true);
  }

  /// Builds an upright grayscale NV21 image of the guide region at up to 2×
  /// scale (nearest-neighbor from the raw luma, folding the sensor rotation
  /// into the same pass). [flip] additionally rotates the crop 180°, for
  /// cards fed upside down. Returns null when the crop would be degenerate.
  (InputImage, Size)? _zoomedInputImage(
    CameraImage image,
    InputImage input,
    Rect guideNorm, {
    bool flip = false,
  }) {
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
    final uw = swap ? hb : wb; // upright frame dims
    final uh = swap ? wb : hb;

    // Crop rect in upright pixels, with a small margin around the guide.
    var left = ((guideNorm.left - 0.03) * uw).floor().clamp(0, uw - 1);
    var top = ((guideNorm.top - 0.03) * uh).floor().clamp(0, uh - 1);
    var right = ((guideNorm.right + 0.03) * uw).ceil().clamp(0, uw);
    var bottom = ((guideNorm.bottom + 0.03) * uh).ceil().clamp(0, uh);
    final cw = right - left;
    final ch = bottom - top;
    if (cw < 64 || ch < 64) return null;

    // 2× upscale, capped so the OCR input stays a sane size. NV21 wants even
    // dimensions. A flipped pass is worthwhile even without upscaling.
    final scale =
        math.min(2.0, math.min(3840 / cw, 3840 / ch)).clamp(1.0, 2.0);
    if (!flip && scale <= 1.05) return null; // nothing to gain
    final w = ((cw * scale).floor()) & ~1;
    final h = ((ch * scale).floor()) & ~1;

    final out = Uint8List(w * h + (w * h) ~/ 2);
    out.fillRange(w * h, out.length, 128); // neutral chroma
    var i = 0;
    for (var y = 0; y < h; y++) {
      final uy =
          flip ? bottom - 1 - (y ~/ scale) : top + y ~/ scale;
      for (var x = 0; x < w; x++, i++) {
        final ux =
            flip ? right - 1 - (x ~/ scale) : left + x ~/ scale;
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

  /// Extracts a collector number (and optional "/total") from an OCR line,
  /// tolerating the classic tiny-print misreads seen in the field: 0↔O,
  /// 1↔I/l/}/|, 5↔S, 8↔B, and the rarity letter glued to the digits
  /// ("C 0116" read as "CO116"). Guarded by a "mostly digits" requirement so
  /// rules/flavor text (e.g. "1ife.") can't produce a number. Returns null
  /// when the line isn't a plausible collector number.
  static (String, String?)? _numberFrom(String raw) {
    final up = raw.toUpperCase().trim();
    final digits = RegExp(r'\d').allMatches(up).length;
    if (digits == 0) return null;
    final alnum = RegExp(r'[A-Z0-9]').allMatches(up).length;
    if (digits * 2 < alnum) return null; // mostly letters — not a number line
    final mapped = up
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('}', '1')
        .replaceAll('|', '1')
        .replaceAll('S', '5')
        .replaceAll('B', '8')
        .replaceAll(RegExp(r'[^0-9/]'), '');
    final m =
        RegExp(r'^0*(\d{1,4})(?:/0*(\d{1,4}))?$').firstMatch(mapped);
    if (m == null) return null;
    return (m.group(1)!, m.group(2));
  }

  /// Set code + separator + language — e.g. "MH3 • EN", "MH3-EN", or OCR-fused
  /// "FINEN". OCR renders the little separator glyph unpredictably (•, ✦, *,
  /// ¢, …), so any single non-alphanumeric character is accepted. Foil
  /// printings print a star there, which [_isFoilSep] detects specifically.
  /// Not anchored: the caller requires the match at line start or after a
  /// numeric prefix ("C0116 FIN EN" as one OCR line).
  static final _setRe =
      RegExp(r'([A-Z0-9]{3,6})\s*([^A-Z0-9\s]?)\s*([A-Z]{2})\b');

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

  _Detection? _parse(
    RecognizedText text,
    Size frame, {
    bool relaxed = false,
    bool collectorOnly = false,
  }) {
    final lines = <TextLine>[
      for (final block in text.blocks) ...block.lines,
    ];

    String? setCode;
    String? number;

    // Only text inside the on-screen guide box counts, so neighboring cards
    // in frame (a box of cards, a binder page) can't hijack the match. The
    // bands derive from the guide's actual (user-movable) position — the
    // preview fills the screen, so normalized guide coordinates map straight
    // onto normalized frame coordinates. [relaxed] (the deskewed-retry path)
    // widens to most of the frame, since a card that was lying at an angle no
    // longer sits where the guide says after deskewing.
    final w = frame.width;
    final h = frame.height;
    final g = _guideRectNorm;
    bool centered(TextLine l) {
      final cx = l.boundingBox.center.dx;
      if (relaxed) return cx > w * 0.03 && cx < w * 0.97;
      return cx > w * (g.left - 0.02) && cx < w * (g.right + 0.02);
    }

    // Collector pair: anywhere inside the guide (the pair's own constraints
    // carry the precision; a vertical band only loses cards that sit low or
    // small within the guide).
    bool inGuide(TextLine l) {
      final cy = l.boundingBox.center.dy;
      if (relaxed) return centered(l) && cy > h * 0.02 && cy < h * 0.98;
      return centered(l) &&
          cy >= h * (g.top - 0.03) &&
          cy <= h * (g.bottom + 0.05);
    }

    // Title: the upper 60% of the guide (generous, since the card may sit
    // low within it) — still below the guide's top edge, so a second card
    // peeking above the guide is excluded.
    bool inTitleBand(TextLine l) {
      final cy = l.boundingBox.center.dy;
      if (relaxed) return centered(l) && cy <= h * 0.65;
      return centered(l) &&
          cy >= h * (g.top - 0.02) &&
          cy <= h * (g.top + g.height * 0.6);
    }

    var foil = false;

    // Collector search: collect number-line and set-line candidates inside
    // the guide, then pair them. A number+set fused into one OCR line
    // ("C0116 FIN EN") pairs with itself.
    final numLines = <(TextLine, String)>[];
    final setLines = <(TextLine, String, bool)>[];
    for (final l in lines) {
      if (!inGuide(l)) continue;
      final up = l.text.trim().toUpperCase();
      String numSource = up;
      final sm = _setRe.firstMatch(up);
      if (sm != null && _langs.contains(sm.group(3))) {
        final prefix = up.substring(0, sm.start).trim();
        // Accept the set match at line start, or after a numeric prefix —
        // never mid-sentence in rules text.
        if (sm.start == 0 || _numberFrom(prefix) != null) {
          setLines.add((l, sm.group(1)!, _isFoilSep(sm.group(2))));
          numSource = prefix; // the number, if any, is what precedes the set
        }
      }
      final n = _numberFrom(numSource);
      if (n != null && _plausibleTotal(n.$1, n.$2)) {
        numLines.add((l, n.$1));
      }
    }
    double best = double.infinity;
    for (final (nl, num) in numLines) {
      for (final (sl, code, starred) in setLines) {
        final sameLine = identical(nl, sl);
        final dy = (sl.boundingBox.top - nl.boundingBox.top).abs();
        final dx = (sl.boundingBox.left - nl.boundingBox.left).abs();
        final lineH = nl.boundingBox.height;
        // Same OCR line (fused number+set), or stacked directly and roughly
        // left-aligned.
        final score = sameLine ? -1.0 : dy;
        final adjacent =
            sameLine || (dy < lineH * 4 && dx < frame.width * 0.3);
        if (adjacent && score < best) {
          best = score;
          number = num;
          setCode = code;
          foil = starred;
        }
      }
    }

    // Title fallback: among plausible name lines in the title band, take the
    // TOPMOST of the tall ones — the title prints above the type/rules text
    // and at a similar or larger size, so "topmost tall line" beats "tallest
    // line" (rules text can measure taller than the title on some frames).
    // Skipped for collector-only passes (crops that exclude the title).
    String? name;
    if (!collectorOnly) {
      final candidates = <(TextLine, double)>[];
      for (final l in lines) {
        if (!inTitleBand(l)) continue;
        final t = l.text.trim();
        if (!_nameRe.hasMatch(t)) continue;
        if (!RegExp(r'[aeiouAEIOU]').hasMatch(t)) continue;
        candidates.add((l, l.boundingBox.height.toDouble()));
      }
      if (candidates.isNotEmpty) {
        final maxH =
            candidates.map((c) => c.$2).reduce(math.max);
        var bestCy = double.infinity;
        for (final (l, lineH) in candidates) {
          final cy = l.boundingBox.center.dy;
          if (lineH >= maxH * 0.8 && cy < bestCy) {
            bestCy = cy;
            name = l.text.trim();
          }
        }
      }
    }

    if (number != null && setCode != null) {
      return _Detection(
          setCode: setCode, number: number, name: name, foil: foil);
    }
    // Diagnostics: when the collector line didn't parse, log what OCR saw in
    // the collector band so misreads can be inspected via adb logcat.
    final seen = [
      for (final l in lines)
        if (inGuide(l))
          '"${l.text}" h=${l.boundingBox.height.round()}',
    ];
    if (seen.isNotEmpty) {
      final tag = collectorOnly ? 'zoom' : (relaxed ? 'relaxed' : 'base');
      debugPrint('scan[$tag]: no collector match; band saw: '
          '${seen.take(8).join(' | ')}');
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
      // Auto-add: collector-line matches are exact printings, safe to add
      // without confirmation. Then pause so the user can swap cards.
      if (_autoAdd && det.setCode != null) {
        final card = MtgCard.fromScryfall(json, foil: det.foil, quantity: 1);
        final result = await widget.store.addCard(card);
        if (!mounted) return;
        _lastAutoKey = det.key;
        _cooldownUntil = DateTime.now().add(const Duration(seconds: 2));
        setState(() {
          _addedCount += 1;
          _phase = _Phase.scanning;
        });
        final label = '${card.name} (${card.setCode} #${card.collectorNumber})'
            '${card.foil ? ' • Foil' : ''}';
        _showHint(result.merged
            ? 'Added $label — now ${result.quantity} owned. Next card…'
            : 'Added $label. Next card…');
        return;
      }
      setState(() {
        _candidate = json;
        _candidateKey = det.key;
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
    // Same-card guard + swap pause, as with auto-add.
    _lastAutoKey = _candidateKey;
    _cooldownUntil = DateTime.now().add(const Duration(seconds: 2));
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
    // The rejected card is presumably still in frame — don't re-match it
    // until it leaves (the guard clears on the next empty frame).
    _lastAutoKey = _candidateKey;
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
            tooltip: 'Reset scan box to center',
            icon: const Icon(Icons.filter_center_focus),
            onPressed: () {
              setState(() {
                _guideCenter = const Offset(0.5, 0.5);
                _guideWidthFactor = 0.8;
              });
              _saveGuide();
              _applyFocusPoint();
            },
          ),
          IconButton(
            tooltip: _afLocked
                ? 'Unlock focus & exposure'
                : 'Lock focus & exposure (for mounted/rig scanning)',
            icon: Icon(_afLocked ? Icons.lock : Icons.lock_open),
            onPressed: _toggleAfLock,
          ),
          // Auto-add: exact (collector-line) matches skip the confirm tap.
          Tooltip(
            message: 'Auto-add exact matches without confirming '
                '(name-only matches still ask)',
            child: FilterChip(
              label: const Text('Auto'),
              selected: _autoAdd,
              onSelected: _setAutoAdd,
            ),
          ),
          const SizedBox(width: 4),
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

  /// Card-shaped framing guide, draggable and pinch-resizable — the detection
  /// bands follow it, so it can be placed over a card lying anywhere in view
  /// (e.g. in a deck box) instead of bringing the card to the center. The
  /// app-bar reset button re-centers it.
  Widget _buildGuide() {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sw = constraints.maxWidth;
          final sh = constraints.maxHeight;
          // Guide size in pixels: chosen width, Magic card ratio (63×88mm),
          // clamped to fit vertically.
          var w = sw * _guideWidthFactor;
          var h = w * 88 / 63;
          if (h > sh * 0.9) {
            h = sh * 0.9;
            w = h * 63 / 88;
          }
          // Center clamped so the box stays fully on screen.
          final cx = (_guideCenter.dx * sw).clamp(w / 2, sw - w / 2);
          final cy = (_guideCenter.dy * sh).clamp(h / 2, sh - h / 2);
          final rect =
              Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
          // Published for the frame parser (normalized). Assigned without
          // setState — build is already running.
          _guideRectNorm = Rect.fromLTWH(
              rect.left / sw, rect.top / sh, rect.width / sw, rect.height / sh);

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: (_) => _scaleStartWidth = _guideWidthFactor,
            onScaleUpdate: (details) {
              setState(() {
                _guideCenter = Offset(
                  (_guideCenter.dx + details.focalPointDelta.dx / sw)
                      .clamp(0.1, 0.9),
                  (_guideCenter.dy + details.focalPointDelta.dy / sh)
                      .clamp(0.1, 0.9),
                );
                _guideWidthFactor =
                    (_scaleStartWidth * details.scale).clamp(0.4, 0.95);
              });
            },
            onScaleEnd: (_) {
              _saveGuide();
              _applyFocusPoint();
            },
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: IgnorePointer(
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
              ],
            ),
          );
        },
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
