import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ble_service.dart';

class AboutDiagnosticsScreen extends StatefulWidget {
  final bool mowerConnected;
  final String? mowerFirmwareVersion;
  final MowerBleService? bleService;

  const AboutDiagnosticsScreen({
    super.key,
    required this.mowerConnected,
    this.mowerFirmwareVersion,
    this.bleService,
  });

  @override
  State<AboutDiagnosticsScreen> createState() => _AboutDiagnosticsScreenState();
}

class _AboutDiagnosticsScreenState extends State<AboutDiagnosticsScreen> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  bool _otaTestRunning = false;
  double _otaTestProgress = 0;
  String? _otaTestResult;

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

  Future<void> _runOtaTest({required bool writesFlash}) async {
    final bleService = widget.bleService;
    if (bleService == null) return;

    setState(() {
      _otaTestRunning = true;
      _otaTestProgress = 0;
      _otaTestResult = writesFlash
          ? 'Erasing and testing the secondary slot...'
          : 'Starting non-destructive transfer test...';
    });
    try {
      void onProgress(double progress) {
        if (mounted) setState(() => _otaTestProgress = progress);
      }

      final result = writesFlash
          ? await bleService.runOtaSecondarySlotFlashTest(
              onProgress: onProgress,
            )
          : await bleService.runOtaTransportTest(onProgress: onProgress);
      if (!mounted) return;
      setState(() {
        _otaTestProgress = 1;
        _otaTestResult =
            'Passed: ${result.bytesTransferred} bytes, CRC-32 '
            '0x${result.crc32.toRadixString(16).padLeft(8, '0').toUpperCase()}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _otaTestResult = 'Failed: $error');
    } finally {
      if (mounted) setState(() => _otaTestRunning = false);
    }
  }

  Future<void> _confirmAndRunFlashTest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Test secondary flash slot?'),
        content: const Text(
          'This will erase the first 4 KiB page of MCUboot\'s secondary '
          'firmware slot at 0x8E000, write 1 KiB, and verify it. It will not '
          'touch the running firmware or reboot the mower.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Run flash test'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runOtaTest(writesFlash: true);
    }
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
          _SectionCard(
            title: 'Mower firmware update',
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.science_outlined),
                title: Text('BLE transport test'),
                subtitle: Text(
                  'Transfers a 1 KiB generated payload and checks its byte '
                  'order and CRC-32. This test does not write flash or reboot.',
                ),
              ),
              if (_otaTestRunning || _otaTestProgress > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(value: _otaTestProgress),
                ),
              if (_otaTestResult != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_otaTestResult!),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed:
                      widget.mowerConnected &&
                          widget.bleService?.otaTransportAvailable == true &&
                          !_otaTestRunning
                      ? () => _runOtaTest(writesFlash: false)
                      : null,
                  icon: const Icon(Icons.compare_arrows),
                  label: Text(
                    _otaTestRunning ? 'Testing...' : 'Run BLE transport test',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed:
                      widget.mowerConnected &&
                          widget.bleService?.otaTransportAvailable == true &&
                          !_otaTestRunning
                      ? _confirmAndRunFlashTest
                      : null,
                  icon: const Icon(Icons.memory),
                  label: const Text('Test secondary flash slot'),
                ),
              ),
              if (widget.mowerConnected &&
                  widget.bleService?.otaTransportAvailable != true)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'The connected firmware does not expose the OTA transport '
                    'test service.',
                    style: TextStyle(color: Colors.black54),
                  ),
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
