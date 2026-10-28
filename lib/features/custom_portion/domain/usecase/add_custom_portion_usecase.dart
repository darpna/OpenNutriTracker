import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/custom_portion/domain/entity/custom_portion_entity.dart';
import 'package:opennutritracker/features/custom_portion/domain/repository/custom_portion_repository.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/custom_portion_validator.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/get_custom_portions_usecase.dart';

/// `ml` for a food measured only in millilitres, `g` for everything else —
/// the same split the unit dropdown makes between its solid and liquid rows.
String customPortionUnitFor(MealEntity meal) =>
    meal.isLiquid && !meal.isSolid ? 'ml' : 'g';

class AddCustomPortionUsecase {
  final CustomPortionRepository _repository;

  AddCustomPortionUsecase(this._repository);

  /// Saves "[label] = [gramWeight]" for [meal].
  ///
  /// Throws an [ArgumentError] for a name or weight the dialog would have
  /// refused, so a caller that skipped the dialog cannot store a serving that
  /// multiplies to nothing.
  Future<CustomPortionEntity> addCustomPortion(
    MealEntity meal, {
    required String label,
    required double gramWeight,
  }) {
    final error =
        validateCustomPortionName(label) ??
        validateCustomPortionWeight(gramWeight);
    if (error != null) throw ArgumentError('Invalid custom portion: $error');
    return _repository.add(
      foodKey: customPortionFoodKey(meal),
      label: label,
      gramWeight: gramWeight,
      unit: customPortionUnitFor(meal),
    );
  }
}
