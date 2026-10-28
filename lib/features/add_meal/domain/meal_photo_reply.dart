import 'package:opennutritracker/core/utils/food_name_validator.dart';
import 'package:opennutritracker/features/add_meal/domain/ai_per100_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

const mealPhotoToolName = 'log_meal_photo';

const mealPhotoToolDescription =
    'Record the dish or foods in the photo, with estimated amounts and '
    'per-100 g macros.';

/// Heaviest single item a photograph may claim, in grams. Anything above this
/// is a misread rather than a meal; the amount is dropped, the food kept.
const mealPhotoMaxItemGrams = 3000.0;

/// Most portions of one name a photograph may claim ("2 slices").
const mealPhotoMaxPortionCount = 24.0;

/// How many components or items are read from one reply. A runaway list is
/// cut, not refused.
const _maxEntries = 20;

const _componentSchema = {
  'type': 'object',
  'properties': {
    'query': {
      'type': 'string',
      'description':
          'Food name only, no amount, in the user\'s language. Generic '
          '("fried chicken", "tortilla"), no brand unless legible in the '
          'photo.',
    },
    'grams': {
      'type': 'number',
      'description':
          'Your estimate of how much of this food is on the plate, in grams '
          '(millilitres for a drink). Always give it.',
    },
    'portion': {
      'type': 'string',
      'description':
          'Optional. One English portion word a food database would know — '
          'slice, piece, cup, tablespoon, small, medium, large. Only together '
          'with "count".',
    },
    'count': {
      'type': 'number',
      'description': 'Optional. How many of "portion" are on the plate.',
    },
    'per_100g': {
      'type': 'object',
      'description':
          'Your estimate of this food\'s macros per 100 g, as eaten. Always '
          'give all four.',
      'properties': {
        'kcal': {'type': 'number'},
        'protein_g': {'type': 'number'},
        'carbs_g': {'type': 'number'},
        'fat_g': {'type': 'number'},
      },
      'required': ['kcal', 'protein_g', 'carbs_g', 'fat_g'],
      'additionalProperties': false,
    },
  },
  'required': ['query', 'grams', 'per_100g'],
  'additionalProperties': false,
};

/// The one schema every provider is held to for a photograph.
///
/// Unlike [mealItemsToolSchema] it carries nutrition fields — `per_100g` — and
/// that is deliberate and narrow: they feed only the "AI estimate" fallback
/// for a component the food database cannot match, never a database match
/// that is good enough (see `ResolveParsedMealsUseCase`). The typed path keeps
/// the no-nutrition schema.
///
/// Like the first schema it is a hint, not a defence: [mealPhotoResultFromJson]
/// re-checks everything in Dart, and a reply that fails falls back to the
/// counts-only reading.
const mealPhotoToolSchema = {
  'type': 'object',
  'properties': {
    'dish': {
      'type': 'object',
      'description':
          'Only when the photo is ONE composed dish a person would log as a '
          'single thing — a wrap, curry, burger, thali item, sandwich. Omit '
          'for a plate of separate foods.',
      'properties': {
        'name': {'type': 'string', 'description': 'The dish\'s name.'},
        'components': {
          'type': 'array',
          'description':
              'What the dish is made of: tortilla, breaded fried chicken, '
              'lettuce, mayo. Include sauces and fillings you can reasonably '
              'infer.',
          'items': _componentSchema,
        },
      },
      'required': ['name', 'components'],
      'additionalProperties': false,
    },
    'items': {
      'type': 'array',
      'description':
          'Separate foods on the plate that are not part of the dish. Empty '
          'when there are none.',
      'items': _componentSchema,
    },
  },
  'additionalProperties': false,
};

const mealPhotoToolSpec = MealToolSpec(
  name: mealPhotoToolName,
  description: mealPhotoToolDescription,
  schema: mealPhotoToolSchema,
  maxTokens: 2048,
);

/// The reply was not the shape the schema asks for. Distinct from
/// [MealInterpreterException] on purpose: the provider answered fine, the
/// answer is unusable, and the right response is the counts-only fallback, not
/// an error shown to the user.
class MealPhotoReplyException implements Exception {
  final String reason;

  const MealPhotoReplyException(this.reason);

  @override
  String toString() => 'MealPhotoReplyException($reason)';
}

