// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get appTitle => 'VaultSync';

  @override
  String get syncEngineDescription =>
      'Motore di sincronizzazione accelerato via hardware';

  @override
  String get settingsTitle => 'Impostazioni';

  @override
  String get sectionServerAccount => 'Server & Account';

  @override
  String get serverUrlTitle => 'URL del server';

  @override
  String get notSet => 'Non impostato';

  @override
  String get accountTitle => 'Account';

  @override
  String get notLoggedIn => 'Non connesso';

  @override
  String get logoutButton => 'LOGOUT';

  @override
  String get sectionAutomation => 'Automazione (Beta)';

  @override
  String get syncOnExitTitle => 'Sincronizza all\'uscita dal gioco';

  @override
  String get syncOnExitSubtitle =>
      'Carica i salvataggi automaticamente al termine del gioco';

  @override
  String get usageAccessRequired =>
      'L\'accesso all\'utilizzo è richiesto per rilevare la chiusura degli emulatori.';

  @override
  String get grantPermissionButton => 'CONCEDI PERMESSO';

  @override
  String get periodicSyncTitle => 'Sincronizzazione periodica in background';

  @override
  String get periodicSyncSubtitle =>
      'Esegui una sincronizzazione di recupero ogni 6 ore';

  @override
  String get viewSyncHistoryTitle => 'Visualizza cronologia sincronizzazione';

  @override
  String get viewSyncHistorySubtitle =>
      'Controlla i log degli eventi di sincronizzazione in background';

  @override
  String get conflictStrategyTitle => 'Strategia di conflitto';

  @override
  String get conflictStrategySubtitle =>
      'Scegli come risolvere le discrepanze dei salvataggi';

  @override
  String get strategyAsk => 'Chiedi ogni volta';

  @override
  String get strategyNewest => 'Sempre il più recente';

  @override
  String get strategyLocal => 'Preferisci locale';

  @override
  String get strategyCloud => 'Preferisci cloud';

  @override
  String get sectionHardwareBridge => 'Ponte hardware';

  @override
  String get useShizukuTitle => 'Usa il ponte Shizuku';

  @override
  String get useShizukuSubtitle =>
      'Accesso ad alta velocità per le cartelle /data su Android 14+';

  @override
  String get runDiagnosticsTitle => 'Esegui diagnostica di sistema';

  @override
  String get runDiagnosticsSubtitle =>
      'Testa la velocità dell\'hardware e la salute di SAF/Shizuku';

  @override
  String get sectionAppearance => 'Aspetto';

  @override
  String get themeModeTitle => 'Modalità tema';

  @override
  String get themeSystem => 'Sistema';

  @override
  String get themeLight => 'Chiaro';

  @override
  String get themeDark => 'Scuro';

  @override
  String get sectionLanguage => 'Lingua';

  @override
  String get languageTitle => 'Lingua dell\'app';

  @override
  String get sectionDeckyBridge => 'Ponte del plugin Decky';

  @override
  String get bridgeServiceTitle => 'Servizio di ponte';

  @override
  String bridgeServiceSubtitle(String status) {
    return 'Serve localhost:5437 per il plugin Decky in modalità Gioco\nStato: $status';
  }

  @override
  String get statusRunning => 'In esecuzione';

  @override
  String get statusStopped => 'Fermato';

  @override
  String get statusInstalling => 'Installazione...';

  @override
  String get statusNotInstalled => 'Non installato';

  @override
  String get statusChecking => 'Controllo...';

  @override
  String get installEnableButton => 'Installa e abilita';

  @override
  String get startButton => 'Avvia';

  @override
  String get uninstallButton => 'Disinstalla';

  @override
  String get stopButton => 'Ferma';

  @override
  String get openingShizuku =>
      'Apertura di Shizuku... Avvia il servizio e torna.';

  @override
  String get shizukuAuthorized => 'Shizuku autorizzato!';

  @override
  String get actionLogin => 'LOGIN';

  @override
  String get actionFix => 'CORREGGI';

  @override
  String get actionSettings => 'IMPOSTAZIONI';

  @override
  String get actionRetry => 'RIPROVA';

  @override
  String get actionDismiss => 'IGNORA';

  @override
  String get actionSetup => 'CONFIGURA';

  @override
  String get actionOpenApp => 'APRI APP';

  @override
  String get actionFixNow => 'CORREGGI ORA';

  @override
  String get bridgeSetupTitle => 'Consigliato: Configura ponte';

  @override
  String bridgeSetupSubtitle(int version) {
    return 'Shizuku è richiesto per la massima velocità su Android $version';
  }

  @override
  String get shizukuNotRunningTitle => 'Shizuku non è in esecuzione';

  @override
  String get shizukuNotRunningSubtitle =>
      'l\'accesso alle cartelle limitate è disabilitato';

  @override
  String get shizukuPermissionTitle => 'Permesso Shizuku richiesto';

  @override
  String get shizukuPermissionSubtitle => 'autorizza VaultSync per continuare';

  @override
  String get scanLibraryTooltip => 'Scansiona libreria';

  @override
  String get notificationsTooltip => 'Notifiche';

  @override
  String get settingsTooltip => 'Impostazioni';

  @override
  String get noSystemsConfigured => 'Nessun sistema ancora configurato.';

  @override
  String get scanLibraryButton => 'Scansiona libreria';

  @override
  String get syncing => 'Sincronizzazione...';

  @override
  String get systemReady => 'Sistema pronto';

  @override
  String get stopSyncButton => 'FERMA SYNC';

  @override
  String get waitingForChanges => 'In attesa di modifiche';

  @override
  String get syncAllButton => 'Sincronizza tutto';

  @override
  String get diagnosticsTitle => 'Diagnostica di sistema';

  @override
  String get runningStressTests => 'Test di stress in corso...';

  @override
  String get startDeltaSyncTest => 'Avvia test sync delta';

  @override
  String refreshFailed(String error) {
    return 'Aggiornamento fallito: $error';
  }

  @override
  String get statusSynced => 'Sincronizzato';

  @override
  String get statusModified => 'Modificato';

  @override
  String get statusLocalOnly => 'Solo locale';

  @override
  String get statusRemoteOnly => 'Solo remoto';

  @override
  String get clickToViewHistory =>
      'Clicca per visualizzare la cronologia delle versioni';

  @override
  String get stateTag => 'STATO';

  @override
  String get versionHistoryTooltip => 'Cronologia versioni';

  @override
  String systemManagementTitle(String systemId) {
    return 'Gestione $systemId';
  }

  @override
  String get syncNowButton => 'SINCRONIZZA ORA';

  @override
  String get syncThisSystemTooltip => 'Sincronizza questo sistema';

  @override
  String get systemNotConfigured => 'Sistema non configurato.';

  @override
  String get noFilesFound => 'Nessun file trovato.';

  @override
  String get registrationFailed => 'Registrazione fallita';

  @override
  String get loginFailed => 'Accesso fallito';

  @override
  String get createAccountTitle => 'Crea account';

  @override
  String get loginTitle => 'Accesso';

  @override
  String get serverSettingsTooltip => 'Impostazioni server';

  @override
  String get usernameLabel => 'Nome utente';

  @override
  String get emailLabel => 'Email';

  @override
  String get passwordLabel => 'Password';

  @override
  String get createAccountButton => 'CREA ACCOUNT';

  @override
  String get loginButton => 'ACCESSO';

  @override
  String get forgotPasswordButton => 'Password dimenticata?';

  @override
  String get alreadyHaveAccount => 'Hai già un account? Accedi';

  @override
  String get dontHaveAccount => 'Non hai un account? Registrati ora';

  @override
  String get diagnosticReportTitle => 'Rapporto di diagnostica';

  @override
  String get diagnosticReportDescription =>
      'Il seguente rapporto verrà inviato a GitHub. Le informazioni sensibili come e-mail e percorsi completi sono state rimosse.';

  @override
  String get reportCopied => 'Rapporto copiato negli appunti';

  @override
  String get copyButton => 'COPIA';

  @override
  String get reportToGithubButton => 'SEGNALA SU GITHUB';

  @override
  String get sessionEventsTitle => 'Eventi sessione';

  @override
  String get reportButton => 'Segnala';

  @override
  String get clearButton => 'Cancella';

  @override
  String get noEventsInSession => 'Nessun evento in questa sessione';

  @override
  String get actionFixBridge => 'RIPRISTINA PONTE';

  @override
  String get syncHistoryTitle => 'Cronologia sincronizzazione';

  @override
  String get clearHistoryTooltip => 'Cancella cronologia';

  @override
  String get noSyncHistoryFound =>
      'Nessuna cronologia di sincronizzazione trovata.';

  @override
  String get recoverVaultTitle => 'Recupera Vault';

  @override
  String get enterEmailToRecover =>
      'Inserisci la tua email per recuperare le domande di sicurezza.';

  @override
  String get fetchRecoveryInfoButton => 'RECUPERA INFORMAZIONI';

  @override
  String get answerSecurityQuestions =>
      'Rispondi alle domande di sicurezza per ripristinare la tua chiave master.';

  @override
  String get masterKeyRestored =>
      'Chiave master ripristinata! Ora puoi accedere.';

  @override
  String recoveryFailed(String error) {
    return 'Recupero fallito: $error';
  }

  @override
  String get restoreMasterKeyButton => 'RIPRISTINA CHIAVE MASTER';

  @override
  String get recoverySetupTitle => 'Configurazione recupero';

  @override
  String get recoverySetupSaved =>
      'Configurazione recupero salvata con successo!';

  @override
  String errorSavingRecovery(String error) {
    return 'Errore durante il salvataggio del recupero: $error';
  }

  @override
  String get saveRecoverySetupButton => 'SALVA CONFIGURAZIONE RECUPERO';

  @override
  String get librarySetupTitle => 'Configurazione libreria';

  @override
  String get noSystemsFound => 'Nessun sistema trovato in quella cartella.';

  @override
  String errorGeneric(String error) {
    return 'Errore: $error';
  }

  @override
  String noInstalledEmulatorsFound(String systemName) {
    return 'Nessun emulatore installato trovato per $systemName.';
  }

  @override
  String selectEmulatorFor(String systemName) {
    return 'Seleziona emulatore per $systemName';
  }

  @override
  String get configureSavePathTitle => 'Configura percorso salvataggio';

  @override
  String emulatorLabel(String emulatorName) {
    return 'Emulatore: $emulatorName';
  }

  @override
  String get saveFolderLabel => 'Cartella salvataggi:';

  @override
  String get cancelButton => 'Annulla';

  @override
  String get saveButton => 'Salva';

  @override
  String get finishSetupButton => 'COMPLETA CONFIGURAZIONE';

  @override
  String get selectRomsRoot => 'SELEZIONA CARTELLA ROM PRINCIPALE';

  @override
  String get baseFolderDescription =>
      'Cartella base contenente le sottocartelle dei giochi (es. Roms/ps2, Roms/snes).';

  @override
  String get pathLabel => 'Percorso';

  @override
  String get scanLibraryAction => 'SCANSIONA LIBRERIA';

  @override
  String get noSystemsDetected =>
      'Nessun sistema rilevato.\nSeleziona la cartella ROM principale e clicca su \"Scansiona\".';

  @override
  String get detectedSystems => 'SISTEMI RILEVATI';

  @override
  String get noInstalledEmulatorsForDetected =>
      'Nessun emulatore installato trovato per i sistemi rilevati.';

  @override
  String get configuredStatus => 'Configurato';

  @override
  String get needsSetupStatus => 'Da configurare';

  @override
  String get deployToDeckyButton => 'Installa su Decky';

  @override
  String get deployToDeckySubtitle =>
      'Installa i file del plugin in Modalità Gioco';

  @override
  String get pluginDeployedSuccess =>
      'Plugin Decky distribuito! Riavvia Decky o ricarica i plugin per vederlo.';

  @override
  String deployFailed(String error) {
    return 'Distribuzione fallita: $error';
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
