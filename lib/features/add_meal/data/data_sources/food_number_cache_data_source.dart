import 'dart:convert';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';

/// [FoodNumberCache] on a Hive box shared by every profile, like the Open
/// Food Facts cache: a food's numbers are a fact about the food, not about the
/// person who photographed it.
///
/// Each value is a small JSON string (`{"n": [kcal, p, c, f], "t": true,
/// "m": "Oil, coconut"}`), so the box needs no adapter and no code generation.
class FoodNumberCacheDataSource implements FoodNumberCache {
  static final _log = Logger('FoodNumberCacheDataSource');

  final Box<String> _box;

  FoodNumberCacheDataSource(this._box);

  @override
  CachedFoodNumbers? read(String key) {
    final raw = _box.get(key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final per100g = Per100g.fromList(json['n']);
      if (per100g == null) return null;
      final matched = json['m'];
      return CachedFoodNumbers(
        per100g,
        fromTable: json['t'] == true,
        matchedName: matched is String ? matched : null,
      );
    } catch (_) {
      // A value this build cannot read is no value: the next photo writes one.
      return null;
    }
  }

  @override
  Future<void> remember(String key, CachedFoodNumbers numbers) async {
    if (!shouldReplace(read(key), numbers)) return;
    try {
      await _box.put(
        key,
        jsonEncode({
          'n': numbers.per100g.toList(),
          if (numbers.fromTable) 't': true,
          if (numbers.matchedName != null) 'm': numbers.matchedName,
        }),
      );
    } catch (e, st) {
      // Losing the write only costs consistency on a later photo, never this
      // one: the numbers are already in the estimate being shown.
      _log.warning('Could not store food numbers', e, st);
    }
  }
}
