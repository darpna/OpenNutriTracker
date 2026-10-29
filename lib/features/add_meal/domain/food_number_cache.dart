import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';

/// What a food's numbers per 100 g were settled as, and where they came from.
class CachedFoodNumbers {
  final Per100g per100g;

  /// True when a table match wrote them. A table value replaces a model value
  /// already stored; a model value never replaces anything.
  final bool fromTable;

  /// The table entry, when [fromTable].
  final String? matchedName;

  const CachedFoodNumbers(
    this.per100g, {
    this.fromTable = false,
    this.matchedName,
  });
}

/// Per-100 g numbers keyed by a food's normalised name, so the same food gets
/// the same numbers on every photo.
///
/// **First value wins, a table match beats the model.** A model asked twice
/// about white sugar answered 100 and 262 kcal/100 g; whichever arrived first
/// is what every later photo uses. The one exception is a value from the
/// bundled table, which replaces a model value: the table is the better
/// source, and it answers the same every time anyway.
abstract interface class FoodNumberCache {
  CachedFoodNumbers? read(String key);

  /// Stores [numbers] under [key] unless something is already there; a table
  /// value replaces a model value.
  Future<void> remember(String key, CachedFoodNumbers numbers);
}

/// The rule [FoodNumberCache.remember] states, for implementations to share.
bool shouldReplace(CachedFoodNumbers? existing, CachedFoodNumbers incoming) =>
    existing == null || (incoming.fromTable && !existing.fromTable);

/// A cache that lives as long as the object. For tests and the replay.
class MemoryFoodNumberCache implements FoodNumberCache {
  final _values = <String, CachedFoodNumbers>{};

  @override
  CachedFoodNumbers? read(String key) => _values[key];

  @override
  Future<void> remember(String key, CachedFoodNumbers numbers) async {
    if (shouldReplace(_values[key], numbers)) _values[key] = numbers;
  }

  int get length => _values.length;
}
