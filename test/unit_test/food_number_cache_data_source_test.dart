import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:opennutritracker/features/add_meal/data/data_sources/food_number_cache_data_source.dart';
import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';

const _rice = Per100g(kcal: 130, proteinG: 2.7, carbsG: 28.2, fatG: 0.3);
const _wrongRice = Per100g(kcal: 200, proteinG: 4, carbsG: 44, fatG: 0.5);

void main() {
  late Directory dir;
  late Box<String> box;
  late FoodNumberCacheDataSource cache;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('food_number_cache_test');
    Hive.init(dir.path);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() async {
    box = await Hive.openBox<String>(
      'food_numbers_${DateTime.now().microsecondsSinceEpoch}',
    );
    cache = FoodNumberCacheDataSource(box);
  });

  tearDown(() => box.deleteFromDisk());

  test('keeps the date and the source through a round trip', () async {
    final checked = DateTime(2026, 10, 1, 12);
    await cache.remember(
      'rice',
      CachedFoodNumbers(
        _rice,
        fromTable: true,
        matchedName: 'Rice, white, cooked',
        checkedAt: checked,
      ),
    );

    final read = cache.read('rice')!;
    expect(read.per100g, _rice);
    expect(read.fromTable, isTrue);
    expect(read.matchedName, 'Rice, white, cooked');
    expect(read.checkedAt, checked);
  });

  test('an entry from before dates were kept is a model value of unknown '
      'age, whatever it says', () async {
    // Written by an earlier build: no `d`, and here claiming the table.
    await box.put(
      'rice',
      jsonEncode({
        'n': _wrongRice.toList(),
        't': true,
        'm': 'Rice, white, cooked',
      }),
    );

    final read = cache.read('rice')!;
    expect(read.per100g, _wrongRice);
    expect(read.fromTable, isFalse);
    expect(read.checkedAt, isNull);
    expect(read.isExpiredAt(DateTime.now()), isTrue);
  });

  test('a model value replaces an old entry on next use', () async {
    await box.put('rice', jsonEncode({'n': _wrongRice.toList()}));
    final now = DateTime(2026, 10, 30);

    await cache.remember('rice', CachedFoodNumbers(_rice, checkedAt: now));

    expect(cache.read('rice')!.per100g, _rice);
    expect(cache.read('rice')!.checkedAt, now);
  });

  test('a fresh model value is kept over a later one; an expired one is '
      'not', () async {
    final day0 = DateTime(2026, 10, 1);
    await cache.remember('rice', CachedFoodNumbers(_rice, checkedAt: day0));

    await cache.remember(
      'rice',
      CachedFoodNumbers(
        _wrongRice,
        checkedAt: day0.add(const Duration(days: 10)),
      ),
    );
    expect(cache.read('rice')!.per100g, _rice);

    await cache.remember(
      'rice',
      CachedFoodNumbers(
        _wrongRice,
        checkedAt: day0.add(foodNumberMaxAge + const Duration(days: 1)),
      ),
    );
    expect(cache.read('rice')!.per100g, _wrongRice);
  });

  test('a table value replaces a fresh model value at once', () async {
    final day0 = DateTime(2026, 10, 1);
    await cache.remember(
      'rice',
      CachedFoodNumbers(_wrongRice, checkedAt: day0),
    );

    await cache.remember(
      'rice',
      CachedFoodNumbers(_rice, fromTable: true, checkedAt: day0),
    );

    expect(cache.read('rice')!.per100g, _rice);
    expect(cache.read('rice')!.fromTable, isTrue);
  });
}
