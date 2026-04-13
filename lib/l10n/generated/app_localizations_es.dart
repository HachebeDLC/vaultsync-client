// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'VaultSync';

  @override
  String get syncEngineDescription =>
      'Motor de sincronización acelerado por hardware';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get sectionServerAccount => 'Servidor y Cuenta';

  @override
  String get serverUrlTitle => 'URL del servidor';

  @override
  String get notSet => 'No establecido';

  @override
  String get accountTitle => 'Cuenta';

  @override
  String get notLoggedIn => 'No has iniciado sesión';

  @override
  String get logoutButton => 'CERRAR SESIÓN';

  @override
  String get sectionAutomation => 'Automatización (Beta)';

  @override
  String get syncOnExitTitle => 'Sincronizar al salir del juego';

  @override
  String get syncOnExitSubtitle =>
      'Sube las partidas guardadas automáticamente al terminar de jugar';

  @override
  String get usageAccessRequired =>
      'Se requiere acceso de uso para detectar cuándo se cierran los emuladores.';

  @override
  String get grantPermissionButton => 'CONCEDER PERMISO';

  @override
  String get periodicSyncTitle => 'Sincronización periódica en segundo plano';

  @override
  String get periodicSyncSubtitle =>
      'Realizar una sincronización de actualización cada 6 horas';

  @override
  String get viewSyncHistoryTitle => 'Ver historial de sincronización';

  @override
  String get viewSyncHistorySubtitle =>
      'Revisar los registros de eventos de sincronización en segundo plano';

  @override
  String get conflictStrategyTitle => 'Estrategia de conflicto';

  @override
  String get conflictStrategySubtitle =>
      'Elige cómo resolver las discrepancias al guardar';

  @override
  String get strategyAsk => 'Preguntar siempre';

  @override
  String get strategyNewest => 'Siempre lo más nuevo';

  @override
  String get strategyLocal => 'Preferir local';

  @override
  String get strategyCloud => 'Preferir la nube';

  @override
  String get sectionHardwareBridge => 'Puente de hardware';

  @override
  String get useShizukuTitle => 'Usar el puente Shizuku';

  @override
  String get useShizukuSubtitle =>
      'Acceso de alta velocidad para carpetas /data en Android 14+';

  @override
  String get runDiagnosticsTitle => 'Ejecutar diagnósticos del sistema';

  @override
  String get runDiagnosticsSubtitle =>
      'Prueba la velocidad del hardware y la salud de SAF/Shizuku';

  @override
  String get sectionAppearance => 'Apariencia';

  @override
  String get themeModeTitle => 'Modo de tema';

  @override
  String get themeSystem => 'Sistema';

  @override
  String get themeLight => 'Luz';

  @override
  String get themeDark => 'Oscuro';

  @override
  String get sectionLanguage => 'Idioma';

  @override
  String get languageTitle => 'Idioma de la aplicación';

  @override
  String get sectionDeckyBridge => 'Puente del plugin Decky';

  @override
  String get bridgeServiceTitle => 'Servicio de puente';

  @override
  String bridgeServiceSubtitle(String status) {
    return 'Sirve localhost:5437 para el plugin Decky en modo Juego\nEstado: $status';
  }

  @override
  String get statusRunning => 'Ejecutándose';

  @override
  String get statusStopped => 'Detenido';

  @override
  String get statusInstalling => 'Instalando...';

  @override
  String get statusNotInstalled => 'No instalado';

  @override
  String get statusChecking => 'Comprobando...';

  @override
  String get installEnableButton => 'Instalar y habilitar';

  @override
  String get startButton => 'Comenzar';

  @override
  String get uninstallButton => 'Desinstalar';

  @override
  String get stopButton => 'Detener';

  @override
  String get openingShizuku =>
      'Abriendo Shizuku... Inicia el servicio y vuelve.';

  @override
  String get shizukuAuthorized => '¡Shizuku autorizado!';

  @override
  String get actionLogin => 'INICIAR SESIÓN';

  @override
  String get actionFix => 'CORREGIR';

  @override
  String get actionSettings => 'AJUSTES';

  @override
  String get actionRetry => 'REINTENTAR';

  @override
  String get actionDismiss => 'DESCARTAR';

  @override
  String get actionSetup => 'CONFIGURAR';

  @override
  String get actionOpenApp => 'ABRIR APLICACIÓN';

  @override
  String get actionFixNow => 'CORREGIR AHORA';

  @override
  String get bridgeSetupTitle => 'Recomendado: Configurar puente';

  @override
  String bridgeSetupSubtitle(int version) {
    return 'Se requiere Shizuku para máxima velocidad en Android $version';
  }

  @override
  String get shizukuNotRunningTitle => 'Shizuku no se está ejecutando';

  @override
  String get shizukuNotRunningSubtitle =>
      'el acceso a carpetas restringidas está deshabilitado';

  @override
  String get shizukuPermissionTitle => 'Se requiere permiso de Shizuku';

  @override
  String get shizukuPermissionSubtitle => 'autoriza a VaultSync para continuar';

  @override
  String get scanLibraryTooltip => 'Escanear biblioteca';

  @override
  String get notificationsTooltip => 'Notificaciones';

  @override
  String get settingsTooltip => 'Ajustes';

  @override
  String get noSystemsConfigured => 'Aún no hay sistemas configurados.';

  @override
  String get scanLibraryButton => 'Escanear biblioteca';

  @override
  String get syncing => 'Sincronizando...';

  @override
  String get systemReady => 'Sistema listo';

  @override
  String get stopSyncButton => 'DETENER SINCRONIZACIÓN';

  @override
  String get waitingForChanges => 'Esperando cambios';

  @override
  String get syncAllButton => 'Sincronizar todo';

  @override
  String get diagnosticsTitle => 'Diagnóstico del sistema';

  @override
  String get runningStressTests => 'Ejecutando pruebas de estrés...';

  @override
  String get startDeltaSyncTest => 'Iniciar prueba de sincronización delta';

  @override
  String refreshFailed(String error) {
    return 'Error al actualizar: $error';
  }

  @override
  String get statusSynced => 'Sincronizado';

  @override
  String get statusModified => 'Modificado';

  @override
  String get statusLocalOnly => 'Solo local';

  @override
  String get statusRemoteOnly => 'Solo remoto';

  @override
  String get clickToViewHistory =>
      'Haga clic para ver el historial de versiones';

  @override
  String get stateTag => 'ESTADO';

  @override
  String get versionHistoryTooltip => 'Historial de versiones';

  @override
  String systemManagementTitle(String systemId) {
    return 'Gestión de $systemId';
  }

  @override
  String get syncNowButton => 'SINCRONIZAR AHORA';

  @override
  String get syncThisSystemTooltip => 'Sincronizar este sistema';

  @override
  String get systemNotConfigured => 'Sistema no configurado.';

  @override
  String get noFilesFound => 'No se encontraron archivos.';

  @override
  String get registrationFailed => 'Error de registro';

  @override
  String get loginFailed => 'Error de inicio de sesión';

  @override
  String get createAccountTitle => 'Crear cuenta';

  @override
  String get loginTitle => 'Iniciar sesión';

  @override
  String get serverSettingsTooltip => 'Ajustes del servidor';

  @override
  String get usernameLabel => 'Nombre de usuario';

  @override
  String get emailLabel => 'Correo electrónico';

  @override
  String get passwordLabel => 'Contraseña';

  @override
  String get createAccountButton => 'CREAR CUENTA';

  @override
  String get loginButton => 'INICIAR SESIÓN';

  @override
  String get forgotPasswordButton => '¿Has olvidado tu contraseña?';

  @override
  String get alreadyHaveAccount => '¿Ya tienes una cuenta? Iniciar sesión';

  @override
  String get dontHaveAccount => '¿No tienes una cuenta? Regístrate ahora';

  @override
  String get diagnosticReportTitle => 'Informe de diagnóstico';

  @override
  String get diagnosticReportDescription =>
      'El siguiente informe se enviará a GitHub. La información confidencial, como correos electrónicos y rutas completas, ha sido redactada.';

  @override
  String get reportCopied => 'Informe copiado al portapapeles';

  @override
  String get copyButton => 'COPIAR';

  @override
  String get reportToGithubButton => 'INFORMAR A GITHUB';

  @override
  String get sessionEventsTitle => 'Eventos de sesión';

  @override
  String get reportButton => 'Informe';

  @override
  String get clearButton => 'Limpiar';

  @override
  String get noEventsInSession => 'No hay eventos en esta sesión';

  @override
  String get actionFixBridge => 'CORREGIR PUENTE';

  @override
  String get syncHistoryTitle => 'Historial de sincronización';

  @override
  String get clearHistoryTooltip => 'Limpiar historial';

  @override
  String get noSyncHistoryFound =>
      'No se encontró historial de sincronización.';

  @override
  String get recoverVaultTitle => 'Recuperar Bóveda';

  @override
  String get enterEmailToRecover =>
      'Ingresa tu correo para recuperar tus preguntas de seguridad.';

  @override
  String get fetchRecoveryInfoButton => 'OBTENER INFORMACIÓN DE RECUPERACIÓN';

  @override
  String get answerSecurityQuestions =>
      'Por favor responde tus preguntas de seguridad para restaurar tu clave maestra.';

  @override
  String get masterKeyRestored =>
      '¡Clave maestra restaurada! Ahora puedes iniciar sesión.';

  @override
  String recoveryFailed(String error) {
    return 'Error en la recuperación: $error';
  }

  @override
  String get restoreMasterKeyButton => 'RESTAURAR CLAVE MAESTRA';

  @override
  String get recoverySetupTitle => 'Configuración de recuperación';

  @override
  String get recoverySetupSaved =>
      '¡Configuración de recuperación guardada con éxito!';

  @override
  String errorSavingRecovery(String error) {
    return 'Error al guardar la recuperación: $error';
  }

  @override
  String get saveRecoverySetupButton => 'GUARDAR CONFIGURACIÓN DE RECUPERACIÓN';

  @override
  String get librarySetupTitle => 'Configuración de la biblioteca';

  @override
  String get noSystemsFound => 'No se encontraron sistemas en esa carpeta.';

  @override
  String errorGeneric(String error) {
    return 'Error: $error';
  }

  @override
  String noInstalledEmulatorsFound(String systemName) {
    return 'No se encontraron emuladores instalados para $systemName.';
  }

  @override
  String selectEmulatorFor(String systemName) {
    return 'Seleccionar emulador para $systemName';
  }

  @override
  String get configureSavePathTitle => 'Configurar ruta de guardado';

  @override
  String emulatorLabel(String emulatorName) {
    return 'Emulador: $emulatorName';
  }

  @override
  String get saveFolderLabel => 'Carpeta de guardado:';

  @override
  String get cancelButton => 'Cancelar';

  @override
  String get saveButton => 'Guardar';

  @override
  String get finishSetupButton => 'FINALIZAR CONFIGURACIÓN';

  @override
  String get selectRomsRoot => 'SELECCIONAR CARPETA RAÍZ DE ROMS';

  @override
  String get baseFolderDescription =>
      'Carpeta base que contiene tus subcarpetas de juegos (p. ej. Roms/ps2, Roms/snes).';

  @override
  String get pathLabel => 'Ruta';

  @override
  String get scanLibraryAction => 'ESCANEAR BIBLIOTECA';

  @override
  String get noSystemsDetected =>
      'Aún no se detectaron sistemas.\nSelecciona la raíz de tus ROMs y haz clic en \"Escanear\".';

  @override
  String get detectedSystems => 'SISTEMAS DETECTADOS';

  @override
  String get noInstalledEmulatorsForDetected =>
      'No se encontraron emuladores instalados para los sistemas detectados.';

  @override
  String get configuredStatus => 'Configurado';

  @override
  String get needsSetupStatus => 'Necesita Configuración';

  @override
  String get deployToDeckyButton => 'Instalar en Decky';

  @override
  String get deployToDeckySubtitle =>
      'Instala los archivos del plugin en el Modo Juego';

  @override
  String get pluginDeployedSuccess =>
      '¡Plugin de Decky desplegado! Reinicia Decky o recarga los plugins para verlo.';

  @override
  String deployFailed(String error) {
    return 'Error al desplegar: $error';
  }

  @override
  String get sectionEcosystem => 'Integración del Ecosistema';

  @override
  String get rommSyncTitle => 'Integración con RomM';

  @override
  String get rommSyncSubtitle =>
      'Sincroniza automáticamente partidas descifradas con tu servidor RomM';

  @override
  String get rommUrlLabel => 'URL del Servidor RomM';

  @override
  String get rommApiKeyLabel => 'Clave API de RomM';

  @override
  String get rommUrlHint => 'ej., https://romm.ejemplo.com';

  @override
  String get rommApiKeyHint => 'rmm_...';
}
