// The parts of the photo replay harness that need neither the network nor the
// app's UI: ids, the output shape, pacing and retry. Kept apart from
// replay_test.dart so the normal test tree can cover them.
//
// PRIVACY: nothing here may ever carry a photo's file name or path. A name can
// hold a date or a place. A photo is identified by a hash of its bytes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';

/// First ten characters of the SHA-1 of the file's bytes. Stable for the same
/// photo whatever it is called or wherever it lives.
String photoId(List<int> bytes) =>
    sha1.convert(bytes).toString().substring(0, 10);

/// File extensions the harness reads. HEIC cannot be decoded without a native
/// library; the private-repo workflow converts it to JPEG first.
const replayExtensions = {'.jpg', '.jpeg', '.png'};

/// Image files under [dir], recursively, in a stable order. Order only; the
/// names are never written anywhere.
List<File> listPhotos(Directory dir) {
  final files = <File>[
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      if (entity is File && _isPhoto(entity.path)) entity,
  ]..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

bool _isPhoto(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return replayExtensions.contains(path.substring(dot).toLowerCase());
}

/// The caption in `<name>.txt` beside [photo], or null when there is none or it
/// is blank.
String? captionFor(File photo) {
  final path = photo.path;
  final dot = path.lastIndexOf('.');
  final sidecar = File('${path.substring(0, dot)}.txt');
  if (!sidecar.existsSync()) return null;
  final text = sidecar.readAsStringSync().trim();
  return text.isEmpty ? null : text;
}

/// One food, as the app would have logged it.
class ReplayItem {
  final String name;

  /// `db` for a food-database match, `ai_estimate` for the model's own numbers.
  final String source;

  /// The database food's name; null for an AI estimate.
  final String? dbName;

  final double? grams;
  final double? kcal;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;

  /// True while the amount is still the model's estimate.
  final bool estimated;

  const ReplayItem({
    required this.name,
    required this.source,
    required this.dbName,
    required this.grams,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.estimated,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'source': source,
    'db_name': dbName,
    'grams': _round(grams),
    'kcal': _round(kcal),
    'protein_g': _round(proteinG),
    'carbs_g': _round(carbsG),
    'fat_g': _round(fatG),
    'estimated': estimated,
  };
}

/// What the app would have logged for one photo.
class ReplayResult {
  final String id;
  final String? caption;

  /// The dish the photo was read as, when it was one composed dish.
  final String? dish;
  final List<ReplayItem> items;

  /// Foods the model named that nothing in the database or its own numbers
  /// could stand in for, so the app would not have logged them.
  final List<String> unmatched;

  /// Set when nothing could be read: a failure kind, never a message from the
  /// provider.
  final String? error;

  /// The recipe estimate's portion in grams, and the model's own confidence.
  final double? portionG;
  final String? confidence;

  /// Totals with the bundled table's numbers where it knew the ingredient
  /// (what the app shows), and the same ingredients with the model's numbers
  /// only. The pair is what shows whether the table helps.
  final EstimateTotals? grounded;
  final EstimateTotals? aiOnly;

  const ReplayResult({
    required this.id,
    required this.caption,
    this.dish,
    this.items = const [],
    this.unmatched = const [],
    this.error,
    this.portionG,
    this.confidence,
    this.grounded,
    this.aiOnly,
  });

  double get totalKcal =>
      items.fold(0.0, (sum, item) => sum + (item.kcal ?? 0));

  Map<String, Object?> toJson() => {
    'id': id,
    'caption': caption,
    'dish': dish,
    'items': [for (final item in items) item.toJson()],
    'unmatched': unmatched,
    'total_kcal': _round(totalKcal),
    'error': error,
    'portion_g': _round(portionG),
    'confidence': confidence,
    'grounded': _totals(grounded),
    'ai_only': _totals(aiOnly),
  };
}

Map<String, Object?>? _totals(EstimateTotals? t) => t == null
    ? null
    : {
        'grams': _round(t.grams),
        'kcal': _round(t.kcal),
        'protein_g': _round(t.proteinG),
        'carbs_g': _round(t.carbsG),
        'fat_g': _round(t.fatG),
      };

double? _round(double? value) =>
    value == null ? null : double.parse(value.toStringAsFixed(1));

/// What the bulk-add screen would log for a loaded batch: the rows that
/// `willBeLogged`, with the numbers the review rows show.
ReplayResult resultFromLoaded({
  required String id,
  required String? caption,
  required BulkAddLoadedState state,
}) {
  final items = <ReplayItem>[];
  final unmatched = <String>[];
  for (final row in state.rows) {
    if (!row.isResolved) {
      unmatched.add(row.resolved.parsed.query);
      continue;
    }
    if (!row.willBeLogged) continue;
    final meal = row.meal!;
    final grams = row.baseAmount;
    final nutriments = meal.nutriments;
    double? scaled(double? perUnit) =>
        perUnit == null || grams == null ? null : perUnit * grams;
    items.add(
      ReplayItem(
        name: row.resolved.parsed.query,
        source: row.usesAiEstimate ? 'ai_estimate' : 'db',
        dbName: row.usesAiEstimate ? null : meal.name,
        grams: grams,
        kcal: row.kcal,
        proteinG: scaled(nutriments.proteinsPerUnit),
        carbsG: scaled(nutriments.carbohydratesPerUnit),
        fatG: scaled(nutriments.fatPerUnit),
        estimated: row.isEstimated,
      ),
    );
  }
  final estimate = state.dish?.estimate;
  return ReplayResult(
    id: id,
    caption: caption,
    dish: state.dish?.name,
    items: items,
    unmatched: unmatched,
    portionG: estimate?.portionG,
    confidence: estimate?.confidence.name,
    grounded: estimate?.totals,
    aiOnly: estimate?.aiOnly,
  );
}

/// The whole output file.
String encodeReplay({
  required String model,
  required String baseUrl,
  required List<ReplayResult> results,
}) => const JsonEncoder.withIndent('  ').convert({
  'model': model,
  'base_url': baseUrl,
  'photos': [for (final result in results) result.toJson()],
});

/// Seconds to wait from a `Retry-After` header, or [fallback] when it is
/// absent or not a plain number of seconds, capped at [cap].
Duration retryAfter(
  Map<String, String> headers, {
  Duration fallback = const Duration(seconds: 30),
  Duration cap = const Duration(seconds: 120),
}) {
  final raw = headers.entries
      .where((e) => e.key.toLowerCase() == 'retry-after')
      .map((e) => e.value)
      .firstOrNull;
  final seconds = raw == null ? null : double.tryParse(raw.trim());
  if (seconds == null || seconds < 0) return fallback;
  final wait = Duration(milliseconds: (seconds * 1000).ceil());
  return wait > cap ? cap : wait;
}

/// Spaces requests at least [minGap] apart. The clock and the wait are
/// injectable so the arithmetic can be tested without waiting.
class RequestPacer {
  final Duration minGap;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  DateTime? _last;

  RequestPacer({
    required this.minGap,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
  }) : _now = now ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed;

  /// Completes when a request may go out, and records that one did.
  Future<void> acquire() async {
    final last = _last;
    if (last != null) {
      final elapsed = _now().difference(last);
      if (elapsed < minGap) await _wait(minGap - elapsed);
    }
    _last = _now();
  }
}

/// Wraps the transport so that every request is paced and a 429 is retried
/// after the provider's own `Retry-After`, up to [maxRetries] times. At the
/// transport so the interpreters run exactly as the app runs them.
///
/// Only ever logs a status code and a wait, never a URL, body or header.
class ReplayHttpClient extends http.BaseClient {
  final http.Client _inner;
  final RequestPacer _pacer;
  final int maxRetries;
  final Future<void> Function(Duration) _wait;
  final void Function(String) _log;

  ReplayHttpClient(
    this._inner,
    this._pacer, {
    this.maxRetries = 3,
    Future<void> Function(Duration)? wait,
    void Function(String)? log,
  }) : _wait = wait ?? Future<void>.delayed,
       _log = log ?? ((_) {});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // The body is replayed from memory on a retry, which a one-shot stream
    // cannot do. Every request the app's clients make is a plain `Request`.
    final original = request as http.Request;
    for (var attempt = 0; ; attempt++) {
      await _pacer.acquire();
      final copy = http.Request(original.method, original.url)
        ..headers.addAll(original.headers)
        ..bodyBytes = original.bodyBytes;
      final response = await _inner.send(copy);
      if (response.statusCode != 429 || attempt >= maxRetries) return response;

      final wait = retryAfter(response.headers);
      await response.stream.drain<void>();
      _log(
        '429; waiting ${wait.inSeconds}s (retry ${attempt + 1}/$maxRetries)',
      );
      await _wait(wait);
    }
  }
}

/// Bytes of [file], for hashing and encoding.
Uint8List readBytes(File file) => file.readAsBytesSync();
