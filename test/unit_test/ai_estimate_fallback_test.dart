import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/ai_per100_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_portion_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/search_products_usecase.dart';
import 'package:opennutritracker/features/add_meal/util/ai_estimate_meal.dart';
import 'package:opennutritracker/features/add_meal/util/estimate_settle.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';
import 'package:opennutritracker/features/add_meal/util/resolver_relevance.dart';

const _estimate = AiPer100Estimate(
  kcal: 250,
  proteinG: 12,
  carbsG: 20,
  fatG: 13,
);

MealEntity _food(
  String name, {
  String? brands,
  MealSourceEntity source = MealSourceEntity.off,
  double kcal = 100,
  double? servingQuantity,
  List<MealPortionEntity> portions = const [],
}) => MealEntity(
  code: '$name|$brands',
  name: name,
  brands: brands,
  url: null,
  mealQuantity: null,
  mealUnit: 'g',
  servingQuantity: servingQuantity,
  servingUnit: null,
  servingSize: null,
  portions: portions,
  source: source,
  nutriments: MealNutrimentsEntity(
    energyKcal100: kcal,
    carbohydrates100: 0,
    fat100: 0,
    proteins100: 0,
    sugars100: null,
    saturatedFat100: null,
    fiber100: null,
  ),
);

class _Search implements SearchProductsUseCase {
  final Map<String, List<MealEntity>> off;

  _Search(this.off);

  @override
  Future<SearchProductsResult> searchOFFProductsByString(
    String searchString, {
    bool skipRemote = false,
  }) async => SearchProductsResult(
    meals: off[searchString] ?? const [],
    remoteSourceEmpty: false,
  );

