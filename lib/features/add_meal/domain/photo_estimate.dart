import 'package:equatable/equatable.dart';

/// How sure the model said it was of the dish and the portion.
enum EstimateConfidence {
  high,
  medium,
  low;

  static EstimateConfidence parse(Object? raw) {
    if (raw is String) {
      for (final value in values) {
        if (value.name == raw.trim().toLowerCase()) return value;
      }
    }
    // Not stated, or not one of the three: the middle, which asserts least.
    return EstimateConfidence.medium;
  }
}

/// Where an ingredient's per-100 g numbers come from. `db` is the bundled
/// generic food table (USDA); `cache` is the value this device settled on the
/// first time it saw a food of that name; `ai` is the model's own, checked.
enum IngredientSource { db, ai, cache }

/// Energy and macros in 100 g of a food.
class Per100g extends Equatable {
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;

  const Per100g({
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  static const zero = Per100g(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0);

  /// What 4 kcal per gram of protein and carbohydrate and 9 of fat give.
  double get kcalFromMacros => 4 * proteinG + 4 * carbsG + 9 * fatG;

  List<double> toList() => [kcal, proteinG, carbsG, fatG];

  /// The inverse of [toList], or null for anything that is not four numbers.
  static Per100g? fromList(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final values = [
      for (final v in raw)
        if (v is num && v.isFinite) v.toDouble(),
    ];
    if (values.length != 4) return null;
    return Per100g(
      kcal: values[0],
      proteinG: values[1],
      carbsG: values[2],
      fatG: values[3],
    );
  }

  @override
  List<Object?> get props => [kcal, proteinG, carbsG, fatG];
}

/// Sums over an estimate's ingredients.
class EstimateTotals extends Equatable {
  final double grams;
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;

  const EstimateTotals({
    required this.grams,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  static const zero = EstimateTotals(
    grams: 0,
    kcal: 0,
    proteinG: 0,
    carbsG: 0,
    fatG: 0,
  );

  EstimateTotals operator +(EstimateTotals other) => EstimateTotals(
    grams: grams + other.grams,
    kcal: kcal + other.kcal,
    proteinG: proteinG + other.proteinG,
    carbsG: carbsG + other.carbsG,
    fatG: fatG + other.fatG,
  );

  @override
  List<Object?> get props => [grams, kcal, proteinG, carbsG, fatG];
}

/// One ingredient of a dish: its grams and its numbers per 100 g. The numbers
/// for the grams listed are always the product of the two, so changing the
/// grams can never leave the energy behind.
class EstimatedIngredient extends Equatable {
  /// A generic, database-style name: "Rice, white, cooked".
  final String name;
  final double grams;
  final Per100g per100g;

  /// Whether the model could see it, as opposed to inferring it (cooking oil,
  /// salt). Null when it did not say.
  final bool? visible;
  final IngredientSource source;

  /// The table entry the numbers came from, when [source] is `db` (or a cache
  /// entry that a table match wrote).
  final String? matchedName;

  const EstimatedIngredient({
    required this.name,
    required this.grams,
    required this.per100g,
    this.visible,
    this.source = IngredientSource.ai,
    this.matchedName,
  });

  double get kcal => per100g.kcal * grams / 100;
  double get proteinG => per100g.proteinG * grams / 100;
  double get carbsG => per100g.carbsG * grams / 100;
  double get fatG => per100g.fatG * grams / 100;

  /// The same ingredient at [factor] times the amount.
  EstimatedIngredient scaled(double factor) => withGrams(grams * factor);

  EstimatedIngredient withGrams(double grams) => EstimatedIngredient(
    name: name,
    grams: grams,
    per100g: per100g,
    visible: visible,
    source: source,
    matchedName: matchedName,
  );

  @override
  List<Object?> get props => [
    name,
    grams,
    per100g,
    visible,
    source,
    matchedName,
  ];
}

/// One dish on the plate, read as its recipe: the ingredients the model
/// recalled, at the grams for the portion in front of the user.
///
/// Totals are always the sum of [ingredients]; the model's own totals are
/// never kept, and neither is a portion it stated apart from them.
class PhotoRecipeEstimate extends Equatable {
  final String dish;

  /// How many standard servings of the dish this portion is.
  final double servings;
  final List<EstimatedIngredient> ingredients;
  final EstimateConfidence confidence;

  /// Guesses that move the numbers, in the model's words, followed by a line
  /// for every check in code that changed something.
  final List<String> assumptions;

  /// The same ingredients (same grams) with only the model's per-100 g numbers
  /// after the sanity checks, before the table or the cache was consulted.
  /// What the replay reports beside the grounded totals.
  final EstimateTotals aiOnly;

  const PhotoRecipeEstimate({
    required this.dish,
    required this.servings,
    required this.ingredients,
    required this.confidence,
    required this.assumptions,
    required this.aiOnly,
  });

  /// The portion as served, in grams: the sum of the ingredients.
  double get portionG => totals.grams;

  EstimateTotals get totals => sumOf(ingredients);

  PhotoRecipeEstimate withAssumption(String line) => PhotoRecipeEstimate(
    dish: dish,
    servings: servings,
    ingredients: ingredients,
    confidence: confidence,
    assumptions: [...assumptions, line],
    aiOnly: aiOnly,
  );

  static EstimateTotals sumOf(Iterable<EstimatedIngredient> ingredients) {
    var grams = 0.0, kcal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0;
    for (final i in ingredients) {
      grams += i.grams;
      kcal += i.kcal;
      protein += i.proteinG;
      carbs += i.carbsG;
      fat += i.fatG;
    }
    return EstimateTotals(
      grams: grams,
      kcal: kcal,
      proteinG: protein,
      carbsG: carbs,
      fatG: fat,
    );
  }

  @override
  List<Object?> get props => [
    dish,
    servings,
    ingredients,
    confidence,
    assumptions,
    aiOnly,
  ];
}

/// What one photo (or set of photos of one meal) was read as: every distinct
/// dish and side on the plate, each its own recipe.
class PhotoMealEstimate extends Equatable {
  final List<PhotoRecipeEstimate> dishes;

  /// The model that answered, when the caller knows it. Set by the use case,
  /// which is the layer that knows which configuration it sent to.
  final String? model;

  const PhotoMealEstimate({required this.dishes, this.model});

  EstimateTotals get totals =>
      dishes.fold(EstimateTotals.zero, (sum, d) => sum + d.totals);

  EstimateTotals get aiOnly =>
      dishes.fold(EstimateTotals.zero, (sum, d) => sum + d.aiOnly);

  PhotoMealEstimate withModel(String? model) =>
      PhotoMealEstimate(dishes: dishes, model: model);

  /// Every dish with [line] added to its assumptions.
  PhotoMealEstimate withAssumption(String line) => PhotoMealEstimate(
    dishes: [for (final d in dishes) d.withAssumption(line)],
    model: model,
  );

  @override
  List<Object?> get props => [dishes, model];
}
