import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate_processor.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';

Map<String, Object?> _ingredient(
  String name,
  num grams, {
  num? kcal,
  num protein = 0,
  num carbs = 0,
  num fat = 0,
  bool? visible,
}) => {
  'name': name,
  'grams': grams,
  'per100g': {
    'kcal': kcal ?? 4 * protein + 4 * carbs + 9 * fat,
    'protein_g': protein,
    'carbs_g': carbs,
    'fat_g': fat,
  },
  'visible': ?visible,
};

Map<String, Object?> _rice(num grams) => _ingredient(
  'Rice, white, cooked',
  grams,
  protein: 2.7,
  carbs: 28,
  fat: 0.3,
);

Map<String, Object?> _lentils(num grams) =>
    _ingredient('Lentils, cooked', grams, protein: 9, carbs: 20, fat: 0.4);

Map<String, Object?> _dish({
  String name = 'Rice and dal',
  Object? portion = 300,
  Object? servings = 1.0,
  List<Object?>? ingredients,
  Object? confidence = 'medium',
  Object? assumptions = const <Object?>[],
}) => {
  'name': name,
  'portion_g': portion,
  'servings': servings,
  'ingredients': ingredients ?? [_rice(200), _lentils(100)],
  'confidence': confidence,
  'assumptions': assumptions,
};

Map<String, Object?> _reply([List<Object?>? dishes]) => {
  'dishes': dishes ?? [_dish()],
};

PhotoMealEstimate _finalize(
  Object? reply, {
  GenericFoodTable? table,
  FoodNumberCache? cache,
  String? caption,
  DateTime? now,
}) => finalizeEstimate(
  mealPhotoEstimateFromJson(reply),
  table: table,
  cache: cache,
  caption: caption,
  now: now,
);

/// The one dish of a one-dish reply.
PhotoRecipeEstimate _single(
  Map<String, Object?> dish, {
  GenericFoodTable? table,
  FoodNumberCache? cache,
  String? caption,
  DateTime? now,
}) => _finalize(
  _reply([dish]),
  table: table,
  cache: cache,
  caption: caption,
  now: now,
).dishes.single;

EstimatedIngredient _named(PhotoRecipeEstimate dish, String name) =>
    dish.ingredients.firstWhere((i) => i.name == name);

Object? _fixture(String name) =>
    jsonDecode(File('test/fixture/$name').readAsStringSync());

