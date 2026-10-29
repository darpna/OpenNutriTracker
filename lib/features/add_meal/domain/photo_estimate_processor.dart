import 'dart:async';
import 'dart:math' as math;

import 'package:opennutritracker/features/add_meal/domain/food_number_cache.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_reply.dart';
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/util/caption_amounts.dart';
import 'package:opennutritracker/features/add_meal/util/generic_food_table.dart';
import 'package:opennutritracker/features/add_meal/util/soft_text_score.dart';

// The sanity band for a model's per-100 g numbers.

/// Nothing edible carries more energy than pure fat.
const per100MaxKcal = 900.0;

/// How far a stated kcal/100 g may sit from 4/4/9 of its own macros before it
/// is replaced by the macros' figure.
const per100KcalTolerance = 0.15;

/// The range a cooking fat's kcal/100 g must land in. A model priced coconut
/// oil at 172; anything outside this takes the table's figure for the closest
/// fat.
const addedFatMinKcal = 700.0;
const addedFatMaxKcal = 900.0;

/// A table row whose kcal/100 g is more than this many times the model's (or
/// less than its inverse) is refused: "Sauce, peanut, made from ... soy sauce"
/// at 257 is not the soy sauce the model meant at 60.
const tableKcalGateRatio = 2.0;

/// Below this many kcal/100 g apart two figures always agree, so water and salt
/// at 0 and 3 are not ten-fold apart.
const tableKcalGateSlack = 20.0;

// The recipe anchors. Each one that changes a dish adds a line to its
// assumptions.

/// Oil, ghee and butter together, as a share of the dish's grams, unless the
/// dish is deep-fried.
const addedFatMaxShare = 0.08;

/// A protein the dish is named after, as a share of the dish's grams.
const namedProteinMinShare = 0.20;

/// Grams per spice or herb, and of salt.
const spiceMinG = 0.5;
const spiceMaxG = 3.0;
const saltMinG = 0.5;
const saltMaxG = 2.0;

/// Turns what a reply claimed into the estimate the app shows.
///
/// Per ingredient, in order:
///  1. **the sanity band** on the model's per-100 g numbers: macros that add
///     up to more than 100 g are scaled to fit; kcal outside 0-900, or more
///     than [per100KcalTolerance] from 4/4/9 of the macros, is replaced by the
///     macros' figure; a cooking fat outside 700-900 kcal takes the table's
///     values for the closest fat. These are the model-only numbers
///     ([PhotoRecipeEstimate.aiOnly]).
///  2. **grounding**: the bundled [table]'s row for the name, unless its
///     kcal/100 g is more than [tableKcalGateRatio] from the model's — then
///     the best row that is not ([GenericFoodTable.match] `accept`);
///  3. otherwise the **[cache]**: the numbers this device settled on for a
///     food of that name the first time it saw one;
///  4. otherwise the checked model numbers, which are then remembered.
///
/// Then per dish:
///  5. a weight the caption states wins, for an ingredient or a dish;
///  6. the recipe anchors: spices and herbs 0.5-3 g, salt 0.5-2 g; added fat
///     at most [addedFatMaxShare] of the dish unless it is deep-fried; a
///     protein the dish is named after at least [namedProteinMinShare]; a soup
///     or curry with no liquid base is flagged. A weight the caption stated is
///     never moved by an anchor.
///
/// The portion is the sum of the ingredients; nothing is scaled to a portion
/// the model stated. The model's totals are not asked for.
PhotoMealEstimate finalizeEstimate(
  RawPhotoEstimate raw, {
  GenericFoodTable? table,
  FoodNumberCache? cache,
  String? caption,
}) {
  final numbers = _Numbers(table, cache);
  var dishes = [
    for (final dish in raw.dishes)
      _Dish(
        dish,
        [for (final ingredient in dish.ingredients) numbers.resolve(ingredient)]
            .nonNulls
            .toList(),
      ),
  ].where((d) => d.ingredients.isNotEmpty).toList();

  final text = caption?.trim();
  if (text != null && text.isNotEmpty) _applyCaption(dishes, text);

  for (final dish in dishes) {
    _anchorSpices(dish);
    _capAddedFat(dish);
    _raiseNamedProtein(dish);
    _flagMissingLiquid(dish);
  }

  dishes = dishes.where((d) => d.ingredients.isNotEmpty).toList();
  return PhotoMealEstimate(
    dishes: [
      for (final dish in dishes)
        PhotoRecipeEstimate(
          dish: dish.raw.name,
          servings: dish.raw.servings,
          ingredients: [for (final i in dish.ingredients) i.estimate],
          confidence: dish.raw.confidence,
          assumptions: [...dish.raw.assumptions, ...dish.notes],
          aiOnly: PhotoRecipeEstimate.sumOf([
            for (final i in dish.ingredients) i.modelEstimate,
          ]),
        ),
    ],
  );
}

