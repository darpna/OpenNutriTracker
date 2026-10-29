import 'dart:async';
import 'dart:math' as math;

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logging/logging.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/domain/entity/intake_type_entity.dart';
import 'package:opennutritracker/core/domain/entity/recipe_ingredient_entity.dart';
import 'package:opennutritracker/core/utils/calc/unit_calc.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/run_ai_endpoint_probe_usecase.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/core/utils/energy_display.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_portion_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart'
    show mealPhotoCaptionMaxChars;
import 'package:opennutritracker/features/add_meal/domain/photo_estimate.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/save_photo_dish_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_text_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_encoder.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_preparer.dart';
import 'package:opennutritracker/features/add_meal/util/portion_label.dart';
import 'package:opennutritracker/features/add_meal/util/portion_unit.dart';
import 'package:opennutritracker/features/custom_portion/domain/usecase/add_custom_portion_usecase.dart';
import 'package:opennutritracker/features/custom_portion/presentation/widgets/add_custom_portion_dialog.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';
import 'package:opennutritracker/features/add_meal/presentation/widgets/own_server_wait_indicator.dart';
import 'package:opennutritracker/features/add_meal/presentation/widgets/quick_add_bottom_sheet.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/calendar_day_bloc.dart';
import 'package:opennutritracker/features/diary/presentation/bloc/diary_bloc.dart';
import 'package:opennutritracker/features/home/presentation/bloc/home_bloc.dart';
import 'package:opennutritracker/features/meal_detail/presentation/bloc/meal_detail_bloc.dart';
import 'package:opennutritracker/features/meal_detail/util/meal_quantity_converter.dart';
import 'package:opennutritracker/features/settings/settings_screen.dart';
import 'package:opennutritracker/generated/l10n.dart';

class BulkAddScreenArguments {
  final IntakeTypeEntity intakeTypeEntity;
  final DateTime day;
  final bool usesImperialUnits;

  const BulkAddScreenArguments(
    this.intakeTypeEntity,
    this.day,
    this.usesImperialUnits,
  );
}

/// Type a whole meal, confirm what it matched, log it in one go.
///
/// **The confirmation step is not optional.** It exists so nothing reaches
/// the diary that the user has not looked at. Tier 0 resolves everything
/// against the food database and invents no numbers, so today that is a
/// correctness concern; once a model tier lands it also becomes the human
/// review that AI Act Art. 50(4) and both providers' usage policies expect.
/// See #599 before removing it.
class BulkAddScreen extends StatefulWidget {
  const BulkAddScreen({super.key});

  @override
  State<BulkAddScreen> createState() => _BulkAddScreenState();
}

class _BulkAddScreenState extends State<BulkAddScreen> {
  /// The unit picker's value for its "Add serving" entry. An action, never a
  /// unit: it is intercepted before it reaches the bloc.
  static const _addServingValue = 'custom-portion-add';

  /// A saved serving is the user's own words, so unlike a database portion it
  /// is not trimmed to a household word; it is only kept short enough not to
  /// blow the row out (#824).
  static const _maxCustomLabelChars = 24;

  final _log = Logger('BulkAddScreen');
  final _bloc = locator<BulkAddBloc>();
  final _textController = TextEditingController();

  /// One controller per row, keyed by row index and rebuilt whenever a new
  /// parse produces a different set of rows.
  final _amountControllers = <int, TextEditingController>{};

  /// What the last submit attempt refused, keyed by index into
  /// `BulkAddLoadedState.rows`.
  ///
  /// Held here rather than derived in `build` because a row is only wrong
  /// once it has been asked for: `BulkAddRow.amountText` is text so that a
  /// field mid-edit ("", "1,") is not marked while it is being typed. The
  /// map is what makes every bad row visible at once — the check refuses the
  /// whole batch, so reporting one at a time asks the user to resubmit for
  /// each. #1013.
  final _quantityErrors = <int, BulkAddQuantityError>{};

  /// Whether the photo action is offered at all. Held rather than resolved
  /// inside `build` — a future rebuilt on every frame would re-read the
  /// keystore continuously for an answer that changes only when the user
  /// visits settings. It is re-read when they come back from there, and only
  /// then; see [_openSettings].
  /// **Both halves are load-bearing, and neither implies the other.**
  ///
  /// Found on a Pixel 6: with a server the user runs configured, the feature
  /// *is* enabled, so the camera icon appeared — and did nothing, because
  /// nothing had established that the model on the other end can see. A
  /// button that is present and inert is worse than one that is absent.
  ///
  /// The destination alone is not the answer either. It resolves for an
  /// install that has never opened settings: nothing stored reads as
  /// Anthropic (#688), and an absent model id falls back to the list's first
  /// entry — so gating on it alone offered the camera to every user with no
  /// key at all, and to every user who had deliberately switched the feature
  /// off.
  late Future<bool> _photoAvailable = _resolvePhotoAvailable();

  Future<bool> _resolvePhotoAvailable() async {
    if (!await locator<AiCredentialStorage>().isEnabled()) return false;
    return await _photoDestination != null;
  }

  /// Whether to offer the model at all, for someone who has never set it up.
  ///
  /// Asked of *every* provider rather than the active one. `readSummary`'s
  /// `configured` speaks only for whichever provider is selected, so a user
  /// holding a key for one of the other three would be invited to set up
  /// something they set up last week — an app that does not know its own
  /// configuration.
  ///
  /// Deliberately **not** gated on `isEnabled`. A user who paused the feature
  /// has not failed to discover it, and this line exists for discovery. The
  /// rule is one sentence: it shows only for someone who has configured
  /// nothing. #844.
  late Future<bool> _modelUnknown = _resolveModelUnknown();

  Future<bool> _resolveModelUnknown() async {
    return !await locator<AiCredentialStorage>().hasAnyUsableProvider();
  }

  /// Where a photo would actually go, **and the name the sheet gives it**.
  ///
  /// The sheet below is the last moment the user can decline, so it has to
  /// name the real destination — it named Anthropic unconditionally until a
  /// Pixel 6 showed it saying so while OpenRouter was selected.
  ///
  /// The name is one field rather than two because there is one question:
  /// *who is at the far end?* For the three providers reached at a
  /// compiled-in endpoint that is a company, taken from the curated model's
  /// [AiModel.servedBy]; for a server the user runs there is no company to
  /// name and the only honest answer is **the address they configured**,
  /// which is what #736 settled and what #781 makes this record able to
  /// express. Two of the four sentences carry the name inside themselves
  /// rather than as a placeholder, which does not make the field less true
  /// for them.
  ///
  /// Deliberately not `readSelection()`: that carries the API key, and
  /// nothing in the widget layer has any business holding it.
  /// Null when the stored provider is a name this build does not know. The
  /// sheet cannot name a destination it cannot identify, so it does not open
  /// — the same outcome as a provider with no key, and the point of #753.
  late Future<({AiProvider provider, String name})?> _photoDestination =
      _resolvePhotoDestination();

  Future<({AiProvider provider, String name})?>
  _resolvePhotoDestination() async {
    final storage = locator<AiCredentialStorage>();
    final provider = await storage.activeProvider();
    if (provider == null) return null;
    if (provider == AiProvider.ownServer) {
      return await _ownServerDestination(storage);
    }
    final model = AiModelCatalogue.resolve(
      provider,
      await storage.readModel(provider: provider),
    );
    if (model == null) return null;
    return (provider: provider, name: model.servedBy);
  }

  /// A server the user runs, **only once a photo probe has passed against the
  /// pair currently configured** — and null otherwise.
  ///
  /// The stored pass is the whole gate (#735). There is no curated list here
  /// and no behavioural screen the project can run against a machine it has
  /// never seen, so the app's own setup-time test is what stands in for one;
  /// and unlike the text path there is nothing underneath a photo to fall
  /// back to, so offering the camera to a model that cannot see is offering a
  /// dead end. [AiCredentialStorage.writeEndpoint] and
  /// [AiCredentialStorage.writeModel] each discard the record when their
  /// value changes, so a pass read here can only describe the address and
  /// model in use right now.
  ///
  /// A missing host is a second, independent null: the sheet's whole job for
  /// this provider is to say the address out loud, and it cannot do that from
  /// text that is not one.
  Future<({AiProvider provider, String name})?> _ownServerDestination(
    AiCredentialStorage storage,
  ) async {
    const provider = AiProvider.ownServer;
    final probe = await storage.readProbe(provider: provider);
    if (probe.photo != AiCapability.passed) return null;
    final endpoint = await storage.readEndpoint(provider: provider);
    if (endpoint == null) return null;
    final host = AiCredentialStorage.displayHost(endpoint);
    if (host == null) return null;
    return (provider: provider, name: host);
  }

