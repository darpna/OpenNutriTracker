import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';
import 'package:opennutritracker/features/add_meal/util/soft_text_score.dart';

/// How well each token of a caption phrase must agree with a component's own
/// words for the phrase to name that component. Soft, so `wraps` names `wrap`
/// and `chicken` names `breaded fried chicken`, yet `oil` does not name `olive`.
const _tokenAgreement = 0.6;

/// A number with a unit against it, anywhere in a sentence: `200g`, `0,5 l`.
/// The deterministic parser only sees an amount at the edge of a segment, and a
/// caption is a sentence ("katsu wrap with 200g chicken"), so this finds where
/// to start reading.
final _statedUnit = RegExp(
  r'-?\d+(?:[.,]\d+)?\s*(?:kg|lb|ml|oz|g|l)(?![\p{L}])',
  caseSensitive: false,
  unicode: true,
);

/// Grams in an ounce / millilitres in a fluid ounce, as the app converts them.
const _gramsPerOz = 28.349523125;
const _mlPerFlOz = 29.5735295625;

/// Lets what the caption *states* win over what the model *guessed*.
///
/// A caption like "ate half of a katsu wrap, 200g chicken" is read with the
/// deterministic text parser — the same one the typed path uses — and every
/// segment that carries a number is a stated amount. Each one is matched to
/// the component (or the dish, or a loose item) it names, and replaces that
/// target's estimate: quantity, unit and portion are the caption's, and the
/// row is no longer `estimated`, because somebody said it.
///
/// A caption that names a dish and gives a weight ("katsu wrap 300 g") rescales
/// the components to that total, keeping their proportions.
///
/// Words the parser cannot turn into an amount — "ate half" — change nothing
/// here; the model was given the caption and has already acted on them.
MealTextParseResult applyCaptionAmounts(
  MealTextParseResult result,
  String? caption,
) {
  final text = caption?.trim();
  if (text == null || text.isEmpty) return result;

  final stated = statedAmounts(text);
  if (stated.isEmpty) return result;

  // `textStatesAUnit` is the guard the typed path uses for the same question:
  // is a unit actually written in this text? A segment's unit survives only
  // when it is, which is what keeps a word like "Glas" from becoming litres.
  final unitsWritten = textStatesAUnit(text);

  final dish = result.dish;
  final components = [...?dish?.components];
  final items = [...result.items];
  final used = <ParsedMealItem>{};

  for (final statement in stated) {
    final amount = unitsWritten
        ? statement
        : ParsedMealItem(query: statement.query, quantity: statement.quantity);
    final tokens = tokenize(amount.query);
    if (tokens.isEmpty) continue;

    // Components and items compete on equal terms; the dish name is tried last,
    // so "chicken" names the chicken before it names "katsu chicken wrap".
    final target = _bestTarget([...components, ...items], tokens, used);
    if (target != null) {
      used.add(target);
      final overridden = _stated(target, amount);
      final ci = components.indexOf(target);
      if (ci >= 0) {
        components[ci] = overridden;
      } else {
        items[items.indexOf(target)] = overridden;
      }
      continue;
    }

    if (dish != null && captionAgreement(tokens, tokenize(dish.name)) > 0) {
      final scaled = _rescaled(components, amount);
      if (scaled != null) {
        components
          ..clear()
          ..addAll(scaled);
      }
    }
  }

  return MealTextParseResult(
    items: items,
    errors: result.errors,
    dish: dish == null
        ? null
        : ParsedMealDish(name: dish.name, components: components),
  );
}

ParsedMealItem _stated(ParsedMealItem target, ParsedMealItem amount) =>
    ParsedMealItem(
      query: target.query,
      quantity: amount.quantity,
      unit: amount.unit,
      aiPer100: target.aiPer100,
    );

