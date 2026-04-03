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

class ErrorMapper {
  static UserFacingError map(dynamic error) {
    final errStr = error.toString();
    
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
