import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate_processor.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// Reads a photograph of a meal the way a dietitian would: name the dish, recall
/// its recipe, list every ingredient (the oil that cannot be seen included), size
/// them to the portion, and give each its nutrition.
///
/// **One call per photo.** A reply that does not fit the schema is an error the
/// caller shows, not a reason to ask again.
///
/// **No food search.** The ingredients are named in USDA FoodData Central style
/// and their numbers come from the model, replaced by the bundled generic table's
/// where it knows the ingredient ([GenericFoodTable]) so the same food always
/// has the same numbers. Open Food Facts is not consulted for what a photograph
/// shows. See [finalizeEstimate] for the checks every reply goes through.
///
/// What a provider is asked is the same for all of them: the prompt, the
/// schema and the single forced tool live above the seam, not in a client.
class ModelMealPhotoInterpreter implements MealPhotoInterpreter {
  static final _log = Logger('ModelMealPhotoInterpreter');

  final MealItemsApi _api;

  /// Where the generic table comes from; null or a failure means ingredients
  /// keep the model's own numbers.
  final Future<GenericFoodTable?> Function()? _table;

  ModelMealPhotoInterpreter(
    this._api, {
    Future<GenericFoodTable?> Function()? table,
  }) : _table = table;

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
    if (raw.ingredients.isEmpty) {
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
      estimate: finalizeEstimate(raw, table: table, caption: caption),
    );
  }
}
