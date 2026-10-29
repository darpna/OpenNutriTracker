part of 'bulk_add_bloc.dart';

abstract class BulkAddState extends Equatable {
  const BulkAddState();

  @override
  List<Object?> get props => [];
}

class BulkAddInitial extends BulkAddState {
  const BulkAddInitial();
}

/// A read is in flight: the model, the food search, or both.
///
/// [attempt] tells one wait from the next. Two loading states used to be
/// equal, so a second Search tapped mid-wait never reached the screen — and
/// the elapsed counter drawn for a server the user runs (#1148) kept counting
/// from the first tap, describing a request that was no longer the one in
/// flight. It is also what [CancelBulkReadEvent] orphans: a result landing
/// for an attempt that is no longer current is dropped rather than shown.
class BulkAddLoadingState extends BulkAddState {
  final int attempt;

  const BulkAddLoadingState({this.attempt = 0});

  @override
  List<Object?> get props => [attempt];
}

/// Resolution itself failed. Distinct from "resolved but matched nothing",
/// which is a normal outcome carried by unresolved rows.
class BulkAddErrorState extends BulkAddState {
  const BulkAddErrorState();
}

/// Which reader produced the rows on screen.
///
/// A bool would not survive the third case, and the third case is the one
/// that most needs saying out loud: rows read off a photograph rest on the
/// model having recognised the food correctly, with no typed text to check
/// it against.
enum BulkAddReadSource {
  /// The deterministic parser. Nothing to disclose — the user's own words,
  /// matched against the food database.
  parser,

  /// A model read the text the user typed.
  model,

  /// A model read a photograph.
  photo,
}

/// Why a photo could not be turned into rows.
///
/// Separate from [BulkAddErrorState] because the photo path has no
/// deterministic fallback, so its failures reach the user instead of being
/// absorbed — and each one wants different advice.
enum BulkAddPhotoError {
  /// No key stored, or the feature was switched off while the screen was
  /// open. A setting, not a fault.
  unavailable,

  /// The provider rejected the credential. "Try again later" is the wrong
  /// advice here and following it never stops being wrong.
  auth,

  /// No answer reached us (no network, a dropped connection, a timeout) —
  /// worth another attempt. A provider that answered with an error is
  /// [providerError].
  transient,

  /// The account is out of credit, or has hit a spend cap. Kept apart from
  /// [transient] because retrying never resolves it, and from [auth] because
  /// the key is fine.
  billing,

  /// The camera could not be opened, commonly because permission was denied.
  camera,

  /// The gallery could not be opened, commonly because photo access was
  /// denied.
  gallery,

  /// The photo itself could not be encoded or was too large to send.
  unreadable,

  /// The configured model cannot read images at all. Sent to settings rather
  /// than offered a retry: nothing about trying again changes the answer.
  unsupported,

  /// The app declined to send a photograph in plaintext to a public address.
  /// The fix is the destination or its scheme, not the model or the network.
  insecureDestination,

  /// The provider answered with an error that is not a bad key, no credit or
  /// an unsupported model: a rate limit, a server error, or a 400. Shown with
  /// the status and the provider's own text, since the cause is in them.
  providerError,
}

class BulkAddPhotoErrorState extends BulkAddState {
  final BulkAddPhotoError error;

  /// The provider's HTTP status, when the failure came from one.
  final int? httpStatus;

  /// The provider's error text (trimmed, key-shaped strings masked).
  final String? providerMessage;

  const BulkAddPhotoErrorState(
    this.error, {
    this.httpStatus,
    this.providerMessage,
  });

  @override
  List<Object?> get props => [error, httpStatus, providerMessage];
}

/// One composed dish a photo was read as. Its components are a run of
/// [BulkAddLoadedState.rows]: the dishes' runs come first, in order, and
/// whatever else was on the plate follows them.
class BulkAddDish extends Equatable {
  final String name;
  final int componentCount;
  final bool expanded;

  /// The recipe the dish was read as, with the model's confidence and
  /// assumptions; null for a dish that did not come from a photo estimate.
  final PhotoRecipeEstimate? estimate;

  const BulkAddDish({
    required this.name,
    required this.componentCount,
    this.expanded = false,
    this.estimate,
  });

  BulkAddDish copyWith({bool? expanded}) => BulkAddDish(
    name: name,
    componentCount: componentCount,
    expanded: expanded ?? this.expanded,
    estimate: estimate,
  );

  @override
  List<Object?> get props => [name, componentCount, expanded, estimate];
}

class BulkAddLoadedState extends BulkAddState {
  /// Every dish's components first, dish by dish, then the plate's separate
  /// foods.
  final List<BulkAddRow> rows;