void main() {
  group('reading a reply', () {
    test('every dish on the plate is its own entry', () {
      final raw = mealPhotoEstimateFromJson(
        _fixture('photo_estimate_multi_dish.json'),
      );

      expect(raw.dishes.map((d) => d.name), [
        'Idli',
        'Sambar',
        'Coconut chutney',
        'Chicken Pad Thai',
      ]);
      expect(raw.dishes.map((d) => d.ingredients.length), [3, 6, 2, 7]);
      final rice = raw.dishes.first.ingredients.first;
      expect(rice.grams, 110);
      expect(
        rice.per100g,
        const Per100g(kcal: 130, proteinG: 2.7, carbsG: 28.2, fatG: 0.3),
      );
      expect(rice.visible, isTrue);
      expect(raw.dishes.first.servings, 4);
      expect(raw.dishes.first.confidence, EstimateConfidence.high);
      expect(raw.dishes.first.assumptions, ['Four medium idli']);
    });

    test('the earlier one-dish shape is read as one dish, per 100 g', () {
      final raw = mealPhotoEstimateFromJson(
        _fixture('photo_estimate_reply.json'),
      );

      final dish = raw.dishes.single;
      expect(dish.name, 'Dal makhani with rice');
      expect(dish.ingredients, hasLength(8));
      // 234 kcal for 180 g is 130 per 100 g.
      expect(dish.ingredients.first.per100g!.kcal, closeTo(130, 0.01));
    });

    test('numeric strings are read like numbers', () {
      final raw = mealPhotoEstimateFromJson(
        _reply([
          _dish(
            portion: '300',
            servings: '1,5',
            ingredients: [
              {
                'name': 'Rice, white, cooked',
                'grams': '200',
                'per100g': {
                  'kcal': '130',
                  'protein_g': '2,7',
                  'carbs_g': 28,
                  'fat_g': 0.3,
                },
              },
            ],
          ),
        ]),
      );

      final dish = raw.dishes.single;
      expect(dish.servings, 1.5);
      expect(dish.ingredients.single.grams, 200);
      expect(dish.ingredients.single.per100g!.proteinG, 2.7);
    });

    test('at most four assumptions per dish, strings only', () {
      final raw = mealPhotoEstimateFromJson(
        _reply([
          _dish(assumptions: ['a', 2, ' ', 'b', 'c', 'd', 'e']),
        ]),
      );

      expect(raw.dishes.single.assumptions, ['a', 'b', 'c', 'd']);
    });

    test('at most six dishes and twenty ingredients are read', () {
      final raw = mealPhotoEstimateFromJson(
        _reply([
          for (var d = 0; d < 8; d++)
            _dish(
              name: 'Dish $d',
              ingredients: [for (var i = 0; i < 25; i++) _rice(10)],
            ),
        ]),
      );

      expect(raw.dishes, hasLength(mealPhotoMaxDishes));
      expect(raw.dishes.first.ingredients, hasLength(mealPhotoMaxIngredients));
    });

    test('a bad ingredient or a bad dish is dropped, the rest kept', () {
      final raw = mealPhotoEstimateFromJson(
        _reply([
          _dish(
            ingredients: [
              _rice(200),
              {'name': 7, 'grams': 10},
              {'name': 'Lentils, cooked', 'grams': -5},
              {'name': 'Ghee', 'grams': 5000},
              {'name': 'Salt', 'grams': 2},
            ],
          ),
          _dish(name: '   '),
          _dish(name: 'No ingredients', ingredients: []),
        ]),
      );

      expect(raw.dishes, hasLength(1));
      expect(raw.dishes.single.ingredients.map((i) => i.name), [
        'Rice, white, cooked',
        'Salt',
      ]);
      expect(
        raw.dishes.single.ingredients.last.per100g,
        isNull,
        reason: 'kept for the table or the cache to supply numbers',
      );
    });

    test('an empty dish list is "no food", not a failure', () {
      expect(mealPhotoEstimateFromJson({'dishes': []}).dishes, isEmpty);
    });

    test('a reply of the wrong shape is refused', () {
      for (final reply in <Object?>[
        null,
        'dishes',
        {'dish': 'x'},
        {'dishes': 'x'},
        {
          'dishes': ['x'],
        },
        {
          'dishes': [_dish(name: '')],
        },
      ]) {
        expect(
          () => mealPhotoEstimateFromJson(reply),
          throwsA(isA<MealPhotoReplyException>()),
          reason: '$reply',
        );
      }
    });
  });

  group('the schema and the prompt', () {
    test('ask for dishes with per-100 g numbers and no totals', () {
      final dishes =
          (mealPhotoToolSchema['properties'] as Map)['dishes'] as Map;
      final dish = (dishes['items'] as Map)['properties'] as Map;
      expect(dish.keys, containsAll(['name', 'portion_g', 'ingredients']));
      final ingredient =
          ((dish['ingredients'] as Map)['items'] as Map)['properties'] as Map;
      expect(ingredient.keys, containsAll(['name', 'grams', 'per100g']));
      expect(ingredient.keys, isNot(contains('kcal')));
      expect(dish.keys, isNot(contains('totals')));
      expect(dishes['maxItems'], 6);
    });

    test('state the anchors, and no longer scale to a portion', () {
      expect(mealPhotoSystemPrompt, contains('separate dishes'));
      expect(mealPhotoSystemPrompt, contains('Never merge a side'));
      expect(mealPhotoSystemPrompt, contains('at most 8%'));
      expect(mealPhotoSystemPrompt, contains('at least 20%'));
      expect(mealPhotoSystemPrompt, contains('0.5 to 3 g'));
      expect(mealPhotoSystemPrompt, contains('0.5 to 2 g'));
      expect(mealPhotoSystemPrompt, contains('liquid base'));
      expect(mealPhotoSystemPrompt, contains('per100g'));
      expect(mealPhotoSystemPrompt, isNot(contains('add up to portion_g')));
    });
  });

  group('the portion', () {
    test('is the sum of the ingredients, whatever was stated', () {
      final dish = _single(_dish(portion: 900));

      expect(dish.portionG, 300);
      expect(dish.ingredients.map((i) => i.grams), [200, 100]);
    });

    test('numbers are per 100 g times the grams', () {
      final dish = _single(_dish());
      final rice = dish.ingredients.first;

      expect(rice.kcal, closeTo(rice.per100g.kcal * 2, 1e-9));
      expect(
        dish.totals.kcal,
        closeTo(rice.kcal + dish.ingredients[1].kcal, 1e-9),
      );
    });

    test('a plate total is the sum of its dishes', () {
      final meal = _finalize(
        _reply([
          _dish(name: 'Rice', ingredients: [_rice(200)]),
          _dish(name: 'Dal', ingredients: [_lentils(150)]),
        ]),
      );

      expect(meal.dishes, hasLength(2));
      expect(meal.totals.grams, 350);
    });
  });

  group('the sanity band', () {
    Per100g band(String name, Per100g stated, [GenericFoodTable? table]) =>
        sanitizePer100g(name, stated, table);

    test('kcal within 15% of 4/4/9 stays', () {
      final stated = const Per100g(
        kcal: 300,
        proteinG: 10,
        carbsG: 50,
        fatG: 5,
      ); // 285 from macros, 5% off
      expect(band('Bread', stated).kcal, 300);
    });

    test('kcal more than 15% off is recomputed from the macros', () {
      // White sugar priced at 100 kcal: the macros say 399.
      final sugar = band(
        'Sugar, white',
        const Per100g(kcal: 100, proteinG: 0, carbsG: 99.8, fatG: 0),
      );
      expect(sugar.kcal, closeTo(399.2, 1e-9));
    });

    test('kcal above 900 is recomputed, and never above 900', () {
      expect(
        band(
          'Cheese',
          const Per100g(kcal: 1200, proteinG: 25, carbsG: 2, fatG: 33),
        ).kcal,
        closeTo(405, 1e-9),
      );
      expect(
        band(
          'Mystery',
          const Per100g(kcal: 1200, proteinG: 0, carbsG: 0, fatG: 0),
        ).kcal,
        lessThanOrEqualTo(per100MaxKcal),
      );
    });

    test('macros heavier than 100 g are scaled to fit', () {
      final fitted = band(
        'Mix',
        const Per100g(kcal: 520, proteinG: 60, carbsG: 60, fatG: 10),
      );
      expect(fitted.proteinG + fitted.carbsG + fitted.fatG, closeTo(100, 1e-9));
    });

    test('a cooking fat outside 700-900 takes the table\'s closest fat', () {
      final table = GenericFoodTable.fromRows([
        ['Oil, coconut', 833, 0, 0.8, 99.1],
        ['Coconut, raw', 354, 3.3, 15.2, 33.5],
      ]);
      // Coconut oil priced at 172 kcal/100 g in a real reply.
      final oil = band(
        'Oil, coconut',
        const Per100g(kcal: 172, proteinG: 0, carbsG: 0, fatG: 19.1),
        table,
      );
      expect(oil.kcal, 833);
    });

    test('without a table the fat takes USDA\'s figure for its kind', () {
      expect(
        band(
          'Ghee',
          const Per100g(kcal: 500, proteinG: 0, carbsG: 0, fatG: 55),
        ).kcal,
        900,
      );
      expect(
        band(
          'Butter, salted',
          const Per100g(kcal: 300, proteinG: 0, carbsG: 0, fatG: 33),
        ).kcal,
        717,
      );
      expect(
        band(
          'Cooking oil',
          const Per100g(kcal: 120, proteinG: 0, carbsG: 0, fatG: 13),
        ).kcal,
        884,
      );
    });

    test('foods that only share a word with a fat are left alone', () {
      for (final name in [
        'Peanut butter',
        'Butter beans',
        'Tuna in oil',
        'Butter chicken sauce',
        'Coconut milk',
      ]) {
        expect(isAddedFat(name), isFalse, reason: name);
      }
      for (final name in ['Ghee', 'Oil, olive', 'Butter, salted', 'Lard']) {
        expect(isAddedFat(name), isTrue, reason: name);
      }
    });
  });

  group('the table', () {
    final table = GenericFoodTable.fromRows([
      ['Rice, white, long-grain, regular, cooked', 130, 2.7, 28.2, 0.3],
      [
        'Sauce, peanut, made from peanut butter, water, soy sauce',
        257,
        6.3,
        22,
        16,
      ],
      ['Soy sauce made from soy and wheat (shoyu)', 53, 8.1, 4.9, 0.6],
    ]);

    test('a matching ingredient takes the table\'s per-100 g numbers', () {
      final rice = _single(_dish(), table: table).ingredients.first;

      expect(rice.source, IngredientSource.db);
      expect(rice.matchedName, 'Rice, white, long-grain, regular, cooked');
      expect(rice.per100g.kcal, 130);
      expect(rice.grams, 200, reason: 'the model keeps the grams');
    });

    test('a row more than 2x from the model\'s kcal is refused', () {
      // "Sauce, soy" picked the peanut sauce at 257 kcal/100 g.
      expect(table.match('Sauce, soy')!.food.kcal, 257);

      final soy = _single(
        _dish(
          ingredients: [
            _ingredient('Sauce, soy', 15, protein: 10.5, carbs: 5.6, fat: 0.1),
          ],
        ),
        table: table,
      ).ingredients.single;

      expect(soy.source, IngredientSource.db);
      expect(soy.matchedName, startsWith('Soy sauce'));
      expect(soy.per100g.kcal, 53);
    });

    test('when every row is refused the model\'s numbers stay', () {
      final rice = _single(
        _dish(
          ingredients: [
            _ingredient(
              'Rice, white, cooked',
              200,
              kcal: 400,
              protein: 8,
              carbs: 88,
              fat: 1,
            ),
          ],
        ),
        table: table,
      ).ingredients.single;

      expect(rice.source, IngredientSource.ai);
      expect(rice.per100g.kcal, 400);
    });

    test('the gate', () {
      expect(kcalAgrees(0, 3), isTrue, reason: 'water and salt');
      expect(kcalAgrees(130, 250), isTrue);
      expect(kcalAgrees(130, 270), isFalse);
      expect(kcalAgrees(257, 60), isFalse);
      expect(kcalAgrees(0, 60), isFalse);
    });

    test('the model-only totals are kept beside the grounded ones', () {
      final dish = _single(
        _dish(
          ingredients: [
            _ingredient(
              'Rice, white, cooked',
              200,
              kcal: 150,
              protein: 3,
              carbs: 33,
              fat: 0.3,
            ),
          ],
        ),
        table: table,
      );

      expect(dish.totals.kcal, closeTo(260, 1e-9));
      expect(dish.aiOnly.kcal, closeTo(300, 1e-9));
      expect(dish.aiOnly.grams, dish.totals.grams);
    });
  });

  group('the cache', () {
    Map<String, Object?> jaggery(num kcal, num carbs) => _dish(
      name: 'Chikki',
      ingredients: [
        _ingredient('Jaggery', 20, kcal: kcal, protein: 0.4, carbs: carbs),
      ],
    );

    test('the first value for a food wins on later photos', () {
      final cache = MemoryFoodNumberCache();
      final first = _single(jaggery(383, 95), cache: cache);
      final second = _single(jaggery(300, 74), cache: cache);

      expect(first.ingredients.single.source, IngredientSource.ai);
      expect(second.ingredients.single.source, IngredientSource.cache);
      expect(
        second.ingredients.single.per100g,
        first.ingredients.single.per100g,
      );
    });

    test('the same food twice on one plate agrees even without a cache', () {
      final meal = _finalize(_reply([jaggery(383, 95), jaggery(300, 74)]));

      expect(
        meal.dishes.last.ingredients.single.per100g,
        meal.dishes.first.ingredients.single.per100g,
      );
      expect(
        meal.dishes.last.ingredients.single.source,
        IngredientSource.cache,
      );
    });

    test('a table match replaces a model value already stored', () async {
      final cache = MemoryFoodNumberCache();
      final key = foodNumberKey('Rice, white, cooked');
      await cache.remember(
        key,
        const CachedFoodNumbers(
          Per100g(kcal: 200, proteinG: 4, carbsG: 44, fatG: 0.5),
        ),
      );
      final table = GenericFoodTable.fromRows([
        ['Rice, white, long-grain, regular, cooked', 130, 2.7, 28.2, 0.3],
      ]);

      final rice = _single(
        _dish(ingredients: [_rice(200)]),
        table: table,
        cache: cache,
      ).ingredients.single;

      expect(rice.source, IngredientSource.db);
      expect(cache.read(key)!.fromTable, isTrue);
      expect(cache.read(key)!.per100g.kcal, 130);
    });

    test('a model value never replaces a table value', () async {
      final cache = MemoryFoodNumberCache();
      await cache.remember(
        'x',
        const CachedFoodNumbers(Per100g.zero, fromTable: true),
      );
      await cache.remember(
        'x',
        const CachedFoodNumbers(
          Per100g(kcal: 100, proteinG: 0, carbsG: 25, fatG: 0),
        ),
      );

      expect(cache.read('x')!.per100g, Per100g.zero);
    });

    group('expiry', () {
      final day0 = DateTime(2026, 10, 1);

      test('a model value is used for 30 days, then checked again', () {
        final cache = MemoryFoodNumberCache();
        _single(jaggery(383, 95), cache: cache, now: day0);

        final day29 = _single(
          jaggery(300, 74),
          cache: cache,
          now: day0.add(const Duration(days: 29)),
        ).ingredients.single;
        expect(day29.source, IngredientSource.cache);
        expect(day29.per100g.kcal, 383);

        final day31 = _single(
          jaggery(300, 74),
          cache: cache,
          now: day0.add(const Duration(days: 31)),
        ).ingredients.single;
        expect(day31.source, IngredientSource.ai);
        expect(day31.per100g.kcal, 300);
        expect(cache.read(foodNumberKey('Jaggery'))!.per100g.kcal, 300);
        expect(
          cache.read(foodNumberKey('Jaggery'))!.checkedAt,
          day0.add(const Duration(days: 31)),
        );
      });

      test('an entry of unknown age is checked again on next use', () async {
        final cache = MemoryFoodNumberCache();
        final key = foodNumberKey('Jaggery');
        await cache.remember(
          key,
          const CachedFoodNumbers(
            Per100g(kcal: 100, proteinG: 0, carbsG: 25, fatG: 0),
          ),
        );

        final jaggeryRow = _single(
          jaggery(383, 95),
          cache: cache,
          now: day0,
        ).ingredients.single;

        expect(jaggeryRow.source, IngredientSource.ai);
        expect(jaggeryRow.per100g.kcal, 383);
        expect(cache.read(key)!.per100g.kcal, 383);
      });

      test('an expired value still stands in for an ingredient with no '
          'numbers', () {
        final cache = MemoryFoodNumberCache();
        _single(jaggery(383, 95), cache: cache, now: day0);

        final later = _single(
          _dish(
            name: 'Tea',
            ingredients: [
              {'name': 'jaggery', 'grams': 10},
            ],
          ),
          cache: cache,
          now: day0.add(const Duration(days: 90)),
        ).ingredients.single;

        expect(later.source, IngredientSource.cache);
        expect(later.per100g.kcal, 383);
      });

      test('a table value never expires', () async {
        final cache = MemoryFoodNumberCache();
        await cache.remember(
          'x',
          CachedFoodNumbers(Per100g.zero, fromTable: true, checkedAt: day0),
        );
        await cache.remember(
          'x',
          CachedFoodNumbers(
            const Per100g(kcal: 100, proteinG: 0, carbsG: 25, fatG: 0),
            checkedAt: day0.add(const Duration(days: 400)),
          ),
        );

        expect(cache.read('x')!.per100g, Per100g.zero);
        expect(
          cache.read('x')!.isExpiredAt(day0.add(const Duration(days: 400))),
          isFalse,
        );
      });
    });

    test('an ingredient with no numbers takes the cached ones', () {
      final cache = MemoryFoodNumberCache();
      _single(jaggery(383, 95), cache: cache);
      final later = _single(
        _dish(
          name: 'Tea',
          ingredients: [
            {'name': 'jaggery', 'grams': 10},
          ],
        ),
        cache: cache,
      ).ingredients.single;

      expect(later.source, IngredientSource.cache);
      expect(later.per100g.kcal, 383);
    });

    test('is keyed by the cleaned, normalised name', () {
      expect(foodNumberKey('Rice, white'), foodNumberKey('White rice'));
      expect(
        foodNumberKey('Coriander (Coriandrum sativum), fresh'),
        foodNumberKey('coriander'),
      );
      expect(foodNumberKey('Chickpeas'), foodNumberKey('chickpea'));
    });
  });

  group('the anchors', () {
    test('added fat is capped at 8% of the dish, and it says so', () {
      final dish = _single(
        _dish(
          name: 'Vegetable biryani',
          ingredients: [
            _rice(300),
            _ingredient('Mixed vegetables, cooked', 100, carbs: 8, protein: 2),
            _ingredient('Ghee', 44.5, fat: 100, kcal: 900),
          ],
        ),
      );

      final ghee = _named(dish, 'Ghee');
      expect(ghee.grams / dish.portionG, closeTo(addedFatMaxShare, 1e-9));
      expect(dish.assumptions.last, contains('Added fat capped at 8%'));
    });

    test('a deep-fried dish keeps its fat', () {
      final dish = _single(
        _dish(
          name: 'Onion pakora',
          ingredients: [
            _ingredient('Gram flour', 60, protein: 22, carbs: 58, fat: 7),
            _ingredient('Onions, raw', 40, carbs: 9, protein: 1),
            _ingredient('Oil, vegetable', 25, fat: 100, kcal: 884),
          ],
        ),
      );

      expect(_named(dish, 'Oil, vegetable').grams, 25);
      expect(dish.assumptions, isEmpty);
    });

    test('a dish that is a fat keeps it', () {
      final dish = _single(
        _dish(
          name: 'Butter',
          ingredients: [_ingredient('Butter, salted', 10, fat: 81, kcal: 717)],
        ),
      );

      expect(dish.ingredients.single.grams, 10);
      expect(dish.assumptions, isEmpty);
    });

    test('a protein the dish is named after is at least 20% of it', () {
      final dish = _single(
        _dish(
          name: 'Chicken biryani',
          ingredients: [
            _rice(300),
            _ingredient('Chicken, thigh, cooked', 30, protein: 26, fat: 8),
            _ingredient('Onions, fried', 60, carbs: 30, fat: 10),
            _ingredient('Chicken stock', 50, protein: 1),
          ],
        ),
      );

      final chicken = _named(dish, 'Chicken, thigh, cooked');
      expect(
        chicken.grams / dish.portionG,
        closeTo(namedProteinMinShare, 1e-9),
      );
      expect(_named(dish, 'Chicken stock').grams, 50, reason: 'not the meat');
      expect(dish.assumptions.last, contains('Chicken raised to 20%'));
    });

    test('a protein already at 20% is left alone', () {
      final dish = _single(
        _dish(
          name: 'Paneer tikka',
          ingredients: [
            _ingredient('Paneer', 150, protein: 18, fat: 20, carbs: 4),
            _ingredient('Capsicum, raw', 50, carbs: 5),
          ],
        ),
      );
      expect(_named(dish, 'Paneer').grams, 150);
      expect(dish.assumptions, isEmpty);
    });

    test('a word inside another word names no protein', () {
      final dish = _single(
        _dish(
          name: 'Eggplant curry with chickpeas',
          ingredients: [
            _ingredient('Eggplant, cooked', 200, carbs: 8),
            _ingredient('Chickpeas, cooked', 100, protein: 9, carbs: 27),
            _ingredient('Water', 100),
            _ingredient('Egg, boiled', 10, protein: 13, fat: 11),
          ],
        ),
      );
      expect(_named(dish, 'Egg, boiled').grams, 10);
    });

    test('spices and herbs are 0.5-3 g each, salt 0.5-2 g', () {
      final dish = _single(
        _dish(
          name: 'Jeera rice',
          ingredients: [
            _rice(200),
            _ingredient(
              'Spices, cumin seed',
              4.5,
              protein: 18,
              carbs: 44,
              fat: 22,
            ),
            _ingredient('Spices, turmeric, ground', 0.2, carbs: 67),
            _ingredient('Pepper, black', 4, carbs: 64),
            _ingredient('Salt, table', 3),
            _ingredient('Ginger root, raw', 10, carbs: 18),
            _ingredient('Green chilli', 8, carbs: 9),
            _ingredient('Peppers, sweet, red, raw', 40, carbs: 6),
          ],
        ),
      );

      expect(_named(dish, 'Spices, cumin seed').grams, spiceMaxG);
      expect(_named(dish, 'Spices, turmeric, ground').grams, spiceMinG);
      expect(_named(dish, 'Pepper, black').grams, spiceMaxG);
      expect(_named(dish, 'Salt, table').grams, saltMaxG);
      expect(_named(dish, 'Ginger root, raw').grams, 10);
      expect(_named(dish, 'Green chilli').grams, 8);
      expect(_named(dish, 'Peppers, sweet, red, raw').grams, 40);
      expect(dish.assumptions, [
        'Spices and herbs set to 0.5-3 g each (Spices, cumin seed, '
            'Spices, turmeric, ground, Pepper, black).',
        'Salt set to 0.5-2 g.',
      ]);
    });

    test('a soup or curry with no liquid base is flagged', () {
      final dry = _single(
        _dish(
          name: 'Chicken curry',
          ingredients: [
            _ingredient('Chicken, breast, cooked', 150, protein: 31, fat: 3.6),
            _ingredient('Onions, raw', 80, carbs: 9),
          ],
        ),
      );
      final wet = _single(
        _dish(
          name: 'Chicken curry',
          ingredients: [
            _ingredient('Chicken, breast, cooked', 150, protein: 31, fat: 3.6),
            _ingredient('Coconut milk', 100, fat: 24, carbs: 6, protein: 2),
          ],
        ),
      );

      expect(dry.assumptions.single, contains('No liquid base'));
      expect(wet.assumptions, isEmpty);
    });

    test('a weight the caption states is never moved by an anchor', () {
      final dish = _single(
        _dish(
          name: 'Dal tadka',
          ingredients: [
            _lentils(200),
            _ingredient('Water', 100),
            _ingredient('Ghee', 10, fat: 100, kcal: 900),
          ],
        ),
        caption: 'dal with 40 g ghee',
      );

      expect(_named(dish, 'Ghee').grams, 40);
      expect(dish.assumptions, isEmpty);
    });

    test('the fixture plate, end to end', () {
      final meal = _finalize(_fixture('photo_estimate_multi_dish.json'));

      expect(meal.dishes, hasLength(4));
      final sambar = meal.dishes[1];
      // Coconut oil priced at 172 kcal/100 g is a fat outside the band.
      expect(_named(sambar, 'Oil, coconut').per100g.kcal, 884);
      expect(
        _named(sambar, 'Coriander (Coriandrum sativum), fresh').grams,
        spiceMaxG,
      );
      expect(_named(sambar, 'Spices, turmeric, ground').grams, spiceMaxG);

      final padThai = meal.dishes[3];
      expect(
        _named(padThai, 'Oil, vegetable').grams / padThai.portionG,
        lessThanOrEqualTo(addedFatMaxShare + 1e-9),
      );
      expect(
        _named(padThai, 'Chicken breast, cooked').grams / padThai.portionG,
        closeTo(namedProteinMinShare, 1e-9),
      );
      // Sugar at 100 kcal/100 g is recomputed from its carbohydrate.
      expect(
        _named(padThai, 'Sugar, white').per100g.kcal,
        closeTo(399.2, 1e-9),
      );
      expect(padThai.assumptions.first, 'Takeaway portion');
      expect(padThai.assumptions.skip(1).join(' '), contains('Added fat'));
    });
  });

  group('the caption', () {
    test('a bare weight is the whole plate\'s', () {
      final dish = _single(_dish(), caption: 'rice and dal, 450 g');

      expect(dish.portionG, closeTo(450, 1e-9));
      expect(dish.ingredients.map((i) => i.grams.round()), [300, 150]);
    });

    test('a weight on an ingredient sets it and the portion follows', () {
      final dish = _single(_dish(), caption: '300g rice');

      expect(dish.ingredients.first.grams, 300);
      expect(dish.ingredients.last.grams, 100);
      expect(dish.portionG, 400);
    });

    test('a weight on a dish sets that dish only', () {
      final meal = _finalize(
        _reply([
          _dish(name: 'Rice', ingredients: [_rice(200)]),
          _dish(name: 'Dal makhani', ingredients: [_lentils(150)]),
        ]),
        caption: 'dal makhani 300 g',
      );

      expect(meal.dishes.first.portionG, 200);
      expect(meal.dishes.last.portionG, closeTo(300, 1e-9));
    });

    test('a caption that states no weight changes nothing', () {
      final plain = _finalize(_reply());
      final captioned = _finalize(
        _reply(),
        caption: 'rice and dal from the canteen, ate half',
      );

      expect(captioned, plain);
    });
  });
}
