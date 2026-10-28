import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';
import 'package:opennutritracker/features/add_meal/util/portion_match.dart';

/// [parsed] with its estimated amount put into terms [meal] can honour.
///
/// A photograph may estimate "2 slices" or "150 g". Grams always mean the same
/// thing, so they stand. A count of a portion only means something against a
/// food that has a portion of that name — in the database or among the user's
/// own servings (both are in [MealEntity.portions] by the time rows are built)
/// — so for any other food the count is swapped for the model's own gram
/// estimate of the same amount. With neither, the amount is dropped and the row
/// says so ("Amount not stated"), rather than logging a count against a food
/// that cannot scale one.
///
/// Anything that was not estimated is returned untouched, and so is any row
/// without a matched food: there is nothing to settle against.
ParsedMealItem settleEstimate(ParsedMealItem parsed, MealEntity? meal) {
  if (!parsed.estimated || parsed.unit != null || parsed.quantity == null) {
    return parsed;
  }
  if (meal == null) return parsed;

  final portion = parsed.portion;
  final honoured = portion != null
      ? matchPortionToKey(portion, meal.portions) != null
      : meal.servingQuantity != null;
  if (honoured) return parsed;

  final grams = parsed.estimatedGrams;
  if (grams == null) return parsed.copyWith(clearAmount: true);
  return ParsedMealItem(
    query: parsed.query,
    quantity: grams,
    unit: 'g',
    estimated: true,
    estimatedGrams: grams,
    aiPer100: parsed.aiPer100,
  );
}