  /// Whether a read from this screen waits on a server the user runs.
  ///
  /// Decides which loading state is drawn. The bloc cannot say: it hands the
  /// line to `ReadMealTextUseCase`, which reads the selection itself and
  /// never reports which provider it chose — and the loading state is
  /// emitted *before* that read, deliberately, so a screen that does nothing
  /// for two seconds does not read as broken. Asked of the keystore here
  /// instead, in the same way and for the same reasons as the answers above:
  /// once, and again after Settings, which is the only place it can change.
  ///
  /// `enabled` and not only the provider, because a paused feature takes the
  /// parser path and answers at once — a two-minute wait drawn for that
  /// would describe a request never sent. Hosted providers keep the bare
  /// spinner; they answer in seconds and the sentence about a model loading
  /// would be noise there (#1148).
  late Future<bool> _waitsOnOwnServer = _resolveWaitsOnOwnServer();

  Future<bool> _resolveWaitsOnOwnServer() async {
    final summary = await locator<AiCredentialStorage>().readSummary();
    return summary.enabled && summary.provider == AiProvider.ownServer;
  }

  late BulkAddScreenArguments _args;
  bool _submitting = false;

  /// Opens settings, and re-reads the three answers above once it pops.
  ///
  /// Every route out of this screen that can change them comes through here,
  /// which is what makes "resolved once" safe. Without it the first run of
  /// the feature ends with the feature missing: a new user follows the hint
  /// below, configures a provider, comes back — and the camera is still
  /// hidden, because the screen is still holding the answers it computed
  /// before they left. #992.
  ///
  /// Re-read on the pop rather than on every rebuild: the keystore is the
  /// only thing that can have changed, and only a visit to settings can have
  /// changed it.
  Future<void> _openSettings({SettingsScreenArguments? arguments}) async {
    await Navigator.of(
      context,
    ).pushNamed(NavigationOptions.settingsRoute, arguments: arguments);
    if (!mounted) return;
    _resolveAiAnswers();
    await _resolveAgainWhenProbeLands();
  }

  void _resolveAiAnswers() {
    setState(() {
      // Destination first: the availability answer awaits this field.
      _photoDestination = _resolvePhotoDestination();
      _photoAvailable = _resolvePhotoAvailable();
      _modelUnknown = _resolveModelUnknown();
      _waitsOnOwnServer = _resolveWaitsOnOwnServer();
    });
  }

  /// A second trigger, for the one answer that is not ready when the user
  /// comes back. #1089.
  ///
  /// Saving an own-server address starts a capability probe **without
  /// awaiting it**, and it takes long enough that returning promptly reads
  /// the verdict as `unknown`. `_ownServerDestination` requires
  /// `photo == passed`, so the camera stays hidden — and the route pop was
  /// the only thing that would have re-read it, and has already happened.
  ///
  /// The waiting itself is deliberate and stays: the camera is offered only
  /// once a photograph has actually been read (#735). What was missing is
  /// that nothing told the screen the verdict had arrived.
  ///
  /// Own-server only, because it is the only provider whose availability
  /// depends on a probe. `current` is null between one probe finishing and
  /// its replacement registering — two keystore reads wide, documented on
  /// the runner — and this returns rather than polling: the answer it would
  /// have waited for is already stored, so the re-resolve above read it.
  Future<void> _resolveAgainWhenProbeLands() async {
    const provider = AiProvider.ownServer;
    if (await locator<AiCredentialStorage>().activeProvider() != provider) {
      return;
    }

    final running = locator<AiEndpointProbeRunner>().current(provider);
    if (running == null) return;

    await running;
    if (!mounted) return;
    _resolveAiAnswers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _args =
        ModalRoute.of(context)!.settings.arguments as BulkAddScreenArguments;
  }

