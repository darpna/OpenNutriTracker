import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

class _PhotoApi implements MealItemsApi, MealPhotoToolApi {
  final Object? reply;
  final List<MealPhotoContent> contents = [];
  final List<String> systems = [];

  _PhotoApi(this.reply);

  @override
  Future<Object?> requestPhotoToolInput({
    required MealPhotoContent content,
    required String system,
  }) async {
    contents.add(content);
    systems.add(system);
    return reply;
  }

  @override
  Future<MealTextParseResult> requestItems({
    required MealContent content,
    required String system,
  }) => throw StateError('the photo path never uses the text tool');
}

class _TextOnlyApi implements MealItemsApi {
  @override
  Future<MealTextParseResult> requestItems({
    required MealContent content,
    required String system,
  }) => throw StateError('unused');
}

final _photo = MealPhoto(
  bytes: Uint8List.fromList([1, 2, 3]),
  mediaType: 'image/jpeg',
);

Object? _fixture([String name = 'photo_estimate_multi_dish.json']) =>
    jsonDecode(File('test/fixture/$name').readAsStringSync());

List<EstimatedIngredient> _ingredients(MealTextParseResult result) => [
  for (final dish in result.estimate!.dishes) ...dish.ingredients,
];

void main() {
  test(
    'a photo is one request with the shared prompt and "Caption: none"',
    () async {
      final api = _PhotoApi(_fixture());
      final result = await ModelMealPhotoInterpreter(api).interpret(_photo);

      expect(api.contents, hasLength(1));
      expect(api.systems.single, mealPhotoSystemPrompt);
      expect(mealPhotoPromptText(api.contents.single), 'Caption: none');
      expect(result.estimate!.dishes.map((d) => d.dish), [
        'Idli',
        'Sambar',
        'Coconut chutney',
        'Chicken Pad Thai',
      ]);
      expect(result.items, isEmpty);
    },
  );

  test('a reply in the earlier one-dish shape still lands', () async {
    final result = await ModelMealPhotoInterpreter(
      _PhotoApi(_fixture('photo_estimate_reply.json')),
    ).interpret(_photo);

    expect(result.estimate!.dishes.single.dish, 'Dal makhani with rice');
  });

  test('the caption travels as text in the same single request', () async {
    final api = _PhotoApi(_fixture());
    await ModelMealPhotoInterpreter(
      api,
    ).interpret(_photo, caption: 'dal makhani, 420 g');

    expect(api.contents, hasLength(1));
    expect(
      mealPhotoPromptText(api.contents.single),
      'Caption: dal makhani, 420 g',
    );
  });

  test('every ingredient keeps the model numbers without a table', () async {
    final result = await ModelMealPhotoInterpreter(
      _PhotoApi(_fixture()),
    ).interpret(_photo);

    // Ai, or the cache this reply built: "Water" is listed twice.
    expect(
      _ingredients(result).map((i) => i.source).toSet(),
      isNot(contains(IngredientSource.db)),
    );
  });

  test(
    'a table that cannot load leaves the model numbers, not an error',
    () async {
      final result = await ModelMealPhotoInterpreter(
        _PhotoApi(_fixture()),
        table: () async => throw StateError('asset missing'),
      ).interpret(_photo);

      expect(_ingredients(result), isNotEmpty);
    },
  );

  test('a matching ingredient is grounded in the table', () async {
    final table = GenericFoodTable.fromRows([
      ['Rice, white, long-grain, regular, cooked', 130, 2.7, 28.2, 0.3],
    ]);
    final result = await ModelMealPhotoInterpreter(
      _PhotoApi(_fixture()),
      table: () async => table,
    ).interpret(_photo);

    final rice = _ingredients(result).first;
    expect(rice.source, IngredientSource.db);
    expect(rice.grams, 110, reason: 'the model keeps the grams');
    expect(rice.kcal, closeTo(143, 1));
  });

  test('a second photo of the same foods gets the same numbers', () async {
    final cache = MemoryFoodNumberCache();
    final first = await ModelMealPhotoInterpreter(
      _PhotoApi(_fixture()),
      cache: cache,
    ).interpret(_photo);
    final second = await ModelMealPhotoInterpreter(
      _PhotoApi(_fixture()),
      cache: cache,
    ).interpret(_photo);

    expect(_ingredients(second).map((i) => i.source).toSet(), {
      IngredientSource.cache,
    });
    expect(
      _ingredients(second).map((i) => i.per100g),
      _ingredients(first).map((i) => i.per100g),
    );
  });

  test(
    'a reply that does not fit is a bad reply, with no second request',
    () async {
      final api = _PhotoApi({'dish': 'x'});

      await expectLater(
        ModelMealPhotoInterpreter(api).interpret(_photo),
        throwsA(
          isA<MealInterpreterException>().having(
            (e) => e.failure,
            'failure',
            MealInterpreterFailure.transient,
          ),
        ),
      );
      expect(api.contents, hasLength(1));
    },
  );

  test('an empty ingredient list is "no food", not an error', () async {
    final result = await ModelMealPhotoInterpreter(
      _PhotoApi({'dishes': []}),
    ).interpret(_photo);

    expect(result.items, isEmpty);
    expect(result.estimate, isNull);
  });

  test('a client without the photo tool is unsupported', () async {
    await expectLater(
      ModelMealPhotoInterpreter(_TextOnlyApi()).interpret(_photo),
      throwsA(
        isA<MealInterpreterException>().having(
          (e) => e.failure,
          'failure',
          MealInterpreterFailure.unsupported,
        ),
      ),
    );
  });
}
