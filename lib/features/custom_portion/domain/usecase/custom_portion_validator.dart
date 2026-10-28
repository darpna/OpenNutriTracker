/// Why a serving the user typed cannot be saved.
enum CustomPortionError {
  emptyName,
  nameTooLong,
  invalidWeight,
  weightTooLarge,
}

const customPortionMaxNameLength = 40;

/// The same ceiling the meal-detail sheet puts on a quantity, so one serving
/// can never weigh more than the most a single entry may hold.
const customPortionMaxWeight = 10000.0;

/// Parses the weight field, accepting `,` as the decimal mark like every
/// other amount field. Null when it is not a number.
double? parseCustomPortionWeight(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

CustomPortionError? validateCustomPortionName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return CustomPortionError.emptyName;
  if (trimmed.length > customPortionMaxNameLength) {
    return CustomPortionError.nameTooLong;
  }
  return null;
}

CustomPortionError? validateCustomPortionWeight(double? weight) {
  if (weight == null || !weight.isFinite || weight <= 0) {
    return CustomPortionError.invalidWeight;
  }
  if (weight > customPortionMaxWeight) return CustomPortionError.weightTooLarge;
  return null;
}