  @override
  void dispose() {
    // registerFactory hands out a new instance per navigation, so this
    // screen owns it and has to close it.
    _bloc.close();
    _textController.dispose();
    for (final controller in _amountControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).bulkAddTitle),
        actions: [
          // Only offered when the user has a key enabled. There is no
          // offline way to read a photo, so showing the action to everyone
          // would advertise a button that can only ever apologise.
          FutureBuilder<bool>(
            future: _photoAvailable,
            builder: (context, snapshot) => snapshot.data == true
                ? Semantics(
                    identifier: 'bulk-add-photo',
                    child: IconButton(
                      onPressed: _onPhotoPressed,
                      icon: const Icon(Icons.photo_camera_rounded),
                      tooltip: S.of(context).bulkAddPhotoLabel,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: SafeArea(
        child: BlocBuilder<BulkAddBloc, BulkAddState>(
          bloc: _bloc,
          builder: (context, state) => LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                // The **field** is bounded, not the block. At 2x on a 320dp
                // screen the entry block measured 388px — a four-line field
                // plus a full-height button — against about 595px of body,
                // and with the submit bar's 192 that left the rows nothing
                // and overflowed by 14px. #820.
                //
                // Capping the whole block was tried first and is worse: the
                // Search button falls below the fold inside the scroll view,
                // so the primary action of the screen has to be scrolled to.
                // Bounding the field alone keeps the button where it is.
                //
                // A ceiling rather than fewer `maxLines`: shrinking the field
                // at large text scales would take multi-line entry away from
                // exactly the users who need the biggest text, on a screen
                // that exists for typing several items at once.
                _buildInput(
                  context,
                  maxFieldHeight: constraints.maxHeight * 0.3,
                ),
                const Divider(height: 1),
                Expanded(child: _buildBody(context, state)),
                if (state is BulkAddLoadedState)
                  _buildSubmitBar(context, state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Puts the hint above [body] without letting it push anything off screen.
  ///
  /// It lives in the body rather than in the entry block above, which is
  /// fixed: adding a standing line there overflowed the column by 184px at 2x
  /// on a 320dp screen, the same defect #820 fixed and the same one #824
  /// uncovered under it. This region is the one that can give ground.
  Widget _withModelHint(BuildContext context, Widget body) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _buildModelHint(context),
      Expanded(child: body),
    ],
  );

  /// The line that says a model could read this, for a user who has never
  /// configured one.
  ///
  /// It names the API key requirement before the tap. The app ships no model,
  /// so a reader who follows this without knowing that lands in a third-party
  /// signup nothing warned them about — the qualifier is what keeps a
  /// standing offer from being a bait.
  ///
  /// It carries the same Experimental marker every other AI surface carries.
  /// This is the most-seen of them, and marking the quiet surfaces while
  /// leaving the loudest one bare would invert the emphasis.
  ///
  /// It says nothing about where nutrition values come from. A model may
  /// never produce them, and that guarantee is reassurance rather than
  /// something that changes whether this tap leads anywhere — it belongs on
  /// the agreement, which is where it is.
  Widget _buildModelHint(BuildContext context) => FutureBuilder<bool>(
    future: _modelUnknown,
    builder: (context, snapshot) {
      // Nothing until the keystore read lands, and nothing for anyone who has
      // configured a provider. A line that appeared and then vanished would
      // resize the screen under someone already typing.
      if (snapshot.data != true) return const SizedBox.shrink();
      final s = S.of(context);
      final theme = Theme.of(context);
      return Semantics(
        identifier: 'bulk-add-model-hint',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            // Asks for the AI dialog by name, the same way the failure
            // notices below have since #852. Plain Settings opens with the
            // AI row several category groups down, and of this screen's two
            // audiences the one reading this hint is the one that knows
            // least about where it is going — sending it the longer way
            // round was exactly backwards. #992.
            onTap: () => _openSettings(
              arguments: const SettingsScreenArguments(openAiAssist: true),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s.bulkAddModelHintLabel} · '
                          '${s.aiAssistExperimentalLabel}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          s.bulkAddModelHintKeyLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _buildInput(
    BuildContext context, {
    required double maxFieldHeight,
  }) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Scrolls past its ceiling rather than being clipped: what is typed
        // must stay reachable, and at ordinary text sizes four lines are far
        // below this so nothing changes.
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxFieldHeight),
          child: Semantics(
            identifier: 'bulk-add-input',
            child: TextField(
              controller: _textController,
              minLines: 2,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: S.of(context).bulkAddInputHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          identifier: 'bulk-add-parse',
          child: FilledButton.icon(
            onPressed: _onParsePressed,
            icon: const Icon(Icons.search),
            label: Text(S.of(context).bulkAddParseLabel),
          ),
        ),
      ],
    ),
  );

  Widget _buildBody(BuildContext context, BulkAddState state) {
    if (state is BulkAddLoadingState) {
      return FutureBuilder<bool>(
        future: _waitsOnOwnServer,
        // The bare spinner until the keystore answers, and for good on the
        // hosted three: they answer in seconds, and #1148 keys the richer
        // state on the one provider whose wait is legitimately long.
        //
        // Keyed by attempt so a Search tapped mid-wait starts the count
        // again for the request now in flight, rather than carrying on
        // from the one it replaced.
        builder: (context, snapshot) => snapshot.data == true
            ? OwnServerWaitIndicator(
                key: ValueKey(state.attempt),
                onCancel: () => _bloc.add(const CancelBulkReadEvent()),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    if (state is BulkAddErrorState) {
      return _centeredMessage(context, S.of(context).bulkAddSearchFailedLabel);
    }
    if (state is BulkAddPhotoErrorState) {
      return _centeredMessage(
        context,
        switch (state.error) {
          BulkAddPhotoError.unavailable =>
            S.of(context).bulkAddPhotoUnavailableLabel,
          BulkAddPhotoError.auth => S.of(context).bulkAddPhotoKeyRejectedLabel,
          BulkAddPhotoError.transient => S.of(context).bulkAddPhotoFailedLabel,
          BulkAddPhotoError.camera =>
            S.of(context).bulkAddPhotoCameraFailedLabel,
          BulkAddPhotoError.gallery =>
            S.of(context).bulkAddPhotoGalleryFailedLabel,
          BulkAddPhotoError.unreadable =>
            S.of(context).bulkAddPhotoUnreadableLabel,
          BulkAddPhotoError.unsupported =>
            S.of(context).bulkAddPhotoUnsupportedLabel,
          BulkAddPhotoError.insecureDestination =>
            S.of(context).bulkAddModelInsecureServerLabel,
          BulkAddPhotoError.billing => S.of(context).bulkAddPhotoNoCreditLabel,
          BulkAddPhotoError.providerError =>
            S.of(context).bulkAddPhotoProviderErrorLabel,
        },
        detail: _photoErrorDetail(context, state),
        // #992. Three of these sentences send the user to Settings by name and
        // the fourth is answered there too, but only the *text* path ever
        // carried a way in — the photo path said "check it in Settings" and
        // left the user to find it, which is the hunt #852 already fixed once,
        // in the same dialog, for the same failures.
        //
        // Exhaustive, and deliberately not a `_ => null` default: a ninth photo
        // failure has to say here whether Settings answers it, rather than
        // inheriting silence from a case nobody weighed it against.
        //
        // The four that get nothing point somewhere else, and a Settings button
        // under them would send the user to fix the one thing that is not
        // broken: the camera case is a permission the OS holds, the unreadable
        // case wants a different photograph, the transient case wants the
        // connection or another attempt, and the billing case is settled on the
        // provider's own site — its sentence says so.
        action: switch (state.error) {
          BulkAddPhotoError.unavailable ||
          BulkAddPhotoError.auth ||
          BulkAddPhotoError.unsupported ||
          BulkAddPhotoError.insecureDestination => () => _openAiSettings(
            context,
          ),
          BulkAddPhotoError.transient ||
          BulkAddPhotoError.camera ||
          BulkAddPhotoError.gallery ||
          BulkAddPhotoError.unreadable ||
          BulkAddPhotoError.billing ||
          BulkAddPhotoError.providerError => null,
        },
      );
    }
    if (state is! BulkAddLoadedState) {
      // Scrollable because here the line *is* the body and takes a tight
      // height from the Expanded above: at 2x in German its two rows want
      // 112px more than this region has before anything has been parsed.
      // Scrolling rather than clipping, for the reason #777 settled — the
      // words are the point.
      return SingleChildScrollView(child: _buildModelHint(context));
    }
    if (state.rows.isEmpty) {
      return _withModelHint(
        context,
        _centeredMessage(context, switch (state) {
          // A bad segment explains itself; that outranks either generic line.
          _ when state.parseErrors.isNotEmpty => _parseErrorsText(
            context,
            state.parseErrors,
          ),
          // The model looked at a photograph and reported no food. "Nothing to
          // log yet" is true but reads as though nothing happened, and the
          // notice that would have said a photo was read is not drawn on this
          // branch — so the one screen where the user most needs to know a
          // machine answered was the one screen that never said so.
          _ when state.source == BulkAddReadSource.photo =>
            S.of(context).bulkAddPhotoNoFoodLabel,
          _ => S.of(context).bulkAddNothingToLogLabel,
        }),
      );
    }

    // The list is the labelled surface, not each child — row identifiers
    // would churn every time the row count changes.
    final entries = <Widget>[
      // One row per dish, then its components when it is open. The
      // components are the leading rows, dish by dish, so they keep their
      // indexes.
      for (var d = 0; d < state.dishes.length; d++) ...[
        _buildDishRow(context, state, d),
        if (state.dishes[d].expanded)
          for (
            var i = state.dishStart(d);
            i < state.dishStart(d) + state.dishes[d].componentCount;
            i++
          )
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16),
              child: _buildRow(context, state, i),
            ),
      ],
      for (var i = state.dishComponentCount; i < state.rows.length; i++)
        _buildRow(context, state, i),
      if (state.parseErrors.isNotEmpty)
        _buildParseErrors(context, state.parseErrors),
      // MacroFactor's footer: every number here is an estimate.
      if (state.dishes.any((d) => d.estimate != null))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Text(
            S.of(context).bulkAddEstimateFooter,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
    final list = Semantics(
      identifier: 'bulk-add-row-list',
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) => entries[index],
      ),
    );

    // A model failure that will still be true tomorrow gets said out loud,
    // even though the rows below are perfectly usable parser output. The
    // alternative is what a Pixel 6 actually did with a mistyped key: a
    // plausible screen, a silent 401 on every request, and nothing anywhere
    // to suggest the feature was not running.
    final failure = state.modelFailure;
    if (failure != null) {
      return _noticeAbove(
        context,
        list,
        // The icon tracks the text. A key-off glyph beside "you are out of
        // credit" contradicts the sentence next to it, and the whole point
        // of telling these failures apart is not to send someone to fix the
        // one thing that is not broken.
        icon: switch (failure) {
          MealTextModelFailure.auth => Icons.key_off_rounded,
          MealTextModelFailure.unsupported => Icons.block_rounded,
          MealTextModelFailure.billing => Icons.credit_card_off_rounded,
          // Not a network glyph, for the same reason the sentence is not
          // about a network: the connection was fine and the clock ran out.
          MealTextModelFailure.timeout => Icons.timer_off_rounded,
          // A lock, not a broken plug. Nothing failed to connect — the app
          // declined to send in the clear.
          MealTextModelFailure.insecureDestination => Icons.lock_outline,
        },
        text: switch (failure) {
          MealTextModelFailure.auth =>
            S.of(context).bulkAddModelKeyRejectedLabel,
          MealTextModelFailure.unsupported =>
            S.of(context).bulkAddModelUnsupportedLabel,
          MealTextModelFailure.billing =>
            S.of(context).bulkAddModelNoCreditLabel,
          MealTextModelFailure.timeout =>
            S.of(context).bulkAddModelTimedOutLabel,
          MealTextModelFailure.insecureDestination =>
            S.of(context).bulkAddModelInsecureServerLabel,
        },
        // Coloured as a warning, unlike the neutral "read by AI" banner:
        // this one is asking the user to go and change something.
        emphasised: true,
        // #777: the advice used to be the tail of the sentence, and the tail
        // is what a three-line cap ate. It is a control now, so it cannot be
        // truncated at any text scale — and every one of these failures is
        // answered in the same place.
        //
        // #852: which is why it asks for that place by name. Plain Settings
        // opens on Units & Energy and the AI row is four category groups
        // below it, so the recovery from "your server did not answer in
        // time" used to end in a hunt through a long list. The failure kind
        // does not appear here on purpose: the auth, unsupported, billing,
        // timeout and insecure-destination cases are all fixed in this one
        // dialog, so they all ask for the same thing.
        action: () => _openAiSettings(context),
      );
    }

    if (state.source == BulkAddReadSource.parser) return list;

    // Shown above the rows, not inside one. A model read the whole input, so
    // the caution belongs to the batch — and the confirmation step is only
    // meaningful if the user knows what did the reading.
    //
    // The photo wording is stronger on purpose. Reading typed text, the user
    // can compare a row against what they wrote; reading a photograph there
    // is nothing to compare against, and the food itself may be misidentified
    // rather than merely mis-measured.
    final photo = state.source == BulkAddReadSource.photo;
    return _noticeAbove(
      context,
      list,
      icon: photo ? Icons.photo_camera_rounded : Icons.auto_awesome_rounded,
      text: photo
          ? S.of(context).bulkAddReadFromPhotoLabel
          : S.of(context).bulkAddReadByModelLabel,
    );
  }

  /// A one-line banner above the rows. The caution belongs to the batch, not
  /// to any single row, so it sits above the list rather than inside it.
  Widget _noticeAbove(
    BuildContext context,
    Widget list, {
    required IconData icon,
    required String text,
    bool emphasised = false,
    VoidCallback? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // The ceiling is a share of what this widget was actually given, not of
    // the screen: the screen includes the app bar and the input above, so a
    // fraction of it overflows the part that is left.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Semantics(
            identifier: 'bulk-add-model-notice',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: emphasised
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest,
              // **Bounded, and scrollable rather than clipped.** Dropping the
              // cap on its own overflowed by 317px at 2x on a 320dp screen —
              // the notice sits above the rows in a `Column`, so its height
              // comes straight out of them. A ceiling gives the rows their
              // share back; scrolling is what stops the ceiling becoming a
              // second truncation, which is the bug this is fixing.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * 0.4,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            icon,
                            size: 16,
                            color: emphasised ? scheme.onErrorContainer : null,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              text,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: emphasised
                                        ? scheme.onErrorContainer
                                        : null,
                                  ),
                              // **No cap.** There used to be three lines, on the
                              // reasoning that these run long in German. Measured for
                              // #777, every one of them overran it — in English too —
                              // and no cap survives the combination that matters:
                              // German at 2x on a 320dp screen needed twenty lines,
                              // which is when the words are needed most. Now that the
                              // advice is a button, what is left is one sentence: two
                              // or three lines on a handset, up to eight at 2x on the
                              // narrowest screen, and never cut off.
                            ),
                          ),
                        ],
                      ),
                      // **Below the sentence, not beside it.** Sharing the row was
                      // measured first and is worse: a button takes about 120px,
                      // which on a 320dp screen leaves the text 144 and pushes
                      // German at 2x back up to twelve lines. Full width for the
                      // words, the control underneath.
                      if (action != null)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: Semantics(
                            identifier: 'bulk-add-notice-action',
                            child: TextButton(
                              onPressed: action,
                              style: TextButton.styleFrom(
                                foregroundColor: emphasised
                                    ? scheme.onErrorContainer
                                    : null,
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(S.of(context).settingsLabel),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: list),
        ],
      ),
    );
  }

