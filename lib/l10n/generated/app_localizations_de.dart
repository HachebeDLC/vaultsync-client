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
  String get shizukuAuthorized => 'Shizuku autorisiert!';

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
  String get recoverVaultTitle => 'Vault wiederherstellen';

  @override
  String get enterEmailToRecover =>
      'Gib deine E-Mail-Adresse ein, um deine Sicherheitsfragen abzurufen.';

  @override
  String get fetchRecoveryInfoButton => 'WIEDERHERSTELLUNGSINFOS ABRUFEN';

  @override
  String get answerSecurityQuestions =>
      'Beantworte deine Sicherheitsfragen, um deinen Master-Key wiederherzustellen.';

  @override
  String get masterKeyRestored =>
      'Master-Key wiederhergestellt! Du kannst dich jetzt anmelden.';

  @override
  String recoveryFailed(String error) {
    return 'Wiederherstellung fehlgeschlagen: $error';
  }

  @override
  String get restoreMasterKeyButton => 'MASTER-KEY WIEDERHERSTELLEN';

  @override
  String get recoverySetupTitle => 'Wiederherstellungs-Setup';

  @override
  String get recoverySetupSaved =>
      'Wiederherstellungs-Setup erfolgreich gespeichert!';

  @override
  String errorSavingRecovery(String error) {
    return 'Fehler beim Speichern der Wiederherstellung: $error';
  }

  @override
  String get saveRecoverySetupButton => 'WIEDERHERSTELLUNGS-SETUP SPEICHERN';

  @override
  String get librarySetupTitle => 'Bibliotheks-Setup';

  @override
  String get noSystemsFound => 'Keine Systeme in diesem Ordner gefunden.';

  @override
  String errorGeneric(String error) {
    return 'Fehler: $error';
  }

  @override
  String noInstalledEmulatorsFound(String systemName) {
    return 'Keine installierten Emulatoren für $systemName gefunden.';
  }

  @override
  String selectEmulatorFor(String systemName) {
    return 'Emulator für $systemName auswählen';
  }

  @override
  String get configureSavePathTitle => 'Speicherpfad konfigurieren';

  @override
  String emulatorLabel(String emulatorName) {
    return 'Emulator: $emulatorName';
  }

  @override
  String get saveFolderLabel => 'Speicherordner:';

  @override
  String get cancelButton => 'Abbrechen';

  @override
  String get saveButton => 'Speichern';

  @override
  String get finishSetupButton => 'SETUP ABSCHLIESSEN';

  @override
  String get selectRomsRoot => 'ROM-STAMMORDNER AUSWÄHLEN';

  @override
  String get baseFolderDescription =>
      'Basisordner mit deinen Spiel-Unterordnern (z. B. Roms/ps2, Roms/snes).';

  @override
  String get pathLabel => 'Pfad';

  @override
  String get scanLibraryAction => 'BIBLIOTHEK SCANNEN';

  @override
  String get noSystemsDetected =>
      'Noch keine Systeme erkannt.\nWähle deinen ROM-Stammordner aus und klicke auf \"Scannen\".';

  @override
  String get detectedSystems => 'ERKANNTE SYSTEME';

  @override
  String get noInstalledEmulatorsForDetected =>
      'Keine installierten Emulatoren für die erkannten Systeme gefunden.';

  @override
  String get configuredStatus => 'Konfiguriert';

  @override
  String get needsSetupStatus => 'Setup erforderlich';

  @override
  String get deployToDeckyButton => 'Im Decky installieren';

  @override
  String get deployToDeckySubtitle =>
      'Installiert die Plugin-Dateien im Spielmodus';

  @override
  String get pluginDeployedSuccess =>
      'Decky-Plugin bereitgestellt! Starten Sie Decky neu oder laden Sie die Plugins neu.';

  @override
  String deployFailed(String error) {
    return 'Bereitstellung fehlgeschlagen: $error';
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