/// One ingredient while it is being settled: its grams can still move, its
/// numbers cannot.
class _Ingredient {
  final RawIngredient raw;
  final Per100g per100g;

  /// The model's numbers after the band, or [per100g] when it gave none.
  final Per100g modelPer100g;
  final IngredientSource source;
  final String? matchedName;
  double grams;

  /// Set by the caption. Anchors leave a stated weight alone.
  bool stated = false;

  _Ingredient(
    this.raw, {
    required this.per100g,
    required this.modelPer100g,
    required this.source,
    required this.matchedName,
  }) : grams = raw.grams;

  String get name => raw.name;

  EstimatedIngredient get estimate => EstimatedIngredient(
    name: name,
    grams: grams,
    per100g: per100g,
    visible: raw.visible,
    source: source,
    matchedName: matchedName,
  );

  EstimatedIngredient get modelEstimate => EstimatedIngredient(
    name: name,
    grams: grams,
    per100g: modelPer100g,
    visible: raw.visible,
  );
}

class _Dish {
  final RawDish raw;
  final List<_Ingredient> ingredients;
  final notes = <String>[];

  _Dish(this.raw, this.ingredients);

  double get grams => ingredients.fold(0.0, (sum, i) => sum + i.grams);

  Set<String> get nameWords => normalizedWords(raw.name).toSet();
}

/// Steps 1 to 4, and what was settled during this reply, so two ingredients of
/// the same name on one plate agree even without a cache.
class _Numbers {
  final GenericFoodTable? table;
  final FoodNumberCache? cache;
  final _settled = <String, CachedFoodNumbers>{};

  _Numbers(this.table, this.cache);

  _Ingredient? resolve(RawIngredient raw) {
    final stated = raw.per100g;
    final model = stated == null
        ? null
        : sanitizePer100g(raw.name, stated, table);
    final key = foodNumberKey(raw.name);

    final match = table?.match(
      raw.name,
      accept: model == null
          ? null
          : (food) => kcalAgrees(food.kcal, model.kcal),
    );
    if (match != null) {
      final food = match.food;
      final per100g = Per100g(
        kcal: food.kcal,
        proteinG: food.proteinG,
        carbsG: food.carbsG,
        fatG: food.fatG,
      );
      _remember(
        key,
        CachedFoodNumbers(
          per100g,
          fromTable: true,
          matchedName: food.description,
        ),
      );
      return _Ingredient(
        raw,
        per100g: per100g,
        modelPer100g: model ?? per100g,
        source: IngredientSource.db,
        matchedName: food.description,
      );
    }

    final known = _settled[key] ?? cache?.read(key);
    if (known != null) {
      _settled[key] = known;
      return _Ingredient(
        raw,
        per100g: known.per100g,
        modelPer100g: model ?? known.per100g,
        source: IngredientSource.cache,
        matchedName: known.matchedName,
      );
    }

    // Nothing to stand behind the ingredient: no numbers of its own, no table
    // row, nothing remembered. Dropped, as an ingredient with no numbers
    // always was.
    if (model == null) return null;
    _remember(key, CachedFoodNumbers(model));
    return _Ingredient(
      raw,
      per100g: model,
      modelPer100g: model,
      source: IngredientSource.ai,
      matchedName: null,
    );
  }

  void _remember(String key, CachedFoodNumbers numbers) {
    if (shouldReplace(_settled[key], numbers)) _settled[key] = numbers;
    final store = cache;
    if (store != null) unawaited(store.remember(key, numbers));
  }
}

