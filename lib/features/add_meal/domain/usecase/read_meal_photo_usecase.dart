import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// What reading a photo produced.
///
/// Sealed so the caller has to handle all three, and so "the feature is off"
/// cannot be confused with "the call failed". They look similar from the
/// bloc and want opposite words in front of the user: one is a setting they
/// can change, the other is a thing that went wrong.
sealed class MealPhotoReadResult {
  const MealPhotoReadResult();
}

/// The model answered. An empty [result] is a legitimate answer — it looked
/// and found no food — not a failure, exactly as on the text path (#647).
final class MealPhotoRead extends MealPhotoReadResult {
  final MealTextParseResult result;

  const MealPhotoRead(this.result);
}

/// No key stored, or the user has switched the feature off. The screen only
/// offers the camera when a key is enabled, so this is the narrow race where
/// the setting changed while the screen was open — worth handling, not worth
/// an alarming message.
final class MealPhotoUnavailable extends MealPhotoReadResult {
  const MealPhotoUnavailable();
}

/// Why a call failed, in the flavours the user can act on.
enum MealPhotoFailure {
  /// The account cannot pay — no credit, or a spend cap reached. Neither
  /// "try again later" nor "check your key" is true of it, and both send the
  /// user somewhere that cannot help.
  billing,

  /// The provider rejected the credential. Told apart from a transient
  /// failure because "try again later" is the wrong advice for a wrong key,
  /// and following it forever is a bad afternoon.
  auth,

  /// The provider refused this image. A corpus run found real photographs
  /// that are rejected on every attempt but succeed once re-encoded, so the
  /// useful advice is "try another photo", not "try again".
  rejectedImage,

  /// Nothing on the other end can read an image for this configuration —
  /// the chosen model has no vision, or no provider of it will honour a
  /// forced tool call. Kept apart from [transient] because retrying is
  /// hopeless and the fix is in settings, not in the network.
  unsupported,

  /// The app refused to send a photograph over plaintext to a public
  /// destination. The model may support photos perfectly; the address is what
  /// needs changing, so this must not be reported as [unsupported].
  insecureDestination,

  /// No answer reached us: no network, a dropped connection, a timeout.
  /// Worth another attempt, and "check your connection" is true of it.
  transient,

  /// The provider answered, and the answer was an error that none of the
  /// kinds above names: a rate limit, a 5xx, or a 400 whose cause only its
  /// message tells. A 400 is as likely a wrong key or model as a bad image, so
  /// it is not called "unreadable"; the status and the provider's own text
  /// ride along on [MealPhotoFailed] so the cause can be read.
  providerError,
}

/// The call failed.
final class MealPhotoFailed extends MealPhotoReadResult {
  final MealPhotoFailure failure;

  /// The provider's HTTP status, when it answered with one.
  final int? statusCode;

  /// The provider's error text, trimmed and with key-shaped strings masked
  /// (see `providerErrorMessage`).
  final String? providerMessage;

  const MealPhotoFailed(this.failure, {this.statusCode, this.providerMessage});
}

/// Reads a meal photo, when the user has asked for that, on the selected
/// provider and — when that one times out, rate-limits or fails on its side —
/// once more on the fallback provider, if one is configured.
///
/// The sibling of [ReadMealTextUseCase], with the opposite failure policy and
/// for a good reason. Text always has the deterministic parser underneath, so
/// a failed model call there is invisible: the user gets the experience they
/// had before tier 1b existed. A photo has nothing underneath it. There is no
/// offline way to turn a picture into food names, so a failure here is a real
/// dead end and the honest thing is to say so rather than to silently produce
/// nothing and let the screen look broken.
class ReadMealPhotoUseCase {
  static final _log = Logger('ReadMealPhotoUseCase');

  final AiCredentialStorage _credentials;

  /// Builds an interpreter around a key. A factory rather than an instance
  /// because the credential is read per call and should not be captured for
  /// the lifetime of a singleton.
  final MealPhotoInterpreter Function(AiSelection selection)
  _interpreterFactory;

  ReadMealPhotoUseCase(this._credentials, this._interpreterFactory);

  Future<MealPhotoReadResult> read(
    MealPhoto photo, {
    String? localeCode,
    String? caption,
  }) async {
    final selection = await _credentials.readSelection();
    if (selection == null) {
      return const MealPhotoUnavailable();
    }

    try {
      final result = await _interpreterFactory(
        selection,
      ).interpret(photo, localeCode: localeCode, caption: caption);
      return MealPhotoRead(_withModel(result, modelOf(selection)));
    } on MealInterpreterException catch (e) {
      _log.info('Photo interpreter failed: ${e.reason}');
      if (e.failure == MealInterpreterFailure.unsupported) {
        await _retractPhotoPass(selection);
      }
      if (shouldFallBack(e)) {
        final fallen = await _readWithFallback(
          photo,
          localeCode: localeCode,
          caption: caption,
        );
        if (fallen != null) return fallen;
      }
      return _failed(e);
    } catch (e, stackTrace) {
      // An interpreter that throws something unexpected is a bug. Report it
      // as a transient failure rather than as a rejected key — telling the
      // user to check a credential that is fine sends them to fix the one
      // thing that is not broken.
      _log.severe('Photo interpreter failed unexpectedly', e, stackTrace);
      return const MealPhotoFailed(MealPhotoFailure.transient);
    }
  }

  /// The failures a fallback provider is asked to cover: the selected one
  /// stopped answering in time, is rate limiting, or failed on its own side.
  /// Google's endpoint answered 503 to two of six photos in one bake-off.
  ///
  /// Not a 400 or a 401: a request the provider refused, or a key it does not
  /// know, says something about the request or the account that another
  /// provider would not fix, and the user should hear about it.
  static bool shouldFallBack(MealInterpreterException e) {
    if (e.timedOut || e.failure == MealInterpreterFailure.timeout) return true;
    final status = e.statusCode;
    return status != null && (status == 429 || (status >= 500 && status < 600));
  }