  /// The composed dishes on the plate, in the order their components appear
  /// in [rows]. Each is shown as a single row that expands to its components,
  /// and logged as one recipe.
  final List<BulkAddDish> dishes;

  /// The whole photo estimate, when the rows came from one: which model
  /// answered, and every dish's numbers before the user edited anything.
  final PhotoMealEstimate? photoEstimate;

  /// Per-segment complaints from the parser, carrying the item number and
  /// the reason rather than a message — the string is built at the render
  /// site so it can be localized (#631). Shown alongside the rows rather
  /// than replacing them: a line with one bad segment and three good ones
  /// should still log the three.
  final List<MealTextParseError> parseErrors;

  final bool usesImperialUnits;

  /// What produced these rows. Surfaced so the user can see what they are
  /// being asked to confirm.
  final BulkAddReadSource source;

  /// Set when the model was asked, could not answer, and the reason will
  /// still be true tomorrow. The rows below are the parser's — this says why
  /// the better reader was not used, rather than withholding anything.
  final MealTextModelFailure? modelFailure;

  const BulkAddLoadedState({
    required this.rows,
    required this.parseErrors,
    required this.usesImperialUnits,
    this.source = BulkAddReadSource.parser,
    this.modelFailure,
    this.dishes = const [],
    this.photoEstimate,
  });

  Iterable<BulkAddRow> get loggableRows =>
      rows.where((row) => row.willBeLogged);

  /// Index into [rows] of dish [dish]'s first component.
  int dishStart(int dish) => dishes
      .take(dish)
      .fold(0, (start, d) => start + d.componentCount);

  /// How many leading rows belong to a dish.
  int get dishComponentCount => dishStart(dishes.length);

  /// The dish row [index] is a component of, or null for a plate row.
  int? dishOfRow(int index) {
    var start = 0;
    for (var d = 0; d < dishes.length; d++) {
      final end = start + dishes[d].componentCount;
      if (index >= start && index < end) return d;
      start = end;
    }
    return null;
  }

  /// Dish [dish]'s component rows.
  List<BulkAddRow> dishRows(int dish) => rows
      .skip(dishStart(dish))
      .take(dishes[dish].componentCount)
      .toList();

  /// The rows that are not part of a dish.
  List<BulkAddRow> get plateRows => rows.skip(dishComponentCount).toList();

  /// What the confirm button counts: each dish is one item however many
  /// components it has, and it is there only while one of them will be logged.
  int get loggableCount =>
      plateRows.where((row) => row.willBeLogged).length +
      [
        for (var d = 0; d < dishes.length; d++)
          if (dishRows(d).any((row) => row.willBeLogged)) d,
      ].length;

  /// Total weight of dish [dish]'s components that will be logged, in grams
  /// (a millilitre counts as a gram, as the recipe maths does).
  double dishWeightG(int dish) =>
      _dishSum(dish, (row) => row.baseAmount);

  /// Protein, carbohydrate and fat over the same components, in grams.
  double dishProteinG(int dish) => _dishSum(dish, (row) => row.proteinG);
  double dishCarbsG(int dish) => _dishSum(dish, (row) => row.carbsG);
  double dishFatG(int dish) => _dishSum(dish, (row) => row.fatG);

  double _dishSum(int dish, double? Function(BulkAddRow) of) =>
      dishRows(dish)
          .where((row) => row.willBeLogged)
          .map((row) => of(row) ?? 0)
          .fold(0.0, (sum, grams) => sum + grams);

  /// Dish [dish]'s energy over the same components, or null when none reports
  /// one.
  double? dishKcal(int dish) {
    double? total;
    for (final row in dishRows(dish).where((row) => row.willBeLogged)) {
      final kcal = row.kcal;
      if (kcal != null) total = (total ?? 0) + kcal;
    }
    return total;
  }

  bool get hasUnresolved => rows.any((row) => !row.isResolved);

  BulkAddLoadedState copyWith({
    List<BulkAddRow>? rows,
    List<BulkAddDish>? dishes,
  }) => BulkAddLoadedState(
    rows: rows ?? this.rows,
    parseErrors: parseErrors,
    usesImperialUnits: usesImperialUnits,
    source: source,
    modelFailure: modelFailure,
    dishes: dishes ?? this.dishes,
    photoEstimate: photoEstimate,
  );

  @override
  List<Object?> get props => [
    rows,
    dishes,
    photoEstimate,
    parseErrors,
    usesImperialUnits,
    source,
    modelFailure,
  ];
}
