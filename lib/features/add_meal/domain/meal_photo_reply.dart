import 'package:opennutritracker/core/utils/food_name_validator.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';

const mealPhotoToolName = 'log_meal_estimate';

const mealPhotoToolDescription =
    'Record the dish in the photo as its recipe, with the ingredients, their '
    'grams and nutrition for this portion.';

/// The instructions the photo reading is held to. One prompt for every
/// provider; the schema below is the shape of the answer.
const mealPhotoSystemPrompt = '''
You are a nutrition estimator inside a calorie tracker. You receive 1 to 3 photos of one meal and an optional caption from the user. Work like a dietitian who knows the standard recipe of every dish.
Steps:
1. Identify the dish. If the caption names it, trust the caption over the photo. If unsure, pick the most likely dish and say so in assumptions.
2. Estimate the portion as cooked/served weight in grams (portion_g), using plate size, utensils and other objects as scale. If the caption gives a weight, use it as portion_g.
3. Recall the standard recipe for this dish. List EVERY ingredient it normally needs, including things you cannot see: cooking oil or ghee, salt, sugar, sauces, tempering spices, water absorbed.
4. Scale the ingredients so their grams add up to portion_g (within 3%). Use the amounts a home cook would use for this portion.
5. Give each ingredient a generic, database-style name in USDA FoodData Central style ("Rice, white, cooked", "Oil, peanut", "Raisins, seedless"). No brand names, no free text.
6. For each ingredient give kcal, protein_g, carbs_g, fat_g for the grams listed, using standard reference values (USDA FoodData Central, per 100 g scaled to grams). Check kcal against 4*protein + 4*carbs + 9*fat and fix any mismatch above 10%.
7. totals = sum of ingredients. servings = how many standard servings of the dish this portion equals (1.0 unless clearly more or less).
8. confidence: "high" (dish and portion clear), "medium" (dish clear, portion or hidden ingredients uncertain), "low" (dish itself uncertain). Put every guess that moves the numbers by more than 10% into assumptions.
Output ONLY valid JSON matching the schema. No prose.''';

/// Most ingredients one reply may list; the schema says the same.
const mealPhotoMaxIngredients = 20;

/// Most assumptions kept.
const mealPhotoMaxAssumptions = 6;

/// Heaviest single ingredient believed, in grams. Above it the ingredient is
/// dropped (a misread, not a meal).
const mealPhotoMaxIngredientGrams = 3000.0;

const _number = {'type': 'number'};

/// The one schema every provider is held to for a photograph.
///
/// Like the other schema it is a hint, not a defence:
/// [mealPhotoEstimateFromJson] re-checks everything in Dart.
const mealPhotoToolSchema = {
  'type': 'object',
  'properties': {
    'dish': {'type': 'string', 'description': 'The dish\'s name.'},
    'portion_g': {
      'type': 'number',
      'description': 'The portion as served, in grams.',
    },
    'servings': {
      'type': 'number',
      'description': 'Standard servings of the dish in this portion.',
    },
    'ingredients': {
      'type': 'array',
      'minItems': 1,
      'maxItems': mealPhotoMaxIngredients,
      'items': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description':
                'Generic database-style name, USDA FoodData Central style.',
          },
          'grams': _number,
          'kcal': _number,
          'protein_g': _number,
          'carbs_g': _number,
          'fat_g': _number,
          'visible': {
            'type': 'boolean',
            'description': 'True when the ingredient can be seen in the photo.',
          },
        },
        'required': ['name', 'grams', 'kcal', 'protein_g', 'carbs_g', 'fat_g'],
        'additionalProperties': false,
      },
    },
    'totals': {
      'type': 'object',
      'properties': {
        'grams': _number,
        'kcal': _number,
        'protein_g': _number,
        'carbs_g': _number,
        'fat_g': _number,
      },
      'required': ['grams', 'kcal', 'protein_g', 'carbs_g', 'fat_g'],
      'additionalProperties': false,
    },
    'confidence': {
      'type': 'string',
      'enum': ['high', 'medium', 'low'],
    },
    'assumptions': {
      'type': 'array',
      'maxItems': mealPhotoMaxAssumptions,
      'items': {'type': 'string'},
    },
  },
  'required': [
    'dish',
    'portion_g',
    'servings',
    'ingredients',
    'totals',
    'confidence',
    'assumptions',
  ],
  'additionalProperties': false,
};

const mealPhotoToolSpec = MealToolSpec(
  name: mealPhotoToolName,
  description: mealPhotoToolDescription,
  schema: mealPhotoToolSchema,
  maxTokens: 3072,
);

/// The reply was not the shape the schema asks for. Distinct from
/// [MealInterpreterException] on purpose: the provider answered fine and the
/// answer is unusable.
class MealPhotoReplyException implements Exception {
  final String reason;

