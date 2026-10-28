import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_portion_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';
import 'package:opennutritracker/features/add_meal/util/portion_unit.dart';
import 'package:opennutritracker/features/meal_detail/util/meal_quantity_converter.dart';
import 'package:opennutritracker/features/meal_detail/util/quick_serving_option.dart';

const _cup = MealPortionEntity(
  label: '1 cup',
  gramWeight: 244,
  localized: false,
);
const _slice = MealPortionEntity(
  label: '1 slice',
  gramWeight: 38,
  localized: false,
);
const _bowl = MealPortionEntity(
  label: '1 bowl',
  gramWeight: 250,
  localized: true,
  customPortionId: 'bowl',
);
const _roti = MealPortionEntity(
  label: '1 roti',
  gramWeight: 40,
  localized: true,
  customPortionId: 'roti',
);

MealEntity _meal({
  double? servingQuantity,
  String? servingSize,
  List<MealPortionEntity> portions = const [],
  String unit = 'g',
}) => MealEntity(
  code: '1',
  name: 'Dal',
  url: null,
  mealQuantity: null,
  mealUnit: unit,
  servingQuantity: servingQuantity,
  servingUnit: unit,
  servingSize: servingSize,
  source: MealSourceEntity.custom,
  nutriments: MealNutrimentsEntity.empty(),
  portions: portions,
);

BulkAddRow _row(MealEntity meal, String unit) => BulkAddRow(
  resolved: ResolvedMealItem(
    parsed: ParsedMealItem(query: 'dal'),
    candidates: [meal],
    selectedIndex: 0,
    confidence: 0.9,
  ),
  selectedIndex: 0,
  amountText: '2',
  unit: unit,
);

void main() {
  group('a custom serving converts like any other portion', () {
    test('on a food with no portions it is the first and only one', () {
      final meal = _meal().withCustomPortions([_bowl, _roti]);

      expect(meal.portions, [_bowl, _roti]);
      expect(convertQuantityToBaseUnit(1, 'serving', meal), 250);
      expect(convertQuantityToBaseUnit(2, 'serving#1', meal), 80);
    });

    test('after the database portions, which keep their places', () {
      final meal = _meal(portions: [_cup, _slice]).withCustomPortions([_bowl]);

      expect(meal.portions, [_cup, _slice, _bowl]);
      expect(convertQuantityToBaseUnit(1, 'serving', meal), 244);
      expect(convertQuantityToBaseUnit(1, 'serving#1', meal), 38);
      expect(convertQuantityToBaseUnit(1.5, 'serving#2', meal), 375);
    });

    test('a food with a serving of its own keeps it as `serving`', () {
      // Otherwise the first custom serving would take over what the bare
      // `serving` unit has always meant for this food.
      final meal = _meal(
        servingQuantity: 30,
        servingSize: '1 slice (30 g)',
      ).withCustomPortions([_bowl]);

      expect(meal.portions.map((p) => p.gramWeight), [30, 250]);
      expect(meal.portions.first.isCustom, isFalse);
      expect(convertQuantityToBaseUnit(2, 'serving', meal), 60);
      expect(convertQuantityToBaseUnit(2, 'serving#1', meal), 500);
    });

    test('a millilitre food scales in millilitres', () {
      final meal = _meal(unit: 'ml').withCustomPortions([_bowl]);
      expect(convertQuantityToBaseUnit(2, 'serving', meal), 500);
    });

    test('the stored unit is still the closed vocabulary', () {
      expect(storedUnit(portionUnit(3)), 'serving');
    });

    test('merging is idempotent and deleting drops only the user\'s', () {
      final merged = _meal(portions: [_cup]).withCustomPortions([_bowl, _roti]);

      expect(merged.withCustomPortions([_bowl, _roti]).portions, merged.portions);
      expect(merged.withCustomPortions([_roti]).portions, [_cup, _roti]);
      expect(merged.withCustomPortions(const []).portions, [_cup]);
    });

    test('nothing to add leaves the meal as it was', () {
      final meal = _meal(servingQuantity: 30, servingSize: '30 g');
      expect(identical(meal.withCustomPortions(const []), meal), isTrue);
      expect(meal.withCustomPortions(const []).portions, isEmpty);
    });

    test('equality tells a custom serving from a database one', () {
      expect(
        const MealPortionEntity(label: '1 bowl', gramWeight: 250, localized: true),
        isNot(_bowl),
      );
    });
  });

  group('the bulk-add unit picker lists them', () {
    test('after the database portions, one entry each', () {
      final meal = _meal(portions: [_cup, _slice]).withCustomPortions([_bowl]);
      expect(
        _row(meal, 'serving').allowedUnits.where(isPortionUnit),
        ['serving', 'serving#1', 'serving#2'],
      );
    });

    test('on a food that had none, where `serving` was not offered at all', () {
      final plain = _row(_meal(), 'g');
      expect(plain.allowedUnits.where(isPortionUnit), isEmpty);

      final withBowl = _row(_meal().withCustomPortions([_bowl]), 'serving');
      expect(withBowl.allowedUnits.where(isPortionUnit), ['serving']);
      expect(
        convertQuantityToBaseUnit(2, withBowl.effectiveUnit, withBowl.meal!),
        500,
      );
    });
  });

  group('the Add serving chip', () {
    test('is offered when the food has no portions and no serving values', () {
      expect(offersAddServingChip(_meal()), isTrue);
    });

    test('is not when the food has a serving or portions or a serving text', () {
      expect(offersAddServingChip(_meal(servingQuantity: 30)), isFalse);
      expect(offersAddServingChip(_meal(servingSize: '1 cup')), isFalse);
      expect(offersAddServingChip(_meal(portions: [_cup])), isFalse);
      expect(offersAddServingChip(_meal().withCustomPortions([_bowl])), isFalse);
    });
  });
}
