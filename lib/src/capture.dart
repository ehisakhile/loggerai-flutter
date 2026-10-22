// Pictures of the app's own screen, for reports: a screenshot, and a screen
// recording the user starts and stops. Text fields (and anything wrapped in
// LoggerAIMask) are painted over before a frame is kept, so passwords and card
// numbers never leave the device. No plugin: Flutter draws the screen, so it
// can take a picture of what it drew.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Hides what it wraps in screenshots and recordings sent with reports.
///
/// ```dart
/// LoggerAIMask(child: Text(user.accountNumber))
/// ```
class LoggerAIMask extends StatelessWidget {
  const LoggerAIMask({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

const _maskColor = Color(0xFF9AA3AD);

/// The rectangles (in logical pixels, from the top left of the screen) to hide.
List<Rect> sensitiveAreas({bool textFields = true}) {
  final out = <Rect>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is LoggerAIMask || (textFields && w is EditableText)) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        out.add(ro.localToGlobal(Offset.zero) & ro.size);
        return; // everything inside is covered
      }
    }
    e.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return out;
}

/// A picture of the screen as Flutter last drew it, at most [maxWidth] pixels wide,
/// with sensitive areas painted over. Null when there's nothing to capture.
Future<ui.Image?> captureScreen({double maxWidth = 480, bool maskTextFields = true}) async {
  final views = WidgetsBinding.instance.renderViews;
  if (views.isEmpty) return null;
  final view = views.first;
  // ignore: invalid_use_of_protected_member
  final layer = view.layer;
  if (layer is! OffsetLayer) return null;
  final size = view.size; // logical
  final dpr = view.flutterView.devicePixelRatio;
  final physical = Size(size.width * dpr, size.height * dpr);
  if (physical.isEmpty) return null;
  final scale = (maxWidth / physical.width).clamp(0.05, 1.0);
  final masks = sensitiveAreas(textFields: maskTextFields);
  // The root layer scales logical pixels to physical ones: capture in physical pixels.
  final raw = await layer.toImage(Offset.zero & physical, pixelRatio: scale);
  if (masks.isEmpty) return raw;
  final w = raw.width, h = raw.height;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawImage(raw, Offset.zero, Paint());
  final k = dpr * scale;
  final paint = Paint()..color = _maskColor;
  for (final r in masks) {
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(r.left * k, r.top * k, r.width * k, r.height * k), const Radius.circular(4)), paint);
  }
  final out = await rec.endRecording().toImage(w, h);
  raw.dispose();
  return out;
}

Future<Uint8List?> png(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

/// A screenshot as PNG bytes, or null.
Future<Uint8List?> screenshotPng({double maxWidth = 480, bool maskTextFields = true}) async {
  try {
    final img = await captureScreen(maxWidth: maxWidth, maskTextFields: maskTextFields);
    if (img == null) return null;
    final bytes = await png(img);
    img.dispose();
    return bytes;
  } catch (_) {
    return null; // a report goes without its picture rather than not at all
  }
}

/// Records the screen a few times a second until [stop] (or [maxDuration], or
/// [maxBytes]). The frames are written as one LREC file the dashboard plays.
class ScreenRecorder {
  ScreenRecorder({this.fps = 2, this.maxDuration = const Duration(seconds: 60), this.maxBytes = 20 * 1024 * 1024, this.maxWidth = 400, this.maskTextFields = true});

  final int fps;
  final Duration maxDuration;
  final int maxBytes;
  final double maxWidth;
  final bool maskTextFields;

  final _frames = <(int, Uint8List)>[];
  final _done = Completer<Uint8List?>();
  final _clock = Stopwatch();
  Timer? _timer;
  bool _busy = false;
  int _bytes = 0;
  int _width = 0, _height = 0;

  bool get recording => _timer != null;
  Duration get elapsed => _clock.elapsed;
  int get frameCount => _frames.length;

  /// Completes with the recording when it stops (null if no frame was captured).
  Future<Uint8List?> get done => _done.future;

  void start() {
    if (_timer != null || _done.isCompleted) return;
    _clock.start();
    _tick();
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ fps), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_busy || _done.isCompleted) return;
    if (_clock.elapsed >= maxDuration || _bytes >= maxBytes) {
      stop();
      return;
    }
    _busy = true;
    try {
      final t = _clock.elapsedMilliseconds;
      final img = await captureScreen(maxWidth: maxWidth, maskTextFields: maskTextFields);
      if (img != null) {
        final bytes = await png(img);
        _width = img.width;
        _height = img.height;
        img.dispose();
        if (bytes != null && !_done.isCompleted) {
          _frames.add((t, bytes));
          _bytes += bytes.length;
        }
      }
    } catch (_) {
      // a frame missed; the next one may work
    } finally {
      _busy = false;
    }
  }

  /// Stops and builds the recording.
  Future<Uint8List?> stop() {
    if (!_done.isCompleted) {
      _timer?.cancel();
      _timer = null;
      _clock.stop();
      _done.complete(_frames.isEmpty ? null : encodeRecording(_frames, _width, _height));
    }
    return _done.future;
  }

  /// Stops and throws the frames away.
  void cancel() {
    _frames.clear();
    stop();
  }
}

/// The LREC format: "LREC", a 4-byte big-endian header length, a JSON header
/// {v, width, height, frames: [{t, o, n}]}, then the images.
Uint8List encodeRecording(List<(int, Uint8List)> frames, int width, int height) {
  final meta = <Map<String, int>>[];
  var offset = 0;
  for (final (t, img) in frames) {
    meta.add({'t': t, 'o': offset, 'n': img.length});
    offset += img.length;
  }
  final head = utf8.encode(jsonEncode({'v': 1, 'width': width, 'height': height, 'frames': meta}));
  final out = BytesBuilder(copy: false)
    ..add(ascii.encode('LREC'))
    ..add((ByteData(4)..setUint32(0, head.length)).buffer.asUint8List())
    ..add(head);
  for (final (_, img) in frames) {
    out.add(img);
  }
  return out.takeBytes();
}
