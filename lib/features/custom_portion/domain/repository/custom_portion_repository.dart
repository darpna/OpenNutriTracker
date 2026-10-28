import 'package:opennutritracker/core/data/dbo/custom_portion_dbo.dart';
import 'package:opennutritracker/features/custom_portion/domain/entity/custom_portion_entity.dart';

/// The user's own servings, shared by every profile like the custom-meal and
/// recipe libraries they belong to.
abstract interface class CustomPortionRepository {
  /// Every serving saved for the food under [foodKey], oldest first.
  Future<List<CustomPortionEntity>> getForFood(String foodKey);

  /// Saves a serving for [foodKey]. A serving of the same name on that food
  /// (ignoring case and surrounding space) is updated in place rather than
  /// listed twice.
  Future<CustomPortionEntity> add({
    required String foodKey,
    required String label,
    required double gramWeight,
    required String unit,
  });

  Future<void> delete(String id);

  /// Every serving, for the JSON export.
  Future<List<CustomPortionDBO>> getAllDBOs();

  /// Upserts by id, for the JSON import. Rows that cannot scale an amount
  /// (blank name or food, a weight that is not a positive number) are
  /// skipped instead of being stored.
  Future<void> upsertAllDBOs(List<CustomPortionDBO> portions);
}
