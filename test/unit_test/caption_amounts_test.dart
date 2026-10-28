import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/ai_per100_estimate.dart';
import 'package:opennutritracker/features/add_meal/util/caption_amounts.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

const _macros = AiPer100Estimate(kcal: 200, proteinG: 10, carbsG: 20, fatG: 8);

ParsedMealItem _est(String query, double grams) => ParsedMealItem(
  query: query,
  quantity: grams,
  unit: 'g',
  estimated: true,
  estimatedGrams: grams,
  aiPer100: _macros,
);

MealTextParseResult _wrap() => MealTextParseResult(
  items: const [],
  errors: const [],
  dish: ParsedMealDish(
    name: 'Katsu chicken wrap',
    components: [
      _est('flour tortilla', 70),
      _est('breaded fried chicken', 120),
      _est('lettuce', 20),
    ],
  ),
);

void main() {
  test('no caption changes nothing', () {
    final result = _wrap();
    expect(applyCaptionAmounts(result, null), same(result));
    expect(applyCaptionAmounts(result, '  '), same(result));
  });

  test('a caption with no amount in it changes nothing', () {
    final result = _wrap();
    expect(
      applyCaptionAmounts(result, 'katsu chicken wrap from a cafe, ate half'),
      same(result),
    );
  });

  test('a stated weight overrides the estimate for the food it names', () {
    final result = applyCaptionAmounts(_wrap(), '200g chicken, katsu wrap');

    final chicken = result.dish!.components[1];
    expect(chicken.query, 'breaded fried chicken');
    expect(chicken.quantity, 200);
    expect(chicken.unit, 'g');
    expect(chicken.estimated, isFalse, reason: 'somebody said it');
    expect(chicken.estimatedGrams, isNull);
    expect(chicken.aiPer100, _macros, reason: 'the fallback numbers stay');

    // The others keep their estimates.
    expect(result.dish!.components[0].quantity, 70);
    expect(result.dish!.components[0].estimated, isTrue);
  });

  test('amounts written inside a sentence are found', () {
    final result = applyCaptionAmounts(
      _wrap(),
      'katsu wrap from a cafe with 200g chicken and 15 g lettuce, ate half',
    );

    final parts = result.dish!.components;
    expect(parts[1].quantity, 200);
    expect(parts[1].estimated, isFalse);
    expect(parts[2].quantity, 15);
    expect(parts[2].estimated, isFalse);
    expect(parts[0].quantity, 70, reason: 'the tortilla was not mentioned');
  });

  test('a weight in another unit is converted by the parser, not here', () {
    final result = applyCaptionAmounts(_wrap(), '0.25 kg chicken');
    final chicken = result.dish!.components[1];
    expect(chicken.quantity, 250);
    expect(chicken.unit, 'g');
  });

  test('a bare count overrides with a count', () {
    final result = applyCaptionAmounts(
      MealTextParseResult(items: [_est('fried egg', 50)], errors: const []),
      '2 eggs',
    );
    expect(result.items.single.quantity, 2);
    expect(result.items.single.unit, isNull);
    expect(result.items.single.estimated, isFalse);
  });

  test('a phrase that names nothing on the plate is ignored', () {
    final result = applyCaptionAmounts(_wrap(), '300g pizza');
    expect(result.dish!.components[1].quantity, 120);
    expect(result.dish!.components[1].estimated, isTrue);
  });

  test('a stated total for the dish rescales the components', () {
    final result = applyCaptionAmounts(_wrap(), 'katsu chicken wrap 420 g');

    final grams = result.dish!.components.map((c) => c.quantity!).toList();
    // 70 + 120 + 20 = 210, doubled.
    expect(grams, [140, 240, 40]);
    expect(grams.reduce((a, b) => a + b), closeTo(420, 1e-9));
    expect(
      result.dish!.components.every((c) => c.estimated),
      isTrue,
      reason: 'the total is stated, the split between parts is not',
    );
  });

  test('a stated total with no unit cannot rescale', () {
    final result = applyCaptionAmounts(_wrap(), 'katsu chicken wrap 2');
    expect(result.dish!.components.map((c) => c.quantity), [70, 120, 20]);
  });

  test('each statement overrides one target', () {
    final result = applyCaptionAmounts(
      MealTextParseResult(
        items: [_est('chicken', 100), _est('chicken breast', 100)],
        errors: const [],
      ),
      '150g chicken, 80g chicken breast',
    );
    expect(result.items.map((i) => i.quantity), [150, 80]);
  });
}