/// Whether a table row's kcal/100 g is close enough to the model's to be the
/// same food (see [tableKcalGateRatio]).
bool kcalAgrees(double table, double model) {
  if ((table - model).abs() <= tableKcalGateSlack) return true;
  final low = math.min(table, model);
  final high = math.max(table, model);
  return low > 0 && high / low <= tableKcalGateRatio;
}

/// Step 1: [stated] made believable for a food called [name].
Per100g sanitizePer100g(String name, Per100g stated, GenericFoodTable? table) {
  var protein = stated.proteinG, carbs = stated.carbsG, fat = stated.fatG;
  final macroGrams = protein + carbs + fat;
  // Grams of macros within 100 g of food cannot add up to more than 100 (a
  // rounding allowance of 1 g).
  if (macroGrams > 101) {
    final factor = 100 / macroGrams;
    protein *= factor;
    carbs *= factor;
    fat *= factor;
  }
  final fromMacros = 4 * protein + 4 * carbs + 9 * fat;
  var kcal = stated.kcal;
  if (kcal > per100MaxKcal ||
      (fromMacros > 0 &&
          (kcal - fromMacros).abs() / fromMacros > per100KcalTolerance)) {
    kcal = fromMacros;
  }
  kcal = kcal.clamp(0.0, per100MaxKcal);

  if (isAddedFat(name) && (kcal < addedFatMinKcal || kcal > addedFatMaxKcal)) {
    return closestFat(name, table);
  }
  return Per100g(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat);
}

/// The table's numbers for the fat [name] is closest to: the row it matches
/// among fats, else ghee, butter or a plain vegetable oil by what it names.
/// Without a table, the same three USDA rows as constants.
Per100g closestFat(String name, GenericFoodTable? table) {
  final words = normalizedWords(cleanFoodName(name)).toSet();
  final kind = words.contains('ghee')
      ? _Fat.ghee
      : words.contains('butter')
      ? _Fat.butter
      : _Fat.oil;
  bool isFat(GenericFood food) => food.kcal >= addedFatMinKcal;
  final food =
      table?.match(name, accept: isFat)?.food ??
      table?.match(kind.tableName, accept: isFat)?.food;
  if (food == null) return kind.fallback;
  return Per100g(
    kcal: food.kcal,
    proteinG: food.proteinG,
    carbsG: food.carbsG,
    fatG: food.fatG,
  );
}

enum _Fat {
  ghee(
    'Butter, Clarified butter (ghee)',
    Per100g(kcal: 900, proteinG: 0, carbsG: 0, fatG: 100),
  ),
  butter(
    'Butter, without salt',
    Per100g(kcal: 717, proteinG: 0.8, carbsG: 0.1, fatG: 81.1),
  ),
  oil(
    'Oil, vegetable, soybean, refined',
    Per100g(kcal: 884, proteinG: 0, carbsG: 0, fatG: 100),
  );

  final String tableName;
  final Per100g fallback;

  const _Fat(this.tableName, this.fallback);
}

/// Oil, ghee, butter and their kin, and not the foods that only share a word
/// with them (peanut butter, butter beans, tuna in oil, butter chicken).
bool isAddedFat(String name) {
  final words = normalizedWords(cleanFoodName(name)).toSet();
  if (words.any(_fatWords.contains)) return true;
  if (words.contains('oil')) return !words.any(_oilNotFat.contains);
  if (words.contains('butter')) return !words.any(_butterNotFat.contains);
  return false;
}

const _fatWords = {'ghee', 'lard', 'shortening', 'margarine', 'vanaspati'};
const _oilNotFat = {
  'tuna',
  'sardine',
  'anchovy',
  'mackerel',
  'salmon',
  'fish',
  'packed',
};
const _butterNotFat = {
  'peanut',
  'almond',
  'cashew',
  'nut',
  'seed',
  'apple',
  'cocoa',
  'shea',
  'bean',
  'chicken',
  'squash',
  'lettuce',
  'sauce',
  'cookie',
  'cake',
  'bread',
};

