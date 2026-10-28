import 'package:equatable/equatable.dart';

/// A model's own per-100 g guess at a food's macros.
///
/// **Only ever a fallback.** The resolver consults it when the food database
/// has nothing good enough for a component (see `ResolveParsedMealsUseCase`);
/// it never overrides a database match that clears the confidence threshold.
/// The row built from it is labelled "AI estimate" so nobody mistakes it for a
/// cited number.
///
/// Built through [tryParse] only, which refuses figures that cannot describe
/// 100 g of any food: a model that answers 2000 kcal or 120 g of fat loses the
/// estimate rather than writing it to the diary.
class AiPer100Estimate extends Equatable {
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;

  const AiPer100Estimate({
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  /// Pure fat is about 900 kcal per 100 g; nothing edible is denser.
  static const maxKcalPer100 = 900.0;

  /// Macros are grams within 100 g, so each is bounded by 100 and together by
  /// 100 as well. A little slack covers rounding in the model's answer.
  static const maxMacroSumG = 101.0;

  /// How far the stated energy may sit from what 4/4/9 kcal per gram of
  /// protein/carbs/fat gives before the figures are called inconsistent.
  /// Wide on purpose: fibre, polyols and alcohol all move it, and this only has
  /// to catch answers that cannot be right, like 600 kcal from 2 g of fat.
  static const _energySlackKcal = 50.0;
  static const _energySlackRatio = 0.4;

  /// [raw] is the `per_100g` object of one component, or null when the figures
  /// are absent or implausible.
  static AiPer100Estimate? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kcal = _number(raw['kcal']);
    final protein = _number(raw['protein_g']);
    final carbs = _number(raw['carbs_g']);
    final fat = _number(raw['fat_g']);
    if (kcal == null || protein == null || carbs == null || fat == null) {
      return null;
    }
    if (kcal < 0 || kcal > maxKcalPer100) return null;
    for (final macro in [protein, carbs, fat]) {
      if (macro < 0 || macro > 100) return null;
    }
    if (protein + carbs + fat > maxMacroSumG) return null;

    final fromMacros = 4 * protein + 4 * carbs + 9 * fat;
    final slack = _energySlackKcal + _energySlackRatio * fromMacros;
    if ((kcal - fromMacros).abs() > slack) return null;

    return AiPer100Estimate(
      kcal: kcal,
      proteinG: protein,
      carbsG: carbs,
      fatG: fat,
    );
  }

  static double? _number(Object? value) {
    final number = switch (value) {
      num n => n.toDouble(),
      String s => double.tryParse(s.replaceAll(',', '.')),
      _ => null,
    };
    return number != null && number.isFinite ? number : null;
  }

  @override
  List<Object?> get props => [kcal, proteinG, carbsG, fatG];
}