  /// The one place every "change a setting" recovery on this screen goes.
  ///
  /// Shared rather than repeated so the two paths cannot drift: the photo
  /// failures are answered in the same dialog as the text ones, and the whole
  /// point of #852 is that the route carries *which* part of Settings to
  /// open. A second copy of these arguments is a second chance to lose them.
  /// Every route from this screen to the AI dialog, so all of them both
  /// deep-link (#852, #992) and re-resolve on the way back (#992).
  ///
  /// Delegating rather than pushing directly is the whole point: this had
  /// three call sites — the discovery hint, the text failure notice and the
  /// photo failure action — and only the ones that went through
  /// [_openSettings] noticed a provider configured while they were away.
  void _openAiSettings(BuildContext context) => unawaited(
    _openSettings(arguments: const SettingsScreenArguments(openAiAssist: true)),
  );

  /// What the provider said, under the sentence: its status and error text, or
  /// null when it gave neither (a dropped connection, a photo that never
  /// encoded). The words are the provider's own and not translated.
  String? _photoErrorDetail(
    BuildContext context,
    BulkAddPhotoErrorState state,
  ) {
    final status = state.httpStatus;
    final message = state.providerMessage;
    if (status != null && message != null) {
      return S.of(context).bulkAddPhotoErrorStatusDetail('$status', message);
    }
    if (status != null) {
      return S.of(context).bulkAddPhotoErrorStatusOnly('$status');
    }
    return message;
  }

