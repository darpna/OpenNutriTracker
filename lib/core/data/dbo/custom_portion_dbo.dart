import 'package:hive_ce/hive.dart';
import 'package:json_annotation/json_annotation.dart';

part 'custom_portion_dbo.g.dart';

/// A serving the user named for one food — "1 bowl = 250 g" — kept so every
/// later visit to that food offers it beside the portions the database has.
///
/// [foodKey] is `FavouriteMealDBO.keyFor` of the food (its source plus its
/// code, or its name when it has none), the identity the Favourites list and
/// the search de-duplication already use. [gramWeight] is what one serving
/// weighs in [unit], `g` or `ml` — the base unit of the food it belongs to.
///
/// Stored under [id], so one food can carry any number of servings.
@HiveType(typeId: 24)
@JsonSerializable()
class CustomPortionDBO extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String foodKey;

  @HiveField(2)
  final String label;

  @HiveField(3)
  final double gramWeight;

  @HiveField(4)
  @JsonKey(defaultValue: 'g')
  final String unit;

  @HiveField(5)
  final DateTime createdAt;

  CustomPortionDBO({
    required this.id,
    required this.foodKey,
    required this.label,
    required this.gramWeight,
    this.unit = 'g',
    required this.createdAt,
  });

  factory CustomPortionDBO.fromJson(Map<String, dynamic> json) =>
      _$CustomPortionDBOFromJson(json);

  Map<String, dynamic> toJson() => _$CustomPortionDBOToJson(this);
}
