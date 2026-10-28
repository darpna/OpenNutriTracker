import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/data/dbo/recipe_dbo.dart';
import 'package:opennutritracker/core/data/repository/recipe_repository.dart';
import 'package:opennutritracker/core/domain/entity/recipe_entity.dart';
import 'package:opennutritracker/core/domain/entity/recipe_ingredient_entity.dart';
import 'package:opennutritracker/core/domain/usecase/compute_recipe_nutrition_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/save_recipe_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/save_photo_dish_usecase.dart';

class _MemoryRecipes implements RecipeRepository {
  final saved = <String, RecipeEntity>{};
  bool failOnSave = false;

  @override
  Future<void> saveRecipe(RecipeEntity recipe) async {
    if (failOnSave) throw StateError('disk full');
    saved[recipe.id] = recipe;
  }

  @override
  List<RecipeEntity> getAllRecipes() => saved.values.toList();

  @override
  RecipeEntity? getRecipeById(String id) => saved[id];

  @override
  Future<void> deleteRecipe(String id) async => saved.remove(id);

  @override
  List<RecipeDBO> getAllRecipesDBO() => throw UnimplementedError();

  @override
  Future<void> addAllRecipeDBOs(List<RecipeDBO> recipes) =>
      throw UnimplementedError();
}

RecipeIngredientEntity _ingredient(
  String name,
  double grams, {
  required double kcal,
  required double protein,
  required double carbs,
  required double fat,
}) => RecipeIngredientEntity(
  snapshotMeal: MealEntity(
    code: name,
    name: name,
    url: null,
    mealQuantity: '100',
    mealUnit: 'g',
    servingQuantity: null,
    servingUnit: null,
    servingSize: null,
    nutriments: MealNutrimentsEntity(
      energyKcal100: kcal,
      carbohydrates100: carbs,
      fat100: fat,
      proteins100: protein,
      sugars100: null,
      saturatedFat100: null,
      fiber100: null,
    ),
    source: MealSourceEntity.custom,
  ),
  amount: grams,
  unit: 'g',
  convertedAmountG: grams,
);

final _tortilla = _ingredient(
  'Tortilla',
  70,
  kcal: 300,
  protein: 8,
  carbs: 50,
  fat: 7,
);
final _chicken = _ingredient(
  'Breaded fried chicken',
  120,
  kcal: 260,
  protein: 18,
  carbs: 14,
  fat: 15,
);

void main() {
  late _MemoryRecipes repository;
  late SavePhotoDishUseCase useCase;

  setUp(() {
    repository = _MemoryRecipes();
    final compute = ComputeRecipeNutritionUseCase();
    useCase = SavePhotoDishUseCase(
      repository,
      SaveRecipeUseCase(repository, compute),
      compute,
    );
  });

  test('a dish becomes a recipe with its components as ingredients', () async {
    final recipe = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla, _chicken],
    );

    expect(repository.saved, hasLength(1));
    final stored = repository.saved[recipe.id]!;
    expect(stored.name, 'Katsu chicken wrap');
    expect(stored.ingredients.map((i) => i.snapshotMeal.name), [
      'Tortilla',
      'Breaded fried chicken',
    ]);
    expect(stored.tags, contains(photoDishRecipeTag));
    expect(stored.servingsCount, 1);
  });

  test('its numbers are the components\' numbers, weighted by grams', () async {
    final recipe = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla, _chicken],
    );

    expect(recipe.totalWeightG, 190);
    // (300 * 0.7 + 260 * 1.2) / 1.9 per 100 g.
    final kcal = recipe.aggregatedNutrimentsPer100.energyKcal100!;
    expect(kcal, closeTo((300 * 70 + 260 * 120) / 190, 1e-9));
    // And what is logged from it: 190 g of it.
    final logged = recipe.toMealEntity();
    expect(logged.source, MealSourceEntity.recipe);
    expect(logged.code, recipe.id);
    expect(
      190 * logged.nutriments.energyKcal100! / 100,
      closeTo(300 * 0.7 + 260 * 1.2, 1e-9),
    );
    // One serving is the whole dish, so the next log defaults to it.
    expect(logged.servingQuantity, 190);
  });

  test('logging the same dish again updates it instead of adding a copy', () async {
    final first = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla, _chicken],
    );
    final lighter = _ingredient(
      'Breaded fried chicken',
      60,
      kcal: 260,
      protein: 18,
      carbs: 14,
      fat: 15,
    );

    final second = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla, lighter],
    );

    expect(repository.saved, hasLength(1));
    expect(second.id, first.id);
    expect(second.createdAt, first.createdAt);
    expect(second.totalWeightG, 130);
    expect(repository.saved[first.id]!.totalWeightG, 130);
  });

  test('the same name in another case or with spaces is the same dish', () async {
    final first = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla],
    );
    final second = await useCase.save(
      name: '  katsu CHICKEN wrap ',
      ingredients: [_tortilla, _chicken],
    );

    expect(second.id, first.id);
    expect(repository.saved, hasLength(1));
  });

  test('a different dish is a different recipe', () async {
    await useCase.save(name: 'Katsu chicken wrap', ingredients: [_tortilla]);
    await useCase.save(name: 'Chicken tikka wrap', ingredients: [_tortilla]);

    expect(repository.saved, hasLength(2));
  });

  test('a recipe the user wrote by hand under that name is left alone', () async {
    final mine = RecipeEntity(
      id: 'mine',
      name: 'Katsu chicken wrap',
      description: 'my own',
      ingredients: [_tortilla],
      totalWeightG: 70,
      aggregatedNutrimentsPer100: _tortilla.snapshotMeal.nutriments,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      servingsCount: 4,
    );
    await repository.saveRecipe(mine);

    final saved = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla, _chicken],
    );

    expect(saved.id, isNot('mine'));
    expect(repository.saved, hasLength(2));
    expect(repository.saved['mine']!.description, 'my own');
    expect(repository.saved['mine']!.ingredients, hasLength(1));
  });

  test('a storage failure still hands back a recipe that can be logged', () async {
    repository.failOnSave = true;

    final recipe = await useCase.save(
      name: 'Katsu chicken wrap',
      ingredients: [_tortilla, _chicken],
    );

    expect(repository.saved, isEmpty);
    expect(recipe.totalWeightG, 190);
    expect(recipe.aggregatedNutrimentsPer100.energyKcal100, greaterThan(0));
  });
}