  /// A message that fills the body, optionally with something to do about it.
  ///
  /// [action] is optional because most callers have nothing to offer: a
  /// failed food search and an empty parse are not fixed anywhere in
  /// particular, so they stay a sentence and nothing else.
  ///
  /// [detail] is a smaller line under the message, for words that are not ours
  /// to translate (a provider's status and error text).
  Widget _centeredMessage(
    BuildContext context,
    String message, {
    VoidCallback? action,
    String? detail,
  }) => Padding(
    padding: const EdgeInsets.all(24),
    // Scrollable rather than clipped, for the reason #777 settled: this
    // region takes a tight height from the `Expanded` above, and German at 2x
    // on a 320dp screen wants 484px more than it has. A bare `Column` there
    // paints its overflow past the bottom of the screen, and the button is
    // the last thing in it — so the control this change exists to add would
    // have been the first thing to go: in the tree, and untappable. Measured,
    // not assumed; the test pins it.
    child: Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  detail,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (action != null)
              Semantics(
                identifier: 'bulk-add-message-action',
                child: TextButton(
                  onPressed: action,
                  child: Text(S.of(context).settingsLabel),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  /// The parser reports *what* was wrong with *which* item; the sentence is
  /// built here, where there is a `BuildContext` to localize it with. See
  /// #631 — these read in English on every locale until they moved.
  String _parseErrorText(BuildContext context, MealTextParseError error) =>
      switch (error) {
        InvalidFoodNameError() =>
          S.of(context).bulkAddErrorInvalidName(error.itemNumber),
        QuantityTooSmallError() =>
          S.of(context).bulkAddErrorQuantityTooSmall(error.itemNumber),
        // `bound` is non-null here by construction, so there is nothing to
        // fall back to and no chance of telling the user their quantity has
        // to be "0 or less".
        QuantityTooLargeError(:final bound) =>
          S.of(context).bulkAddErrorQuantityTooLarge(error.itemNumber, bound),
      };

  String _parseErrorsText(
    BuildContext context,
    List<MealTextParseError> errors,
  ) => errors.map((e) => _parseErrorText(context, e)).join('\n');

  Widget _buildParseErrors(
    BuildContext context,
    List<MealTextParseError> errors,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Text(
      _parseErrorsText(context, errors),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.error,
      ),
    ),
  );

  Widget _buildRow(BuildContext context, BulkAddLoadedState state, int index) {
    final row = state.rows[index];
    final theme = Theme.of(context);
    final meal = row.meal;

    final title = _rowTitle(row);
    final faded = row.skipped || !row.isResolved;

    // Both rows below decide between one line and two, so they need the width
    // they were actually given rather than the screen's.
    return Opacity(
      opacity: row.skipped ? 0.5 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxWidth;
            final actions = _rowActions(context, index, row);
            // A `TextButton` is its label plus Material's padding, floored at
            // its minimum size. At 2x on a 320dp screen the German "skip"
            // alone measures 353px of the 288 this row gets, and a `Row`
            // answers that by squeezing the name to nothing and overflowing
            // by 65 anyway. #824.
            final actionsWidth = actions.fold<double>(
              0,
              (sum, action) => sum + _actionWidth(context, action.label),
            );
            // Below this the name has no share of the line worth reading, so
            // the controls take a line of their own and leave it the width.
            final stacked =
                available - actionsWidth <
                MediaQuery.textScalerOf(context).scale(72);

            final buttons = [
              for (final action in actions)
                TextButton(
                  onPressed: action.onPressed,
                  child: Text(action.label),
                ),
            ];

            final titleBlock = InkWell(
              onTap: row.isResolved
                  ? () => _showCandidatePicker(index, row)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // User content inside a Row: shrink to fit before
                  // ellipsizing, never wrap (AGENTS.md).
                  AutoSizeText(
                    title,
                    maxLines: 1,
                    minFontSize: 12,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      decoration: row.skipped
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  // The brand names *which* food this is; a warning only
                  // qualifies it. They were alternatives, and that inverted
                  // the intent below: the more doubtful a row looked, the
                  // less identifying detail it showed. #847 found the cost
                  // on a Pixel 6 — "Spiegeleier" resolved to Haribo's gummy
                  // sweets, and because the row also carried a unit warning,
                  // the word "Haribo" never reached the screen. The one
                  // field that gives the mistake away is the one a warning
                  // used to hide, so it is now unconditional.
                  if (meal?.brands != null)
                    Text(meal!.brands!, style: theme.textTheme.bodySmall),
                  if (!row.isResolved)
                    Text(
                      S.of(context).bulkAddNoMatchLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    )
                  // The numbers were generated by the model rather than taken
                  // from the generic food table: a small sparkle, as in
                  // MacroFactor, and nothing louder.
                  else if (row.usesAiEstimate)
                    Tooltip(
                      message: S.of(context).bulkAddAiEstimateLabel,
                      child: Icon(
                        Icons.auto_awesome_rounded,
                        size: 16,
                        color: theme.colorScheme.tertiary,
                        semanticLabel: S.of(context).bulkAddAiEstimateLabel,
                      ),
                    )
                  else if (row.isLowConfidence)
                    Text(
                      S.of(context).bulkAddUncertainLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    )
                  // A bare count the app could not interpret. Shown
                  // below a doubtful match, because a wrong food
                  // matters more than a wrong unit on the right one.
                  else if (row.amountNeedsCheck)
                    Text(
                      S.of(context).bulkAddCheckAmountLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    )
                  // The amount was read off a photograph: a guess the user can
                  // see and edit, so it says so instead of "not stated".
                  else if (row.isEstimated)
                    _estimatedLabel(context)
                  // Last, and the quietest of the four. The others say
                  // something is probably wrong; this only says the number
                  // is the app's rather than the user's, so it takes the
                  // muted surface colour instead of an accent. #864.
                  else if (row.amountIsProvisional)
                    Text(
                      S.of(context).bulkAddDefaultAmountLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (stacked)
                  // Stretched, so each label is bounded by the line rather
                  // than by whatever is left of it.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [titleBlock, ...buttons],
                  )
                else
                  // Unchanged wherever they fit, which is every ordinary
                  // text size: name on the left, controls on the right.
                  Row(
                    children: [
                      Expanded(child: titleBlock),
                      ...buttons,
                    ],
                  ),
                if (!faded)
                  _buildAmountRow(context, state, index, row, available),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _estimatedLabel(BuildContext context) => Text(
    S.of(context).bulkAddEstimatedLabel,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  /// The single row a composed dish takes on the review screen: its name, the
  /// total weight and energy of the components that will be logged, and a
  /// chevron that opens them. The numbers are sums over the components below,
  /// so editing one there moves them here.
  Widget _buildDishRow(BuildContext context, BulkAddLoadedState state, int d) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final dish = state.dishes[d];
    final loggable = state.dishRows(d).any((row) => row.willBeLogged);
    final grams = state.dishWeightG(d);
    final kcal = state.dishKcal(d);
    final weight = state.usesImperialUnits
        ? '${UnitCalc.gToOz(grams).round()} ${s.ozUnit}'
        : '${grams.round()} ${s.gramUnit}';
    final skipLabel = state.dishRows(d).any((row) => !row.skipped)
        ? s.bulkAddSkipLabel
        : s.bulkAddIncludeLabel;

    return Opacity(
      opacity: loggable ? 1.0 : 0.5,
      child: Semantics(
        identifier: 'bulk-add-dish-row',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => _bloc.add(ToggleDishExpandedEvent(d)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AutoSizeText(
                            dish.name,
                            maxLines: 1,
                            minFontSize: 12,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            s.bulkAddDishComponentsLabel(dish.componentCount),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (kcal != null)
                          Text(
                            EnergyDisplay.formatWithUnit(context, kcal),
                            style: theme.textTheme.titleSmall,
                          ),
                        Text(weight, style: theme.textTheme.bodySmall),
                      ],
                    ),
                    Icon(
                      dish.expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      semanticLabel: dish.expanded
                          ? s.bulkAddDishCollapseLabel
                          : s.bulkAddDishExpandLabel,
                    ),
                  ],
                ),
              ),
              if (dish.estimate != null && loggable)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _macrosText(
                          context,
                          state.dishProteinG(d),
                          state.dishCarbsG(d),
                          state.dishFatG(d),
                        ) ??
                        '',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (dish.estimate != null) _DishNotes(estimate: dish.estimate!),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => _bloc.add(ToggleDishSkippedEvent(d)),
                  child: Text(skipLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "P 24 g · C 60 g · F 18 g", or null when nothing is known.
  String? _macrosText(
    BuildContext context,
    double? protein,
    double? carbs,
    double? fat,
  ) {
    if (protein == null && carbs == null && fat == null) return null;
    String grams(double? v) => (v ?? 0).round().toString();
    return S
        .of(context)
        .bulkAddMacrosLine(grams(protein), grams(carbs), grams(fat));
  }

  /// What the row is called, on screen and in any message about it: the
  /// matched food, or the words the user typed when nothing matched.
  String _rowTitle(BulkAddRow row) =>
      row.meal?.name ?? row.resolved.parsed.query;

  /// The controls on a row, as label and action rather than as widgets, so
  /// that what is measured cannot drift from what is drawn.
  List<({String label, VoidCallback onPressed})> _rowActions(
    BuildContext context,
    int index,
    BulkAddRow row,
  ) => [
    if (!row.isResolved)
      (label: S.of(context).quickAddCardLabel, onPressed: _showQuickAdd),
    (
      label: row.skipped
          ? S.of(context).bulkAddIncludeLabel
          : S.of(context).bulkAddSkipLabel,
      onPressed: () => _bloc.add(ToggleRowSkippedEvent(index)),
    ),
  ];

  /// The width a text button needs for [label]: the label itself, Material's
  /// horizontal padding at its widest, and never less than the narrowest a
  /// button is allowed to be.
  double _actionWidth(BuildContext context, String label) => math.max(
    _minButtonWidth,
    _textWidth(context, label, Theme.of(context).textTheme.labelLarge) +
        _buttonPadding,
  );

  static const _buttonPadding = 24.0;
  static const _minButtonWidth = 64.0;

  /// The width [text] needs at the current text scale.
  ///
  /// Measured rather than estimated. These rows have to choose between one
  /// line and two, and an estimate wide enough to be safe for the widest
  /// possible glyphs is about twice too wide for a real font — it would
  /// stack the controls on screens where they comfortably fit.
  double _textWidth(BuildContext context, String text, TextStyle? style) =>
      (TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout()).width;

  Widget _buildAmountRow(
    BuildContext context,
    BulkAddLoadedState state,
    int index,
    BulkAddRow row,
    double available,
  ) {
    final controller = _amountControllers.putIfAbsent(
      index,
      () => TextEditingController(text: row.amountText),
    );
    if (controller.text != row.amountText) {
      controller.text = row.amountText;
    }

    final theme = Theme.of(context);
    // The quantity box was a flat 110px while every label beside it grew with
    // the text scale, so at 2x on a 320dp screen this row wanted 532px of a
    // 288px slot and overflowed by 244. It scales now, like the other fixed
    // widths in the app. #824.
    final fieldWidth = MediaQuery.textScalerOf(context).scale(110);
    final unitWidth = _unitDropdownWidth(context, row);
    final energyText = _energyLabel(context, row);
    final energyWidth = _textWidth(
      context,
      energyText,
      theme.textTheme.titleSmall,
    );
    // Nothing flexes 532px into 288px. Where the three do not fit, they take
    // a line each rather than share one: the unit is a whole word in some
    // locales, and a clipped unit is not a narrower reading of the amount,
    // it is a wrong one.
    final stacked = available < fieldWidth + 12 + unitWidth + 8 + energyWidth;

    final field = TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // Same shape the manual-entry field enforces, so the two paths accept
      // exactly the same input.
      inputFormatters: [
        FilteringTextInputFormatter.allow(bulkAddQuantityPattern),
      ],
      decoration: InputDecoration(
        labelText: S.of(context).quantityLabel,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) {
        // The complaint belonged to the text that is no longer there.
        // Re-checking as they type would put it back mid-keystroke, which
        // is the thing `amountText` is a String to avoid; the next submit
        // asks again.
        if (_quantityErrors.containsKey(index)) {
          setState(() => _quantityErrors.remove(index));
        }
        _bloc.add(ChangeRowAmountEvent(index, value));
      },
    );

    final supportsServings = _bloc.supportsCustomPortions && row.isResolved;
    final unit = DropdownButton<String>(
      value: row.effectiveUnit,
      items: _unitItems(context, index, row, supportsServings),
      selectedItemBuilder: (context) =>
          _selectedUnitItems(context, row, supportsServings),
      // The menu is as wide as the button, which is as wide as the longest
      // unit; the "Add serving" entry is wider than most of them.
      menuWidth: supportsServings
          ? math.max(
              unitWidth,
              _textWidth(
                    context,
                    S.of(context).customPortionAddAction,
                    theme.textTheme.titleMedium,
                  ) +
                  _addServingIconWidth +
                  _dropdownArrowWidth,
            )
          : null,
      // Only when it has a line to fill; on a shared line it takes the width
      // its longest unit needs, which is what `stacked` was measured against.
      isExpanded: stacked,
      onChanged: (value) {
        if (value == _addServingValue) {
          _addServing(index, row);
        } else if (value != null) {
          _bloc.add(ChangeRowUnitEvent(index, value));
        }
      },
    );

    final energy = Text(energyText, style: theme.textTheme.titleSmall);
    final macros = _macrosText(context, row.proteinG, row.carbsG, row.fatG);

    final error = _quantityErrors[index];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stacked)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field,
                const SizedBox(height: 8),
                unit,
                const SizedBox(height: 4),
                Align(alignment: AlignmentDirectional.centerEnd, child: energy),
              ],
            )
          // Unchanged wherever it fits, which is every ordinary text size:
          // the figure stays on the same line, pushed to the trailing edge.
          else
            Row(
              children: [
                SizedBox(width: fieldWidth, child: field),
                const SizedBox(width: 12),
                unit,
                const Spacer(),
                energy,
              ],
            ),
          // The whole width, not the field's. `errorText` would put this
          // inside a 110px box, where every one of the three sentences
          // ellipsizes to nothing worth reading — and the decimal rule, the
          // one constraint stated nowhere else in the UI, is the longest of
          // them.
          // Photo rows also show protein, carbohydrate and fat, as the result
          // is a recipe the user reads line by line.
          if (row.fromPhoto && macros != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  macros,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _quantityErrorText(context, error),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Says which of the three failures this is. They used to render
  /// identically, as the field's own name.
  String _quantityErrorText(
    BuildContext context,
    BulkAddQuantityError error,
  ) => switch (error) {
    BulkAddQuantityError.malformed => S.of(context).bulkAddRowQuantityInvalid,
    BulkAddQuantityError.tooSmall => S.of(context).bulkAddRowQuantityTooSmall,
    BulkAddQuantityError.tooLarge =>
      S.of(context).bulkAddRowQuantityTooLarge(bulkAddMaxQuantity),
  };

  /// What the unit dropdown needs to show its longest unit without clipping
  /// it: the dropdown sizes itself to its widest item, plus its arrow.
  double _unitDropdownWidth(BuildContext context, BulkAddRow row) {
    final style = Theme.of(context).textTheme.titleMedium;
    var widest = 0.0;
    for (final unit in row.allowedUnits) {
      widest = math.max(
        widest,
        _textWidth(context, _unitLabel(context, unit, row), style),
      );
    }
    return widest + _dropdownArrowWidth;
  }

  static const _dropdownArrowWidth = 24.0;

  /// Empty when the amount is not yet usable or the food has no energy value.
  String _energyLabel(BuildContext context, BulkAddRow row) {
    final meal = row.meal;
    if (meal == null) return '';
    final quantity = double.tryParse(row.amountText.replaceAll(',', '.'));
    if (quantity == null || quantity <= 0) return '';
    final kcal = kcalForQuantity(quantity, row.effectiveUnit, meal);
    return kcal == null ? '' : EnergyDisplay.formatWithUnit(context, kcal);
  }

  static const _addServingIconWidth = 26.0;

  /// The portion [unit] names when it is one of the user's own servings.
  MealPortionEntity? _customPortionOf(String unit, BulkAddRow row) {
    final portions = row.meal?.portions ?? const <MealPortionEntity>[];
    if (!isPortionUnit(unit)) return null;
    final index = effectivePortionIndex(unit);
    if (index >= portions.length) return null;
    return portions[index].isCustom ? portions[index] : null;
  }

  Widget _unitText(BuildContext context, String unit, BulkAddRow row) {
    final text = Text(
      _unitLabel(context, unit, row),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (_customPortionOf(unit, row) == null) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.person_outline_rounded,
          size: 16,
          semanticLabel: S.of(context).customPortionOwnLabel,
        ),
        const SizedBox(width: 4),
        Flexible(child: text),
      ],
    );
  }

  List<DropdownMenuItem<String>> _unitItems(
    BuildContext context,
    int index,
    BulkAddRow row,
    bool supportsServings,
  ) => [
    for (final unit in row.allowedUnits)
      DropdownMenuItem(
        value: unit,
        child: _customPortionOf(unit, row) == null
            ? _unitText(context, unit, row)
            // Long-press deletes one of the user's own servings. Only in the
            // open menu, so the closed field is not a delete trigger.
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () {
                  Navigator.of(context).pop();
                  _deleteServing(index, _customPortionOf(unit, row)!);
                },
                child: _unitText(context, unit, row),
              ),
      ),
    if (supportsServings)
      DropdownMenuItem(
        value: _addServingValue,
        child: Semantics(
          identifier: 'bulk-add-unit-add-serving',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_rounded, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  S.of(context).customPortionAddAction,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
  ];

  List<Widget> _selectedUnitItems(
    BuildContext context,
    BulkAddRow row,
    bool supportsServings,
  ) => [
    for (final unit in row.allowedUnits) _unitText(context, unit, row),
    if (supportsServings) const SizedBox.shrink(),
  ];

  Future<void> _addServing(int index, BulkAddRow row) async {
    final meal = row.meal;
    if (meal == null) return;
    final input = await showAddCustomPortionDialog(
      context,
      unit: customPortionUnitFor(meal) == 'ml'
          ? S.of(context).milliliterUnit
          : S.of(context).gramUnit,
    );
    if (input == null || !mounted) return;
    _bloc.add(AddRowCustomPortionEvent(index, input.label, input.gramWeight));
  }

  Future<void> _deleteServing(int index, MealPortionEntity portion) async {
    final confirmed = await confirmDeleteCustomPortion(context, portion.label);
    if (!confirmed || !mounted) return;
    _bloc.add(DeleteRowCustomPortionEvent(index, portion.customPortionId!));
  }

  /// Takes the row because one of the six units is not a fixed word: the
  /// food names its own portion, and "3 slice" says what "3 serving" only
  /// implies. Display only — the value behind it stays `serving` (#864).
  String _unitLabel(BuildContext context, String unit, BulkAddRow row) {
    // A named portion shows its own word — "slice", "cup" — which is the
    // whole point of offering more than one. Only when the text is in the
    // reader's language: the backend says per portion whether it is, and
    // showing English to the other eight locales is what #966 gated.
    final portions = row.meal?.portions ?? const [];
    if (isPortionUnit(unit) && portions.isNotEmpty) {
      final index = effectivePortionIndex(unit);
      if (index < portions.length) {
        final portion = portions[index];
        if (portion.isCustom) {
          final name = portion.label.trim();
          return name.length <= _maxCustomLabelChars
              ? name
              : '${name.substring(0, _maxCustomLabelChars - 1)}…';
        }
        final label = householdPortionLabel(
          portion.label,
          languageCode: Localizations.localeOf(context).languageCode,
          textIsLocalized: portion.localized,
        );
        if (label != null) return label;
      }
    }
    return _fixedUnitLabel(context, unit, row);
  }

  String _fixedUnitLabel(BuildContext context, String unit, BulkAddRow row) =>
      switch (UnitDropdownItem.g.fromString(storedUnit(unit))) {
        UnitDropdownItem.g => S.of(context).gramUnit,
        UnitDropdownItem.ml => S.of(context).milliliterUnit,
        UnitDropdownItem.gml => S.of(context).gramMilliliterUnit,
        UnitDropdownItem.oz => S.of(context).ozUnit,
        UnitDropdownItem.flOz => S.of(context).flOzUnit,
        UnitDropdownItem.serving =>
          householdPortionLabel(
                row.meal?.servingSize,
                languageCode: Localizations.localeOf(context).languageCode,
                textIsLocalized: row.meal?.servingSizeIsLocalized ?? false,
              ) ??
              S.of(context).servingLabel,
      };

  Widget _buildSubmitBar(BuildContext context, BulkAddLoadedState state) {
    final count = state.loggableCount;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          identifier: 'bulk-add-submit',
          child: FilledButton.icon(
            onPressed: count == 0 || _submitting
                ? null
                : () => _onSubmitPressed(state),
            icon: const Icon(Icons.add_rounded),
            label: Text(S.of(context).bulkAddSubmitLabel(count)),
          ),
        ),
      ),
    );
  }

  void _onParsePressed() {
    FocusScope.of(context).unfocus();
    _resetAmountControllers();
    _bloc.add(
      ParseBulkTextEvent(
        text: _textController.text,
        usesImperialUnits: _args.usesImperialUnits,
        localeCode: Localizations.localeOf(context).languageCode,
      ),
    );
  }

  Future<void> _onPhotoPressed() async {
    FocusScope.of(context).unfocus();
    final destination = await _photoDestination;
    if (!mounted) return;
    // Refusing rather than guessing: with no identifiable destination there
    // is no honest sentence to put in the sheet, and the sheet is the last
    // moment the user can decline.
    if (destination == null) return;
    final disclosure = switch (destination.provider) {
      AiProvider.anthropic => S.of(context).bulkAddPhotoDisclosureAnthropic,
      AiProvider.openrouter =>
        S.of(context).bulkAddPhotoDisclosureOpenRouter(destination.name),
      // No placeholder: a direct path has no serving vendor to name, so this
      // string is flat where OpenRouter's is parameterised.
      AiProvider.openai => S.of(context).bulkAddPhotoDisclosureOpenAI,
      // The address, and nothing beyond it. Not "no third party receives it",
      // however tempting: the app cannot tell a local runtime from a
      // self-hosted proxy forwarding to OpenAI, and #732 ruled those out of
      // scope by making no claim about them rather than by detecting them.
      // The no-copy sentence below is about this app and still holds.
      AiProvider.ownServer =>
        S.of(context).bulkAddPhotoDisclosureOwnServer(destination.name),
    };
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => _PhotoSourceSheet(disclosure: disclosure),
    );
    if (source == null || !mounted) return;

    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: source);
    } catch (e, stackTrace) {
      _log.warning(
        'Opening the meal photo ${source.name} failed',
        e,
        stackTrace,
      );
      if (!mounted) return;
      _bloc.add(
        ReadMealPhotoFailedEvent(switch (source) {
          ImageSource.camera => BulkAddPhotoError.camera,
          ImageSource.gallery => BulkAddPhotoError.gallery,
        }),
      );
      return;
    }
    // A cancelled picker is not a failure and says nothing to the user.
    if (picked == null || !mounted) return;

    // The thumbnail is read before the encode starts, because the encode
    // deletes the picker's cache copy when it finishes. It lives in memory for
    // as long as the sheet is open and no longer.
    final thumbnail = await locator<MealPhotoPreparer>().thumbnail(picked.path);
    if (!mounted) {
      unawaited(_prepare(picked.path, destination.provider));
      return;
    }

    // Started now, not on Analyse, so the wait overlaps the typing. Only the
    // encode runs early: the model is asked once, from the sheet's buttons.
    final encoding = _prepare(picked.path, destination.provider);

    final choice = await showModalBottomSheet<_CaptionChoice>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) =>
          _PhotoCaptionSheet(thumbnail: thumbnail, encoding: encoding),
    );
    // Backed out: nothing is sent. The encode that is still running (or has
    // finished) is left to complete, and its own `finally` removes the cache
    // copy; the encoded bytes are simply never used.
    if (choice == null || !mounted) return;

    final encoded = choice.encoded;
    if (encoded.photo == null) {
      _bloc.add(const ReadMealPhotoFailedEvent(BulkAddPhotoError.unreadable));
      return;
    }

    // A photo replaces the previous batch, so the old controllers go with it.
    _resetAmountControllers();

    _bloc.add(
      ReadMealPhotoEvent(
        photo: encoded.photo!,
        usesImperialUnits: _args.usesImperialUnits,
        localeCode: Localizations.localeOf(context).languageCode,
        caption: choice.caption,
      ),
    );
  }

  /// Encodes the picked file for [provider] and discards the picker's copy —
  /// see [MealPhotoEncoder.encodeAndDiscardSource]. Never throws: a failure is
  /// part of the outcome, so a sheet that is waiting on it and a sheet that was
  /// abandoned both see the same thing.
  Future<_Encoded> _prepare(String path, AiProvider provider) async {
    try {
      final photo = await locator<MealPhotoPreparer>().prepare(
        path,
        // Per destination, not per app: a server the user runs may be
        // llama.cpp, which cannot decode WebP at all (#747).
        MealPhotoFormat.forProvider(provider),
      );
      return (photo: photo);
    } catch (e, stackTrace) {
      // Never logged with the path: on Android the picker's temp filename
      // can carry the original image name.
      _log.warning('Encoding a meal photo failed', e, stackTrace);
      return (photo: null);
    }
  }

  void _resetAmountControllers() {
    for (final controller in _amountControllers.values) {
      controller.dispose();
    }
    _amountControllers.clear();
    // Both are keyed by row index, so both belong to the batch that is
    // being replaced. A mark left behind would land on whichever row
    // happens to take that index next.
    _quantityErrors.clear();
  }

  Future<void> _showCandidatePicker(int index, BulkAddRow row) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        // Label the surface, not each row — identifiers would churn with
        // the candidate count.
        child: Semantics(
          identifier: 'bulk-add-candidate-list',
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  S.of(context).bulkAddChooseFoodLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (var i = 0; i < row.resolved.candidates.length; i++)
                ListTile(
                  title: Text(row.resolved.candidates[i].name ?? ''),
                  subtitle: row.resolved.candidates[i].brands != null
                      ? Text(row.resolved.candidates[i].brands!)
                      : null,
                  trailing: i == row.selectedIndex
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(context).pop(i),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) _bloc.add(ChangeRowCandidateEvent(index, chosen));
  }

  void _showQuickAdd() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => QuickAddBottomSheet(
        intakeType: _args.intakeTypeEntity,
        day: _args.day,
      ),
    );
  }

  /// Logs a dish as one recipe, and remembers it as one.
  ///
  /// Every component is stored in grams (the amount the plate was confirmed
  /// at), so the recipe re-reads the same weights if it is edited later. The
  /// recipe is saved first and the diary entry is made *from* it, so the entry
  /// and the saved food are the same thing; a same-named photo dish updates its
  /// recipe in place (see [SavePhotoDishUseCase]).
  Future<void> _logDish(
    BulkAddDish dish,
    List<({int index, BulkAddRow row, double amount})> components,
  ) async {
    final recipe = await locator<SavePhotoDishUseCase>().save(
      name: dish.name,
      ingredients: [
        for (final component in components)
          RecipeIngredientEntity(
            snapshotMeal: component.row.meal!,
            amount: component.amount,
            unit: 'g',
            convertedAmountG: component.amount,
          ),
      ],
    );
    if (!mounted) return;
    await locator<MealDetailBloc>().addIntake(
      context,
      'g',
      recipe.totalWeightG.toString(),
      _args.intakeTypeEntity,
      recipe.toMealEntity(),
      _args.day,
    );
  }

  /// Validate the whole batch, then write it.
  ///
  /// `MealDetailBloc.addIntake` calls `double.parse` with no guard, so a
  /// single bad row throws mid-loop and leaves the rows before it already
  /// written — a half-logged meal with no rollback. Checking every row up
  /// front is what makes the batch all-or-nothing.
  Future<void> _onSubmitPressed(BulkAddLoadedState state) async {
    // Validate the whole batch before writing any of it. addIntake parses
    // the amount with `double.parse` and no guard, so one bad row would
    // otherwise throw mid-loop and leave the rows before it already
    // written, with no rollback.
    //
    // Every row is checked, and the loop no longer stops at the first
    // failure. It refuses the batch either way, so stopping early only
    // decided how many times the user has to submit it to find out what is
    // wrong: one field fixed, one more refusal, one more field. #1013.
    //
    // Indexed over `rows` rather than `loggableRows`, because the failures
    // are marked on the rows themselves and a filtered iterable cannot say
    // which row it came from.
    final invalid = <int, BulkAddQuantityError>{};
    final writes = <({int index, BulkAddRow row, double amount})>[];
    for (var index = 0; index < state.rows.length; index++) {
      final row = state.rows[index];
      if (!row.willBeLogged) continue;

      final error = row.quantityError;
      if (error != null) {
        invalid[index] = error;
        continue;
      }
      // Cannot throw: `quantityError` returned null, which required this
      // same text to parse.
      final quantity = double.parse(row.amountText.trim().replaceAll(',', '.'));
      // Store the value the intake is actually written with: nutriment
      // values are per gram/millilitre, so oz / fl.oz / serving have to be
      // converted first. Logging the raw amount stores 4 g for 4 oz.
      writes.add((
        index: index,
        row: row,
        amount: convertQuantityToBaseUnit(
          quantity,
          row.effectiveUnit,
          row.meal!,
        ),
      ));
    }

    if (invalid.isNotEmpty) {
      setState(() {
        _quantityErrors
          ..clear()
          ..addAll(invalid);
      });
      // The marks are on the rows, and a row can be off screen — a button
      // that refuses in silence is the state this screen was already in.
      // Naming each food and its reason keeps the snackbar honest about how
      // many rows are waiting.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Bounded: nothing limits how many rows a paste produces, and a
            // snackbar does not scroll — an unbounded join would cover the
            // list the marks are on. The marks carry every failure; this
            // carries as many as fit and ellipsizes the rest.
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            invalid.entries
                .map(
                  (entry) =>
                      '${_rowTitle(state.rows[entry.key])}: '
                      '${_quantityErrorText(context, entry.value)}',
                )
                .join('\n'),
          ),
        ),
      );
      return;
    }

    setState(() {
      _quantityErrors.clear();
      _submitting = true;
    });

    final mealDetailBloc = locator<MealDetailBloc>();
    try {
      // Sequential, not concurrent. The tracked-day totals are accumulated
      // with a read-modify-write, so overlapping writes lose updates and
      // the day silently under-counts.
      //
      // The dishes first, each as its own recipe: their components are the
      // leading rows, and the diary reads in the order the screen did.
      for (var d = 0; d < state.dishes.length; d++) {
        final dishWrites = [
          for (final write in writes)
            if (state.dishOfRow(write.index) == d) write,
        ];
        if (dishWrites.isEmpty) continue;
        await _logDish(state.dishes[d], dishWrites);
        if (!mounted) return;
      }
      for (final write in writes) {
        if (state.dishOfRow(write.index) != null) continue;
        await mealDetailBloc.addIntake(
          context,
          // The suffix is a display device; the stored vocabulary stays
          // the closed set the export format and QR payload were written
          // against. #864 decision 3.
          storedUnit(write.row.effectiveUnit),
          write.amount.toString(),
          _args.intakeTypeEntity,
          write.row.meal!,
          _args.day,
        );
      }
    } catch (e, stackTrace) {
      _log.severe('Bulk intake write failed', e, stackTrace);
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).bulkAddSearchFailedLabel)),
      );
      return;
    }

    if (!mounted) return;

    locator<HomeBloc>().add(const LoadItemsEvent());
    locator<DiaryBloc>().add(const LoadDiaryYearEvent());
    locator<CalendarDayBloc>().add(const RefreshCalendarDayEvent());

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(S.of(context).infoAddedIntakeLabel)));
    Navigator.of(
      context,
    ).popUntil(ModalRoute.withName(NavigationOptions.mainRoute));
  }
}