/// Every amount [text] states, as the parser reads it.
///
/// First the whole text, which finds an amount at the edge of a segment
/// ("200g chicken, 2 eggs"). Then, for each number-with-unit written inside a
/// sentence, the words from there to the next one, read the same way, so
/// "wrap with 200g chicken and 50g lettuce" yields both. Nothing is invented
/// that the parser would not accept: a slice that is only a unit is dropped.
List<ParsedMealItem> statedAmounts(String text) {
  final found = <ParsedMealItem>[];
  void add(ParsedMealItem item) {
    if (item.quantity == null) return;
    // "420 g" on its own reads as a quantity of 420 against the food "g".
    if (tokenize(item.query).every((token) => token.length <= 2)) return;
    final duplicate = found.any(
      (other) =>
          other.quantity == item.quantity &&
          other.unit == item.unit &&
          tokenize(other.query).intersection(tokenize(item.query)).isNotEmpty,
    );
    if (!duplicate) found.add(item);
  }

  parseMealText(text).items.forEach(add);
  final starts = [for (final m in _statedUnit.allMatches(text)) m.start];
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : text.length;
    parseMealText(text.substring(starts[i], end)).items.forEach(add);
  }
  return found;
}

/// The candidate [tokens] name best, or null. A phrase names a food when at
/// least half of its words agree with the food's own; the one it covers most of
/// wins ("fried chicken" names "fried chicken" over "breaded fried chicken
/// tender"). Half rather than all, so a connecting word in a sentence ("chicken
/// and") does not stop "chicken" naming the chicken, with no stop-word list to
/// keep per language.
ParsedMealItem? _bestTarget(
  List<ParsedMealItem> candidates,
  Set<String> tokens,
  Set<ParsedMealItem> used,
) {
  ParsedMealItem? best;
  var bestScore = 0.0;
  for (final candidate in candidates) {
    if (used.contains(candidate)) continue;
    final score = captionAgreement(tokens, tokenize(candidate.query));
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

/// 0 unless at least half of [phrase] agrees with [name]; otherwise how much of
/// the phrase, then of the name, is covered.
double captionAgreement(Set<String> phrase, Set<String> name) {
  if (phrase.isEmpty || name.isEmpty) return 0;
  final phraseHits = phrase
      .where(
        (token) => name.any(
          (other) => tokenSimilarity(token, other) >= _tokenAgreement,
        ),
      )
      .length;
  if (phraseHits == 0 || phraseHits / phrase.length < 0.5) return 0;
  final nameHits = name
      .where(
        (other) => phrase.any(
          (token) => tokenSimilarity(token, other) >= _tokenAgreement,
        ),
      )
      .length;
  return phraseHits / phrase.length + nameHits / name.length;
}

/// The components scaled so their estimated weights sum to the weight [amount]
/// states, or null when that cannot be done honestly: the caption's amount is
/// not a weight, or the model gave no weight for some component to scale.
List<ParsedMealItem>? _rescaled(
  List<ParsedMealItem> components,
  ParsedMealItem amount,
) {
  final target = statedGrams(amount.quantity!, amount.unit);
  if (target == null || target <= 0) return null;
  var total = 0.0;
  for (final component in components) {
    final grams = component.estimatedGrams;
    if (grams == null) return null;
    total += grams;
  }
  if (total <= 0) return null;
  final factor = target / total;
  return [
    for (final component in components)
      ParsedMealItem(
        query: component.query,
        quantity: component.estimatedGrams! * factor,
        unit: 'g',
        // The total was stated; the split between components still is not.
        estimated: true,
        estimatedGrams: component.estimatedGrams! * factor,
        aiPer100: component.aiPer100,
      ),
  ];
}

double? statedGrams(double quantity, String? unit) => switch (unit) {
  'g' || 'ml' || 'g/ml' => quantity,
  'oz' => quantity * _gramsPerOz,
  'fl.oz' => quantity * _mlPerFlOz,
  _ => null,
};

/// A weight the caption gives with no food beside it ("katsu wrap, 250 g"): a
/// segment that is only an amount. It is the dish's weight.
double? bareCaptionWeight(String caption) {
  for (final segment in caption.split(RegExp(r'[;,\n]'))) {
    final match = RegExp(
      r'^\s*(\d+(?:[.,]\d+)?)\s*(kg|g|ml|l|oz|lb)\s*$',
      caseSensitive: false,
    ).firstMatch(segment);
    if (match == null) continue;
    final number = double.parse(match.group(1)!.replaceAll(',', '.'));
    final grams = switch (match.group(2)!.toLowerCase()) {
      'kg' || 'l' => number * 1000,
      'oz' => number * _gramsPerOz,
      'lb' => number * 453.59237,
      _ => number,
    };
    if (grams > 0) return grams;
  }
  return null;
}
