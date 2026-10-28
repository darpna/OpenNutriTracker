import 'package:logging/logging.dart';
import 'package:opennutritracker/core/data/repository/recipe_repository.dart';
import 'package:opennutritracker/core/domain/entity/recipe_entity.dart';
import 'package:opennutritracker/core/domain/entity/recipe_ingredient_entity.dart';
import 'package:opennutritracker/core/domain/usecase/compute_recipe_nutrition_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/save_recipe_usecase.dart';
import 'package:opennutritracker/core/utils/id_generator.dart';

/// Tags the recipes this flow writes, so a later photo of the same dish updates
/// its own recipe and never overwrites one the user wrote by hand under the
/// same name.
const photoDishRecipeTag = 'ai-photo';

/// Stores a confirmed photo dish as a recipe — the entity the app already uses
/// for a composed food — so the next time it is a real entry: a search hit,
/// star-able as a favourite, loggable by serving.
///
/// One recipe per dish name. The same name (ignoring case and surrounding
/// space) from this flow updates the existing recipe in place — new
/// ingredients, new numbers, same id and creation date — rather than adding a
/// second copy. Past diary entries snapshot their meal, so an update changes
/// only what is logged from now on.
class SavePhotoDishUseCase {
  static final _log = Logger('SavePhotoDishUseCase');

  final RecipeRepository _repository;
  final SaveRecipeUseCase _saveRecipe;
  final ComputeRecipeNutritionUseCase _compute;

  SavePhotoDishUseCase(this._repository, this._saveRecipe, this._compute);

  /// The recipe for [name] built from [ingredients], saved. Whole grams per
  /// ingredient: the plate was confirmed in grams, and a recipe edited later
  /// re-reads those instead of a portion name that could mean something else.
  ///
  /// Never throws for a storage failure: the dish is still going to be
  /// logged, and losing the diary entry over the "remember it" step would be
  /// the worse outcome. On failure the unsaved recipe is returned, so the
  /// caller can log it all the same.
  Future<RecipeEntity> save({
    required String name,
    required List<RecipeIngredientEntity> ingredients,
  }) async {
    final trimmed = name.trim();
    final now = DateTime.now();
    RecipeEntity? existing;
    try {
      existing = _existing(trimmed);
    } catch (e, st) {
      _log.warning('Could not look for an existing photo dish', e, st);
    }

    // Computed here as well as inside the save, so the recipe handed back after
    // a failed write still carries the right weight and numbers to log.
    final computed = _compute.compute(ingredients);
    final base = existing != null
        ? existing.copyWith(ingredients: ingredients, updatedAt: now)
        : RecipeEntity(
            id: IdGenerator.getUniqueID(),
            name: trimmed,
            description: null,
            ingredients: ingredients,
            totalWeightG: 0,
            aggregatedNutrimentsPer100: computed.perHundredG,
            createdAt: now,
            updatedAt: now,
            // The whole dish is one serving, so the next log defaults to what
            // was eaten this time.
            servingsCount: 1,
            tags: const [photoDishRecipeTag],
          );
    final draft = base.copyWith(
      totalWeightG: computed.totalWeightG,
      aggregatedNutrimentsPer100: computed.perHundredG,
    );

    try {
      return await _saveRecipe.save(draft);
    } catch (e, st) {
      _log.severe('Could not save the photo dish as a recipe', e, st);
      return draft;
    }
  }

  RecipeEntity? _existing(String name) {
    final wanted = name.toLowerCase();
    for (final recipe in _repository.getAllRecipes()) {
      if (recipe.tags.contains(photoDishRecipeTag) &&
          recipe.name.trim().toLowerCase() == wanted) {
        return recipe;
      }
    }
    return null;
  }
}
