import 'package:opennutritracker/features/add_meal/domain/ai_per100_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';

/// Every food built from a model's own macros carries this prefix in its
/// code. A prefix rather than a field because [MealEntity] is rebuilt by half
/// a dozen `with…` copies (custom servings among them) that would each have to
/// remember to carry a flag, while the code survives all of them.
const aiEstimateCodePrefix = 'ai-estimate:';

extension AiEstimateMeal on MealEntity {
  /// True for a food whose numbers are a model's guess, not a database's.
  bool get isAiEstimate => code?.startsWith(aiEstimateCodePrefix) ?? false;
}

/// A throwaway food for [query], per 100 g as the model guessed it.
///
/// Weight-based and without servings, so an amount for it is always grams; its
/// energy is the figure the model gave, and the three macros likewise, with
/// everything else unknown.
MealEntity aiEstimateMeal(String query, AiPer100Estimate estimate) {
  final name = query.trim();
  return MealEntity(
    code: '$aiEstimateCodePrefix${name.toLowerCase()}',
    name: name.isEmpty ? name : name[0].toUpperCase() + name.substring(1),
    url: null,
    mealQuantity: '100',
    mealUnit: 'g',
    servingQuantity: null,
    servingUnit: null,
    servingSize: null,
    nutriments: MealNutrimentsEntity(
      energyKcal100: estimate.kcal,
      carbohydrates100: estimate.carbsG,
      fat100: estimate.fatG,
      proteins100: estimate.proteinG,
      sugars100: null,
      saturatedFat100: null,
      fiber100: null,
    ),
    source: MealSourceEntity.custom,
  );
}