/// A spice or a herb used as one: ground, dried, a seed, a garnish of leaves.
/// Not ginger, garlic or a fresh chilli, which go in by the clove and the
/// piece, and not anything that is a sauce or a paste made of them.
bool isSpiceOrHerb(String name) {
  final words = normalizedWords(cleanFoodName(name)).toSet();
  if (words.any(_notSpice.contains)) return false;
  if (words.any(_spiceWords.contains)) return true;
  final ground = words.any(_groundWords.contains);
  if (words.contains('pepper') || words.contains('peppercorn')) {
    if (words.contains('bell')) return false;
    return words.contains('peppercorn') ||
        words.contains('black') ||
        words.contains('white') ||
        ground;
  }
  if (words.any(_chilliWords.contains)) return ground;
  if (words.contains('mustard') || words.contains('fennel')) {
    return words.contains('seed') || ground;
  }
  if (words.contains('fenugreek') || words.contains('methi')) {
    return words.contains('seed') ||
        words.contains('kasuri') ||
        words.contains('dried');
  }
  return false;
}

const _spiceWords = {
  'spice',
  'cumin',
  'jeera',
  'turmeric',
  'haldi',
  'paprika',
  'cardamom',
  'clove',
  'cinnamon',
  'nutmeg',
  'mace',
  'saffron',
  'asafoetida',
  'hing',
  'ajwain',
  'carom',
  'anise',
  'aniseed',
  'oregano',
  'thyme',
  'rosemary',
  'basil',
  'mint',
  'parsley',
  'cilantro',
  'coriander',
  'dill',
  'sage',
  'tarragon',
  'chive',
  'marjoram',
  'bay',
  'allspice',
  'sumac',
  'caraway',
  'nigella',
  'kalonji',
  'masala',
  'seasoning',
  'herb',
  'curry',
  'cayenne',
};
const _groundWords = {'powder', 'ground', 'flake', 'dried', 'dry', 'crushed'};
const _chilliWords = {'chili', 'chilli', 'chile'};
const _notSpice = {
  'sauce',
  'paste',
  'chutney',
  'pesto',
  'dressing',
  'salad',
  'tea',
  'oil',
  'butter',
  'stock',
  'water',
  'juice',
  'syrup',
  'garlic',
  'ginger',
  'onion',
  'shallot',
  'tomato',
  'lemon',
  'lime',
  'rice',
  'chicken',
  'potato',
};

/// Salt, and only salt: "Salt, table", "sea salt", "salt to taste".
bool isSalt(String name) {
  final words = normalizedWords(cleanFoodName(name)).toSet();
  return words.contains('salt') && words.every(_saltWords.contains);
}

const _saltWords = {
  'salt',
  'table',
  'sea',
  'rock',
  'black',
  'kosher',
  'iodized',
  'iodised',
  'pink',
  'himalayan',
  'fine',
  'coarse',
  'flake',
  'to',
  'taste',
  'pinch',
};

/// Step 5. Stated grams set an ingredient (anywhere on the plate) or a dish; a
/// bare weight is the whole meal's.
void _applyCaption(List<_Dish> dishes, String caption) {
  final used = <_Ingredient>{};
  final dishWeights = <_Dish, double>{};
  final bare = bareCaptionWeight(caption);

  for (final stated in statedAmounts(caption)) {
    final grams = statedGrams(stated.quantity!, stated.unit);
    if (grams == null || grams <= 0) continue;
    final tokens = tokenize(stated.query);
    if (tokens.isEmpty) continue;

    _Ingredient? best;
    var bestScore = 0.0;
    for (final dish in dishes) {
      for (final ingredient in dish.ingredients) {
        if (used.contains(ingredient)) continue;
        final score = captionAgreement(tokens, tokenize(ingredient.name));
        if (score > bestScore) {
          best = ingredient;
          bestScore = score;
        }
      }
    }
    if (best != null) {
      used.add(best);
      best
        ..grams = grams
        ..stated = true;
      continue;
    }
    for (final dish in dishes) {
      if (captionAgreement(tokens, tokenize(dish.raw.name)) > 0) {
        dishWeights[dish] = grams;
        break;
      }
    }
  }

  for (final entry in dishWeights.entries) {
    _scaleUnstated(entry.key.ingredients, entry.value);
  }
  if (bare != null && dishWeights.isEmpty) {
    _scaleUnstated([for (final d in dishes) ...d.ingredients], bare);
  }
}

