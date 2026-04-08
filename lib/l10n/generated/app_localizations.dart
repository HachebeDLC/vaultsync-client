import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_it.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('it')
  ];

  /// The title of the application
  ///
  /// In en, this message translates to:
  /// **'VaultSync'**
  String get appTitle;

  /// Description of the sync engine
  ///
  /// In en, this message translates to:
  /// **'Hardware-Accelerated Sync Engine'**
  String get syncEngineDescription;

  /// Title of the settings screen
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @sectionServerAccount.
  ///
  /// In en, this message translates to:
  /// **'Server & Account'**
  String get sectionServerAccount;

  /// No description provided for @serverUrlTitle.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serverUrlTitle;

  /// No description provided for @notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get notSet;

  /// No description provided for @accountTitle.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountTitle;

  /// No description provided for @notLoggedIn.
  ///
  /// In en, this message translates to:
  /// **'Not logged in'**
  String get notLoggedIn;

  /// No description provided for @logoutButton.
  ///
  /// In en, this message translates to:
  /// **'LOGOUT'**
  String get logoutButton;

  /// No description provided for @sectionAutomation.
  ///
  /// In en, this message translates to:
  /// **'Automation (Beta)'**
  String get sectionAutomation;

  /// No description provided for @syncOnExitTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync on Game Exit'**
  String get syncOnExitTitle;

  /// No description provided for @syncOnExitSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Upload saves automatically when you finish playing'**
  String get syncOnExitSubtitle;

  /// No description provided for @usageAccessRequired.
  ///
  /// In en, this message translates to:
  /// **'Usage Access is required to detect when emulators close.'**
  String get usageAccessRequired;

  /// No description provided for @grantPermissionButton.
  ///
  /// In en, this message translates to:
  /// **'GRANT PERMISSION'**
  String get grantPermissionButton;

  /// No description provided for @periodicSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Periodic Background Sync'**
  String get periodicSyncTitle;

  /// No description provided for @periodicSyncSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Perform a catch-up sync every 6 hours'**
  String get periodicSyncSubtitle;

  /// No description provided for @viewSyncHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'View Sync History'**
  String get viewSyncHistoryTitle;

  /// No description provided for @viewSyncHistorySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Review logs of background sync events'**
  String get viewSyncHistorySubtitle;

  /// No description provided for @conflictStrategyTitle.
  ///
  /// In en, this message translates to:
  /// **'Conflict Strategy'**
  String get conflictStrategyTitle;

  /// No description provided for @conflictStrategySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose how to resolve save discrepancies'**
  String get conflictStrategySubtitle;

  /// No description provided for @strategyAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask Every Time'**
  String get strategyAsk;

  /// No description provided for @strategyNewest.
  ///
  /// In en, this message translates to:
  /// **'Always Newest'**
  String get strategyNewest;

  /// No description provided for @strategyLocal.
  ///
  /// In en, this message translates to:
  /// **'Prefer Local'**
  String get strategyLocal;

  /// No description provided for @strategyCloud.
  ///
  /// In en, this message translates to:
  /// **'Prefer Cloud'**
  String get strategyCloud;

  /// No description provided for @sectionHardwareBridge.
  ///
  /// In en, this message translates to:
  /// **'Hardware Bridge'**
  String get sectionHardwareBridge;

  /// No description provided for @useShizukuTitle.
  ///
  /// In en, this message translates to:
  /// **'Use Shizuku Bridge'**
  String get useShizukuTitle;

  /// No description provided for @useShizukuSubtitle.
  ///
  /// In en, this message translates to:
  /// **'High-speed access for Android 14+ /data folders'**
  String get useShizukuSubtitle;

  /// No description provided for @runDiagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Run System Diagnostics'**
  String get runDiagnosticsTitle;

  /// No description provided for @runDiagnosticsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Test hardware speed and SAF/Shizuku health'**
  String get runDiagnosticsSubtitle;

  /// No description provided for @sectionAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get sectionAppearance;

  /// No description provided for @themeModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Theme Mode'**
  String get themeModeTitle;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @sectionLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get sectionLanguage;

  /// No description provided for @languageTitle.
  ///
  /// In en, this message translates to:
  /// **'App Language'**
  String get languageTitle;

  /// No description provided for @sectionDeckyBridge.
  ///
  /// In en, this message translates to:
  /// **'Decky Plugin Bridge'**
  String get sectionDeckyBridge;

  /// No description provided for @bridgeServiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Bridge Service'**
  String get bridgeServiceTitle;

  /// No description provided for @bridgeServiceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Serves localhost:5437 for the Decky plugin in Game Mode\nStatus: {status}'**
  String bridgeServiceSubtitle(String status);

  /// No description provided for @statusRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get statusRunning;

  /// No description provided for @statusStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get statusStopped;

  /// No description provided for @statusInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing...'**
  String get statusInstalling;

  /// No description provided for @statusNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Not installed'**
  String get statusNotInstalled;

  /// No description provided for @statusChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get statusChecking;

  /// No description provided for @installEnableButton.
  ///
  /// In en, this message translates to:
  /// **'Install & Enable'**
  String get installEnableButton;

  /// No description provided for @startButton.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get startButton;

  /// No description provided for @uninstallButton.
  ///
  /// In en, this message translates to:
  /// **'Uninstall'**
  String get uninstallButton;

  /// No description provided for @stopButton.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopButton;

  /// No description provided for @openingShizuku.
  ///
  /// In en, this message translates to:
  /// **'Opening Shizuku... Start the service and come back.'**
  String get openingShizuku;

  /// No description provided for @shizukuAuthorized.
  ///
  /// In en, this message translates to:
  /// **'Shizuku authorized!'**
  String get shizukuAuthorized;

  /// No description provided for @actionLogin.
  ///
  /// In en, this message translates to:
  /// **'LOGIN'**
  String get actionLogin;

  /// No description provided for @actionFix.
  ///
  /// In en, this message translates to:
  /// **'FIX'**
  String get actionFix;

  /// No description provided for @actionSettings.
  ///
  /// In en, this message translates to:
  /// **'SETTINGS'**
  String get actionSettings;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'RETRY'**
  String get actionRetry;

  /// No description provided for @actionDismiss.
  ///
  /// In en, this message translates to:
  /// **'DISMISS'**
  String get actionDismiss;

  /// No description provided for @actionSetup.
  ///
  /// In en, this message translates to:
  /// **'SETUP'**
  String get actionSetup;

  /// No description provided for @actionOpenApp.
  ///
  /// In en, this message translates to:
  /// **'OPEN APP'**
  String get actionOpenApp;

  /// No description provided for @actionFixNow.
  ///
  /// In en, this message translates to:
  /// **'FIX NOW'**
  String get actionFixNow;

  /// No description provided for @bridgeSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommended: Setup Bridge'**
  String get bridgeSetupTitle;

  /// No description provided for @bridgeSetupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Shizuku is required for full speed on Android {version}'**
  String bridgeSetupSubtitle(int version);

  /// No description provided for @shizukuNotRunningTitle.
  ///
  /// In en, this message translates to:
  /// **'Shizuku is not running'**
  String get shizukuNotRunningTitle;

  /// No description provided for @shizukuNotRunningSubtitle.
  ///
  /// In en, this message translates to:
  /// **'restricted folder access is disabled'**
  String get shizukuNotRunningSubtitle;

  /// No description provided for @shizukuPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Shizuku Permission Required'**
  String get shizukuPermissionTitle;

  /// No description provided for @shizukuPermissionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'authorize VaultSync to continue'**
  String get shizukuPermissionSubtitle;

  /// No description provided for @scanLibraryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Scan Library'**
  String get scanLibraryTooltip;

  /// No description provided for @notificationsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsTooltip;

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @noSystemsConfigured.
  ///
  /// In en, this message translates to:
  /// **'No systems configured yet.'**
  String get noSystemsConfigured;

  /// No description provided for @scanLibraryButton.
  ///
  /// In en, this message translates to:
  /// **'Scan Library'**
  String get scanLibraryButton;

  /// No description provided for @syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing...'**
  String get syncing;

  /// No description provided for @systemReady.
  ///
  /// In en, this message translates to:
  /// **'System Ready'**
  String get systemReady;

  /// No description provided for @stopSyncButton.
  ///
  /// In en, this message translates to:
  /// **'STOP SYNC'**
  String get stopSyncButton;

  /// No description provided for @waitingForChanges.
  ///
  /// In en, this message translates to:
  /// **'Waiting for changes'**
  String get waitingForChanges;

  /// No description provided for @syncAllButton.
  ///
  /// In en, this message translates to:
  /// **'Sync All'**
  String get syncAllButton;

  /// No description provided for @diagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'System Diagnostics'**
  String get diagnosticsTitle;

  /// No description provided for @runningStressTests.
  ///
  /// In en, this message translates to:
  /// **'Running Stress Tests...'**
  String get runningStressTests;

  /// No description provided for @startDeltaSyncTest.
  ///
  /// In en, this message translates to:
  /// **'Start Delta Sync Test'**
  String get startDeltaSyncTest;

  /// No description provided for @refreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Refresh failed: {error}'**
  String refreshFailed(String error);

  /// No description provided for @statusSynced.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get statusSynced;

  /// No description provided for @statusModified.
  ///
  /// In en, this message translates to:
  /// **'Modified'**
  String get statusModified;

  /// No description provided for @statusLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'Local Only'**
  String get statusLocalOnly;

  /// No description provided for @statusRemoteOnly.
  ///
  /// In en, this message translates to:
  /// **'Remote Only'**
  String get statusRemoteOnly;

  /// No description provided for @clickToViewHistory.
  ///
  /// In en, this message translates to:
  /// **'Click to view version history'**
  String get clickToViewHistory;

  /// No description provided for @stateTag.
  ///
  /// In en, this message translates to:
  /// **'STATE'**
  String get stateTag;

  /// No description provided for @versionHistoryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Version History'**
  String get versionHistoryTooltip;

  /// No description provided for @systemManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'{systemId} Management'**
  String systemManagementTitle(String systemId);

  /// No description provided for @syncNowButton.
  ///
  /// In en, this message translates to:
  /// **'SYNC NOW'**
  String get syncNowButton;

  /// No description provided for @syncThisSystemTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sync This System'**
  String get syncThisSystemTooltip;

  /// No description provided for @systemNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'System not configured.'**
  String get systemNotConfigured;

  /// No description provided for @noFilesFound.
  ///
  /// In en, this message translates to:
  /// **'No files found.'**
  String get noFilesFound;

  /// No description provided for @registrationFailed.
  ///
  /// In en, this message translates to:
  /// **'Registration failed'**
  String get registrationFailed;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Login failed'**
  String get loginFailed;

  /// No description provided for @createAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get createAccountTitle;

  /// No description provided for @loginTitle.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get loginTitle;

  /// No description provided for @serverSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Server Settings'**
  String get serverSettingsTooltip;

  /// No description provided for @usernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get usernameLabel;

  /// No description provided for @emailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @createAccountButton.
  ///
  /// In en, this message translates to:
  /// **'CREATE ACCOUNT'**
  String get createAccountButton;

  /// No description provided for @loginButton.
  ///
  /// In en, this message translates to:
  /// **'LOGIN'**
  String get loginButton;

  /// No description provided for @forgotPasswordButton.
  ///
  /// In en, this message translates to:
  /// **'Forgot Password?'**
  String get forgotPasswordButton;

  /// No description provided for @alreadyHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign In'**
  String get alreadyHaveAccount;

  /// No description provided for @dontHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account? Register Now'**
  String get dontHaveAccount;

  /// No description provided for @diagnosticReportTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic Report'**
  String get diagnosticReportTitle;

  /// No description provided for @diagnosticReportDescription.
  ///
  /// In en, this message translates to:
  /// **'The following report will be submitted to GitHub. Sensitive information like emails and full paths have been redacted.'**
  String get diagnosticReportDescription;

  /// No description provided for @reportCopied.
  ///
  /// In en, this message translates to:
  /// **'Report copied to clipboard'**
  String get reportCopied;

  /// No description provided for @copyButton.
  ///
  /// In en, this message translates to:
  /// **'COPY'**
  String get copyButton;

  /// No description provided for @reportToGithubButton.
  ///
  /// In en, this message translates to:
  /// **'REPORT TO GITHUB'**
  String get reportToGithubButton;

  /// No description provided for @sessionEventsTitle.
  ///
  /// In en, this message translates to:
  /// **'Session Events'**
  String get sessionEventsTitle;

  /// No description provided for @reportButton.
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get reportButton;

  /// No description provided for @clearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clearButton;

  /// No description provided for @noEventsInSession.
  ///
  /// In en, this message translates to:
  /// **'No events in this session'**
  String get noEventsInSession;

  /// No description provided for @actionFixBridge.
  ///
  /// In en, this message translates to:
  /// **'FIX BRIDGE'**
  String get actionFixBridge;

  /// No description provided for @syncHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync History'**
  String get syncHistoryTitle;

  /// No description provided for @clearHistoryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Clear History'**
  String get clearHistoryTooltip;

  /// No description provided for @noSyncHistoryFound.
  ///
  /// In en, this message translates to:
  /// **'No sync history found.'**
  String get noSyncHistoryFound;

  /// No description provided for @recoverVaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Recover Vault'**
  String get recoverVaultTitle;

  /// No description provided for @enterEmailToRecover.
  ///
  /// In en, this message translates to:
  /// **'Enter your email to retrieve your recovery questions.'**
  String get enterEmailToRecover;

  /// No description provided for @fetchRecoveryInfoButton.
  ///
  /// In en, this message translates to:
  /// **'FETCH RECOVERY INFO'**
  String get fetchRecoveryInfoButton;

  /// No description provided for @answerSecurityQuestions.
  ///
  /// In en, this message translates to:
  /// **'Please answer your security questions to restore your master key.'**
  String get answerSecurityQuestions;

  /// No description provided for @masterKeyRestored.
  ///
  /// In en, this message translates to:
  /// **'Master key restored! You can now log in.'**
  String get masterKeyRestored;

  /// No description provided for @recoveryFailed.
  ///
  /// In en, this message translates to:
  /// **'Recovery failed: {error}'**
  String recoveryFailed(String error);

  /// No description provided for @restoreMasterKeyButton.
  ///
  /// In en, this message translates to:
  /// **'RESTORE MASTER KEY'**
  String get restoreMasterKeyButton;

  /// No description provided for @recoverySetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery Setup'**
  String get recoverySetupTitle;

  /// No description provided for @recoverySetupSaved.
  ///
  /// In en, this message translates to:
  /// **'Recovery setup saved successfully!'**
  String get recoverySetupSaved;

  /// No description provided for @errorSavingRecovery.
  ///
  /// In en, this message translates to:
  /// **'Error saving recovery: {error}'**
  String errorSavingRecovery(String error);

  /// No description provided for @saveRecoverySetupButton.
  ///
  /// In en, this message translates to:
  /// **'SAVE RECOVERY SETUP'**
  String get saveRecoverySetupButton;

  /// No description provided for @librarySetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Library Setup'**
  String get librarySetupTitle;

  /// No description provided for @noSystemsFound.
  ///
  /// In en, this message translates to:
  /// **'No systems found in that folder.'**
  String get noSystemsFound;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String errorGeneric(String error);

  /// No description provided for @noInstalledEmulatorsFound.
  ///
  /// In en, this message translates to:
  /// **'No installed emulators found for {systemName}.'**
  String noInstalledEmulatorsFound(String systemName);

  /// No description provided for @selectEmulatorFor.
  ///
  /// In en, this message translates to:
  /// **'Select Emulator for {systemName}'**
  String selectEmulatorFor(String systemName);

  /// No description provided for @configureSavePathTitle.
  ///
  /// In en, this message translates to:
  /// **'Configure Save Path'**
  String get configureSavePathTitle;

  /// No description provided for @emulatorLabel.
  ///
  /// In en, this message translates to:
  /// **'Emulator: {emulatorName}'**
  String emulatorLabel(String emulatorName);

  /// No description provided for @saveFolderLabel.
  ///
  /// In en, this message translates to:
  /// **'Save Folder:'**
  String get saveFolderLabel;

  /// No description provided for @cancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelButton;

  /// No description provided for @saveButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveButton;

  /// No description provided for @finishSetupButton.
  ///
  /// In en, this message translates to:
  /// **'FINISH SETUP'**
  String get finishSetupButton;

  /// No description provided for @selectRomsRoot.
  ///
  /// In en, this message translates to:
  /// **'SELECT ROMS ROOT'**
  String get selectRomsRoot;

  /// No description provided for @baseFolderDescription.
  ///
  /// In en, this message translates to:
  /// **'Base folder containing your game subfolders (e.g. Roms/ps2, Roms/snes).'**
  String get baseFolderDescription;

  /// No description provided for @pathLabel.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get pathLabel;

  /// No description provided for @scanLibraryAction.
  ///
  /// In en, this message translates to:
  /// **'SCAN LIBRARY'**
  String get scanLibraryAction;

  /// No description provided for @noSystemsDetected.
  ///
  /// In en, this message translates to:
  /// **'No systems detected yet.\nSelect your ROMs root and click \"Scan\".'**
  String get noSystemsDetected;

  /// No description provided for @detectedSystems.
  ///
  /// In en, this message translates to:
  /// **'DETECTED SYSTEMS'**
  String get detectedSystems;

  /// No description provided for @noInstalledEmulatorsForDetected.
  ///
  /// In en, this message translates to:
  /// **'No installed emulators found for the detected systems.'**
  String get noInstalledEmulatorsForDetected;

  /// No description provided for @configuredStatus.
  ///
  /// In en, this message translates to:
  /// **'Configured'**
  String get configuredStatus;

  /// No description provided for @needsSetupStatus.
  ///
  /// In en, this message translates to:
  /// **'Needs Setup'**
  String get needsSetupStatus;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en', 'es', 'fr', 'it'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'it':
      return AppLocalizationsIt();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
