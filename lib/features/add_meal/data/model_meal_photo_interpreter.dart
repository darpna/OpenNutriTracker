import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate_processor.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// Reads a photograph of a meal the way a dietitian would: name every dish and
/// side on the plate, recall each one's recipe, list every ingredient (the oil
/// that cannot be seen included) with its grams, and give each its nutrition
/// per 100 g.
///
/// **One call per photo.** A reply that does not fit the schema is an error the
/// caller shows, not a reason to ask again.
///
/// **No food search.** The ingredients are named in USDA FoodData Central style
/// and their numbers per 100 g come from the bundled generic table where it
/// knows the ingredient ([GenericFoodTable]), else from what this device
/// settled on for that name before ([FoodNumberCache]), else from the model,
/// checked — so the same food always has the same numbers. Open Food Facts is
/// not consulted for what a photograph shows. See [finalizeEstimate] for the
/// checks every reply goes through.
///
/// What a provider is asked is the same for all of them: the prompt, the
/// schema and the single forced tool live above the seam, not in a client.
class ModelMealPhotoInterpreter implements MealPhotoInterpreter {
  static final _log = Logger('ModelMealPhotoInterpreter');

  final MealItemsApi _api;

  /// Where the generic table comes from; null or a failure means ingredients
  /// keep the model's own numbers.
  final Future<GenericFoodTable?> Function()? _table;

  /// Where a food's settled numbers are kept; null keeps nothing between
  /// photos.
  final FoodNumberCache? _cache;

  ModelMealPhotoInterpreter(
    this._api, {
    Future<GenericFoodTable?> Function()? table,
    FoodNumberCache? cache,
  }) : _table = table,
       _cache = cache;

  @override
  Future<MealTextParseResult> interpret(
    MealPhoto photo, {
    String? localeCode,
    String? caption,
  }) async {
    final api = _api;
    if (api is! MealPhotoToolApi) {
      // A client that cannot carry the photo tool cannot read a photograph.
      throw const MealInterpreterException(
        'client has no photo tool',
        failure: MealInterpreterFailure.unsupported,
      );
    }
    final input = await (api as MealPhotoToolApi).requestPhotoToolInput(
      content: MealPhotoContent(
        mediaType: photo.mediaType,
        base64Data: base64Encode(photo.bytes),
        caption: caption,
      ),
      // Not localised: ingredient names are USDA-style English so they can be
      // matched against the generic table. The app shows them as given.
      system: mealPhotoSystemPrompt,
    );

    final RawPhotoEstimate raw;
    try {
      raw = mealPhotoEstimateFromJson(input);
    } on MealPhotoReplyException catch (e) {
      // Not logged with anything from the reply: it can echo the photograph.
      _log.info('Photo estimate reply refused (${e.reason})');
      throw MealInterpreterException.badReply(e.reason);
    }

    // The model looked and listed nothing: no food in the photo.
    if (raw.dishes.isEmpty) {
      return const MealTextParseResult(items: [], errors: []);
    }

    GenericFoodTable? table;
    try {
      table = await _table?.call();
    } catch (e) {
      _log.warning('The generic food table could not be loaded');
    }

    return MealTextParseResult(
      items: const [],
      errors: const [],
      estimate: finalizeEstimate(
        raw,
        table: table,
        cache: _cache,
        caption: caption,
      ),
    );
  }
}
