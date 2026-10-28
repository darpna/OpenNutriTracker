import 'package:equatable/equatable.dart';
import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_portion_entity.dart';

/// A serving the user defined for one food, as the UI and blocs see it.
class CustomPortionEntity extends Equatable {
  const CustomPortionEntity({
    required this.id,
    required this.foodKey,
    required this.label,
    required this.gramWeight,
    required this.unit,
    required this.createdAt,
  });

  final String id;

  /// `FavouriteMealDBO.keyFor` of the food this serving belongs to.
  final String foodKey;

  /// As the user typed it — "1 bowl".
  final String label;

  /// What one serving weighs, in [unit].
  final double gramWeight;

  /// `g` or `ml`, following the food.
  final String unit;

  final DateTime createdAt;

  factory CustomPortionEntity.fromDBO(CustomPortionDBO dbo) =>
      CustomPortionEntity(
        id: dbo.id,
        foodKey: dbo.foodKey,
        label: dbo.label,
        gramWeight: dbo.gramWeight,
        unit: dbo.unit,
        createdAt: dbo.createdAt,
      );

  CustomPortionDBO toDBO() => CustomPortionDBO(
    id: id,
    foodKey: foodKey,
    label: label,
    gramWeight: gramWeight,
    unit: unit,
    createdAt: createdAt,
  );

  /// The entry this serving takes in a food's portion list.
  MealPortionEntity toPortion() => MealPortionEntity(
    label: label,
    gramWeight: gramWeight,
    localized: true,
    customPortionId: id,
  );

  @override
  List<Object?> get props => [id, foodKey, label, gramWeight, unit, createdAt];
}
