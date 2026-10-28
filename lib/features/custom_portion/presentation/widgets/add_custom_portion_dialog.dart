import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/custom_portion_validator.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// What the "Add serving" dialog returns: a validated name and weight.
class CustomPortionInput {
  const CustomPortionInput({required this.label, required this.gramWeight});

  final String label;
  final double gramWeight;
}

/// Asks for a serving's name and weight, in [unit] (`g` or `ml`).
///
/// Returns null when dismissed. The result is already valid, so callers can
/// pass it straight to `AddCustomPortionUsecase`.
Future<CustomPortionInput?> showAddCustomPortionDialog(
  BuildContext context, {
  required String unit,
}) => showDialog<CustomPortionInput>(
  context: context,
  builder: (_) => AddCustomPortionDialog(unit: unit),
);

class AddCustomPortionDialog extends StatefulWidget {
  const AddCustomPortionDialog({super.key, required this.unit});

  /// The base unit of the food, shown in the weight field's label.
  final String unit;

  @override
  State<AddCustomPortionDialog> createState() => _AddCustomPortionDialogState();
}

class _AddCustomPortionDialogState extends State<AddCustomPortionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _weightController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  String? _validateName(String? value) =>
      switch (validateCustomPortionName(value ?? '')) {
        null => null,
        CustomPortionError.nameTooLong =>
          S.of(context).customPortionNameTooLong(customPortionMaxNameLength),
        _ => S.of(context).customPortionNameRequired,
      };

  String? _validateWeight(String? value) => switch (validateCustomPortionWeight(
    parseCustomPortionWeight(value ?? ''),
  )) {
    null => null,
    CustomPortionError.weightTooLarge =>
      S.of(context).customPortionWeightTooLarge,
    _ => S.of(context).customPortionWeightInvalid,
  };

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      CustomPortionInput(
        label: _nameController.text.trim(),
        gramWeight: parseCustomPortionWeight(_weightController.text)!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.of(context).customPortionAddAction),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              identifier: 'custom-portion-name',
              child: TextFormField(
                controller: _nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: S.of(context).customPortionNameLabel,
                  hintText: S.of(context).customPortionNameHint,
                ),
                validator: _validateName,
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              identifier: 'custom-portion-weight',
              child: TextFormField(
                controller: _weightController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    RegExp(r'^\d*([.,]\d{0,2})?$'),
                  ),
                ],
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: S
                      .of(context)
                      .customPortionWeightLabel(widget.unit),
                ),
                validator: _validateWeight,
                onFieldSubmitted: (_) => _save(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.of(context).dialogCancelLabel),
        ),
        TextButton(
          onPressed: _save,
          child: Text(S.of(context).buttonSaveLabel),
        ),
      ],
    );
  }
}

/// Asks before deleting the saved serving named [label]. True on confirm.
Future<bool> confirmDeleteCustomPortion(
  BuildContext context,
  String label,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.of(context).customPortionDeleteTitle),
      content: Text(S.of(context).customPortionDeleteBody(label)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(S.of(context).dialogCancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(S.of(context).dialogDeleteLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
