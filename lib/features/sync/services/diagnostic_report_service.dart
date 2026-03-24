import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/services/api_client_provider.dart';
import '../domain/notification_models.dart';
import '../domain/notification_provider.dart';
import 'system_path_service.dart';
import 'shizuku_service.dart';

final diagnosticReportServiceProvider = Provider<DiagnosticReportService>((ref) {
  return DiagnosticReportService(ref);
});

class DiagnosticReportService {
  final Ref _ref;
  DiagnosticReportService(this._ref);

  Future<String> generateMarkdownReport() async {
    final deviceInfo = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();
    final apiClient = _ref.read(apiClientProvider);
    final pathService = _ref.read(systemPathServiceProvider);
    final shizuku = _ref.read(shizukuServiceProvider);
    final logs = _ref.read(notificationLogProvider);

    final sb = StringBuffer();
    sb.writeln('# VaultSync Diagnostic Report');
    sb.writeln('Generated: ${DateTime.now().toIso8601String()}');
    sb.writeln();

    sb.writeln('## 📱 Environment');
    sb.writeln('- **App Version**: ${packageInfo.version}+${packageInfo.buildNumber}');
    sb.writeln('- **Platform**: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    
    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      sb.writeln('- **Device**: ${android.manufacturer} ${android.model}');
      sb.writeln('- **Android SDK**: ${android.version.sdkInt}');
    } else if (Platform.isLinux) {
      final linux = await deviceInfo.linuxInfo;
      sb.writeln('- **Distro**: ${linux.prettyName}');
    }

    sb.writeln();
    sb.writeln('## ⚙️ Configuration');
    final baseUrl = await apiClient.getBaseUrl() ?? 'Not Configured';
    // Redact URL sensitive parts (keep domain for troubleshooting)
    final redactedUrl = baseUrl.replaceAll(RegExp(r'https?://[^/]+'), 'https://[REDACTED]');
    sb.writeln('- **Server Status**: $redactedUrl');
    sb.writeln('- **Auth Status**: ${apiClient.isConfigured() ? 'Authenticated' : 'Not Authenticated'}');
    
    if (Platform.isAndroid) {
       final status = await shizuku.getStatus();
       sb.writeln('- **Shizuku**: ${status.isRunning ? 'Running' : 'Not Running'} (Authorized: ${status.isAuthorized})');
    }

    sb.writeln();
    sb.writeln('## 📂 Configured Systems');
    final paths = await pathService.getAllSystemPaths();
    if (paths.isEmpty) {
      sb.writeln('- No systems configured.');
    } else {
      for (final sid in paths.keys) {
        sb.writeln('- $sid');
      }
    }

    sb.writeln();
    sb.writeln('## ⚠️ Recent Events (Last 10)');
    final lastLogs = logs.take(10);
    if (lastLogs.isEmpty) {
      sb.writeln('No events recorded in this session.');
    } else {
      for (final log in lastLogs) {
        final typeStr = log.type.toString().split('.').last.toUpperCase();
        sb.writeln('### [$typeStr] ${log.title}');
        sb.writeln('- **Time**: ${log.timestamp}');
        sb.writeln('- **Message**: ${log.message}');
        if (log.systemId != null) sb.writeln('- **System**: ${log.systemId}');
        sb.writeln();
      }
    }

    return sb.toString();
  }

  Future<void> reportToGitHub() async {
    final report = await generateMarkdownReport();
    final encodedBody = Uri.encodeComponent(report);
    final url = Uri.parse('https://github.com/dandandandan1/Smali.Smali/issues/new?title=Diagnostic+Report&body=$encodedBody');
    
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      throw Exception('Could not launch browser for GitHub report.');
    }
  }
}
