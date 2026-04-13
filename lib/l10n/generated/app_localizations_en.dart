// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'VaultSync';

  @override
  String get syncEngineDescription => 'Hardware-Accelerated Sync Engine';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get sectionServerAccount => 'Server & Account';

  @override
  String get serverUrlTitle => 'Server URL';

  @override
  String get notSet => 'Not set';

  @override
  String get accountTitle => 'Account';

  @override
  String get notLoggedIn => 'Not logged in';

  @override
  String get logoutButton => 'LOGOUT';

  @override
  String get sectionAutomation => 'Automation (Beta)';

  @override
  String get syncOnExitTitle => 'Sync on Game Exit';

  @override
  String get syncOnExitSubtitle =>
      'Upload saves automatically when you finish playing';

  @override
  String get usageAccessRequired =>
      'Usage Access is required to detect when emulators close.';

  @override
  String get grantPermissionButton => 'GRANT PERMISSION';

  @override
  String get periodicSyncTitle => 'Periodic Background Sync';

  @override
  String get periodicSyncSubtitle => 'Perform a catch-up sync every 6 hours';

  @override
  String get viewSyncHistoryTitle => 'View Sync History';

  @override
  String get viewSyncHistorySubtitle => 'Review logs of background sync events';

  @override
  String get conflictStrategyTitle => 'Conflict Strategy';

  @override
  String get conflictStrategySubtitle =>
      'Choose how to resolve save discrepancies';

  @override
  String get strategyAsk => 'Ask Every Time';

  @override
  String get strategyNewest => 'Always Newest';

  @override
  String get strategyLocal => 'Prefer Local';

  @override
  String get strategyCloud => 'Prefer Cloud';

  @override
  String get sectionHardwareBridge => 'Hardware Bridge';

  @override
  String get useShizukuTitle => 'Use Shizuku Bridge';

  @override
  String get useShizukuSubtitle =>
      'High-speed access for Android 14+ /data folders';

  @override
  String get runDiagnosticsTitle => 'Run System Diagnostics';

  @override
  String get runDiagnosticsSubtitle =>
      'Test hardware speed and SAF/Shizuku health';

  @override
  String get sectionAppearance => 'Appearance';

  @override
  String get themeModeTitle => 'Theme Mode';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get sectionLanguage => 'Language';

  @override
  String get languageTitle => 'App Language';

  @override
  String get sectionDeckyBridge => 'Decky Plugin Bridge';

  @override
  String get bridgeServiceTitle => 'Bridge Service';

  @override
  String bridgeServiceSubtitle(String status) {
    return 'Serves localhost:5437 for the Decky plugin in Game Mode\nStatus: $status';
  }

  @override
  String get statusRunning => 'Running';

  @override
  String get statusStopped => 'Stopped';

  @override
  String get statusInstalling => 'Installing...';

  @override
  String get statusNotInstalled => 'Not installed';

  @override
  String get statusChecking => 'Checking...';

  @override
  String get installEnableButton => 'Install & Enable';

  @override
  String get startButton => 'Start';

  @override
  String get uninstallButton => 'Uninstall';

  @override
  String get stopButton => 'Stop';

  @override
  String get openingShizuku =>
      'Opening Shizuku... Start the service and come back.';

  @override
  String get shizukuAuthorized => 'Shizuku authorized!';

  @override
  String get actionLogin => 'LOGIN';

  @override
  String get actionFix => 'FIX';

  @override
  String get actionSettings => 'SETTINGS';

  @override
  String get actionRetry => 'RETRY';

  @override
  String get actionDismiss => 'DISMISS';

  @override
  String get actionSetup => 'SETUP';

  @override
  String get actionOpenApp => 'OPEN APP';

  @override
  String get actionFixNow => 'FIX NOW';

  @override
  String get bridgeSetupTitle => 'Recommended: Setup Bridge';

  @override
  String bridgeSetupSubtitle(int version) {
    return 'Shizuku is required for full speed on Android $version';
  }

  @override
  String get shizukuNotRunningTitle => 'Shizuku is not running';

  @override
  String get shizukuNotRunningSubtitle =>
      'restricted folder access is disabled';

  @override
  String get shizukuPermissionTitle => 'Shizuku Permission Required';

  @override
  String get shizukuPermissionSubtitle => 'authorize VaultSync to continue';

  @override
  String get scanLibraryTooltip => 'Scan Library';

  @override
  String get notificationsTooltip => 'Notifications';

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get noSystemsConfigured => 'No systems configured yet.';

  @override
  String get scanLibraryButton => 'Scan Library';

  @override
  String get syncing => 'Syncing...';

  @override
  String get systemReady => 'System Ready';

  @override
  String get stopSyncButton => 'STOP SYNC';

  @override
  String get waitingForChanges => 'Waiting for changes';

  @override
  String get syncAllButton => 'Sync All';

  @override
  String get diagnosticsTitle => 'System Diagnostics';

  @override
  String get runningStressTests => 'Running Stress Tests...';

  @override
  String get startDeltaSyncTest => 'Start Delta Sync Test';

  @override
  String refreshFailed(String error) {
    return 'Refresh failed: $error';
  }

  @override
  String get statusSynced => 'Synced';

  @override
  String get statusModified => 'Modified';

  @override
  String get statusLocalOnly => 'Local Only';

  @override
  String get statusRemoteOnly => 'Remote Only';

  @override
  String get clickToViewHistory => 'Click to view version history';

  @override
  String get stateTag => 'STATE';

  @override
  String get versionHistoryTooltip => 'Version History';

  @override
  String systemManagementTitle(String systemId) {
    return '$systemId Management';
  }

  @override
  String get syncNowButton => 'SYNC NOW';

  @override
  String get syncThisSystemTooltip => 'Sync This System';

  @override
  String get systemNotConfigured => 'System not configured.';

  @override
  String get noFilesFound => 'No files found.';

  @override
  String get registrationFailed => 'Registration failed';

  @override
  String get loginFailed => 'Login failed';

  @override
  String get createAccountTitle => 'Create Account';

  @override
  String get loginTitle => 'Login';

  @override
  String get serverSettingsTooltip => 'Server Settings';

  @override
  String get usernameLabel => 'Username';

  @override
  String get emailLabel => 'Email';

  @override
  String get passwordLabel => 'Password';

  @override
  String get createAccountButton => 'CREATE ACCOUNT';

  @override
  String get loginButton => 'LOGIN';

  @override
  String get forgotPasswordButton => 'Forgot Password?';

  @override
  String get alreadyHaveAccount => 'Already have an account? Sign In';

  @override
  String get dontHaveAccount => 'Don\'t have an account? Register Now';

  @override
  String get diagnosticReportTitle => 'Diagnostic Report';

  @override
  String get diagnosticReportDescription =>
      'The following report will be submitted to GitHub. Sensitive information like emails and full paths have been redacted.';

  @override
  String get reportCopied => 'Report copied to clipboard';

  @override
  String get copyButton => 'COPY';

  @override
  String get reportToGithubButton => 'REPORT TO GITHUB';

  @override
  String get sessionEventsTitle => 'Session Events';

  @override
  String get reportButton => 'Report';

  @override
  String get clearButton => 'Clear';

  @override
  String get noEventsInSession => 'No events in this session';

  @override
  String get actionFixBridge => 'FIX BRIDGE';

  @override
  String get syncHistoryTitle => 'Sync History';

  @override
  String get clearHistoryTooltip => 'Clear History';

  @override
  String get noSyncHistoryFound => 'No sync history found.';

  @override
  String get recoverVaultTitle => 'Recover Vault';

  @override
  String get enterEmailToRecover =>
      'Enter your email to retrieve your recovery questions.';

  @override
  String get fetchRecoveryInfoButton => 'FETCH RECOVERY INFO';

  @override
  String get answerSecurityQuestions =>
      'Please answer your security questions to restore your master key.';

  @override
  String get masterKeyRestored => 'Master key restored! You can now log in.';

  @override
  String recoveryFailed(String error) {
    return 'Recovery failed: $error';
  }

  @override
  String get restoreMasterKeyButton => 'RESTORE MASTER KEY';

  @override
  String get recoverySetupTitle => 'Recovery Setup';

  @override
  String get recoverySetupSaved => 'Recovery setup saved successfully!';

  @override
  String errorSavingRecovery(String error) {
    return 'Error saving recovery: $error';
  }

  @override
  String get saveRecoverySetupButton => 'SAVE RECOVERY SETUP';

  @override
  String get librarySetupTitle => 'Library Setup';

  @override
  String get noSystemsFound => 'No systems found in that folder.';

  @override
  String errorGeneric(String error) {
    return 'Error: $error';
  }

  @override
  String noInstalledEmulatorsFound(String systemName) {
    return 'No installed emulators found for $systemName.';
  }

  @override
  String selectEmulatorFor(String systemName) {
    return 'Select Emulator for $systemName';
  }

  @override
  String get configureSavePathTitle => 'Configure Save Path';

  @override
  String emulatorLabel(String emulatorName) {
    return 'Emulator: $emulatorName';
  }

  @override
  String get saveFolderLabel => 'Save Folder:';

  @override
  String get cancelButton => 'Cancel';

  @override
  String get saveButton => 'Save';

  @override
  String get finishSetupButton => 'FINISH SETUP';

  @override
  String get selectRomsRoot => 'SELECT ROMS ROOT';

  @override
  String get baseFolderDescription =>
      'Base folder containing your game subfolders (e.g. Roms/ps2, Roms/snes).';

  @override
  String get pathLabel => 'Path';

  @override
  String get scanLibraryAction => 'SCAN LIBRARY';

  @override
  String get noSystemsDetected =>
      'No systems detected yet.\nSelect your ROMs root and click \"Scan\".';

  @override
  String get detectedSystems => 'DETECTED SYSTEMS';

  @override
  String get noInstalledEmulatorsForDetected =>
      'No installed emulators found for the detected systems.';

  @override
  String get configuredStatus => 'Configured';

  @override
  String get needsSetupStatus => 'Needs Setup';

  @override
  String get deployToDeckyButton => 'Deploy to Decky';

  @override
  String get deployToDeckySubtitle => 'Installs the plugin files to Game Mode';

  @override
  String get pluginDeployedSuccess =>
      'Decky plugin deployed! Restart Decky or reload plugins to see it.';

  @override
  String deployFailed(String error) {
    return 'Deployment failed: $error';
  }

  @override
  String get sectionEcosystem => 'Ecosystem Integration';

  @override
  String get rommSyncTitle => 'RomM Integration';

  @override
  String get rommSyncSubtitle =>
      'Automatically push decrypted saves to your RomM server';

  @override
  String get rommUrlLabel => 'RomM Server URL';

  @override
  String get rommApiKeyLabel => 'RomM API Key';

  @override
  String get rommUrlHint => 'e.g., https://romm.example.com';

  @override
  String get rommApiKeyHint => 'rmm_...';
}
