import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  'kcal': kcal ?? 4 * protein + 4 * carbs + 9 * fat,
  'protein_g': protein,
  'carbs_g': carbs,
  'fat_g': fat,
  'visible': ?visible,
};

Map<String, Object?> _reply({
  String dish = 'Rice and dal',
  Object? portion = 300,
  Object? servings = 1.0,
  List<Object?>? ingredients,
  Object? totals,
  Object? confidence = 'medium',
  Object? assumptions = const <Object?>[],
}) => {
  'dish': dish,
  'portion_g': portion,
  'servings': servings,
  'ingredients':
      ingredients ??
      [
        _ingredient(
          'Rice, white, cooked',
          200,
          protein: 5.4,
          carbs: 56,
          fat: 0.6,
        ),
        _ingredient('Lentils, cooked', 100, protein: 9, carbs: 20, fat: 0.4),
      ],
  'totals':
      totals ??
      {'grams': 300, 'kcal': 360, 'protein_g': 14, 'carbs_g': 76, 'fat_g': 1},
  'confidence': confidence,
  'assumptions': assumptions,
};

PhotoRecipeEstimate _finalize(
  Map<String, Object?> reply, {
  GenericFoodTable? table,
  String? caption,
}) => finalizeEstimate(
  mealPhotoEstimateFromJson(reply),
  table: table,
  caption: caption,
);

