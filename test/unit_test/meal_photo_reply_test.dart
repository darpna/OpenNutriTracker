import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/ai_per100_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';

Map<String, Object?> _per100({
  num kcal = 250,
  num protein = 12,
  num carbs = 20,
  num fat = 13,
}) => {'kcal': kcal, 'protein_g': protein, 'carbs_g': carbs, 'fat_g': fat};

Map<String, Object?> _component(
  String query, {
  Object? grams = 100,
  String? portion,
  Object? count,
  Object? per100 = 'default',
}) => {
  'query': query,
  'grams': grams,
  'portion': ?portion,
  'count': ?count,
  'per_100g': per100 == 'default' ? _per100() : per100,
};

void main() {
  group('a dish reply', () {
    test('keeps the dish, its components and their estimates', () {
      final result = mealPhotoResultFromJson({
        'dish': {
          'name': 'Katsu chicken wrap',
          'components': [
            _component('flour tortilla', grams: 70),
            _component('breaded fried chicken', grams: 120),
          ],
        },
        'items': [],
      });

      expect(result.dish!.name, 'Katsu chicken wrap');
      expect(result.dish!.components, hasLength(2));
      final chicken = result.dish!.components.last;
      expect(chicken.query, 'breaded fried chicken');
      expect(chicken.quantity, 120);
      expect(chicken.unit, 'g');
      expect(chicken.estimated, isTrue);
      expect(chicken.estimatedGrams, 120);
      expect(chicken.aiPer100!.kcal, 250);
      expect(result.items, isEmpty);
    });

    test('separate foods on the plate stay items beside the dish', () {
      final result = mealPhotoResultFromJson({
        'dish': {
          'name': 'Burger',
          'components': [_component('beef patty')],
        },
        'items': [_component('fries', grams: 150)],
      });

      expect(result.dish!.components.single.query, 'beef patty');
      expect(result.items.single.query, 'fries');
    });

    test('a dish whose components are all unusable is refused', () {
      expect(
        () => mealPhotoResultFromJson({
          'dish': {
            'name': 'Wrap',
            'components': [_component('123')],
          },
        }),
        throwsA(isA<MealPhotoReplyException>()),
      );
    });
  });

  group('amounts', () {
    ParsedAmount read(Object? grams, {String? portion, Object? count}) {
      final item = mealPhotoResultFromJson({
        'items': [_component('rice', grams: grams, portion: portion, count: count)],
      }).items.single;
      return (
        quantity: item.quantity,
        unit: item.unit,
        estimated: item.estimated,
        portion: item.portion,
      );
    }

    test('a gram estimate is kept and flagged estimated', () {
      final amount = read(180);
      expect(amount.quantity, 180);
      expect(amount.unit, 'g');
      expect(amount.estimated, isTrue);
    });

    test('3 kg for one item is the largest believed', () {
      expect(read(3000).quantity, 3000);
      expect(read(3000.5).quantity, isNull);
    });

    test('zero, negative and absurd amounts are dropped, the food kept', () {
      for (final bad in [0, -50, 5000, 'lots', true, double.nan]) {
        final amount = read(bad);
        expect(amount.quantity, isNull, reason: '$bad');
        expect(amount.estimated, isFalse, reason: '$bad');
      }
    });

    test('a numeric string is read like a number', () {
      expect(read('120').quantity, 120);
      expect(read('1,5').quantity, 1.5);
    });

    test('a portion needs a count and carries the grams beside it', () {
      final item = mealPhotoResultFromJson({
        'items': [_component('bread', grams: 60, portion: 'slice', count: 2)],
      }).items.single;

      expect(item.quantity, 2);
      expect(item.unit, isNull);
      expect(item.portion, 'slice');
      expect(item.estimatedGrams, 60);
      expect(item.estimated, isTrue);
    });

    test('a portion with an absurd count falls back to the grams', () {
      final item = mealPhotoResultFromJson({
        'items': [_component('bread', grams: 60, portion: 'slice', count: 99)],
      }).items.single;

      expect(item.quantity, 60);
      expect(item.unit, 'g');
      expect(item.portion, isNull);
    });
  });

  group('per-100 g macros', () {
    AiPer100Estimate? read(Map<String, Object?> per100) => mealPhotoResultFromJson(
      {
        'items': [_component('rice', per100: per100)],
      },
    ).items.single.aiPer100;

    test('plausible figures are kept', () {
      expect(read(_per100()), isNotNull);
    });

    test('figures that cannot describe 100 g are dropped, the food kept', () {
      expect(read(_per100(kcal: 2000)), isNull, reason: 'denser than fat');
      expect(read(_per100(fat: 120)), isNull, reason: 'more than 100 g');
      expect(
        read(_per100(protein: 60, carbs: 60, fat: 0, kcal: 480)),
        isNull,
        reason: 'macros sum past 100 g',
      );
      expect(
        read(_per100(kcal: 600, protein: 1, carbs: 1, fat: 2)),
        isNull,
        reason: '600 kcal from 2 g of fat',
      );
      expect(read(_per100(kcal: -5)), isNull);
    });

    test('a figure missing from the object drops the estimate', () {
      expect(read({'kcal': 100, 'protein_g': 1, 'carbs_g': 1}), isNull);
    });
  });

  group('strict validation', () {
    void refused(Object? input, String why) => expect(
      () => mealPhotoResultFromJson(input),
      throwsA(isA<MealPhotoReplyException>()),
      reason: why,
    );

    test('anything but an object', () {
      refused(null, 'null');
      refused('[]', 'a string');
      refused([], 'a list');
    });

    test('neither dish nor items', () => refused({}, 'empty object'));

    test('items that are not an array', () {
      refused({'items': 'eggs'}, 'string items');
      refused({'items': {}}, 'object items');
    });

    test('an entry that is not an object', () {
      refused({'items': ['egg']}, 'bare string entry');
    });

    test('a component with no query or no per_100g', () {
      refused({
        'items': [
          {'grams': 100, 'per_100g': _per100()},
        ],
      }, 'no query');
      refused({
        'items': [
          {'query': 'rice', 'grams': 100},
        ],
      }, 'no per_100g');
    });

    test('a dish with no name or no components', () {
      refused({
        'dish': {'components': [_component('rice')]},
      }, 'no name');
      refused({
        'dish': {'name': 'Bowl'},
      }, 'no components');
      refused({
        'dish': {'name': 'Bowl', 'components': []},
      }, 'empty components');
      refused({'dish': 'wrap'}, 'dish is a string');
    });

    test('every entry unusable is not "no food"', () {
      refused({
        'items': [_component('123'), _component('!!')],
      }, 'all dropped');
    });

    test('an empty items list is the answer "no food here"', () {
      final result = mealPhotoResultFromJson({'items': []});
      expect(result.items, isEmpty);
      expect(result.dish, isNull);
    });

    test('a long list is cut, not refused', () {
      final result = mealPhotoResultFromJson({
        'items': [for (var i = 0; i < 30; i++) _component('food $i')],
      });
      expect(result.items, hasLength(20));
    });
  });
}

typedef ParsedAmount = ({
  double? quantity,
  String? unit,
  bool estimated,
  String? portion,
});
