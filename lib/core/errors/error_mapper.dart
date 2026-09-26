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

/// Builds the raw diagnostic string persisted alongside a friendly mapped
/// error (see `SyncLog.detail`) — the exception's real type and message,
/// trimmed to ~300 chars. This is what actually failed; it is never shown as
/// the primary UI text (that stays the friendly title/message from
/// [ErrorMapper.map]) but lets adb/logcat and the in-app history show the
/// real cause instead of a swallowed generic message.
String buildErrorDetail(dynamic error) {
  final raw = '${error.runtimeType}: $error';
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