void main() {
  group('reading a reply', () {
    test(
      'a recorded-shape reply parses to its dish, ingredients and notes',
      () {
        final fixture = jsonDecode(
          File('test/fixture/photo_estimate_reply.json').readAsStringSync(),
        );

        final raw = mealPhotoEstimateFromJson(fixture);

        expect(raw.dish, 'Dal makhani with rice');
        expect(raw.portionG, 420);
        expect(raw.servings, 1.0);
        expect(raw.confidence, EstimateConfidence.medium);
        expect(raw.assumptions, hasLength(2));
        expect(raw.ingredients, hasLength(8));
        expect(raw.ingredients.first.name, 'Rice, white, cooked');
        expect(raw.ingredients.first.visible, isTrue);
        expect(raw.ingredients[3].visible, isFalse);
        expect(raw.claimedKcal, 649);
      },
    );

    test('numeric strings are read like numbers', () {
      final raw = mealPhotoEstimateFromJson(
        _reply(
          portion: '300',
          ingredients: [
            {
              'name': 'Rice, white, cooked',
              'grams': '300',
              'kcal': '390',
              'protein_g': '8',
              'carbs_g': '84',
              'fat_g': '1,2',
            },
          ],
        ),
      );
      expect(raw.portionG, 300);
      expect(raw.ingredients.single.fatG, 1.2);
    });

    test(
      'an unknown or missing confidence is "medium", servings default to 1',
      () {
        final raw = mealPhotoEstimateFromJson(
          _reply(confidence: 'certain', servings: 'many'),
        );
        expect(raw.confidence, EstimateConfidence.medium);
        expect(raw.servings, 1.0);
      },
    );

    test('at most six assumptions, strings only', () {
      final raw = mealPhotoEstimateFromJson(
        _reply(assumptions: ['a', 2, ' ', 'b', 'c', 'd', 'e', 'f', 'g', 'h']),
      );
      expect(raw.assumptions, ['a', 'b', 'c', 'd', 'e', 'f']);
    });

    test('at most twenty ingredients are read', () {
      final raw = mealPhotoEstimateFromJson(
        _reply(
          ingredients: [
            for (var i = 0; i < 30; i++)
              _ingredient('Food number $i', 10, carbs: 5),
          ],
        ),
      );
      expect(raw.ingredients, hasLength(mealPhotoMaxIngredients));
    });

    test('a bad ingredient is dropped, the rest kept', () {
      final raw = mealPhotoEstimateFromJson(
        _reply(
          ingredients: [
            _ingredient('Rice, white, cooked', 200, carbs: 56),
            _ingredient('Mystery', 0, carbs: 5),
            _ingredient('Boulder', 9000, carbs: 5),
            _ingredient('123', 10, carbs: 5),
            {'name': 'No numbers', 'grams': 50},
          ],
        ),
      );
      expect(raw.ingredients.map((i) => i.name), ['Rice, white, cooked']);
    });

    void refused(Object? input, String why) => expect(
      () => mealPhotoEstimateFromJson(input),
      throwsA(isA<MealPhotoReplyException>()),
      reason: why,
    );

    test('an empty ingredient list is "no food", not a failure', () {
      final raw = mealPhotoEstimateFromJson(_reply(ingredients: []));
      expect(raw.ingredients, isEmpty);
    });

    test('a reply of the wrong shape is refused', () {
      refused(null, 'null');
      refused('[]', 'a string');
      refused(<Object?>[], 'a list');
      refused(_reply(dish: ''), 'no dish');
      refused({..._reply(), 'ingredients': 'rice'}, 'ingredients not an array');
      refused(
        _reply(ingredients: ['rice']),
        'an ingredient that is not an object',
      );
      refused(
        _reply(ingredients: [_ingredient('Boulder', 9000, carbs: 5)]),
        'nothing survives',
      );
      refused(
        _reply(
          ingredients: [
            {'grams': 100, 'kcal': 1, 'protein_g': 0, 'carbs_g': 0, 'fat_g': 0},
          ],
        ),
        'an ingredient with no name',
      );
    });
  });

  group('the schema', () {
    test('asks for every field the prompt names', () {
      final properties = mealPhotoToolSchema['properties'] as Map;
      expect(
        properties.keys,
        containsAll([
          'dish',
          'portion_g',
          'servings',
          'ingredients',
          'totals',
          'confidence',
          'assumptions',
        ]),
      );
      final ingredients = properties['ingredients'] as Map;
      expect(ingredients['minItems'], 1);
      expect(ingredients['maxItems'], 20);
      expect(
        ((ingredients['items'] as Map)['required'] as List),
        containsAll(['name', 'grams', 'kcal', 'protein_g', 'carbs_g', 'fat_g']),
      );
      expect(((properties['confidence'] as Map)['enum'] as List), [
        'high',
        'medium',
        'low',
      ]);
      expect((properties['assumptions'] as Map)['maxItems'], 6);
    });

    test('the prompt names the steps the schema answers', () {
      expect(mealPhotoSystemPrompt, contains('portion_g'));
      expect(mealPhotoSystemPrompt, contains('EVERY ingredient'));
      expect(mealPhotoSystemPrompt, contains('USDA FoodData Central'));
      expect(mealPhotoSystemPrompt, contains('4*protein + 4*carbs + 9*fat'));
      expect(mealPhotoSystemPrompt, endsWith('No prose.'));
    });
  });

  group('totals', () {
    test('are the sum of the ingredients, whatever the model claimed', () {
      final estimate = _finalize(
        _reply(
          totals: {
            'grams': 1,
            'kcal': 9999,
            'protein_g': 1,
            'carbs_g': 1,
            'fat_g': 1,
          },
        ),
      );

      final sum = estimate.ingredients.fold(0.0, (t, i) => t + i.kcal);
      expect(estimate.totals.kcal, closeTo(sum, 1e-9));
      expect(
        estimate.totals.kcal,
        closeTo(5.4 * 4 + 56 * 4 + 0.6 * 9 + 9 * 4 + 20 * 4 + 0.4 * 9, 1e-6),
      );
      expect(estimate.totals.grams, closeTo(300, 1e-9));
    });
  });

  group('the portion', () {
    test('ingredients within 10% of it are left alone', () {
      final estimate = _finalize(_reply(portion: 320)); // sum 300: 6.25% off

      expect(estimate.ingredients.map((i) => i.grams), [200, 100]);
      expect(estimate.portionG, 300);
    });

    test('ingredients more than 10% off are scaled to it, numbers and all', () {
      final estimate = _finalize(_reply(portion: 450)); // sum 300: 33% off

      expect(estimate.ingredients.map((i) => i.grams), [300, 150]);
      expect(estimate.portionG, closeTo(450, 1e-9));
      final rice = estimate.ingredients.first;
      expect(rice.carbsG, closeTo(56 * 1.5, 1e-9));
      expect(rice.kcal, closeTo((5.4 * 4 + 56 * 4 + 0.6 * 9) * 1.5, 1e-6));
    });

    test('a portion that is missing is the sum', () {
      final estimate = _finalize(_reply(portion: null));
      expect(estimate.portionG, 300);
    });

    test('ingredients above the stated portion are scaled down', () {
      final estimate = _finalize(_reply(portion: 150));
      expect(estimate.ingredients.map((i) => i.grams), [100, 50]);
    });
  });

  group('energy', () {
    test('within 10% of 4/4/9 the stated figure stays', () {
      final estimate = _finalize(
        _reply(
          portion: 100,
          ingredients: [
            _ingredient(
              'Rice, white, cooked',
              100,
              kcal: 118,
              protein: 2.5,
              carbs: 28,
              fat: 0.3,
            ),
          ],
        ),
      ); // 4*2.5 + 4*28 + 9*0.3 = 124.7: 5.4% off
      expect(estimate.ingredients.single.kcal, 118);
    });

    test('more than 10% off it is replaced by the macros\' figure', () {
      final estimate = _finalize(
        _reply(
          portion: 100,
          ingredients: [
            _ingredient(
              'Rice, white, cooked',
              100,
              kcal: 300,
              protein: 2.5,
              carbs: 28,
              fat: 0.3,
            ),
          ],
        ),
      );
      expect(estimate.ingredients.single.kcal, closeTo(124.7, 1e-9));
    });

    test('macros with no energy at all give it back', () {
      final estimate = _finalize(
        _reply(
          portion: 100,
          ingredients: [_ingredient('Oil, peanut', 100, kcal: 0, fat: 100)],
        ),
      );
      expect(estimate.ingredients.single.kcal, 900);
    });

    test(
      'macros that cannot fit in the ingredient\'s grams are scaled down first',
      () {
        final estimate = _finalize(
          _reply(
            portion: 10,
            ingredients: [_ingredient('Oil, peanut', 10, kcal: 5000, fat: 80)],
          ),
        );
        final oil = estimate.ingredients.single;
        expect(
          oil.proteinG + oil.carbsG + oil.fatG,
          lessThanOrEqualTo(10.0 * 1.02 + 1e-9),
        );
        expect(oil.kcal, closeTo(9 * oil.fatG, 1e-9));
      },
    );

    test('an ingredient with no macros keeps its stated energy', () {
      final estimate = _finalize(
        _reply(
          portion: 100,
          ingredients: [_ingredient('Mystery sauce', 100, kcal: 80)],
        ),
      );
      expect(estimate.ingredients.single.kcal, 80);
    });
  });

  group('never zero', () {
    test(
      'ingredients with no energy take the model\'s own total, by grams',
      () {
        final estimate = _finalize(
          _reply(
            portion: 300,
            ingredients: [
              {
                'name': 'Mystery stew',
                'grams': 200,
                'kcal': 0,
                'protein_g': 0,
                'carbs_g': 0,
                'fat_g': 0,
              },
              {
                'name': 'Mystery rice',
                'grams': 100,
                'kcal': 0,
                'protein_g': 0,
                'carbs_g': 0,
                'fat_g': 0,
              },
            ],
            totals: {
              'grams': 300,
              'kcal': 600,
              'protein_g': 0,
              'carbs_g': 0,
              'fat_g': 0,
            },
          ),
        );

        expect(estimate.totals.kcal, closeTo(600, 1e-9));
        expect(estimate.ingredients.map((i) => i.kcal.round()), [400, 200]);
      },
    );

    test(
      'a table that knows the ingredients fills in what the model left empty',
      () {
        final table = GenericFoodTable.fromRows([
          ['Rice, white, cooked', 130, 2.7, 28.2, 0.3],
        ]);
        final estimate = _finalize(
          _reply(
            portion: 200,
            ingredients: [
              {
                'name': 'Rice, white, cooked',
                'grams': 200,
                'kcal': 0,
                'protein_g': 0,
                'carbs_g': 0,
                'fat_g': 0,
              },
            ],
            totals: {
              'grams': 200,
              'kcal': 0,
              'protein_g': 0,
              'carbs_g': 0,
              'fat_g': 0,
            },
          ),
          table: table,
        );

        expect(estimate.totals.kcal, 260);
      },
    );
  });

  group('grounding in the table', () {
    final table = GenericFoodTable.fromRows([
      ['Rice, white, long-grain, cooked', 130, 2.7, 28.2, 0.3],
      ['Oil, peanut, salad or cooking', 884, 0, 0, 100],
    ]);

    test(
      'a matched ingredient keeps its grams and takes the table\'s per-100 g',
      () {
        final estimate = _finalize(
          _reply(
            portion: 230,
            ingredients: [
              _ingredient(
                'Rice, white, cooked',
                200,
                protein: 9,
                carbs: 70,
                fat: 1,
              ),
              _ingredient('Oil, peanut', 30, protein: 0, carbs: 0, fat: 30),
            ],
          ),
          table: table,
        );

        final rice = estimate.ingredients.first;
        expect(rice.source, IngredientSource.db);
        expect(rice.matchedName, 'Rice, white, long-grain, cooked');
        expect(rice.grams, 200);
        expect(rice.kcal, closeTo(260, 1e-9));
        expect(rice.carbsG, closeTo(56.4, 1e-9));
        expect(estimate.ingredients.last.kcal, closeTo(265.2, 1e-9));
      },
    );

    test(
      'an unmatched ingredient keeps the model\'s numbers and is marked ai',
      () {
        final estimate = _finalize(
          _reply(
            portion: 230,
            ingredients: [
              _ingredient(
                'Rice, white, cooked',
                200,
                protein: 9,
                carbs: 70,
                fat: 1,
              ),
              _ingredient('Curry leaves', 30, protein: 2, carbs: 5, fat: 1),
            ],
          ),
          table: table,
        );

        final leaves = estimate.ingredients.last;
        expect(leaves.source, IngredientSource.ai);
        expect(leaves.matchedName, isNull);
        expect(leaves.kcal, closeTo(4 * 2 + 4 * 5 + 9 * 1, 1e-9));
      },
    );

    test('the model-only totals are kept beside the grounded ones', () {
      final reply = _reply(
        portion: 200,
        ingredients: [
          _ingredient(
            'Rice, white, cooked',
            200,
            protein: 9,
            carbs: 70,
            fat: 1,
          ),
        ],
      );

      final grounded = _finalize(reply, table: table);
      final plain = _finalize(reply);

      expect(plain.totals.kcal, closeTo(4 * 9 + 4 * 70 + 9, 1e-9));
      expect(grounded.totals.kcal, closeTo(260, 1e-9));
      expect(grounded.aiOnly.kcal, closeTo(plain.totals.kcal, 1e-9));
      expect(plain.aiOnly, plain.totals);
    });

    test('without a table every ingredient is the model\'s', () {
      final estimate = _finalize(_reply());
      expect(
        estimate.ingredients.every((i) => i.source == IngredientSource.ai),
        isTrue,
      );
    });
  });

  group('the caption', () {
    test('a weight with no food beside it is the dish\'s portion', () {
      final estimate = _finalize(
        _reply(portion: 300),
        caption: 'rice and dal, 450 g',
      );

      expect(estimate.portionG, closeTo(450, 1e-9));
      expect(estimate.ingredients.map((i) => i.grams.round()), [300, 150]);
    });

    test(
      'a weight on an ingredient sets that ingredient and the portion follows',
      () {
        final estimate = _finalize(_reply(portion: 300), caption: '300g rice');

        expect(estimate.ingredients.first.grams, closeTo(300, 1e-9));
        expect(estimate.ingredients.last.grams, 100);
        expect(estimate.portionG, closeTo(400, 1e-9));
      },
    );

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
