import '../domain/manifest.dart';
import '../domain/position.dart';
import '../domain/resolver.dart' show jumpThresholdMs;
import '../l10n/strings.dart';

/// The undo hint banner shown after a jump over 2 min (invariant 6 /
/// docs/KONZEPT.md Texte-Tabelle: "Zurück zu Kapitel 7, 23:41"). Pure: it
/// only formats text and carries the [target] position the "Rückgängig"
/// action should return to -- the caller (audio/handler.dart, wired from
/// ui/player_screen.dart) is the one that turns a tap into an `UNDO` event
/// through the journal (invariant 3).
class UndoHint {
  final Position target;
  final String message;

  /// The SnackBar action; null: "Rückgängig".
  final String? actionLabel;

  const UndoHint({required this.target, required this.message, this.actionLabel});

  /// After a start from the Faden search (decision E89): "Rückgängig:
  /// wieder, wo es anhielt" with "Zurück" back to [target].
  UndoHint.fromFaden(this.target)
      : message = AppStrings.undoHintFaden,
        actionLabel = AppStrings.undoActionBack;
}

/// Whether a jump from [fromGlobalMs] to [toGlobalMs] is "over 2 minutes"
/// (invariant 6 / docs/ARCHITEKTUR.md section 7 rule 6 use the same
/// threshold, [jumpThresholdMs]).
bool isUndoWorthyJump(int fromGlobalMs, int toGlobalMs) =>
    (toGlobalMs - fromGlobalMs).abs() > jumpThresholdMs;

/// Builds the undo hint for a jump away from [from], or null if the jump
/// was not "over 2 minutes" (per [isUndoWorthyJump]) or [from]'s
/// `file_hash` is not part of [manifest] (its global-ms position, and so
/// its chapter number, cannot be determined).
UndoHint? undoHintForJump({
  required Position from,
  required int fromGlobalMs,
  required int toGlobalMs,
  required Manifest manifest,
}) {
  if (!isUndoWorthyJump(fromGlobalMs, toGlobalMs)) return null;
  final chapterIndex = manifest.files.indexWhere((f) => f.fileHash == from.fileHash);
  if (chapterIndex == -1) return null;
  final chapter = AppStrings.chapterLabel(chapterIndex + 1);
  final time = _formatMmSs(from.offsetMs);
  return UndoHint(target: from, message: AppStrings.undoHint(chapter, time));
}

String _formatMmSs(int offsetMs) {
  final totalSeconds = offsetMs ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