/// Scales the ingredients a caption did not state so all of them add up to
/// [total] grams.
void _scaleUnstated(List<_Ingredient> ingredients, double total) {
  final stated = ingredients
      .where((i) => i.stated)
      .fold(0.0, (sum, i) => sum + i.grams);
  final free = ingredients.where((i) => !i.stated).toList();
  final freeGrams = free.fold(0.0, (sum, i) => sum + i.grams);
  final target = total - stated;
  if (freeGrams <= 0 || target <= 0) return;
  final factor = target / freeGrams;
  for (final i in free) {
    i.grams *= factor;
  }
}

/// Spices and herbs 0.5-3 g each, salt 0.5-2 g.
void _anchorSpices(_Dish dish) {
  final spices = <String>[];
  var salt = false;
  for (final i in dish.ingredients) {
    if (i.stated) continue;
    final (min, max, isSpice) = isSalt(i.name)
        ? (saltMinG, saltMaxG, false)
        : isSpiceOrHerb(i.name)
        ? (spiceMinG, spiceMaxG, true)
        : (null, null, false);
    if (min == null || max == null) continue;
    final clamped = i.grams.clamp(min, max);
    if (clamped == i.grams) continue;
    i.grams = clamped;
    if (isSpice) {
      spices.add(i.name);
    } else {
      salt = true;
    }
  }
  if (spices.isNotEmpty) {
    dish.notes.add(
      'Spices and herbs set to ${_g(spiceMinG)}-${_g(spiceMaxG)} g each '
      '(${spices.join(', ')}).',
    );
  }
  if (salt) {
    dish.notes.add('Salt set to ${_g(saltMinG)}-${_g(saltMaxG)} g.');
  }
}

/// Oil, ghee and butter together at most [addedFatMaxShare] of the dish's
/// grams, unless it is deep-fried.
void _capAddedFat(_Dish dish) {
  // A deep-fried dish carries the fat it was fried in, and a dish that is a
  // fat (a pat of butter served on the side) is all fat by definition.
  if (isDeepFried(dish.raw.name) || isAddedFat(dish.raw.name)) return;
  final fats = dish.ingredients.where((i) => isAddedFat(i.name)).toList();
  if (fats.isEmpty) return;
  final free = fats.where((i) => !i.stated).toList();
  final freeFat = free.fold(0.0, (sum, i) => sum + i.grams);
  final statedFat = fats
      .where((i) => i.stated)
      .fold(0.0, (sum, i) => sum + i.grams);
  final rest = dish.grams - freeFat;
  if (rest <= 0) return;
  // The free fat F that makes (stated + F) / (rest + F) the cap.
  final allowed = math.max(
    0.0,
    (addedFatMaxShare * rest - statedFat) / (1 - addedFatMaxShare),
  );
  if (freeFat <= allowed + 0.05) return;
  final factor = allowed / freeFat;
  for (final i in free) {
    i.grams *= factor;
  }
  dish.notes.add(
    'Added fat capped at ${_percent(addedFatMaxShare)} of the dish: '
    '${_g(freeFat)} g to ${_g(allowed)} g.',
  );
}

/// Deep-fried dishes carry the fat they were fried in, so the cap does not
/// apply to them.
bool isDeepFried(String dish) {
  final text = dish.toLowerCase();
  if (_deepFriedPhrases.any(text.contains)) return true;
  return normalizedWords(dish).any(_deepFriedWords.contains);
}

const _deepFriedPhrases = {
  'deep fried',
  'deep-fried',
  'fried chicken',
  'fish and chips',
  'french fries',
  'spring roll',
};
const _deepFriedWords = {
  'pakora',
  'pakoda',
  'bhaji',
  'bhajia',
  'samosa',
  'vada',
  'wada',
  'puri',
  'poori',
  'bhatura',
  'bhature',
  'kachori',
  'jalebi',
  'tempura',
  'fritter',
  'katsu',
  'karaage',
  'churro',
  'doughnut',
  'donut',
  'fries',
  'chip',
  'falafel',
};

