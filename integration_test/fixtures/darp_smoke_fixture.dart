import 'dart:convert';

/// Synthetic export bundle for `darp_smoke_test.dart`: the JSON members of a
/// Settings > Export / Import App Data zip (schema in docs/export-format.md),
/// hand-written, no user data. It lives in Dart rather than a `.json` asset
/// because the test runs on the emulator and cannot read repo files, and
/// bundling an asset would mean touching pubspec.yaml.
///
/// Dates are built from [today] so the entries land on the day the diary
/// opens on; everything else is fixed so the assertions can pin exact values.
class SmokeFixture {
  /// Seeded intakes dated today, as (name, kcal) — all logged as 100 g, so the
  /// card shows exactly the per-100 g energy.
  static const todayIntakes = <(String, int)>[
    ('Smoke Oats', 350),
    ('Smoke Chicken Rice', 620),
    ('Smoke Lentil Soup', 410),
    ('Smoke Almonds', 180),
  ];

  static const yesterdayIntake = ('Smoke Yesterday Toast', 240);

  static const intakeCount = 5;
  static const trackedDayCount = 2;
  static const activityCount = 1;

  /// File name inside the zip -> JSON body.
  static Map<String, String> files(DateTime today) {
    final day = DateTime(today.year, today.month, today.day);
    final yesterday = day.subtract(const Duration(days: 1));
    const types = ['breakfast', 'lunch', 'dinner', 'snack'];
    const hours = [8, 12, 19, 16];

    final intakes = <Map<String, Object?>>[
      for (var i = 0; i < todayIntakes.length; i++)
        _intake(
          'smoke-intake-$i',
          todayIntakes[i].$1,
          todayIntakes[i].$2,
          types[i],
          DateTime(day.year, day.month, day.day, hours[i]),
        ),
      _intake(
        'smoke-intake-yesterday',
        yesterdayIntake.$1,
        yesterdayIntake.$2,
        'breakfast',
        DateTime(yesterday.year, yesterday.month, yesterday.day, 8),
      ),
    ];

    final todayKcal = todayIntakes.fold<int>(0, (sum, e) => sum + e.$2);
    final trackedDays = [
      _trackedDay(day, todayKcal),
      _trackedDay(yesterday, yesterdayIntake.$2),
    ];

    final activities = [
      {
        'id': 'smoke-activity-0',
        'duration': 30.0,
        'burnedKcal': 250.0,
        'date': DateTime(day.year, day.month, day.day, 17).toIso8601String(),
        'physicalActivityDBO': {
          'code': '01015',
          'specificActivity': 'Smoke Cycling',
          'description': 'Smoke Cycling, general',
          'mets': 7.5,
          'tags': <String>[],
          'type': 'bicycling',
        },
      },
    ];

    return {
      'user_intake.json': jsonEncode(intakes),
      'user_tracked_day.json': jsonEncode(trackedDays),
      'user_activity.json': jsonEncode(activities),
    };
  }

  static Map<String, Object?> _intake(
    String id,
    String name,
    int kcal,
    String type,
    DateTime at,
  ) => {
    'id': id,
    'unit': 'g',
    'amount': 100.0,
    'type': type,
    'dateTime': at.toIso8601String(),
    'meal': {
      'code': 'smoke-$id',
      'name': name,
      'brands': null,
      'thumbnailImageUrl': null,
      'mainImageUrl': null,
      'url': null,
      'mealQuantity': '100',
      'mealUnit': 'g',
      'servingQuantity': null,
      'servingUnit': 'g',
      'servingSize': '',
      'source': 'custom',
      'nutriments': {
        'energyKcal100': kcal.toDouble(),
        'carbohydrates100': 40.0,
        'fat100': 10.0,
        'proteins100': 15.0,
        'sugars100': null,
        'saturatedFat100': null,
        'fiber100': null,
      },
      'dataVersion': 1,
    },
  };

  static Map<String, Object?> _trackedDay(DateTime day, int kcal) => {
    'day': day.toIso8601String(),
    'calorieGoal': 2200.0,
    'caloriesTracked': kcal.toDouble(),
    'carbsGoal': 275.0,
    'carbsTracked': 100.0,
    'fatGoal': 73.0,
    'fatTracked': 25.0,
    'proteinGoal': 110.0,
    'proteinTracked': 40.0,
  };
}
