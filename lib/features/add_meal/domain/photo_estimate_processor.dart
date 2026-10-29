import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/util/caption_amounts.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';
import 'package:opennutritracker/features/add_meal/util/soft_text_score.dart';

/// How far a stated energy may be from 4/4/9 of its macros before it is
/// replaced by the macros' figure.
const kcalTolerance = 0.10;

/// How far the ingredients' grams may be from the stated portion before they
/// are scaled to it.
const portionTolerance = 0.10;

/// Turns what a reply claimed into the estimate the app shows.
///
/// In order:
///  1. each ingredient's energy is checked against 4 kcal per gram of protein
///     and carbohydrate and 9 of fat, and replaced by that figure when it is
///     more than [kcalTolerance] off (macros that cannot fit in the ingredient's
///     grams are first scaled down to fit);
///  2. a reply whose ingredients carry no energy at all, but whose own totals
///     do, is spread over them by grams — never a 0 kcal result when the model
///     returned ingredients;
///  3. a weight the caption states wins: for an ingredient it sets that
///     ingredient's grams, for the dish it is the portion;
///  4. the ingredients are scaled to the portion when their grams are more than
///     [portionTolerance] away from it;
///  5. these are the model-only numbers ([PhotoRecipeEstimate.aiOnly]);
///  6. each ingredient the generic [table] knows takes the table's per-100 g
///     values at its grams, and is marked `db`.
///
/// The model's own totals are never used, except as step 2's last resort.
PhotoRecipeEstimate finalizeEstimate(
  RawPhotoEstimate raw, {
  GenericFoodTable? table,
  String? caption,
}) {
  var ingredients = [for (final i in raw.ingredients) _checked(i)];

  if (_sum(ingredients, (i) => i.kcal) <= 0 && (raw.claimedKcal ?? 0) > 0) {
    final grams = _sum(ingredients, (i) => i.grams);
    ingredients = [
      for (final i in ingredients)
        i.copyWith(kcal: raw.claimedKcal! * i.grams / grams),
    ];
  }

  var portion = raw.portionG;
  final text = caption?.trim();
  if (text != null && text.isNotEmpty) {
    final stated = _applyCaption(ingredients, raw.dish, text);
    ingredients = stated.ingredients;
    portion = stated.dishGrams ?? (stated.changed ? null : portion);
  }

  final sum = _sum(ingredients, (i) => i.grams);
  if (portion != null &&
      portion > 0 &&
      (sum - portion).abs() / portion > portionTolerance) {
    final factor = portion / sum;
    ingredients = [for (final i in ingredients) i.scaled(factor)];
  }

  final aiOnly = PhotoRecipeEstimate.sumOf(ingredients);

  if (table != null) {
    ingredients = [for (final i in ingredients) _grounded(i, table)];
  }

  return PhotoRecipeEstimate(
    dish: raw.dish,
    portionG: PhotoRecipeEstimate.sumOf(ingredients).grams,
    servings: raw.servings,
    ingredients: ingredients,
    confidence: raw.confidence,
    assumptions: raw.assumptions,
    aiOnly: aiOnly,
  );
}

double _sum(
  Iterable<EstimatedIngredient> items,
  double Function(EstimatedIngredient) of,
) => items.fold(0.0, (total, i) => total + of(i));

/// Step 1 for one ingredient.
EstimatedIngredient _checked(EstimatedIngredient i) {
  var protein = i.proteinG, carbs = i.carbsG, fat = i.fatG;
  final macroGrams = protein + carbs + fat;
  // Protein, carbohydrate and fat are parts of the ingredient's weight, so
  // they cannot add up to more than it (a rounding allowance of 2%).
  if (macroGrams > i.grams * 1.02) {
    final factor = i.grams / macroGrams;
    protein *= factor;
    carbs *= factor;
    fat *= factor;
  }
  final fromMacros = 4 * protein + 4 * carbs + 9 * fat;
  var kcal = i.kcal;
  if (fromMacros > 0 &&
      (kcal - fromMacros).abs() / fromMacros > kcalTolerance) {
    kcal = fromMacros;
  }
  return EstimatedIngredient(
    name: i.name,
    grams: i.grams,
    kcal: kcal,
    proteinG: protein,
    carbsG: carbs,
    fatG: fat,
    visible: i.visible,
    source: i.source,
    matchedName: i.matchedName,
  );
}

/// Step 6 for one ingredient.
EstimatedIngredient _grounded(EstimatedIngredient i, GenericFoodTable table) {
  final match = table.match(i.name);
  if (match == null) return i;
  final food = match.food;
  final factor = i.grams / 100;
  return EstimatedIngredient(
    name: i.name,
    grams: i.grams,
    kcal: food.kcal * factor,
    proteinG: food.proteinG * factor,
    carbsG: food.carbsG * factor,
    fatG: food.fatG * factor,
    visible: i.visible,
    source: IngredientSource.db,
    matchedName: food.description,
  );
}

/// Step 3. [changed] is true when an ingredient's grams were set, so the old
/// portion no longer describes the ingredients and the sum is the new portion.
({List<EstimatedIngredient> ingredients, double? dishGrams, bool changed})
_applyCaption(
  List<EstimatedIngredient> ingredients,
  String dish,
  String caption,
) {
  final result = [...ingredients];
  final used = <int>{};
  var changed = false;
  double? dishGrams = bareCaptionWeight(caption);

  for (final stated in statedAmounts(caption)) {
    final grams = statedGrams(stated.quantity!, stated.unit);
    if (grams == null || grams <= 0) continue;
    final tokens = tokenize(stated.query);
    if (tokens.isEmpty) continue;

    var best = -1;
    var bestScore = 0.0;
    for (var i = 0; i < result.length; i++) {
      if (used.contains(i)) continue;
      final score = captionAgreement(tokens, tokenize(result[i].name));
      if (score > bestScore) {
        best = i;
        bestScore = score;
      }
    }
    if (best >= 0) {
      used.add(best);
      result[best] = result[best].scaled(grams / result[best].grams);
      changed = true;
    } else if (captionAgreement(tokens, tokenize(dish)) > 0) {
      dishGrams = grams;
    }
  }
  return (ingredients: result, dishGrams: dishGrams, changed: changed);
}
