import 'package:opennutritracker/core/utils/food_name_validator.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';

const mealPhotoToolName = 'log_meal_estimate';

const mealPhotoToolDescription =
    'Record every dish in the photo as its recipe, with the ingredients, their '
    'grams and their nutrition per 100 g.';

/// The instructions the photo reading is held to. One prompt for every
/// provider; the schema below is the shape of the answer.
///
/// The amount rules in step 4 are checked again in code
/// (`photo_estimate_processor.dart`), which adds an assumption line whenever it
/// has to act on one. The prompt states them so the model gets them right the
/// first time; the code is what makes them true.
const mealPhotoSystemPrompt = '''
You are a nutrition estimator inside a calorie tracker. You receive 1 to 3 photos of one meal and an optional caption from the user. Work like a dietitian who knows the standard recipe of every dish.
Steps:
1. List every distinct dish on the plate as its own entry in dishes (1 to 6). Rice, bread, raita, salad, a second curry, a drink and a dessert are separate dishes. Never merge a side into a main dish. If the caption names dishes, trust the caption over the photo. If unsure what a dish is, pick the most likely one and say so in its assumptions.
2. For each dish, recall its standard recipe and list EVERY ingredient it normally needs, including what you cannot see: cooking oil or ghee, salt, sugar, sauces, tempering spices, and the liquid base of a soup or curry (stock, water, coconut milk).
3. Give each ingredient its grams in this portion, as a home cook would use them. portion_g is the sum of the dish's ingredient grams: do not stretch or shrink ingredients to reach a portion. Use plate size, utensils and other objects as scale. If the caption gives a weight, use it.
4. Amount rules:
   - Added fat (oil, ghee, butter) is at most 8% of the dish's grams, unless the dish is deep-fried.
   - When the dish name names a protein (chicken, mutton, lamb, fish, prawn, egg, paneer, tofu, beef, pork), that ingredient is at least 20% of the dish's grams.
   - Each spice or herb is 0.5 to 3 g. Salt is 0.5 to 2 g.
5. Name each ingredient generically, in USDA FoodData Central style ("Rice, white, cooked", "Oil, coconut", "Coriander leaves, raw"). No brand names, no Latin names, no free text.
6. For each ingredient give per100g: kcal, protein_g, carbs_g, fat_g in 100 g of that ingredient as listed, from standard reference values (USDA FoodData Central). kcal must agree with 4*protein_g + 4*carbs_g + 9*fat_g. Oils, ghee and butter are 700 to 900 kcal per 100 g. Give no totals: the app multiplies.
7. servings = how many standard servings of the dish this portion is (1.0 unless clearly more or less). confidence: "high" (dish and portion clear), "medium" (dish clear, portion or hidden ingredients uncertain), "low" (dish itself uncertain). Up to 4 assumptions per dish: every guess that moves its numbers by more than 10%.
Output ONLY valid JSON matching the schema. No prose.''';

/// Most dishes one reply may list; the schema says the same.
const mealPhotoMaxDishes = 6;

/// Most ingredients one dish may list; the schema says the same.
const mealPhotoMaxIngredients = 20;

/// Most assumptions kept from the model, per dish. Lines the code adds come
/// on top.
const mealPhotoMaxAssumptions = 4;

/// Heaviest single ingredient believed, in grams. Above it the ingredient is
/// dropped (a misread, not a meal).
const mealPhotoMaxIngredientGrams = 3000.0;

const _number = {'type': 'number'};

const _per100gSchema = {
  'type': 'object',
  'description': 'Nutrition in 100 g of the ingredient as listed.',
  'properties': {
    'kcal': _number,
    'protein_g': _number,
    'carbs_g': _number,
    'fat_g': _number,
  },
  'required': ['kcal', 'protein_g', 'carbs_g', 'fat_g'],
  'additionalProperties': false,
};

/// The one schema every provider is held to for a photograph.
///
/// Like the other schema it is a hint, not a defence:
/// [mealPhotoEstimateFromJson] re-checks everything in Dart.
const mealPhotoToolSchema = {
  'type': 'object',
  'properties': {
    'dishes': {
      'type': 'array',
      'minItems': 1,
      'maxItems': mealPhotoMaxDishes,
      'items': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'The dish\'s name.'},
          'portion_g': {
            'type': 'number',
            'description': 'The sum of the ingredient grams.',
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
                      'Generic database-style name, USDA FoodData Central '
                      'style.',
                },
                'grams': _number,
                'per100g': _per100gSchema,
                'visible': {
                  'type': 'boolean',
                  'description':
                      'True when the ingredient can be seen in the photo.',
                },
              },
              'required': ['name', 'grams', 'per100g'],
              'additionalProperties': false,
            },
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
          'name',
          'portion_g',
          'servings',
          'ingredients',
          'confidence',
          'assumptions',
        ],
        'additionalProperties': false,
      },
    },
  },
  'required': ['dishes'],
  'additionalProperties': false,
};

