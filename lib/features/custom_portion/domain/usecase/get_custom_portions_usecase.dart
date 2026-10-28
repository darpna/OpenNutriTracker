import 'package:opennutritracker/core/data/repository/favourite_meal_repository.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/custom_portion/domain/entity/custom_portion_entity.dart';
import 'package:opennutritracker/features/custom_portion/domain/repository/custom_portion_repository.dart';

/// The key a food's custom servings are stored under: the one Favourites and
/// the search de-duplication use (source plus code, or name without a code).
String customPortionFoodKey(MealEntity meal) =>
    FavouriteMealRepository.keyOf(meal);

class GetCustomPortionsUsecase {
  final CustomPortionRepository _repository;

  GetCustomPortionsUsecase(this._repository);

  Future<List<CustomPortionEntity>> getCustomPortions(MealEntity meal) =>
      _repository.getForFood(customPortionFoodKey(meal));
}