  const MealPhotoReplyException(this.reason);

  @override
  String toString() => 'MealPhotoReplyException($reason)';
}

/// What a reply claimed, before any of it has been checked against the others:
/// the ingredients with the model's own numbers, and the portion it stated.
class RawPhotoEstimate {
  final String dish;
  final double? portionG;
  final double servings;
  final List<EstimatedIngredient> ingredients;
  final EstimateConfidence confidence;
  final List<String> assumptions;

  /// The model's own `totals.kcal`, used only to rescue a reply whose
  /// ingredients all came back with no energy.
  final double? claimedKcal;

  const RawPhotoEstimate({
    required this.dish,
    required this.portionG,
    required this.servings,
    required this.ingredients,
    required this.confidence,
    required this.assumptions,
    required this.claimedKcal,
  });
}

/// Reads the photo tool's input strictly.
///
/// **Structure is checked hard, values softly.** A reply that is not an object,
/// has no dish name, or has no `ingredients` array, throws
/// [MealPhotoReplyException]; an empty array is read as "no food". Beyond that a
/// bad ingredient (no usable name, no grams, absurd grams) is dropped and the
/// rest kept; only when none survive is the reply refused.
RawPhotoEstimate mealPhotoEstimateFromJson(Object? input) {
  if (input is! Map) {
    throw const MealPhotoReplyException('tool input is not an object');
  }
  final rawIngredients = input['ingredients'];
  if (rawIngredients is! List) {
    throw const MealPhotoReplyException('no ingredients');
  }
  // An empty list is an answer — nothing to eat in this photo — not a failure,
  // as on the typed path. The caller shows "no food found".
  if (rawIngredients.isEmpty) {
    return const RawPhotoEstimate(
      dish: '',
      portionG: null,
      servings: 1.0,
      ingredients: [],
      confidence: EstimateConfidence.low,
      assumptions: [],
      claimedKcal: null,
    );
  }
  final dish = input['dish'];
  if (dish is! String || !FoodNameValidator.isValid(dish.trim())) {
    throw const MealPhotoReplyException('no usable dish name');
  }

  final ingredients = <EstimatedIngredient>[];
  for (final entry in rawIngredients.take(mealPhotoMaxIngredients)) {
    if (entry is! Map) {
      throw const MealPhotoReplyException('ingredient is not an object');
    }
    final ingredient = _ingredient(entry);
    if (ingredient != null) ingredients.add(ingredient);
  }
  if (ingredients.isEmpty) {
    throw const MealPhotoReplyException('no ingredient survived');
  }

  final totals = input['totals'];
  final rawAssumptions = input['assumptions'];
  final servings = _positive(input['servings']);
  return RawPhotoEstimate(
    dish: dish.trim(),
    portionG: _positive(input['portion_g']),
    servings: servings ?? 1.0,
    ingredients: ingredients,
    confidence: EstimateConfidence.parse(input['confidence']),
    assumptions: [
      if (rawAssumptions is List)
        for (final a in rawAssumptions)
          if (a is String && a.trim().isNotEmpty) a.trim(),
    ].take(mealPhotoMaxAssumptions).toList(),
    claimedKcal: totals is Map ? _positive(totals['kcal']) : null,
  );
}

EstimatedIngredient? _ingredient(Map<dynamic, dynamic> raw) {
  final name = raw['name'];
  if (name is! String) {
    throw const MealPhotoReplyException('ingredient has no name');
  }
  final grams = _positive(raw['grams']);
  final kcal = _nonNegative(raw['kcal']);
  final protein = _nonNegative(raw['protein_g']);
  final carbs = _nonNegative(raw['carbs_g']);
  final fat = _nonNegative(raw['fat_g']);
  if (grams == null ||
      kcal == null ||
      protein == null ||
      carbs == null ||
      fat == null) {
    // A number missing or not a number: this ingredient cannot be trusted, the
    // others still can.
    return null;
  }
  final trimmed = name.trim();
  if (!FoodNameValidator.isValid(trimmed)) return null;
  if (grams > mealPhotoMaxIngredientGrams) return null;
  final visible = raw['visible'];
  return EstimatedIngredient(
    name: trimmed,
    grams: grams,
    kcal: kcal,
    proteinG: protein,
    carbsG: carbs,
    fatG: fat,
    visible: visible is bool ? visible : null,
  );
}

double? _number2(Object? value) {
  final number = switch (value) {
    num n => n.toDouble(),
    String s => double.tryParse(s.replaceAll(',', '.')),
    _ => null,
  };
  return number != null && number.isFinite ? number : null;
}

double? _positive(Object? value) {
  final n = _number2(value);
  return n != null && n > 0 ? n : null;
}

double? _nonNegative(Object? value) {
  final n = _number2(value);
  return n != null && n >= 0 ? n : null;
}
