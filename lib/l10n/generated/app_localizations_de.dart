// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'VaultSync';

  @override
  String get syncEngineDescription =>
      'Hardwarebeschleunigte Synchronisations-Engine';

  @override
  String get settingsTitle => 'Einstellungen';

  @override
  String get sectionServerAccount => 'Server & Konto';

  @override
  String get serverUrlTitle => 'Server-URL';

  @override
  String get notSet => 'Nicht festgelegt';

  @override
  String get accountTitle => 'Konto';

  @override
  String get notLoggedIn => 'Nicht eingeloggt';

  @override
  String get logoutButton => 'ABMELDEN';

  @override
  String get sectionAutomation => 'Automatisierung (Beta)';

  @override
  String get syncOnExitTitle => 'Sync beim Beenden des Spiels';

  @override
  String get syncOnExitSubtitle =>
      'Spielstände nach dem Spielen automatisch hochladen';

  @override
  String get usageAccessRequired =>
      'Nutzungszugriff erforderlich, um das Schließen von Emulatoren zu erkennen.';

  @override
  String get grantPermissionButton => 'BERECHTIGUNG ERTEILEN';

  @override
  String get periodicSyncTitle => 'Periodischer Hintergrund-Sync';

  @override
  String get periodicSyncSubtitle =>
      'Alle 6 Stunden einen Catch-up-Sync durchführen';

  @override
  String get viewSyncHistoryTitle => 'Sync-Verlauf anzeigen';

  @override
  String get viewSyncHistorySubtitle =>
      'Protokolle von Hintergrund-Sync-Ereignissen überprüfen';

  @override
  String get conflictStrategyTitle => 'Konfliktstrategie';

  @override
  String get conflictStrategySubtitle =>
      'Wählen Sie, wie Speicherdiskrepanzen gelöst werden sollen';

  @override
  String get strategyAsk => 'Jedes Mal fragen';

  @override
  String get strategyNewest => 'Immer das Neueste';

  @override
  String get strategyLocal => 'Lokal bevorzugen';

  @override
  String get strategyCloud => 'Cloud bevorzugen';

  @override
  String get sectionHardwareBridge => 'Hardware-Brücke';

  @override
  String get useShizukuTitle => 'Shizuku-Brücke verwenden';

  @override
  String get useShizukuSubtitle =>
      'Hochgeschwindigkeitszugriff auf /data-Ordner unter Android 14+';

  @override
  String get runDiagnosticsTitle => 'Systemdiagnose ausführen';

  @override
  String get runDiagnosticsSubtitle =>
      'Hardwaregeschwindigkeit und SAF/Shizuku-Zustand testen';

  @override
  String get sectionAppearance => 'Erscheinungsbild';

  @override
  String get themeModeTitle => 'Design-Modus';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Hell';

  @override
  String get themeDark => 'Dunkel';

  @override
  String get sectionLanguage => 'Sprache';

  @override
  String get languageTitle => 'App-Sprache';

  @override
  String get sectionDeckyBridge => 'Decky-Plugin-Brücke';

  @override
  String get bridgeServiceTitle => 'Brückendienst';

  @override
  String bridgeServiceSubtitle(String status) {
    return 'Bedient localhost:5437 für das Decky-Plugin im Spielmodus\nStatus: $status';
  }

  @override
  String get statusRunning => 'Läuft';

  @override
  String get statusStopped => 'Gestoppt';

  @override
  String get statusInstalling => 'Installiere...';

  @override
  String get statusNotInstalled => 'Nicht installiert';

  @override
  String get statusChecking => 'Prüfe...';

  @override
  String get installEnableButton => 'Installieren & Aktivieren';

  @override
  String get startButton => 'Start';

  @override
  String get uninstallButton => 'Deinstallieren';

  @override
  String get stopButton => 'Stopp';

  @override
  String get openingShizuku =>
      'Öffne Shizuku... Starten Sie den Dienst und kommen Sie zurück.';

  @override
  String get shizukuAuthorized => 'Shizuku authorized!';

  @override
  String get actionLogin => 'LOGIN';

  @override
  String get actionFix => 'REPARIEREN';

  @override
  String get actionSettings => 'EINSTELLUNGEN';

  @override
  String get actionRetry => 'WIEDERHOLEN';

  @override
  String get actionDismiss => 'VERWERFEN';

  @override
  String get actionSetup => 'SETUP';

  @override
  String get actionOpenApp => 'APP ÖFFNEN';

  @override
  String get actionFixNow => 'JETZT REPARIEREN';

  @override
  String get bridgeSetupTitle => 'Empfohlen: Brücke einrichten';

  @override
  String bridgeSetupSubtitle(int version) {
    return 'Shizuku ist erforderlich für volle Geschwindigkeit auf Android $version';
  }

  @override
  String get shizukuNotRunningTitle => 'Shizuku läuft nicht';

  @override
  String get shizukuNotRunningSubtitle =>
      'Zugriff auf eingeschränkte Ordner ist deaktiviert';

  @override
  String get shizukuPermissionTitle => 'Shizuku-Berechtigung erforderlich';

  @override
  String get shizukuPermissionSubtitle =>
      'Autorisieren Sie VaultSync, um fortzufahren';

  @override
  String get scanLibraryTooltip => 'Bibliothek scannen';

  @override
  String get notificationsTooltip => 'Benachrichtigungen';

  @override
  String get settingsTooltip => 'Einstellungen';

  @override
  String get noSystemsConfigured => 'Noch keine Systeme konfiguriert.';

  @override
  String get scanLibraryButton => 'Bibliothek scannen';

  @override
  String get syncing => 'Synchronisiere...';

  @override
  String get systemReady => 'System bereit';

  @override
  String get stopSyncButton => 'SYNC STOPPEN';

  @override
  String get waitingForChanges => 'Warte auf Änderungen';

  @override
  String get syncAllButton => 'Alles synchronisieren';

  @override
  String get diagnosticsTitle => 'Systemdiagnose';

  @override
  String get runningStressTests => 'Stresstests laufen...';

  @override
  String get startDeltaSyncTest => 'Delta-Sync-Test starten';

  @override
  String refreshFailed(String error) {
    return 'Aktualisierung fehlgeschlagen: $error';
  }

  @override
  String get statusSynced => 'Synchronisiert';

  @override
  String get statusModified => 'Geändert';

  @override
  String get statusLocalOnly => 'Nur lokal';

  @override
  String get statusRemoteOnly => 'Nur entfernt';

  @override
  String get clickToViewHistory => 'Klicken, um den Versionsverlauf anzuzeigen';

  @override
  String get stateTag => 'STATUS';

  @override
  String get versionHistoryTooltip => 'Versionsverlauf';

  @override
  String systemManagementTitle(String systemId) {
    return '$systemId-Verwaltung';
  }

  @override
  String get syncNowButton => 'JETZT SYNCHRONISIEREN';

  @override
  String get syncThisSystemTooltip => 'Dieses System synchronisieren';

  @override
  String get systemNotConfigured => 'System nicht konfiguriert.';

  @override
  String get noFilesFound => 'Keine Dateien gefunden.';

  @override
  String get registrationFailed => 'Registrierung fehlgeschlagen';

  @override
  String get loginFailed => 'Login fehlgeschlagen';

  @override
  String get createAccountTitle => 'Konto erstellen';

  @override
  String get loginTitle => 'Login';

  @override
  String get serverSettingsTooltip => 'Server-Einstellungen';

  @override
  String get usernameLabel => 'Benutzername';

  @override
  String get emailLabel => 'E-Mail';

  @override
  String get passwordLabel => 'Passwort';

  @override
  String get createAccountButton => 'KONTO ERSTELLEN';

  @override
  String get loginButton => 'LOGIN';

  @override
  String get forgotPasswordButton => 'Passwort vergessen?';

  @override
  String get alreadyHaveAccount => 'Bereits ein Konto? Anmelden';

  @override
  String get dontHaveAccount => 'Kein Konto? Jetzt registrieren';

  @override
  String get diagnosticReportTitle => 'Diagnosebericht';

  @override
  String get diagnosticReportDescription =>
      'Der folgende Bericht wird an GitHub übermittelt. Sensible Informationen wie E-Mails und vollständige Pfade wurden geschwärzt.';

  @override
  String get reportCopied => 'Bericht in die Zwischenablage kopiert';

  @override
  String get copyButton => 'KOPIEREN';

  @override
  String get reportToGithubButton => 'AN GITHUB MELDEN';

  @override
  String get sessionEventsTitle => 'Sitzungsereignisse';

  @override
  String get reportButton => 'Bericht';

  @override
  String get clearButton => 'Löschen';

  @override
  String get noEventsInSession => 'Keine Ereignisse in dieser Sitzung';

  @override
  String get actionFixBridge => 'BRÜCKE REPARIEREN';

  @override
  String get syncHistoryTitle => 'Sync-Verlauf';

  @override
  String get clearHistoryTooltip => 'Verlauf löschen';

  @override
  String get noSyncHistoryFound => 'Kein Sync-Verlauf gefunden.';

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
}
