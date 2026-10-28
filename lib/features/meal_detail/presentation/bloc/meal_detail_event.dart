part of 'meal_detail_bloc.dart';

abstract class MealDetailEvent extends Equatable {
  const MealDetailEvent();
}

class UpdateKcalEvent extends MealDetailEvent {
  final MealEntity meal;
  final double? totalCarbs;
  final double? totalFat;
  final double? totalProtein;
  final String? totalQuantity;
  final String? selectedUnit;

  const UpdateKcalEvent({
    required this.meal,
    this.totalCarbs,
    this.totalFat,
    this.totalProtein,
    this.totalQuantity,
    this.selectedUnit,
  });

  @override
  List<Object?> get props => [
        meal,
        totalCarbs,
        totalFat,
        totalProtein,
        totalQuantity,
        selectedUnit,
      ];
}

class LoadDailyTotalsEvent extends MealDetailEvent {
  final DateTime day;

  const LoadDailyTotalsEvent(this.day);

  @override
  List<Object?> get props => [day];
}

/// Fetch the full product record for a thin Open Food Facts search result so
/// the detail view can show serving options and micronutrients. A no-op for
/// non-OFF meals, already-detailed meals, or meals without a code.
class HydrateMealEvent extends MealDetailEvent {
  final MealEntity meal;

  const HydrateMealEvent(this.meal);

  @override
  List<Object?> get props => [meal];
}

/// Reads the servings the user saved for [meal], so the sheet can list them
/// after the portions the food already has.
class LoadCustomPortionsEvent extends MealDetailEvent {
  final MealEntity meal;

  const LoadCustomPortionsEvent(this.meal);

  @override
  List<Object?> get props => [meal];
}

/// Saves "[label] = [gramWeight]" as a serving of [meal]. The state then
/// names it in [MealDetailState.addedCustomPortionId] so the screen can
/// select it.
class AddCustomPortionEvent extends MealDetailEvent {
  final MealEntity meal;
  final String label;
  final double gramWeight;

  const AddCustomPortionEvent({
    required this.meal,
    required this.label,
    required this.gramWeight,
  });

  @override
  List<Object?> get props => [meal, label, gramWeight];
}

/// Deletes the saved serving [portionId] of [meal].
class DeleteCustomPortionEvent extends MealDetailEvent {
  final MealEntity meal;
  final String portionId;

  const DeleteCustomPortionEvent({required this.meal, required this.portionId});

  @override
  List<Object?> get props => [meal, portionId];
}
