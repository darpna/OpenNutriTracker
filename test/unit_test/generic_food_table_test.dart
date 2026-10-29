import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';

GenericFoodTable _small(List<List<Object?>> rows) =>
    GenericFoodTable.fromRows(rows);

void main() {
  group('words', () {
    test('are lower-cased, punctuation-free and singular', () {
      expect(normalizedWords('Chickpeas, Cooked!'), ['chickpea', 'cooked']);
      expect(normalizedWords('Tomatoes'), ['tomato']);
      expect(normalizedWords('Berries'), ['berry']);
      expect(normalizedWords('Curry leaves'), ['curry', 'leaf']);
      expect(normalizedWords('Hummus, Couscous, Asparagus, Swiss'), [
        'hummus',
        'couscous',
        'asparagus',
        'swiss',
      ]);
    });

    test('drop the words that only join others', () {
      expect(normalizedWords('Oil, salad or cooking'), [
        'oil',
        'salad',
        'cooking',
      ]);
    });

    test('"without salt" is not a salty food', () {
      expect(normalizedWords('Butter, without salt'), ['butter']);
      expect(normalizedWords('Butter, without added salt'), ['butter']);
      expect(normalizedWords('Butter, with salt'), ['butter', 'salt']);
    });
  });

  group('the threshold is on the share of the name\'s words found', () {
    final table = _small([
      ['Rice, white, long-grain, cooked', 130, 2.7, 28.2, 0.3],
    ]);

    test('all of them matches', () {
      expect(table.match('Rice, white, cooked'), isNotNull);
    });

    test('three of four is exactly enough', () {
      expect(GenericFoodTable.minRecall, 0.75);
      expect(table.match('Rice, white, cooked, fluffy')!.recall, 0.75);
    });

    test('two of three is not', () {
      expect(table.match('Rice, purple, cooked'), isNull);
    });

    test('one of two is not', () {
      expect(table.match('Rice, wild'), isNull);
    });
  });

  group('the head noun must match', () {
    final table = _small([
      ['Spices, curry powder', 325, 14.3, 55.8, 14.0],
      ['Oil, peanut, salad or cooking', 884, 0, 0, 100],
    ]);

    test('a name that only shares a later word does not match', () {
      // "cooking" is in the description, but the name's head is "pan".
      expect(table.match('Pan cooking oil'), isNull);
    });

    test(
      'a head that is only a modifier in the description does not match',
      () {
        expect(table.match('Curry leaves'), isNull);
      },
    );
  });

  group('among equals', () {
    test('the plainer description wins', () {
      final table = _small([
        [
          'Rice, white, long-grain, enriched, cooked, with salt',
          130,
          2.7,
          28.2,
          0.3,
        ],
        ['Rice, white, glutinous, unenriched, cooked', 97, 2.0, 21.1, 0.2],
        ['Rice, white, cooked', 128, 2.6, 28.0, 0.3],
      ]);
      expect(table.match('Rice, white, cooked')!.food.kcal, 128);
    });

    test('a processed product is not what a plain name asks for', () {
      final table = _small([
        [
          'Chicken breast tenders, breaded, cooked, microwaved',
          252,
          18,
          16,
          13,
        ],
        [
          'Chicken, broilers or fryers, breast, meat only, cooked, roasted',
          165,
          31,
          0,
          3.6,
        ],
      ]);
      expect(
        table.match('Chicken breast, cooked')!.food.description,
        startsWith('Chicken, broilers'),
      );
    });
  });

  group('the bundled table', () {
    late GenericFoodTable table;

    setUpAll(() {
      table = GenericFoodTable.fromGzipBytes(
        File(GenericFoodTable.assetPath).readAsBytesSync(),
      );
    });

    test('is USDA Foundation Foods and SR Legacy, thousands of rows', () {
      expect(table.length, greaterThan(7000));
    });

    // Real pairs, run against the real asset. What the matcher answers for each
    // is the whole of its tuning: change the threshold or the scoring and this
    // list says what moved.
    final matches = <String, (String, double)>{
      'Rice, white, cooked': ('Rice, white', 130),
      'Oil, peanut': ('Oil, peanut, salad or cooking', 884),
      'Chickpeas, cooked': ('Chickpeas', 164),
      'Ghee': ('Butter, Clarified butter (ghee)', 900),
      'Tamarind': ('Tamarinds, raw', 239),
      'Onions, raw': ('Onions, raw', 40),
      'Butter, salted': ('Butter, salted', 717),
      'Salt': ('Salt, table', 0),
      'Cream, heavy': ('Cream, heavy', 335.9),
      'Lentils, cooked': ('Lentils, mature seeds, cooked', 116),
      'Garlic, raw': ('Garlic, raw', 143),
      'Egg, scrambled': ('Egg, whole, cooked, scrambled', 149),
      'Black beans, cooked': ('Beans, black', 132),
      'Potatoes, boiled': ('Potatoes, boiled', 78),
      'Cheese, cheddar': ('Cheese, cheddar', 408),
    };
    for (final entry in matches.entries) {
      test('"${entry.key}" matches ${entry.value.$1}', () {
        final match = table.match(entry.key);

        expect(match, isNotNull);
        expect(match!.food.description, startsWith(entry.value.$1));
        expect(match.food.kcal, closeTo(entry.value.$2, 0.5));
      });
    }

    for (final name in ['Curry leaves', 'Chili oil', 'Paneer', 'Dal makhani']) {
      test('"$name" has no match, and keeps the model\'s numbers', () {
        expect(table.match(name), isNull);
      });
    }

    test('a blank name matches nothing', () {
      expect(table.match(''), isNull);
      expect(table.match('  ,, '), isNull);
    });

    // The names a bake-off of real photos missed or mismatched, and what each
    // matches now. Latin binomials and brackets, and words for how a food was
    // cut, are dropped before matching.
    final fixed = <String, (String, double)>{
      'Coriander (Coriandrum sativum)': (
        'Coriander (cilantro) leaves, raw',
        23,
      ),
      'Coriander (Coriandrum sativum), fresh': (
        'Coriander (cilantro) leaves, raw',
        23,
      ),
      'Fresh coriander': ('Coriander (cilantro) leaves, raw', 23),
      'Turmeric, Curcuma longa, ground': ('Spices, turmeric, ground', 312),
      'Onion, chopped': ('Onions, raw', 40),
      'Chopped onion': ('Onions, raw', 40),
      'Garlic, minced': ('Garlic, raw', 143),
      'Ginger, fresh, minced': ('Ginger root, raw', 80),
      'Cooked chickpeas': ('Chickpeas', 164),
      'Coconut oil': ('Oil, coconut', 833),
      'Ghee (clarified butter)': ('Butter, Clarified butter (ghee)', 900),
    };
    for (final entry in fixed.entries) {
      test('"${entry.key}" matches ${entry.value.$1}', () {
        final match = table.match(entry.key);

        expect(match, isNotNull);
        expect(match!.food.description, startsWith(entry.value.$1));
        expect(match.food.kcal, closeTo(entry.value.$2, 0.5));
      });
    }

    test('"Sauce, soy" picks peanut sauce on words alone, soy sauce through '
        'the kcal gate', () {
      expect(
        table.match('Sauce, soy')!.food.description,
        startsWith('Sauce, peanut'),
      );

      final gated = table.match(
        'Sauce, soy',
        accept: (food) => food.kcal <= 2 * 60 && food.kcal >= 60 / 2,
      );
      expect(gated!.food.description, startsWith('Soy sauce'));
      expect(gated.food.kcal, lessThan(100));
    });

    test('"raw" or "cooked" the table never says for a food costs nothing', () {
      // Garlic is only ever "raw" in the table; "cooked" is not a reason to
      // miss it.
      expect(table.match('Garlic, cooked')!.food.description, 'Garlic, raw');
      // Rice is both, so the word still decides.
      expect(
        table.match('Rice, white, raw')!.food.description,
        contains('raw'),
      );
    });
  });

  group('cleaning a name', () {
    test('drops brackets, Latin binomials and how it was cut', () {
      expect(cleanFoodName('Coriander (Coriandrum sativum)'), 'Coriander');
      expect(
        cleanFoodName('Turmeric, Curcuma longa, ground'),
        'Turmeric, ground',
      );
      expect(cleanFoodName('Cumin [Cuminum cyminum] seeds'), 'Cumin seeds');
      expect(cleanFoodName('Fresh mint, finely chopped'), 'mint');
      expect(cleanFoodName('Onion, diced'), 'Onion');
    });

    test('keeps capitalised words that are not a genus', () {
      expect(cleanFoodName('Chicken tikka'), 'Chicken tikka');
      expect(cleanFoodName('Basmati rice'), 'Basmati rice');
    });

    test('never cleans a name down to nothing', () {
      expect(cleanFoodName('Fresh'), 'Fresh');
    });
  });
}
