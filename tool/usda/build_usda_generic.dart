// Builds assets/nutrition/usda_generic.json.gz from USDA FoodData Central.
//
//   dart run tool/usda/build_usda_generic.dart \
//     --out assets/nutrition/usda_generic.json.gz \
//     <dir with food.csv + food_nutrient.csv> [<another such dir> ...]
//
// Inputs are the official CSV downloads (public domain, CC0), unzipped:
//   SR Legacy:        https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
//   Foundation Foods: https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_csv_2025-04-24.zip
// Only `sr_legacy_food` and `foundation_food` rows are kept; branded foods and
// the sample / acquisition rows Foundation Foods ships alongside are skipped.
//
// The asset is a gzipped JSON array of [description, kcal, protein_g, carbs_g,
// fat_g] per 100 g, in input order, rounded to one decimal. Energy is nutrient
// 1008 (SR Legacy), else the Atwater specific (2048) or general (2047) factor
// (Foundation), else 4/4/9 from the macros.
//
// A pure Dart script with no dependencies, so it runs anywhere `dart` does.
import 'dart:convert';
import 'dart:io';

const _kept = {'sr_legacy_food', 'foundation_food'};

const _protein = '1003';
const _fat = '1004';
const _carbs = '1005';
const _energy = ['1008', '2048', '2047'];

void main(List<String> args) {
  String? out;
  final dirs = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out') {
      out = args[++i];
    } else {
      dirs.add(args[i]);
    }
  }
  if (out == null || dirs.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/usda/build_usda_generic.dart --out <file.json.gz> <csv dir>...',
    );
    exit(64);
  }

  final rows = <List<Object>>[];
  final seen = <String>{};
  for (final dir in dirs) {
    final foods = _foods('$dir/food.csv');
    final nutrients = _nutrients('$dir/food_nutrient.csv', foods.keys.toSet());
    var added = 0;
    for (final entry in foods.entries) {
      final n = nutrients[entry.key];
      if (n == null) continue;
      final protein = n[_protein];
      final fat = n[_fat];
      final carbs = n[_carbs];
      if (protein == null || fat == null || carbs == null) continue;
      double? kcal;
      for (final id in _energy) {
        kcal ??= n[id];
      }
      kcal ??= 4 * protein + 4 * carbs + 9 * fat;
      final description = entry.value;
      if (!seen.add(description)) continue; // first source wins
      rows.add([
        description,
        _r(kcal),
        _r(protein),
        _r(carbs),
        _r(fat),
      ]);
      added++;
    }
    stdout.writeln('$dir: $added foods');
  }

  final bytes = gzip.encode(utf8.encode(jsonEncode(rows)));
  File(out).createSync(recursive: true);
  File(out).writeAsBytesSync(bytes);
  stdout.writeln('wrote ${rows.length} foods, ${bytes.length} bytes to $out');
}

double _r(double v) => double.parse(v.toStringAsFixed(1));

Map<String, String> _foods(String path) {
  final foods = <String, String>{};
  var header = <String>[];
  for (final row in _csv(path)) {
    if (header.isEmpty) {
      header = row;
      continue;
    }
    final record = _record(header, row);
    if (_kept.contains(record['data_type'])) {
      foods[record['fdc_id']!] = record['description']!;
    }
  }
  return foods;
}

Map<String, Map<String, double>> _nutrients(String path, Set<String> wanted) {
  final result = <String, Map<String, double>>{};
  const ids = {_protein, _fat, _carbs, '1008', '2048', '2047'};
  var header = <String>[];
  for (final row in _csv(path)) {
    if (header.isEmpty) {
      header = row;
      continue;
    }
    final record = _record(header, row);
    final id = record['nutrient_id']!;
    final food = record['fdc_id']!;
    if (!ids.contains(id) || !wanted.contains(food)) continue;
    final amount = double.tryParse(record['amount'] ?? '');
    if (amount == null) continue;
    (result[food] ??= {})[id] = amount;
  }
  return result;
}

Map<String, String> _record(List<String> header, List<String> row) => {
  for (var i = 0; i < header.length && i < row.length; i++) header[i]: row[i],
};

/// Rows of a CSV file with quoted fields (and doubled quotes inside them).
Iterable<List<String>> _csv(String path) sync* {
  for (final line in File(path).readAsLinesSync(encoding: utf8)) {
    if (line.isEmpty) continue;
    final fields = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buffer.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          buffer.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == ',') {
        fields.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(c);
      }
    }
    fields.add(buffer.toString());
    yield fields;
  }
}
