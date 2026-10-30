import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';

/// How long the model's own numbers for a food are trusted before the next
/// photo of it asks again. A table value never expires.
const foodNumberMaxAge = Duration(days: 30);

/// What a food's numbers per 100 g were settled as, and where they came from.
class CachedFoodNumbers {
  final Per100g per100g;

  /// True when a table match wrote them. A table value replaces a model value
  /// already stored; a model value never replaces a table value.
  final bool fromTable;

  /// The table entry, when [fromTable].
  final String? matchedName;

  /// When the numbers were settled. Null for an entry written before dates
  /// were kept: its age is unknown, so a model value is treated as expired.
  final DateTime? checkedAt;

  const CachedFoodNumbers(
    this.per100g, {
    this.fromTable = false,
    this.matchedName,
    this.checkedAt,
  });

  /// True when these are the model's numbers and more than [foodNumberMaxAge]
  /// old at [now], or of unknown age: the next photo of the food should check
  /// them again rather than use them.
  bool isExpiredAt(DateTime now) {
    if (fromTable) return false;
    final checked = checkedAt;
    return checked == null || now.difference(checked) > foodNumberMaxAge;
  }
}

/// Per-100 g numbers keyed by a food's normalised name, so the same food gets
/// the same numbers on every photo.
///
/// **A table match beats the model; the model's numbers expire.** A model
/// asked twice about white sugar answered 100 and 262 kcal/100 g; whichever
/// arrived first is what later photos use, for [foodNumberMaxAge]. A value
/// from the bundled table replaces a model value at once: the table is the
/// better source, and it answers the same every time anyway. A model value
/// that has expired is replaced by the next one, so one wrong but plausible
/// figure cannot stay forever.
abstract interface class FoodNumberCache {
  CachedFoodNumbers? read(String key);

  /// Stores [numbers] under [key] when [shouldReplace] says so.
  Future<void> remember(String key, CachedFoodNumbers numbers);
}

/// The rule [FoodNumberCache.remember] states, for implementations to share:
/// nothing stored yet, a table value over a model value, or anything over a
/// model value that has expired by the time [incoming] was checked.
bool shouldReplace(CachedFoodNumbers? existing, CachedFoodNumbers incoming) {
  if (existing == null) return true;
  if (incoming.fromTable && !existing.fromTable) return true;
  return existing.isExpiredAt(incoming.checkedAt ?? DateTime.now());
}

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
