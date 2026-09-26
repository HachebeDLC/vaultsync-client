import 'dart:io';
import 'package:flutter/services.dart';
import '../../core/services/api_client.dart';

enum SyncAction { login, openShizuku, checkNetwork, reselectFolder, none }

class UserFacingError {
  final String title;
  final String message;
  final SyncAction action;
  final dynamic originalError;

  UserFacingError({
    required this.title,
    required this.message,
    this.action = SyncAction.none,
    this.originalError,
  });

  @override
  String toString() => '$title: $message';
}

/// Thrown by [SyncRepository.syncSystem] when a system's configured local
/// folder does not exist and cannot be created because it lives inside
/// another app's `Android/data/<package>` directory — that directory is only
/// created by the emulator itself the first time it runs, and VaultSync has
/// no way to create it under scoped storage (see
/// `SystemPathService.safNeededFor`). Mapped below into a specific,
/// non-fatal, per-system message instead of the generic "Sync Failed"
/// catch-all, and must not abort syncing the other configured systems.
class MissingSyncFolderException implements Exception {
  final String systemId;
  final String path;

  MissingSyncFolderException(this.systemId, this.path);

  @override
  String toString() =>
      '$systemId: folder not found ($path). Open the emulator once or pick the folder again.';
}

/// Matches a `Bearer <token>` credential, e.g. inside a stringified HTTP
/// exception that echoes the request/response headers.
final _bearerTokenPattern =
    RegExp(r'(Bearer)\s+[A-Za-z0-9\-_.~+/]+=*', caseSensitive: false);

/// Matches `key: value` / `key=value` / `"key": "value"` pairs whose key
/// name suggests a credential — API keys, auth tokens, passwords, client
/// secrets — regardless of casing or separator style, so it catches both
/// JSON-ish and header-ish renderings of the same exception text.
///
/// Deliberately does not match the bare word "authorization": a
/// `Authorization: Bearer <token>` header is already fully handled by
/// [_bearerTokenPattern] above, and re-matching it here would consume the
/// literal word "Bearer" itself (already replaced with `[REDACTED]`) as if
/// it were the secret value, garbling the output.
final _sensitiveKeyValuePattern = RegExp(
  r'("?(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|client[_-]?secret|secret|password)"?\s*[:=]\s*)'
  r'"?[A-Za-z0-9\-_.~+/=]+"?',
  caseSensitive: false,
);

/// Redacts anything that looks like a bearer token, API key, auth header, or
/// password from [input] before it is persisted or logged. Never perfect
/// (it can't catch a secret in a shape it doesn't recognize), but it removes
/// the two most common leak shapes: `Authorization: Bearer <token>` and
/// `api_key=<value>`/`"apiKey": "<value>"`.
String _redactSensitive(String input) {
  return input
      .replaceAllMapped(_bearerTokenPattern, (m) => '${m.group(1)} [REDACTED]')
      .replaceAllMapped(
          _sensitiveKeyValuePattern, (m) => '${m.group(1)}[REDACTED]');
}

/// Builds the raw diagnostic string persisted alongside a friendly mapped
/// error (see `SyncLog.detail`) — the exception's real type and message,
/// with anything resembling a bearer token, API key, auth header or password
/// stripped (see [_redactSensitive]), then trimmed to ~300 chars. No stack
/// traces are included — `error.toString()` on Dart exceptions does not
/// include one. This is what actually failed; it is never shown as the
/// primary UI text (that stays the friendly title/message from
/// [ErrorMapper.map]) but lets adb/logcat and the in-app history show the
/// real cause instead of a swallowed generic message.
String buildErrorDetail(dynamic error) {
  final raw = _redactSensitive('${error.runtimeType}: $error');
  return raw.length > 300 ? '${raw.substring(0, 300)}…' : raw;
}

class ErrorMapper {
  static UserFacingError map(dynamic error) {
    final errStr = error.toString();

    if (error is MissingSyncFolderException) {
      return UserFacingError(
        title: 'Folder Not Found',
        message: error.toString(),
        action: SyncAction.reselectFolder,
        originalError: error,
      );
    }

    if (error is ApiException || errStr.contains('HTTP 401') || errStr.contains('HTTP 403')) {
      int statusCode = 0;
      if (error is ApiException) {
        statusCode = error.statusCode;
      } else if (errStr.contains('HTTP 401')) {
        statusCode = 401;
      } else if (errStr.contains('HTTP 403')) {
        statusCode = 403;
      }

      if (statusCode == 401 || statusCode == 403) {
        return UserFacingError(
          title: 'Session Expired',
          message: 'Your login session has expired. Please log in again.',
          action: SyncAction.login,
          originalError: error,
        );
      }
      
      return UserFacingError(
        title: 'Server Error',
        message: 'The server returned an error ($statusCode). Please try again later.',
        originalError: error,
      );
    }

    if (error is SocketException || error.toString().contains('SocketException')) {
      return UserFacingError(
        title: 'Network Error',
        message: 'Could not reach the server. Please check your internet connection.',
        action: SyncAction.checkNetwork,
        originalError: error,
      );
    }

    if (error is PlatformException) {
      if (error.code == 'SHIZUKU_NOT_RUNNING' || error.message?.contains('Shizuku') == true) {
        return UserFacingError(
          title: 'Shizuku Required',
          message: 'Shizuku is not running or authorized. It is required to access restricted system folders.',
          action: SyncAction.openShizuku,
          originalError: error,
        );
      }
    }

    final lowerErr = errStr.toLowerCase();
    if (lowerErr.contains('shizuku not running') || lowerErr.contains('shizuku not authorized')) {
      return UserFacingError(
        title: 'Shizuku Required',
        message: 'Shizuku is not running or authorized. It is required to access restricted system folders.',
        action: SyncAction.openShizuku,
        originalError: error,
      );
    }

    if (lowerErr.contains('permission denied') || lowerErr.contains('saf permission')) {
       return UserFacingError(
        title: 'Permission Denied',
        message: 'VaultSync does not have permission to access this folder. Please re-select it in Settings.',
        action: SyncAction.reselectFolder,
        originalError: error,
      );
    }

    return UserFacingError(
      title: 'Sync Failed',
      message: 'An unexpected error occurred. Please try again.',
      originalError: error,
    );
  }
}
