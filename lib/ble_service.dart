import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

final _mowerServiceUuid = Guid('12345678-1234-5678-1234-56789abcdef0');
final _telemetryCharUuid = Guid('12345678-1234-5678-1234-56789abcdef1');
final _controlCharUuid = Guid('12345678-1234-5678-1234-56789abcdef2');
final _versionCharUuid = Guid('12345678-1234-5678-1234-56789abcdef3');

class MowerBleService {
  final String deviceName;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _telemetryChar;
  BluetoothCharacteristic? _controlChar;
  BluetoothCharacteristic? _versionChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  MowerBleService({this.deviceName = 'MowerXiao'});

  String get platformName {
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isWindows) return 'Windows';
    return Platform.operatingSystem;
  }

  Future<void> _ensureBluetoothReady() async {
    if (!Platform.isIOS && !Platform.isWindows) {
      throw UnsupportedError(
        'Mower BLE is currently supported on Windows and iPhone only',
      );
    }

    if (!await FlutterBluePlus.isSupported) {
      throw StateError(
        'Bluetooth LE is not supported on this $platformName device',
      );
    }

    var state = FlutterBluePlus.adapterStateNow;
    if (state == BluetoothAdapterState.unknown) {
      state = await FlutterBluePlus.adapterState
          .where((value) => value != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
    }

    switch (state) {
      case BluetoothAdapterState.on:
        return;
      case BluetoothAdapterState.unauthorized:
        throw StateError(
          'Bluetooth access is not authorized. Enable it for Mower Phone in '
          '${Platform.isIOS ? 'iPhone Settings' : 'Windows Settings'}.',
        );
      case BluetoothAdapterState.off:
        throw StateError(
          'Bluetooth is turned off on this $platformName device',
        );
      default:
        throw StateError(
          'Bluetooth is not ready on this $platformName device ($state)',
        );
    }
  }

  Future<ScanResult> startScan() async {
    await _ensureBluetoothReady();
    await stopScan();
    _device = null;
    final completer = Completer<ScanResult>();

    _scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final result in results) {
          final advName = result.advertisementData.advName;
          final serviceUuids = result.advertisementData.serviceUuids;
          if (advName == deviceName ||
              serviceUuids.contains(_mowerServiceUuid)) {
            if (_device == null) {
              _device = result.device;
              completer.complete(result);
              break;
            }
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );

    final scanTimer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Scan timed out without finding mower'),
        );
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [_mowerServiceUuid],
        timeout: const Duration(seconds: 15),
      );

      final result = await completer.future;
      return result;
    } finally {
      scanTimer.cancel();
      await stopScan();
    }
  }

  Future<void> stopScan() async {
    if (_scanSub != null) {
      await _scanSub!.cancel();
      _scanSub = null;
    }
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> connectAndDiscover() async {
    if (_device == null) throw StateError('No device to connect');
    await stopScan();
    _connSub?.cancel();

    await _device!.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );

    _connSub = _device!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _telemetryChar = null;
        _controlChar = null;
        _versionChar = null;
      }
    });

    final services = await _device!.discoverServices();
    for (final service in services) {
      if (service.uuid == _mowerServiceUuid) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == _telemetryCharUuid) {
            _telemetryChar = characteristic;
          }
          if (characteristic.uuid == _controlCharUuid) {
            _controlChar = characteristic;
          }
          if (characteristic.uuid == _versionCharUuid) {
            _versionChar = characteristic;
          }
        }
      }
    }

    if (_telemetryChar == null || _controlChar == null) {
      throw StateError('Required mower characteristics not found');
    }

    await _telemetryChar!.setNotifyValue(true);
  }

  Future<void> disconnect() async {
    _connSub?.cancel();
    _connSub = null;

    if (_device != null) {
      await _device!.disconnect();
    }

    _telemetryChar = null;
    _controlChar = null;
    _versionChar = null;
    _device = null;
  }

  Future<String?> readFirmwareVersion() async {
    final characteristic = _versionChar;
    if (characteristic == null) return null;

    final bytes = await characteristic.read();
    final version = utf8.decode(bytes, allowMalformed: true).trim();
    return version.isEmpty ? null : version;
  }

  Stream<List<int>> subscribeTelemetry() {
    if (_telemetryChar == null) {
      throw StateError('Telemetry characteristic not found');
    }
    return _telemetryChar!.onValueReceived;
  }

  Future<void> sendZeroCommand() async {
    if (_controlChar == null) {
      throw StateError('Control characteristic not found');
    }
    await _controlChar!.write([0x01], withoutResponse: false);
  }

  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
  }
}
