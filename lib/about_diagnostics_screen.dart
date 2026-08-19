import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AboutDiagnosticsScreen extends StatefulWidget {
  final bool mowerConnected;
  final String? mowerFirmwareVersion;

  const AboutDiagnosticsScreen({
    super.key,
    required this.mowerConnected,
    this.mowerFirmwareVersion,
  });

  @override
  State<AboutDiagnosticsScreen> createState() => _AboutDiagnosticsScreenState();
}

class _AboutDiagnosticsScreenState extends State<AboutDiagnosticsScreen> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  String get _platformName {
    if (Platform.isIOS) return 'iPhone (iOS)';
    if (Platform.isWindows) return 'Windows';
    return Platform.operatingSystem;
  }

  String get _bleBackend {
    if (Platform.isIOS) return 'Apple CoreBluetooth';
    if (Platform.isWindows) return 'Windows WinRT';
    return 'Not supported';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About & Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _SectionCard(
            title: 'Mower EMU app',
            children: [
              FutureBuilder<PackageInfo>(
                future: _packageInfo,
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  return _DiagnosticRow(
                    icon: Icons.phone_iphone,
                    label: 'App version',
                    value: info == null
                        ? 'Loading…'
                        : '${info.version} (${info.buildNumber})',
                  );
                },
              ),
              _DiagnosticRow(
                icon: Icons.devices,
                label: 'Platform',
                value: _platformName,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Mower EMU connection',
            children: [
              _DiagnosticRow(
                icon: Icons.bluetooth,
                label: 'BLE backend',
                value: _bleBackend,
              ),
              _DiagnosticRow(
                icon: widget.mowerConnected ? Icons.link : Icons.link_off,
                label: 'Status',
                value: widget.mowerConnected ? 'Connected' : 'Disconnected',
              ),
              _DiagnosticRow(
                icon: Icons.memory,
                label: 'EMU firmware',
                value: widget.mowerFirmwareVersion ?? 'Unknown',
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'More diagnostics, event logs, hardware revision, and firmware '
                'update controls can be added here as the system develops.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DiagnosticRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
    );
  }
}
