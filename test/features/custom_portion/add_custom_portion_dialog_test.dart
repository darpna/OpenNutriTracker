import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/custom_portion/presentation/widgets/add_custom_portion_dialog.dart';
import 'package:opennutritracker/generated/l10n.dart';

import '../../helpers/test_l10n.dart';

void main() {
  CustomPortionInput? result;
  var closed = false;

  Future<void> openDialog(WidgetTester tester, {String unit = 'g'}) async {
    result = null;
    closed = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [S.delegate],
        supportedLocales: S.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showAddCustomPortionDialog(context, unit: unit);
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  Future<void> fill(WidgetTester tester, String name, String weight) async {
    await tester.enterText(field(l10nEn.customPortionNameLabel), name);
    await tester.enterText(field(l10nEn.customPortionWeightLabel('g')), weight);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text(l10nEn.buttonSaveLabel));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty name is rejected and the dialog stays open', (
    tester,
  ) async {
    await openDialog(tester);
    await fill(tester, '', '250');
    await save(tester);

    expect(find.text(l10nEn.customPortionNameRequired), findsOneWidget);
    expect(closed, isFalse);
    expect(find.byType(AddCustomPortionDialog), findsOneWidget);
  });

  testWidgets('a name of only spaces counts as empty', (tester) async {
    await openDialog(tester);
    await fill(tester, '   ', '250');
    await save(tester);

    expect(find.text(l10nEn.customPortionNameRequired), findsOneWidget);
    expect(closed, isFalse);
  });

  testWidgets('0 g, an empty weight and a huge weight are rejected', (
    tester,
  ) async {
    await openDialog(tester);

    await fill(tester, '1 bowl', '0');
    await save(tester);
    expect(find.text(l10nEn.customPortionWeightInvalid), findsOneWidget);

    await fill(tester, '1 bowl', '');
    await save(tester);
    expect(find.text(l10nEn.customPortionWeightInvalid), findsOneWidget);

    await fill(tester, '1 bowl', '0,00');
    await save(tester);
    expect(find.text(l10nEn.customPortionWeightInvalid), findsOneWidget);

    await fill(tester, '1 bowl', '10001');
    await save(tester);
    expect(find.text(l10nEn.customPortionWeightTooLarge), findsOneWidget);

    expect(closed, isFalse);
    expect(result, isNull);
  });

  testWidgets('both problems are shown at once', (tester) async {
    await openDialog(tester);
    await save(tester);

    expect(find.text(l10nEn.customPortionNameRequired), findsOneWidget);
    expect(find.text(l10nEn.customPortionWeightInvalid), findsOneWidget);
  });

  testWidgets('a valid name and weight come back trimmed and parsed', (
    tester,
  ) async {
    await openDialog(tester);
    await fill(tester, '  1 bowl ', '250,5');
    await save(tester);

    expect(closed, isTrue);
    expect(result!.label, '1 bowl');
    expect(result!.gramWeight, 250.5);
  });

  testWidgets('cancel returns nothing', (tester) async {
    await openDialog(tester);
    await fill(tester, '1 bowl', '250');
    await tester.tap(find.text(l10nEn.dialogCancelLabel));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('the weight field names the unit of the food', (tester) async {
    await openDialog(tester, unit: 'ml');
    expect(find.text(l10nEn.customPortionWeightLabel('ml')), findsOneWidget);
  });
}
