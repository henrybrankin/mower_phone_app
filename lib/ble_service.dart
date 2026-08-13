import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

final _mowerServiceUuid = Guid('12345678-1234-5678-1234-56789abcdef0');
final _telemetryCharUuid = Guid('12345678-1234-5678-1234-56789abcdef1');
final _controlCharUuid = Guid('12345678-1234-5678-1234-56789abcdef2');

class MowerBleService {
  final String deviceName;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _telemetryChar;
  BluetoothCharacteristic? _controlChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  MowerBleService({this.deviceName = 'MowerXiao'});

  Future<ScanResult> startScan() async {
    await stopScan();
    _device = null;
    final completer = Completer<ScanResult>();

    _scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final result in results) {
          final advName = result.advertisementData.advName;
          final serviceUuids = result.advertisementData.serviceUuids;
          if (advName == deviceName || serviceUuids.contains(_mowerServiceUuid)) {
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
        completer.completeError(StateError('Scan timed out without finding mower'));
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
    _device = null;
  }

  Stream<List<int>> subscribeTelemetry() {
    if (_telemetryChar == null) throw StateError('Telemetry characteristic not found');
    return _telemetryChar!.onValueReceived;
  }

  Future<void> sendZeroCommand() async {
    if (_controlChar == null) throw StateError('Control characteristic not found');
    await _controlChar!.write([0x01], withoutResponse: false);
  }

  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
  }
}
