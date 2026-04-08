// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'VaultSync';

  @override
  String get syncEngineDescription =>
      'Moteur de synchronisation accéléré par le matériel';

  @override
  String get settingsTitle => 'Paramètres';

  @override
  String get sectionServerAccount => 'Serveur et Compte';

  @override
  String get serverUrlTitle => 'URL du serveur';

  @override
  String get notSet => 'Non défini';

  @override
  String get accountTitle => 'Compte';

  @override
  String get notLoggedIn => 'Pas connecté';

  @override
  String get logoutButton => 'DÉCONNEXION';

  @override
  String get sectionAutomation => 'Automatisation (Bêta)';

  @override
  String get syncOnExitTitle => 'Sync à la sortie du jeu';

  @override
  String get syncOnExitSubtitle =>
      'Télécharger les sauvegardes automatiquement à la fin du jeu';

  @override
  String get usageAccessRequired =>
      'L\'accès à l\'utilisation est requis pour détecter la fermeture des émulateurs.';

  @override
  String get grantPermissionButton => 'ACCORDER LA PERMISSION';

  @override
  String get periodicSyncTitle => 'Sync périodique en arrière-plan';

  @override
  String get periodicSyncSubtitle =>
      'Effectuer une synchronisation de rattrapage toutes les 6 heures';

  @override
  String get viewSyncHistoryTitle => 'Voir l\'historique de synchronisation';

  @override
  String get viewSyncHistorySubtitle =>
      'Consulter les journaux des événements de synchronisation';

  @override
  String get conflictStrategyTitle => 'Stratégie de conflit';

  @override
  String get conflictStrategySubtitle =>
      'Choisir comment résoudre les écarts de sauvegarde';

  @override
  String get strategyAsk => 'Demander à chaque fois';

  @override
  String get strategyNewest => 'Toujours le plus récent';

  @override
  String get strategyLocal => 'Préférer local';

  @override
  String get strategyCloud => 'Préférer le cloud';

  @override
  String get sectionHardwareBridge => 'Pont matériel';

  @override
  String get useShizukuTitle => 'Utiliser le pont Shizuku';

  @override
  String get useShizukuSubtitle =>
      'Accès haute vitesse pour les dossiers /data sur Android 14+';

  @override
  String get runDiagnosticsTitle => 'Lancer les diagnostics système';

  @override
  String get runDiagnosticsSubtitle =>
      'Tester la vitesse du matériel et la santé de SAF/Shizuku';

  @override
  String get sectionAppearance => 'Apparence';

  @override
  String get themeModeTitle => 'Mode de thème';

  @override
  String get themeSystem => 'Système';

  @override
  String get themeLight => 'Clair';

  @override
  String get themeDark => 'Sombre';

  @override
  String get sectionLanguage => 'Langue';

  @override
  String get languageTitle => 'Langue de l\'application';

  @override
  String get sectionDeckyBridge => 'Pont du plugin Decky';

  @override
  String get bridgeServiceTitle => 'Service de pont';

  @override
  String bridgeServiceSubtitle(String status) {
    return 'Sert localhost:5437 pour le plugin Decky en mode Jeu\nStatut: $status';
  }

  @override
  String get statusRunning => 'En cours';

  @override
  String get statusStopped => 'Arrêté';

  @override
  String get statusInstalling => 'Installation...';

  @override
  String get statusNotInstalled => 'Non installé';

  @override
  String get statusChecking => 'Vérification...';

  @override
  String get installEnableButton => 'Installer et activer';

  @override
  String get startButton => 'Démarrer';

  @override
  String get uninstallButton => 'Désinstaller';

  @override
  String get stopButton => 'Arrêter';

  @override
  String get openingShizuku =>
      'Ouverture de Shizuku... Démarrez le service et revenez.';

  @override
  String get shizukuAuthorized => 'Shizuku autorisé !';

  @override
  String get actionLogin => 'CONNEXION';

  @override
  String get actionFix => 'RÉPARER';

  @override
  String get actionSettings => 'PARAMÈTRES';

  @override
  String get actionRetry => 'RÉESSAYER';

  @override
  String get actionDismiss => 'IGNORER';

  @override
  String get actionSetup => 'CONFIGURER';

  @override
  String get actionOpenApp => 'OUVRIR L\'APP';

  @override
  String get actionFixNow => 'RÉPARER MAINTENANT';

  @override
  String get bridgeSetupTitle => 'Recommandé : Configurer le pont';

  @override
  String bridgeSetupSubtitle(int version) {
    return 'Shizuku est requis pour la vitesse maximale sur Android $version';
  }

  @override
  String get shizukuNotRunningTitle => 'Shizuku ne tourne pas';

  @override
  String get shizukuNotRunningSubtitle =>
      'l\'accès aux dossiers restreints est désactivé';

  @override
  String get shizukuPermissionTitle => 'Permission Shizuku requise';

  @override
  String get shizukuPermissionSubtitle => 'autorisez VaultSync pour continuer';

  @override
  String get scanLibraryTooltip => 'Scanner la bibliothèque';

  @override
  String get notificationsTooltip => 'Notifications';

  @override
  String get settingsTooltip => 'Paramètres';

  @override
  String get noSystemsConfigured => 'Aucun système configuré pour le moment.';

  @override
  String get scanLibraryButton => 'Scanner la bibliothèque';

  @override
  String get syncing => 'Synchronisation...';

  @override
  String get systemReady => 'Système prêt';

  @override
  String get stopSyncButton => 'ARRÊTER LA SYNC';

  @override
  String get waitingForChanges => 'En attente de changements';

  @override
  String get syncAllButton => 'Tout synchroniser';

  @override
  String get diagnosticsTitle => 'Diagnostics système';

  @override
  String get runningStressTests => 'Tests de stress en cours...';

  @override
  String get startDeltaSyncTest => 'Démarrer le test de sync delta';

  @override
  String refreshFailed(String error) {
    return 'Échec de l\'actualisation : $error';
  }

  @override
  String get statusSynced => 'Synchronisé';

  @override
  String get statusModified => 'Modifié';

  @override
  String get statusLocalOnly => 'Local uniquement';

  @override
  String get statusRemoteOnly => 'Distant uniquement';

  @override
  String get clickToViewHistory =>
      'Cliquez pour voir l\'historique des versions';

  @override
  String get stateTag => 'ÉTAT';

  @override
  String get versionHistoryTooltip => 'Historique des versions';

  @override
  String systemManagementTitle(String systemId) {
    return 'Gestion de $systemId';
  }

  @override
  String get syncNowButton => 'SYNC MAINTENANT';

  @override
  String get syncThisSystemTooltip => 'Synchroniser ce système';

  @override
  String get systemNotConfigured => 'Système non configuré.';

  @override
  String get noFilesFound => 'Aucun fichier trouvé.';

  @override
  String get registrationFailed => 'Échec de l\'inscription';

  @override
  String get loginFailed => 'Échec de la connexion';

  @override
  String get createAccountTitle => 'Créer un compte';

  @override
  String get loginTitle => 'Connexion';

  @override
  String get serverSettingsTooltip => 'Paramètres du serveur';

  @override
  String get usernameLabel => 'Nom d\'utilisateur';

  @override
  String get emailLabel => 'E-mail';

  @override
  String get passwordLabel => 'Mot de passe';

  @override
  String get createAccountButton => 'CRÉER UN COMPTE';

  @override
  String get loginButton => 'CONNEXION';

  @override
  String get forgotPasswordButton => 'Mot de passe oublié ?';

  @override
  String get alreadyHaveAccount => 'Déjà un compte ? Se connecter';

  @override
  String get dontHaveAccount => 'Pas de compte ? S\'inscrire maintenant';

  @override
  String get diagnosticReportTitle => 'Rapport de diagnostic';

  @override
  String get diagnosticReportDescription =>
      'Le rapport suivant sera soumis à GitHub. Les informations sensibles comme les e-mails et les chemins complets ont été rédigées.';

  @override
  String get reportCopied => 'Rapport copié dans le presse-papiers';

  @override
  String get copyButton => 'COPIER';

  @override
  String get reportToGithubButton => 'SIGNALER SUR GITHUB';

  @override
  String get sessionEventsTitle => 'Événements de session';

  @override
  String get reportButton => 'Signaler';

  @override
  String get clearButton => 'Effacer';

  @override
  String get noEventsInSession => 'Aucun événement dans cette session';

  @override
  String get actionFixBridge => 'RÉPARER LE PONT';

  @override
  String get syncHistoryTitle => 'Historique de synchronisation';

  @override
  String get clearHistoryTooltip => 'Effacer l\'historique';

  @override
  String get noSyncHistoryFound =>
      'Aucun historique de synchronisation trouvé.';

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