  /// One more try, on the fallback, or null when there is none or it failed
  /// too — then the selected provider's failure is what the user sees, since
  /// that is the provider they chose.
  Future<MealPhotoReadResult?> _readWithFallback(
    MealPhoto photo, {
    String? localeCode,
    String? caption,
  }) async {
    final AiSelection? fallback;
    try {
      fallback = await _credentials.readFallbackSelection();
    } catch (e, stackTrace) {
      _log.severe('Could not read the fallback provider', e, stackTrace);
      return null;
    }
    if (fallback == null) return null;

    final model = modelOf(fallback);
    try {
      final result = await _interpreterFactory(
        fallback,
      ).interpret(photo, localeCode: localeCode, caption: caption);
      _log.info('Photo read by the fallback provider');
      final estimate = result.estimate;
      return MealPhotoRead(
        result.withEstimate(
          estimate?.withModel(model).withAssumption('Estimated with $model.'),
        ),
      );
    } catch (e) {
      // Never surfaced: the fallback is a second chance, not a second error.
      _log.info('The fallback provider failed too');
      return null;
    }
  }

  /// The model a request to [selection] names.
  static String? modelOf(AiSelection selection) =>
      AiModelCatalogue.resolve(selection.provider, selection.modelId)?.id ??
      selection.modelId;

  static MealTextParseResult _withModel(
    MealTextParseResult result,
    String? model,
  ) {
    final estimate = result.estimate;
    return estimate == null
        ? result
        : result.withEstimate(estimate.withModel(model));
  }

  MealPhotoFailed _failed(MealInterpreterException e) {
    // The provider answered with an error (a status, or an error message in a
    // 200). Of the kinds it can arrive as, only these two say nothing about
    // the cause, so they become `providerError` instead of "bad image" or
    // "check your connection".
    final fromProvider = e.statusCode != null || e.providerMessage != null;
    final failure = switch (e.failure) {
      MealInterpreterFailure.auth => MealPhotoFailure.auth,
      MealInterpreterFailure.rejected =>
        fromProvider
            ? MealPhotoFailure.providerError
            : MealPhotoFailure.rejectedImage,
      MealInterpreterFailure.unsupported => MealPhotoFailure.unsupported,
      MealInterpreterFailure.billing => MealPhotoFailure.billing,
      MealInterpreterFailure.insecureDestination =>
        MealPhotoFailure.insecureDestination,
      // Reachable for the same reason and still folded on purpose: a
      // server the user runs is the only configuration that reports a
      // timeout as its own kind of failure, and "try again" is honest
      // advice for one — a cold Ollama can spend the whole budget loading
      // the model. #774.
      MealInterpreterFailure.timeout => MealPhotoFailure.transient,
      MealInterpreterFailure.transient =>
        fromProvider
            ? MealPhotoFailure.providerError
            : MealPhotoFailure.transient,
    };
    return MealPhotoFailed(
      failure,
      statusCode: e.statusCode,
      providerMessage: e.providerMessage,
    );
  }

  /// Forgets that photos ever worked here, so the camera stops being offered
  /// until a fresh check passes. #782.
  ///
  /// A stored pass is a fact about one `(endpoint, model)`, and it can stop
  /// being true without the user touching anything: pull a different model
  /// under the same tag and the camera is still offered, still says photos
  /// work, and fails on every photograph taken.
  ///
  /// **Only [MealInterpreterFailure.unsupported].** It is the one member that
  /// means *nothing on the other end can serve this kind of request* — a
  /// durable fact about the destination. `transient`, `timeout`, `auth` and
  /// `billing` say something about the network, the load, the credential or
  /// the bill, and none of them about whether the model has eyes; retracting
  /// over any of those would take a working feature away for a reason that
  /// clears on its own. `insecureDestination` is the same shape and the one
  /// this rule had to wait for — [#790] separated it out precisely so that a
  /// photo the app *refused to send* could not be read as a model that cannot
  /// see. No counter and no threshold: a rule that waits for repetition needs
  /// state whose only job is to delay a conclusion `unsupported` already
  /// states outright, plus a rule for when that state resets.
  ///
  /// Recorded as `failed` rather than as "not checked", because something was
  /// learned. `unknown` would also be a no-op: [AiCredentialStorage.writeProbe]
  /// merges, and an inconclusive verdict deliberately leaves a conclusive one
  /// alone — so writing it here would leave the pass exactly where it was.
  ///
  /// The text verdict is left as it stands. This photograph says nothing
  /// about whether a meal line still reads, and the same merge is what keeps
  /// it: `unknown` for text means "no opinion", not "forget".
  ///
  /// The configuration and write are one serialized storage operation. A
  /// photo request can outlive the settings it started with, and a failure
  /// from the old model must not recreate the probe slot
  /// [AiCredentialStorage.writeModel] just cleared for its replacement.
  Future<void> _retractPhotoPass(AiSelection selection) async {
    try {
      final stored = await _credentials.writeProbeIfConfigurationMatches(
        const AiEndpointProbe(
          text: AiCapability.unknown,
          photo: AiCapability.failed,
        ),
        provider: selection.provider,
        endpoint: selection.endpoint,
        modelId: selection.modelId,
      );
      if (!stored) {
        _log.info('Dropped a photo retraction for a configuration that moved');
      }
    } catch (e, stackTrace) {
      // A keystore that will not answer must not turn a failure the user
      // could have read into a crash on the way to reporting it.
      _log.severe('Could not retract the photo pass', e, stackTrace);
    }
  }
}