/// Reads the photo tool's input strictly.
///
/// **Structure is checked hard, values softly.** A reply with no `dish` and no
/// `items`, a dish without a name or components, a component that is not an
/// object or lacks `query` or `per_100g` — all of those throw
/// [MealPhotoReplyException], because they mean the model did not answer the
/// question asked. A well-formed component with a nonsense number (zero or
/// 5 kg of rice, 2000 kcal per 100 g) keeps its food and loses just that
/// number: the user can see and edit the row, which beats discarding the plate.
///
/// Amounts: grams in (0, [mealPhotoMaxItemGrams]]; a portion needs a count in
/// (0, [mealPhotoMaxPortionCount]]. Both are kept flagged `estimated`.
MealTextParseResult mealPhotoResultFromJson(Object? input) {
  if (input is! Map) {
    throw const MealPhotoReplyException('tool input is not an object');
  }
  final hasDish = input.containsKey('dish') && input['dish'] != null;
  final hasItems = input.containsKey('items');
  if (!hasDish && !hasItems) {
    throw const MealPhotoReplyException('neither dish nor items');
  }

  ParsedMealDish? dish;
  if (hasDish) {
    final raw = input['dish'];
    if (raw is! Map) {
      throw const MealPhotoReplyException('dish is not an object');
    }
    final name = raw['name'];
    if (name is! String || !FoodNameValidator.isValid(name.trim())) {
      throw const MealPhotoReplyException('dish has no usable name');
    }
    final components = _components(raw['components']);
    if (components.isEmpty) {
      throw const MealPhotoReplyException('dish has no usable components');
    }
    dish = ParsedMealDish(name: name.trim(), components: components);
  }

  final rawItems = input['items'];
  final items = hasItems
      ? _components(rawItems, allowEmpty: true)
      : const <ParsedMealItem>[];

  return MealTextParseResult(items: items, errors: const [], dish: dish);
}

List<ParsedMealItem> _components(Object? raw, {bool allowEmpty = false}) {
  if (raw is! List) {
    throw const MealPhotoReplyException('components is not an array');
  }
  if (raw.isEmpty && !allowEmpty) {
    throw const MealPhotoReplyException('components is empty');
  }
  final parsed = <ParsedMealItem>[];
  for (final entry in raw.take(_maxEntries)) {
    if (entry is! Map) {
      throw const MealPhotoReplyException('component is not an object');
    }
    final item = _component(entry);
    if (item != null) parsed.add(item);
  }
  // Every entry present and none usable is a reply that was not the one asked
  // for, not "no food": the same distinction `mealItemsFromJson` draws.
  if (parsed.isEmpty && raw.isNotEmpty) {
    throw const MealPhotoReplyException('no component survived');
  }
  return parsed;
}

/// One component, or null when its name is unusable (dropped, not fatal).
ParsedMealItem? _component(Map<dynamic, dynamic> raw) {
  final query = raw['query'];
  if (query is! String) {
    throw const MealPhotoReplyException('component has no query');
  }
  if (!raw.containsKey('per_100g')) {
    throw const MealPhotoReplyException('component has no per_100g');
  }
  final name = query.trim();
  if (!FoodNameValidator.isValid(name)) return null;

  final grams = _amount(raw['grams'], max: mealPhotoMaxItemGrams);
  final count = _amount(raw['count'], max: mealPhotoMaxPortionCount);
  final rawPortion = raw['portion'];
  final portion = rawPortion is String && rawPortion.trim().isNotEmpty
      ? rawPortion.trim()
      : null;
  final aiPer100 = AiPer100Estimate.tryParse(raw['per_100g']);

  if (portion != null && count != null) {
    return ParsedMealItem(
      query: name,
      quantity: count,
      portion: portion,
      estimated: true,
      estimatedGrams: grams,
      aiPer100: aiPer100,
    );
  }
  if (grams != null) {
    return ParsedMealItem(
      query: name,
      quantity: grams,
      unit: 'g',
      estimated: true,
      estimatedGrams: grams,
      aiPer100: aiPer100,
    );
  }
  return ParsedMealItem(query: name, aiPer100: aiPer100);
}

/// A positive finite number within [max], or null. Numeric strings are read
/// the way `mealItemsFromJson` reads them; any other type is not an amount.
double? _amount(Object? value, {required double max}) {
  final number = switch (value) {
    num n => n.toDouble(),
    String s => double.tryParse(s.replaceAll(',', '.')),
    _ => null,
  };
  if (number == null || !number.isFinite) return null;
  if (number <= 0 || number > max) return null;
  return number;
}
