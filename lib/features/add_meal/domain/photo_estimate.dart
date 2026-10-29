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

/// Where an ingredient's numbers come from. `db` is the bundled generic food
/// table (USDA, per 100 g, scaled to the grams); `ai` is the model's own.
enum IngredientSource { db, ai }

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

  @override
  List<Object?> get props => [grams, kcal, proteinG, carbsG, fatG];
}

/// One ingredient of the dish, with the numbers for the grams listed (not per
/// 100 g).
class EstimatedIngredient extends Equatable {
  /// A generic, database-style name: "Rice, white, cooked".
  final String name;
  final double grams;
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;

  /// Whether the model could see it, as opposed to inferring it (cooking oil,
  /// salt). Null when it did not say.
  final bool? visible;
  final IngredientSource source;

  /// The table entry the numbers came from, when [source] is `db`.
  final String? matchedName;

  const EstimatedIngredient({
    required this.name,
    required this.grams,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    this.visible,
    this.source = IngredientSource.ai,
    this.matchedName,
  });

  /// The same ingredient at [factor] times the amount, numbers and all.
  EstimatedIngredient scaled(double factor) => EstimatedIngredient(
    name: name,
    grams: grams * factor,
    kcal: kcal * factor,
    proteinG: proteinG * factor,
    carbsG: carbsG * factor,
    fatG: fatG * factor,
    visible: visible,
    source: source,
    matchedName: matchedName,
  );

  EstimatedIngredient copyWith({
    double? kcal,
    double? proteinG,
    double? carbsG,
    double? fatG,
    IngredientSource? source,
    String? matchedName,
  }) => EstimatedIngredient(
    name: name,
    grams: grams,
    kcal: kcal ?? this.kcal,
    proteinG: proteinG ?? this.proteinG,
    carbsG: carbsG ?? this.carbsG,
    fatG: fatG ?? this.fatG,
    visible: visible,
    source: source ?? this.source,
    matchedName: matchedName ?? this.matchedName,
  );

  @override
  List<Object?> get props => [
    name,
    grams,
    kcal,
    proteinG,
    carbsG,
    fatG,
    visible,
    source,
    matchedName,
  ];
}

/// What a photo was read as: a dish, the recipe the model recalled for it, and
/// the numbers for the portion in front of the user.
///
/// Totals are always the sum of [ingredients]; the model's own totals are
/// never kept.
class PhotoRecipeEstimate extends Equatable {
  final String dish;

  /// The portion as served, in grams. The ingredients add up to it.
  final double portionG;

  /// How many standard servings of the dish this portion is.
  final double servings;
  final List<EstimatedIngredient> ingredients;
  final EstimateConfidence confidence;

  /// Guesses that move the numbers, in the model's words.
  final List<String> assumptions;

  /// The same ingredients with only the model's numbers, before the generic
  /// table was consulted. What the replay reports beside the grounded totals.
  final EstimateTotals aiOnly;

  const PhotoRecipeEstimate({
    required this.dish,
    required this.portionG,
    required this.servings,
    required this.ingredients,
    required this.confidence,
    required this.assumptions,
    required this.aiOnly,
  });

  EstimateTotals get totals => sumOf(ingredients);

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
    portionG,
    servings,
    ingredients,
    confidence,
    assumptions,
    aiOnly,
  ];
}
