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

/// The one composed dish a photo was read as. Its components are the first
/// [componentCount] of [BulkAddLoadedState.rows]; whatever else was on the
/// plate follows them.
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
  /// The dish's components first, then the plate's separate foods.
  final List<BulkAddRow> rows;

  /// Set when the photo was one composed dish. Shown as a single row that
  /// expands to its components, and logged as one recipe.
  final BulkAddDish? dish;

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
    this.dish,
  });

  Iterable<BulkAddRow> get loggableRows =>
      rows.where((row) => row.willBeLogged);

  /// The dish's component rows; empty when there is no dish.
  List<BulkAddRow> get dishRows =>
      dish == null ? const [] : rows.take(dish!.componentCount).toList();

  /// The rows that are not part of the dish.
  List<BulkAddRow> get plateRows =>
      dish == null ? rows : rows.skip(dish!.componentCount).toList();

  /// What the confirm button counts: the dish is one item however many
  /// components it has, and it is there only while one of them will be logged.
  int get loggableCount =>
      plateRows.where((row) => row.willBeLogged).length +
      (dishRows.any((row) => row.willBeLogged) ? 1 : 0);

  /// Total weight of the dish components that will be logged, in grams (a
  /// millilitre counts as a gram, as the recipe maths does).
  double get dishWeightG => dishRows
      .where((row) => row.willBeLogged)
      .map((row) => row.baseAmount ?? 0)
      .fold(0.0, (sum, grams) => sum + grams);

  /// Protein, carbohydrate and fat over the same components, in grams.
  double get dishProteinG => _dishSum((row) => row.proteinG);
  double get dishCarbsG => _dishSum((row) => row.carbsG);
  double get dishFatG => _dishSum((row) => row.fatG);

  double _dishSum(double? Function(BulkAddRow) of) => dishRows
      .where((row) => row.willBeLogged)
      .map((row) => of(row) ?? 0)
      .fold(0.0, (sum, grams) => sum + grams);

  /// The dish's energy over the same components, or null when none reports one.
  double? get dishKcal {
    double? total;
    for (final row in dishRows.where((row) => row.willBeLogged)) {
      final kcal = row.kcal;
      if (kcal != null) total = (total ?? 0) + kcal;
    }
    return total;
  }

  bool get hasUnresolved => rows.any((row) => !row.isResolved);

  BulkAddLoadedState copyWith({List<BulkAddRow>? rows, BulkAddDish? dish}) =>
      BulkAddLoadedState(
        rows: rows ?? this.rows,
        parseErrors: parseErrors,
        usesImperialUnits: usesImperialUnits,
        source: source,
        modelFailure: modelFailure,
        dish: dish ?? this.dish,
      );

  @override
  List<Object?> get props => [
    rows,
    dish,
    parseErrors,
    usesImperialUnits,
    source,
    modelFailure,
  ];
}