/// The outcome of encoding a picked photo: the photo, or null when it could
/// not be encoded or was too large to send.
typedef _Encoded = ({MealPhoto? photo});

/// What the caption sheet hands back for Analyse or Skip caption.
class _CaptionChoice {
  final _Encoded encoded;

  /// Null for Skip caption and for an empty field.
  final String? caption;

  const _CaptionChoice(this.encoded, this.caption);
}

/// The first sheet: the disclosure and where the picture comes from.
class _PhotoSourceSheet extends StatelessWidget {
  final String disclosure;

  const _PhotoSourceSheet({required this.disclosure});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SafeArea(
      child: Wrap(
        children: [
          // The disclosure sits here rather than in a dialog the user has
          // to dismiss: this is the moment a photograph would leave the
          // device, and it is the last moment they can decline.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '$disclosure '
              '${s.bulkAddPhotoDisclosureCommon}\n\n'
              // The photo path has no deterministic fallback, so this is
              // the only surface besides Settings where a user opts into a
              // model. The stability note belongs on both.
              '${s.aiAssistExperimentalNote}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Semantics(
            identifier: 'bulk-add-photo-camera',
            child: ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: Text(s.mealImageTakePhoto),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
          ),
          Semantics(
            identifier: 'bulk-add-photo-gallery',
            child: ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(s.mealImagePickFromGallery),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ),
        ],
      ),
    );
  }
}