  @override
  Future<SearchProductsResult> searchFDCFoodByString(
    String searchString, {
    bool skipRemote = false,
    bool forResolution = false,
  }) async => const SearchProductsResult(meals: [], remoteSourceEmpty: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ResolvedMealItem> _resolve(
  Map<String, List<MealEntity>> db,
  ParsedMealItem item,
) async => (await ResolveParsedMealsUseCase(_Search(db)).resolve([item])).single;

void main() {
  group('the threshold sits where the matcher already draws its lines', () {
    // These pin the numbers kAiFallbackConfidenceThreshold was chosen from. If
    // the scorer moves, this is the place that says the threshold has to.
    double score(String name, String query) =>
        scoreMealForResolution(_food(name), query);

    test('one word an inflection apart clears it', () {
      expect(score('Egg', 'eggs'), greaterThanOrEqualTo(
        kAiFallbackConfidenceThreshold,
      ));
    });

    test('the right family but the wrong food does not', () {
      expect(score('Chicken', 'fried chicken'), lessThan(
        kAiFallbackConfidenceThreshold,
      ));
    });

    test('a record that is not the food at all does not', () {
      expect(score('Mayonnaise', 'mayo'), lessThan(
        kAiFallbackConfidenceThreshold,
      ));
    });

    test('an exact name is far above it', () {
      expect(score('Lettuce', 'lettuce'), greaterThan(0.95));
    });

    test('sits between the floor and the one-inflection match', () {
      expect(kAiFallbackConfidenceThreshold, greaterThan(
        kResolutionConfidenceFloor,
      ));
      expect(kAiFallbackConfidenceThreshold, lessThan(0.75));
    });
  });

  group('database first', () {
    test('a good match keeps its own numbers, estimate or not', () async {
      final item = await _resolve(
        {
          'lettuce': [_food('Lettuce', kcal: 15)],
        },
        const ParsedMealItem(query: 'lettuce', aiPer100: _estimate),
      );

      expect(item.usesAiEstimate, isFalse);
      expect(item.candidates.single.name, 'Lettuce');
      expect(item.candidates.single.isAiEstimate, isFalse);
      expect(item.selected!.nutriments.energyKcal100, 15);
    });

    test('a weak match yields to the estimate and stays pickable', () async {
      final item = await _resolve(
        {
          'fried chicken': [_food('Chicken', kcal: 120)],
        },
        const ParsedMealItem(query: 'fried chicken', aiPer100: _estimate),
      );

      expect(item.usesAiEstimate, isTrue);
      expect(item.selected!.isAiEstimate, isTrue);
      expect(item.selected!.nutriments.energyKcal100, 250);
      expect(item.selected!.nutriments.proteins100, 12);
      expect(item.selected!.nutriments.carbohydrates100, 20);
      expect(item.selected!.nutriments.fat100, 13);
      expect(
        item.candidates.map((c) => c.name),
        ['Fried chicken', 'Chicken'],
        reason: 'the database food is still one tap away',
      );
      expect(item.isLowConfidence, isFalse, reason: 'the label is "AI estimate"');
    });

    test('no match at all yields to the estimate', () async {
      final item = await _resolve(
        const {},
        const ParsedMealItem(query: 'katsu sauce', aiPer100: _estimate),
      );

      expect(item.isResolved, isTrue);
      expect(item.usesAiEstimate, isTrue);
      expect(item.selected!.name, 'Katsu sauce');
    });

    test('without an estimate nothing changes', () async {
      final weak = await _resolve(
        {
          'fried chicken': [_food('Chicken', kcal: 120)],
        },
        const ParsedMealItem(query: 'fried chicken'),
      );
      expect(weak.usesAiEstimate, isFalse);
      expect(weak.candidates.single.name, 'Chicken');

      final none = await _resolve(
        const {},
        const ParsedMealItem(query: 'katsu sauce'),
      );
      expect(none.isResolved, isFalse);
    });

    test('a generic query matched to somebody\'s product is weak', () async {
      final item = await _resolve(
        {
          'fried chicken': [
            _food('Fried chicken strips', brands: 'Coop Prix Garantie', kcal: 210),
          ],
        },
        const ParsedMealItem(query: 'fried chicken', aiPer100: _estimate),
      );

      // 0.8 on the name clears the threshold. The brand is not one the query
      // names and 0.8 is under the branded bar, so it is somebody's product
      // standing in for the food.
      expect(item.usesAiEstimate, isTrue);
    });

    test('the same record unbranded is kept', () async {
      final item = await _resolve(
        {
          'fried chicken': [_food('Fried chicken strips', kcal: 210)],
        },
        const ParsedMealItem(query: 'fried chicken', aiPer100: _estimate),
      );

      expect(item.usesAiEstimate, isFalse);
    });

    test('a brand the query names is not held against the match', () async {
      final item = await _resolve(
        {
          'oatly oat drink': [_food('Oat drink', brands: 'Oatly', kcal: 46)],
        },
        const ParsedMealItem(query: 'oatly oat drink', aiPer100: _estimate),
      );

      expect(item.usesAiEstimate, isFalse);
    });

    test('isWeakMatch: the threshold is the line', () {
      final f = _food('X');
      expect(
        ResolveParsedMealsUseCase.isWeakMatch(
          f,
          'x',
          kAiFallbackConfidenceThreshold - 0.01,
        ),
        isTrue,
      );
      expect(
        ResolveParsedMealsUseCase.isWeakMatch(
          f,
          'x',
          kAiFallbackConfidenceThreshold,
        ),
        isFalse,
      );
    });
  });

  group('an estimated amount settles against the matched food', () {
    const bread = ParsedMealItem(
      query: 'bread',
      quantity: 2,
      portion: 'slice',
      estimated: true,
      estimatedGrams: 60,
    );
    final slice = MealPortionEntity(
      label: '1 slice',
      englishLabel: '1 slice',
      gramWeight: 30,
      localized: true,
    );
    final custom = MealPortionEntity(
      label: 'sandwich',
      englishLabel: 'sandwich',
      gramWeight: 90,
      localized: true,
      customPortionId: 'c1',
    );

    test('grams stand as they are', () {
      const grams = ParsedMealItem(
        query: 'rice',
        quantity: 150,
        unit: 'g',
        estimated: true,
        estimatedGrams: 150,
      );
      expect(settleEstimate(grams, _food('Rice')), same(grams));
    });

    test('a portion the food has is kept', () {
      final settled = settleEstimate(bread, _food('Bread', portions: [slice]));
      expect(settled.quantity, 2);
      expect(settled.portion, 'slice');
      expect(settled.unit, isNull);
    });

    test('a portion among the user\'s own servings is kept too', () {
      const sandwich = ParsedMealItem(
        query: 'sandwich',
        quantity: 1,
        portion: 'sandwich',
        estimated: true,
        estimatedGrams: 200,
      );
      final settled = settleEstimate(
        sandwich,
        _food('Sandwich', portions: [custom]),
      );
      expect(settled.portion, 'sandwich');
      expect(settled.quantity, 1);
    });

    test('a portion the food lacks becomes the model\'s grams', () {
      final settled = settleEstimate(bread, _food('Bread'));
      expect(settled.quantity, 60);
      expect(settled.unit, 'g');
      expect(settled.portion, isNull);
      expect(settled.estimated, isTrue);
    });

    test('a bare count needs a scalable serving, else grams', () {
      const eggs = ParsedMealItem(
        query: 'egg',
        quantity: 2,
        estimated: true,
        estimatedGrams: 100,
      );
      expect(settleEstimate(eggs, _food('Egg', servingQuantity: 50)).quantity, 2);
      expect(settleEstimate(eggs, _food('Egg')).quantity, 100);
    });

    test('no grams and nothing to honour the count: no amount', () {
      const lone = ParsedMealItem(
        query: 'bread',
        quantity: 2,
        portion: 'slice',
        estimated: true,
      );
      final settled = settleEstimate(lone, _food('Bread'));
      expect(settled.quantity, isNull);
      expect(settled.estimated, isFalse);
    });

    test('an unresolved row has nothing to settle against', () {
      expect(settleEstimate(bread, null), same(bread));
    });
  });
}
