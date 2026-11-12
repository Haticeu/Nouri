import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

/// Free, on-device food recognition (no API, no cost, works offline).
///
/// MobileCLIP-S0 turns the photo into a vector; `food_index.bin` holds one
/// vector per food in our database, made from its names and a short visual
/// description (supabase/seed/build_photo_index.mjs + looks.mjs). The closest
/// foods are offered to the user, who confirms them. The model never gives
/// calories: those come from the foods table.
///
/// Several crops are scored (whole photo, the four quarters and the centre)
/// so a plate with a few different foods can surface each of them.
class FoodPhotoRecognizer {
  FoodPhotoRecognizer._(this._session, this._index, this._keys, this._dim, this._size);

  static const _modelAsset = 'assets/ai/food_vision.onnx';
  static Future<FoodPhotoRecognizer>? _loading;

  final OrtSession _session;
  final Float32List _index;
  final List<String> _keys;
  final int _dim;
  final int _size;

  /// Scores (cosine similarity x 100) from testing on real photos: correct
  /// dishes score ~27-33, photos with no food ~14-18.
  static const noFoodBelow = 21.0;
  static const keepWithin = 3.0; // offer foods this close to the best one

  static Future<FoodPhotoRecognizer> instance() => _loading ??= _load().catchError((Object e) {
        _loading = null; // allow a retry
        throw e;
      });

  static Future<FoodPhotoRecognizer> _load() async {
    final meta = jsonDecode(await rootBundle.loadString('assets/ai/food_index.json')) as Map<String, dynamic>;
    final bin = await rootBundle.load('assets/ai/food_index.bin');
    final index = bin.buffer.asFloat32List(bin.offsetInBytes, bin.lengthInBytes ~/ 4);
    // On the web the plugin fetches the model by URL, and Flutter web serves assets under assets/.
    final session = kIsWeb
        ? await OnnxRuntime().createSession('assets/$_modelAsset')
        : await OnnxRuntime().createSessionFromAsset(_modelAsset);
    return FoodPhotoRecognizer._(
      session,
      Float32List.fromList(index),
      [for (final k in meta['keys'] as List) k as String],
      meta['dim'] as int,
      meta['image_size'] as int? ?? 256,
    );
  }

  /// Best matching foods for a photo, best first. Empty when it doesn't look like food.
  Future<List<PhotoGuess>> recognize(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return const [];
    final photo = img.bakeOrientation(decoded);
    final w = photo.width, h = photo.height;
    final crops = <img.Image>[
      photo,
      if (math.min(w, h) >= 400) ...[
        img.copyCrop(photo, x: 0, y: 0, width: w ~/ 2, height: h ~/ 2),
        img.copyCrop(photo, x: w ~/ 2, y: 0, width: w - w ~/ 2, height: h ~/ 2),
        img.copyCrop(photo, x: 0, y: h ~/ 2, width: w ~/ 2, height: h - h ~/ 2),
        img.copyCrop(photo, x: w ~/ 2, y: h ~/ 2, width: w - w ~/ 2, height: h - h ~/ 2),
        img.copyCrop(photo, x: w ~/ 5, y: h ~/ 5, width: w * 3 ~/ 5, height: h * 3 ~/ 5),
      ],
    ];

    final best = <String, double>{};
    double? whole;
    for (final (i, crop) in crops.indexed) {
      final scores = _score(await _embed(crop));
      if (i == 0) whole = scores.reduce(math.max);
      // Parts of the photo only add foods they are fairly sure about.
      final floor = i == 0 ? 0.0 : noFoodBelow + 3;
      for (var f = 0; f < scores.length; f++) {
        if (scores[f] < floor) continue;
        final k = _keys[f];
        if (scores[f] > (best[k] ?? -1)) best[k] = scores[f];
      }
    }
    if (best.isEmpty || (whole ?? 0) < noFoodBelow && best.values.reduce(math.max) < noFoodBelow + 3) return const [];
    final top = best.values.reduce(math.max);
    final guesses = [
      for (final e in best.entries)
        if (e.value >= top - keepWithin) PhotoGuess(e.key, e.value),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return guesses.take(6).toList();
  }

  /// Shortest side to [_size], centre crop, RGB in 0..1, CHW (MobileCLIP preprocessing).
  Future<Float32List> _embed(img.Image photo) async {
    final scale = _size / math.min(photo.width, photo.height);
    final resized = img.copyResize(
      photo,
      width: math.max(_size, (photo.width * scale).round()),
      height: math.max(_size, (photo.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
    final square = img.copyCrop(resized,
        x: (resized.width - _size) ~/ 2, y: (resized.height - _size) ~/ 2, width: _size, height: _size);
    final plane = _size * _size;
    final input = Float32List(3 * plane);
    for (final p in square) {
      final i = p.y * _size + p.x;
      input[i] = p.rNormalized.toDouble();
      input[plane + i] = p.gNormalized.toDouble();
      input[2 * plane + i] = p.bNormalized.toDouble();
    }
    final tensor = await OrtValue.fromList(input, [1, 3, _size, _size]);
    try {
      final outputs = await _session.run({_session.inputNames.first: tensor});
      final name = _session.outputNames.firstWhere((n) => n.contains('image_embeds'), orElse: () => _session.outputNames.first);
      final values = (await outputs[name]!.asList()).expand((x) => x is List ? x : [x]).map((x) => (x as num).toDouble()).toList();
      for (final o in outputs.values) {
        await o.dispose();
      }
      var norm = 0.0;
      for (final v in values) {
        norm += v * v;
      }
      norm = math.sqrt(norm);
      return Float32List.fromList([for (final v in values) v / norm]);
    } finally {
      await tensor.dispose();
    }
  }

  List<double> _score(Float32List image) {
    final n = _keys.length;
    final out = List<double>.filled(n, 0);
    for (var f = 0; f < n; f++) {
      var s = 0.0;
      final base = f * _dim;
      for (var i = 0; i < _dim; i++) {
        s += _index[base + i] * image[i];
      }
      out[f] = s * 100;
    }
    return out;
  }
}

class PhotoGuess {
  const PhotoGuess(this.seedKey, this.score);
  final String seedKey;
  final double score;

  Map<String, dynamic> toJson() => {'food': seedKey, 'score': double.parse(score.toStringAsFixed(2))};
}
