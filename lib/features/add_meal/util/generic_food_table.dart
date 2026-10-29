import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// One row of the bundled generic food table: USDA FoodData Central
/// (Foundation Foods and SR Legacy, public domain), per 100 g.
class GenericFood {
  final String description;
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;

  const GenericFood({
    required this.description,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });
}

/// A table row a name was matched to, and how well.
class GenericFoodMatch {
  final GenericFood food;

  /// Share of the name's words found in the description, 0.0-1.0.
  final double recall;

  const GenericFoodMatch(this.food, this.recall);
}

/// Words that join a name without being part of it.
const _stopWords = {
  'and',
  'or',
  'with',
  'without',
  'in',
  'of',
  'the',
  'a',
  'an',
};

/// Words that look plural and are not, or whose singular is not "drop the s".
const _singulars = {
  'leaves': 'leaf',
  'loaves': 'loaf',
  'halves': 'half',
  'molasses': 'molasses',
  'hummus': 'hummus',
  'couscous': 'couscous',
  'asparagus': 'asparagus',
  'swiss': 'swiss',
};

/// "chickpeas" -> "chickpea", "tomatoes" -> "tomato", "berries" -> "berry".
/// Applied to both sides of every comparison, so it only has to agree with
/// itself, not with English.
String singularize(String word) {
  final known = _singulars[word];
  if (known != null) return known;
  if (word.length <= 3) return word;
  if (word.endsWith('ies')) return '${word.substring(0, word.length - 3)}y';
  if (word.endsWith('oes')) return word.substring(0, word.length - 2);
  if (word.endsWith('ches') ||
      word.endsWith('shes') ||
      word.endsWith('sses') ||
      word.endsWith('xes')) {
    return word.substring(0, word.length - 2);
  }
  if (word.endsWith('s') &&
      !word.endsWith('ss') &&
      !word.endsWith('us') &&
      !word.endsWith('is')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// Lower-cased, punctuation-free, singular words of [text], without the words
/// that only join others.
List<String> normalizedWords(String text) => [
  // "Butter, without salt" is not a salty food: what follows "without" is
  // named only to be denied.
  for (final word
      in text
          .toLowerCase()
          .replaceAll(RegExp(r'without\s+(added\s+)?[a-z]+'), ' ')
          .split(RegExp(r'[^a-z]+')))
    if (word.isNotEmpty && !_stopWords.contains(word)) singularize(word),
];

/// Words that mark a rarer variant of a common food ("glutinous" rice, a
/// "sprouted" lentil, a "nonfat" yogurt). A plain name means the common one.
const _variants = {
  'glutinous',
  'sprouted',
  'unenriched',
  'nonfat',
  'lowfat',
  'reduced',
  'light',
  'diet',
  'tofu',
  'fortified',
};

/// Words that mark a processed or prepared product. A name that does not use
/// them is not asking for one: "chicken breast" is not "breaded chicken breast
/// tenders", "tortilla" is not a tortilla mix.
const _processed = {
  'breaded',
  'fried',
  'frozen',
  'canned',
  'dried',
  'dehydrated',
  'mix',
  'babyfood',
  'imitation',
  'instant',
  'substitute',
  'flavored',
  'sweetened',
  'powder',
  'pudding',
  'restaurant',
  'formulated',
  'bar',
  'snack',
  'microwaved',
};

/// The generic food table, and the matcher that grounds a model's ingredient
/// names in it.
///
/// **Why a table at all.** A model asked for "kcal for 150 g of cooked rice"
/// answers a little differently every time. A fixed table answers the same
/// every time, which is what lets two photos of the same meal agree and lets
/// the user's targets be adjusted against the app's own numbers.
///
/// **Matching** is deliberately strict, because a wrong match is worse than
/// none (the model's own figure is kept when nothing matches):
///  * the name's first word, its head noun, must be a word of the table
///    description's first two comma-separated parts ("Rice, white, ..." heads
///    "rice"; "Butter, Clarified butter (ghee)" heads "butter" and "ghee");
///  * at least [minRecall] of the name's words must appear in the description;
///  * among the rest the one with most name words, then fewest other words,
///    wins ("Rice, white, cooked" picks the plain cooked rice, not the
///    enriched or salted variants).
class GenericFoodTable {
  /// Share of a name's words that must be found in a description. Two words
  /// need both, three or four need all but one: "Chickpeas, cooked" matches,
  /// "Curry leaves" does not match "Spices, curry powder".
  static const minRecall = 0.75;

  final List<_Entry> _entries;
  final Map<String, List<int>> _byHead;

  GenericFoodTable._(this._entries, this._byHead);

  int get length => _entries.length;

  /// A table from `[description, kcal, protein_g, carbs_g, fat_g]` rows, the
  /// shape of the bundled asset.
  factory GenericFoodTable.fromRows(Iterable<List<Object?>> rows) {
    final entries = <_Entry>[];
    final byHead = <String, List<int>>{};
    for (final row in rows) {
      if (row.length < 5) continue;
      final description = row[0] as String;
      final kcal = (row[1] as num).toDouble();
      final food = GenericFood(
        description: description,
        kcal: kcal,
        proteinG: (row[2] as num).toDouble(),
        carbsG: (row[3] as num).toDouble(),
        fatG: (row[4] as num).toDouble(),
      );
      final words = normalizedWords(description);
      if (words.isEmpty) continue;
      final index = entries.length;
      entries.add(_Entry(food, words.toSet()));
      for (final head in _headWords(description)) {
        (byHead[head] ??= []).add(index);
      }
    }
    return GenericFoodTable._(entries, byHead);
  }

  /// Reads the bundled asset's bytes: gzipped JSON.
  factory GenericFoodTable.fromGzipBytes(List<int> bytes) {
    final json = jsonDecode(utf8.decode(gzip.decode(bytes))) as List<dynamic>;
    return GenericFoodTable.fromRows(json.cast<List<Object?>>());
  }

  static const assetPath = 'assets/nutrition/usda_generic.json.gz';

  static Future<GenericFoodTable>? _bundled;

  /// The table bundled with the app, loaded once. Fails (the future errors) if
  /// the asset is missing; callers treat that as "no table".
  static Future<GenericFoodTable> loadBundled() => _bundled ??= rootBundle
      .load(assetPath)
      .then(
        (data) => GenericFoodTable.fromGzipBytes(Uint8List.sublistView(data)),
      );

  /// The best match for [name], or null when nothing clears [minRecall].
  GenericFoodMatch? match(String name) {
    final words = normalizedWords(name);
    if (words.isEmpty) return null;
    final unique = words.toSet().toList();
    final candidates = _byHead[words.first];
    if (candidates == null) return null;

    _Entry? best;
    var bestScore = -1.0;
    var bestRecall = 0.0;
    for (final index in candidates) {
      final entry = _entries[index];
      final matched = unique.where(entry.words.contains).toList();
      final recall = matched.length / unique.length;
      if (recall < minRecall) continue;
      final extra = entry.words.difference(unique.toSet());
      // The name decides first (recall). The rest only orders the entries that
      // match it equally well: the food whose description starts with the
      // name's head, says the name's words early, and says nothing that makes
      // it a different product.
      final score =
          recall +
          (entry.first == words.first ? 0.15 : 0) +
          0.05 * matched.where(entry.firstTwoParts.contains).length -
          0.1 * extra.where(_processed.contains).length -
          0.1 * extra.where(_variants.contains).length -
          0.02 * extra.where(entry.firstPart.contains).length -
          0.005 * extra.length;
      if (score > bestScore) {
        best = entry;
        bestScore = score;
        bestRecall = recall;
      }
    }
    return best == null ? null : GenericFoodMatch(best.food, bestRecall);
  }
}

class _Entry {
  final GenericFood food;
  final Set<String> words;

  /// The description's first word, its first part and its first two parts.
  final String first;
  final Set<String> firstPart;
  final Set<String> firstTwoParts;

  _Entry(this.food, this.words)
    : first = normalizedWords(food.description).first,
      firstPart = normalizedWords(food.description.split(',').first).toSet(),
      firstTwoParts = _headWords(food.description);
}

/// The words of a description's first two comma-separated parts, which is
/// where USDA puts what the food is ("Butter, Clarified butter (ghee)").
Set<String> _headWords(String description) {
  final parts = description.split(',');
  return {for (final part in parts.take(2)) ...normalizedWords(part)};
}