/// The proteins a dish can be named after, and the ingredient words that
/// count as each.
const namedProteins = <String, Set<String>>{
  'chicken': {'chicken'},
  'mutton': {'mutton', 'lamb', 'goat'},
  'lamb': {'lamb', 'mutton'},
  'goat': {'goat', 'mutton'},
  'fish': {
    'fish',
    'salmon',
    'cod',
    'tilapia',
    'tuna',
    'pomfret',
    'basa',
    'mackerel',
    'sardine',
    'trout',
    'haddock',
    'snapper',
    'hake',
    'pollock',
    'catfish',
    'kingfish',
    'seabass',
    'bass',
    'halibut',
    'barramundi',
    'rohu',
    'hilsa',
    'surmai',
  },
  'prawn': {'prawn', 'shrimp'},
  'shrimp': {'shrimp', 'prawn'},
  'egg': {'egg'},
  'paneer': {'paneer'},
  'tofu': {'tofu'},
  'beef': {'beef', 'steak'},
  'pork': {'pork'},
};

/// Words that make an ingredient something other than the protein itself:
/// chicken stock, fish sauce, egg noodles.
const _notTheProtein = {
  'stock',
  'broth',
  'bouillon',
  'sauce',
  'powder',
  'fat',
  'oil',
  'noodle',
  'pasta',
  'bread',
  'roll',
  'wrapper',
  'paste',
  'cube',
};

/// A protein the dish is named after, at least [namedProteinMinShare] of its
/// grams.
void _raiseNamedProtein(_Dish dish) {
  final named = dish.nameWords;
  for (final entry in namedProteins.entries) {
    if (!named.contains(entry.key)) continue;
    final matching = dish.ingredients.where((i) {
      final words = normalizedWords(cleanFoodName(i.name)).toSet();
      return words.any(entry.value.contains) &&
          !words.any(_notTheProtein.contains) &&
          !isAddedFat(i.name);
    }).toList();
    final free = matching.where((i) => !i.stated).toList();
    if (free.isEmpty) continue;
    final protein = matching.fold(0.0, (sum, i) => sum + i.grams);
    final total = dish.grams;
    if (total <= 0 || protein / total >= namedProteinMinShare) continue;
    // The protein P that makes P / (rest + P) the floor.
    final wanted =
        namedProteinMinShare * (total - protein) / (1 - namedProteinMinShare);
    final freeGrams = free.fold(0.0, (sum, i) => sum + i.grams);
    final factor = (freeGrams + wanted - protein) / freeGrams;
    for (final i in free) {
      i.grams *= factor;
    }
    dish.notes.add(
      '${_capitalised(entry.key)} raised to '
      '${_percent(namedProteinMinShare)} of the dish: '
      '${_g(protein)} g to ${_g(wanted)} g.',
    );
  }
}

/// Soups and curries are mostly their liquid; one with no stock, water or
/// milk listed is probably missing it, and the line says so.
void _flagMissingLiquid(_Dish dish) {
  if (!isSoupOrCurry(dish.raw.name)) return;
  final hasLiquid = dish.ingredients.any((i) {
    final words = normalizedWords(cleanFoodName(i.name)).toSet();
    return words.any(_liquidWords.contains);
  });
  if (hasLiquid) return;
  dish.notes.add(
    'No liquid base (stock, water, coconut milk) was listed; this soup or '
    'curry may weigh more than shown.',
  );
}

bool isSoupOrCurry(String dish) =>
    normalizedWords(dish).any(_soupOrCurryWords.contains);

const _soupOrCurryWords = {
  'soup',
  'curry',
  'dal',
  'daal',
  'dhal',
  'stew',
  'broth',
  'ramen',
  'pho',
  'laksa',
  'sambar',
  'rasam',
  'korma',
  'chowder',
  'bisque',
  'gumbo',
  'kadhi',
  'kadi',
  'vindaloo',
  'jalfrezi',
  'nihari',
};

const _liquidWords = {
  'water',
  'stock',
  'broth',
  'bouillon',
  'dashi',
  'milk',
  'cream',
  'yogurt',
  'yoghurt',
  'curd',
};

String _g(double grams) => grams >= 10
    ? grams.round().toString()
    : grams.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

String _percent(double share) => '${(share * 100).round()}%';

String _capitalised(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);