/// The second sheet, shown right after a photo is picked: the thumbnail, a
/// caption field with the keyboard up, and the two ways to go on.
///
/// The encode is already running behind it ([encoding]); a small indicator says
/// so. **Nothing is sent from here until a button is tapped**, and then exactly
/// once: Analyse sends the photo with the caption, Skip caption sends it
/// without. Tapping either while the encode is still running waits for it, with
/// the sheet staying open and the buttons busy, then closes with the result.
/// Dismissing the sheet any other way returns null, and nothing is sent.
class _PhotoCaptionSheet extends StatefulWidget {
  final Uint8List? thumbnail;
  final Future<_Encoded> encoding;

  const _PhotoCaptionSheet({required this.thumbnail, required this.encoding});

  @override
  State<_PhotoCaptionSheet> createState() => _PhotoCaptionSheetState();
}

class _PhotoCaptionSheetState extends State<_PhotoCaptionSheet> {
  final _caption = TextEditingController();
  bool _preparing = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.encoding.whenComplete(() {
      if (mounted) setState(() => _preparing = false);
    });
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _go({required bool withCaption}) async {
    if (_sending) return;
    final text = withCaption ? _caption.text.trim() : '';
    setState(() => _sending = true);
    final encoded = await widget.encoding;
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(_CaptionChoice(encoded, text.isEmpty ? null : text));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: widget.thumbnail == null
                            ? const Icon(Icons.image_outlined)
                            : Image.memory(
                                widget.thumbnail!,
                                fit: BoxFit.cover,
                                cacheWidth: 216,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.image_outlined),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_preparing)
                      Expanded(
                        child: Semantics(
                          identifier: 'bulk-add-photo-preparing',
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  s.bulkAddPhotoPreparingLabel,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Semantics(
                  identifier: 'bulk-add-photo-caption',
                  child: TextField(
                    controller: _caption,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    enabled: !_sending,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(
                        mealPhotoCaptionMaxChars,
                      ),
                    ],
                    onSubmitted: (_) => _go(withCaption: true),
                    decoration: InputDecoration(
                      hintText: s.bulkAddPhotoCaptionHint,
                      helperText: s.bulkAddPhotoCaptionDisclosure,
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Semantics(
                      identifier: 'bulk-add-photo-skip-caption',
                      child: TextButton(
                        onPressed: _sending
                            ? null
                            : () => _go(withCaption: false),
                        child: Text(s.bulkAddPhotoSkipCaptionLabel),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Semantics(
                      identifier: 'bulk-add-photo-analyse',
                      child: FilledButton(
                        onPressed: _sending
                            ? null
                            : () => _go(withCaption: true),
                        child: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(s.bulkAddPhotoAnalyseLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The model's confidence in the dish and portion, and its assumptions, on one
/// line that opens to list them. Nothing is hidden for good: the line says how
/// many assumptions there are.
class _DishNotes extends StatefulWidget {
  final PhotoRecipeEstimate estimate;

  const _DishNotes({required this.estimate});

  @override
  State<_DishNotes> createState() => _DishNotesState();
}

class _DishNotesState extends State<_DishNotes> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final estimate = widget.estimate;
    final confidence = switch (estimate.confidence) {
      EstimateConfidence.high => s.bulkAddConfidenceHigh,
      EstimateConfidence.medium => s.bulkAddConfidenceMedium,
      EstimateConfidence.low => s.bulkAddConfidenceLow,
    };
    final count = estimate.assumptions.length;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Semantics(
      identifier: 'bulk-add-dish-notes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: count == 0 ? null : () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      count == 0
                          ? confidence
                          : '$confidence · ${s.bulkAddAssumptionsLabel(count)}',
                      style: style,
                    ),
                  ),
                  if (count > 0)
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                ],
              ),
            ),
          ),
          if (_open)
            for (final assumption in estimate.assumptions)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• $assumption', style: style),
              ),
        ],
      ),
    );
  }
}