const mealPhotoToolSpec = MealToolSpec(
  name: mealPhotoToolName,
  description: mealPhotoToolDescription,
  schema: mealPhotoToolSchema,
  // Six dishes of up to twenty ingredients each, every one with four numbers.
  maxTokens: 6144,
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

/// One ingredient as the reply stated it, before any check.
class RawIngredient {
  final String name;
  final double grams;

  /// The model's numbers per 100 g, or null when it gave none that can be
  /// read. Unchecked beyond being finite and not negative.
  final Per100g? per100g;
  final bool? visible;

  const RawIngredient({
    required this.name,
    required this.grams,
    required this.per100g,
    this.visible,
  });
}

/// One dish as the reply stated it.
class RawDish {
  final String name;

  /// The portion the model stated. Kept only to report; the portion used is
  /// the sum of the ingredients.
  final double? portionG;
  final double servings;
  final List<RawIngredient> ingredients;
  final EstimateConfidence confidence;
  final List<String> assumptions;

  const RawDish({
    required this.name,
    required this.portionG,
    required this.servings,
    required this.ingredients,
    required this.confidence,
    required this.assumptions,
  });
}

/// What a reply claimed: every dish, with the model's own numbers.
class RawPhotoEstimate {
  final List<RawDish> dishes;

  const RawPhotoEstimate(this.dishes);

  static const empty = RawPhotoEstimate([]);
}

/// Reads the photo tool's input strictly.
///
/// **Structure is checked hard, values softly.** A reply that is not an object
/// or has no `dishes` array throws [MealPhotoReplyException]; an empty array is
/// read as "no food". Beyond that a bad dish (no usable name, no ingredients
/// that survive) or a bad ingredient (no usable name, no grams, absurd grams)
/// is dropped and the rest kept; only when no dish survives is the reply
/// refused.
///
/// A reply in the earlier one-dish shape (`dish` and `ingredients` at the top,
/// numbers for the grams rather than per 100 g) is read as one dish, so a
/// model that ignores the new schema still lands.
RawPhotoEstimate mealPhotoEstimateFromJson(Object? input) {
  if (input is! Map) {
    throw const MealPhotoReplyException('tool input is not an object');
  }
  var rawDishes = input['dishes'];
  if (rawDishes == null && input['ingredients'] is List) {
    rawDishes = [
      {...input, 'name': input['name'] ?? input['dish']},
    ];
  }
  if (rawDishes is! List) {
    throw const MealPhotoReplyException('no dishes');
  }
  // An empty list is an answer — nothing to eat in this photo — not a failure,
  // as on the typed path. The caller shows "no food found". So is a list whose
  // every dish lists no ingredients at all.
  if (rawDishes.every(
    (d) =>
        d is Map &&
        d['ingredients'] is List &&
        (d['ingredients'] as List).isEmpty,
  )) {
    return RawPhotoEstimate.empty;
  }

  final dishes = <RawDish>[];
  for (final entry in rawDishes.take(mealPhotoMaxDishes)) {
    if (entry is! Map) {
      throw const MealPhotoReplyException('dish is not an object');
    }
    final dish = _dish(entry);
    if (dish != null) dishes.add(dish);
  }
  if (dishes.isEmpty) {
    throw const MealPhotoReplyException('no dish survived');
  }
  return RawPhotoEstimate(dishes);
}

RawDish? _dish(Map<dynamic, dynamic> raw) {
  final name = raw['name'];
  if (name is! String || !FoodNameValidator.isValid(name.trim())) return null;
  final rawIngredients = raw['ingredients'];
  if (rawIngredients is! List) return null;
  final ingredients = [
    for (final entry in rawIngredients.take(mealPhotoMaxIngredients))
      if (entry is Map) _ingredient(entry),
  ].nonNulls.toList();
  if (ingredients.isEmpty) return null;

  final rawAssumptions = raw['assumptions'];
  return RawDish(
    name: name.trim(),
    portionG: _positive(raw['portion_g']),
    servings: _positive(raw['servings']) ?? 1.0,
    ingredients: ingredients,
    confidence: EstimateConfidence.parse(raw['confidence']),
    assumptions: [
      if (rawAssumptions is List)
        for (final a in rawAssumptions)
          if (a is String && a.trim().isNotEmpty) a.trim(),
    ].take(mealPhotoMaxAssumptions).toList(),
  );
}

RawIngredient? _ingredient(Map<dynamic, dynamic> raw) {
  final name = raw['name'];
  if (name is! String) return null;
  final trimmed = name.trim();
  if (!FoodNameValidator.isValid(trimmed)) return null;
  final grams = _positive(raw['grams']);
  if (grams == null || grams > mealPhotoMaxIngredientGrams) return null;
  final visible = raw['visible'];
  return RawIngredient(
    name: trimmed,
    grams: grams,
    per100g: _per100g(raw['per100g']) ?? _legacyPer100g(raw, grams),
    visible: visible is bool ? visible : null,
  );
}

Per100g? _per100g(Object? raw) {
  if (raw is! Map) return null;
  final kcal = _nonNegative(raw['kcal']);
  final protein = _nonNegative(raw['protein_g']);
  final carbs = _nonNegative(raw['carbs_g']);
  final fat = _nonNegative(raw['fat_g']);
  if (kcal == null || protein == null || carbs == null || fat == null) {
    return null;
  }
  return Per100g(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat);
}

/// The earlier shape: numbers for [grams], turned into numbers per 100 g.
Per100g? _legacyPer100g(Map<dynamic, dynamic> raw, double grams) {
  final forGrams = _per100g(raw);
  if (forGrams == null) return null;
  final factor = 100 / grams;
  return Per100g(
    kcal: forGrams.kcal * factor,
    proteinG: forGrams.proteinG * factor,
    carbsG: forGrams.carbsG * factor,
    fatG: forGrams.fatG * factor,
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
