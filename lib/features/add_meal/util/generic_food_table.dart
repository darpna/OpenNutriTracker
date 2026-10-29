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

/// Words that describe how a food was cut or how recently it was bought, which
/// no table row is named by. Dropped from a name before it is matched, so
/// "Fresh coriander" is matched as "coriander" and "Onion, chopped" as
/// "onion".
const _modifiers = {
  'fresh',
  'freshly',
  'chopped',
  'sliced',
  'diced',
  'minced',
  'finely',
  'roughly',
  'thinly',
};

/// Words a name may carry that the table uses only for some forms of a food.
/// Kept when one of the food's rows says it ("Rice, white, cooked" against the
/// raw grain), dropped when none does ("Paneer, cooked" against a table that
/// knows paneer only one way), so the word cannot cost the match.
const _softForms = {'raw', 'cooked'};

/// Genera that turn up in a model's ingredient names as the second half of
/// "Coriander (Coriandrum sativum)" or "Turmeric, Curcuma longa". A Latin
/// binomial whose genus is one of these is dropped before matching.
const _genera = {
  'abelmoschus',
  'allium',
  'anacardium',
  'arachis',
  'bos',
  'brassica',
  'capsicum',
  'carum',
  'cicer',
  'cinnamomum',
  'citrus',
  'cocos',
  'coriandrum',
  'cucumis',
  'cucurbita',
  'cuminum',
  'curcuma',
  'daucus',
  'elettaria',
  'ferula',
  'foeniculum',
  'gallus',
  'glycine',
  'lactuca',
  'lens',
  'mangifera',
  'mentha',
  'murraya',
  'musa',
  'myristica',
  'nigella',
  'ocimum',
  'oryza',
  'ovis',
  'phaseolus',
  'piper',
  'prunus',
  'sesamum',
  'solanum',
  'spinacia',
  'sus',
  'syzygium',
  'tamarindus',
  'trigonella',
  'triticum',
  'vigna',
  'zea',
  'zingiber',
};

final _parenthetical = RegExp(r'\([^()]*\)|\[[^\[\]]*\]');
final _binomial = RegExp(r'\b([A-Z][a-z]+)\s+([a-z]+)\b');

/// [name] without what no table row is named by: anything in brackets, a
/// Latin binomial ("Coriandrum sativum"), and words for how it was cut
/// ([_modifiers]). Only for matching; the name shown is the model's.
///
/// A name that would be left empty is returned unchanged, so "Fresh" is still
/// a word to fail on rather than an empty match.
String cleanFoodName(String name) {
  var text = name.replaceAll(_parenthetical, ' ');
  text = text.replaceAllMapped(
    _binomial,
    (m) => _genera.contains(m[1]!.toLowerCase()) ? ' ' : m[0]!,
  );
  final kept = <String>[];
  for (final part in text.split(',')) {
    final words = [
      for (final word in part.trim().split(RegExp(r'\s+')))
        if (word.isNotEmpty && !_modifiers.contains(word.toLowerCase())) word,
    ];
    if (words.isNotEmpty) kept.add(words.join(' '));
  }
  final cleaned = kept.join(', ');
  return cleaned.trim().isEmpty ? name.trim() : cleaned;
}

/// The key a food is remembered by in the food-number cache: its cleaned,
/// normalised words in a fixed order, so "Rice, white" and "White rice" are
/// one food.
String foodNumberKey(String name) =>
    (normalizedWords(cleanFoodName(name)).toSet().toList()..sort()).join(' ');

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
  ///
  /// The name is cleaned first ([cleanFoodName]). [accept] can refuse a row
  /// the words would otherwise pick — the photo estimate refuses one whose
  /// energy is far from what the model said — and the best row it accepts
  /// wins instead.
  GenericFoodMatch? match(
    String name, {
    bool Function(GenericFood food)? accept,
  }) {
    var words = normalizedWords(cleanFoodName(name));
    if (words.isEmpty) return null;
    // "Cooked rice" is rice: a form word is never the head noun.
    if (words.length > 1 && _softForms.contains(words.first)) {
      words = [...words.skip(1), words.first];
    }
    final candidates = _byHead[words.first];
    if (candidates == null) return null;
    // "raw" or "cooked" that none of this food's rows says is a word the table
    // does not use for it, not a reason to miss.
    final soft = words.where(_softForms.contains).toSet();
    if (soft.isNotEmpty) {
      final unused = soft.where(
        (word) => !candidates.any((i) => _entries[i].words.contains(word)),
      );
      final drop = unused.toSet();
      if (drop.isNotEmpty) {
        final kept = words.where((w) => !drop.contains(w)).toList();
        if (kept.isNotEmpty) words = kept;
      }
    }
    final unique = words.toSet().toList();

    _Entry? best;
    var bestScore = -1.0;
    var bestRecall = 0.0;
    for (final index in candidates) {
      final entry = _entries[index];
      final matched = unique.where(entry.words.contains).toList();
      final recall = matched.length / unique.length;
      if (recall < minRecall) continue;
      if (accept != null && !accept(entry.food)) continue;
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
