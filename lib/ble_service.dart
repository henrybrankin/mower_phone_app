import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

final _mowerServiceUuid = Guid('12345678-1234-5678-1234-56789abcdef0');
final _telemetryCharUuid = Guid('12345678-1234-5678-1234-56789abcdef1');
final _controlCharUuid = Guid('12345678-1234-5678-1234-56789abcdef2');
final _versionCharUuid = Guid('12345678-1234-5678-1234-56789abcdef3');
final _otaControlCharUuid = Guid('12345678-1234-5678-1234-56789abcdef4');
final _otaDataCharUuid = Guid('12345678-1234-5678-1234-56789abcdef5');
final _otaStatusCharUuid = Guid('12345678-1234-5678-1234-56789abcdef6');

class OtaTransportTestResult {
  final int bytesTransferred;
  final int crc32;

  const OtaTransportTestResult({
    required this.bytesTransferred,
    required this.crc32,
  });
}

class _OtaStatus {
  final int state;
  final int result;
  final int receivedBytes;
  final int expectedBytes;

  const _OtaStatus({
    required this.state,
    required this.result,
    required this.receivedBytes,
    required this.expectedBytes,
  });
}

class MowerBleService {
  final String deviceName;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _telemetryChar;
  BluetoothCharacteristic? _controlChar;
  BluetoothCharacteristic? _versionChar;
  BluetoothCharacteristic? _otaControlChar;
  BluetoothCharacteristic? _otaDataChar;
  BluetoothCharacteristic? _otaStatusChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final _connectionStateController =
      StreamController<BluetoothConnectionState>.broadcast();

  MowerBleService({this.deviceName = 'MowerEMU'});

  Stream<BluetoothConnectionState> get connectionState =>
      _connectionStateController.stream;

  bool get otaTransportAvailable =>
      _otaControlChar != null && _otaDataChar != null && _otaStatusChar != null;

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
          'Bluetooth access is not authorized. Enable it for Mower EMU in '
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
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(state);
      }
      if (state == BluetoothConnectionState.disconnected) {
        _telemetryChar = null;
        _controlChar = null;
        _versionChar = null;
        _otaControlChar = null;
        _otaDataChar = null;
        _otaStatusChar = null;
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
          if (characteristic.uuid == _otaControlCharUuid) {
            _otaControlChar = characteristic;
          }
          if (characteristic.uuid == _otaDataCharUuid) {
            _otaDataChar = characteristic;
          }
          if (characteristic.uuid == _otaStatusCharUuid) {
            _otaStatusChar = characteristic;
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
    _otaControlChar = null;
    _otaDataChar = null;
    _otaStatusChar = null;
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

  Future<OtaTransportTestResult> runOtaTransportTest({
    void Function(double progress)? onProgress,
  }) => _runOtaTest(startCommand: 0x01, onProgress: onProgress);

  Future<OtaTransportTestResult> runOtaSecondarySlotFlashTest({
    void Function(double progress)? onProgress,
  }) => _runOtaTest(startCommand: 0x04, onProgress: onProgress);

  Future<OtaTransportTestResult> _runOtaTest({
    required int startCommand,
    void Function(double progress)? onProgress,
  }) async {
    final control = _otaControlChar;
    final data = _otaDataChar;
    final status = _otaStatusChar;
    if (control == null || data == null || status == null) {
      throw StateError('Firmware transport characteristics not found');
    }

    final payload = List<int>.generate(
      1024,
      (index) => (index * 37 + 11) & 0xff,
      growable: false,
    );
    final crc = _crc32(payload);
    final start = <int>[
      startCommand,
      ..._uint32Le(payload.length),
      ..._uint32Le(crc),
    ];

    try {
      await control.write(start, withoutResponse: false);
      var current = await _readOtaStatus(status);
      _requireOtaStatus(
        current,
        expectedState: 1,
        expectedBytes: payload.length,
      );

      for (var offset = 0; offset < payload.length; offset += 16) {
        final end = (offset + 16 < payload.length)
            ? offset + 16
            : payload.length;
        final packet = <int>[
          ..._uint32Le(offset),
          ...payload.sublist(offset, end),
        ];
        await data.write(packet, withoutResponse: false);
        current = await _readOtaStatus(status);
        _requireOtaStatus(
          current,
          expectedState: 1,
          expectedBytes: payload.length,
          expectedReceivedBytes: end,
        );
        onProgress?.call(end / payload.length);
      }

      await control.write([0x02], withoutResponse: false);
      final completed = await _readOtaStatus(status);
      _requireOtaStatus(
        completed,
        expectedState: 2,
        expectedBytes: payload.length,
        expectedReceivedBytes: payload.length,
      );
      return OtaTransportTestResult(
        bytesTransferred: payload.length,
        crc32: crc,
      );
    } catch (_) {
      try {
        await control.write([0x03], withoutResponse: false);
      } catch (_) {
        // Preserve the original transfer error if the best-effort abort fails.
      }
      rethrow;
    }
  }

  static List<int> _uint32Le(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

  static int _readUint32Le(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static Future<_OtaStatus> _readOtaStatus(
    BluetoothCharacteristic characteristic,
  ) async {
    final bytes = await characteristic.read();
    if (bytes.length != 10) {
      throw StateError('Invalid firmware transport status length');
    }
    return _OtaStatus(
      state: bytes[0],
      result: bytes[1],
      receivedBytes: _readUint32Le(bytes, 2),
      expectedBytes: _readUint32Le(bytes, 6),
    );
  }

  static void _requireOtaStatus(
    _OtaStatus status, {
    required int expectedState,
    required int expectedBytes,
    int? expectedReceivedBytes,
  }) {
    if (status.result != 0) {
      throw StateError('Firmware transport rejected data (${status.result})');
    }
    if (status.state != expectedState ||
        status.expectedBytes != expectedBytes ||
        (expectedReceivedBytes != null &&
            status.receivedBytes != expectedReceivedBytes)) {
      throw StateError(
        'Unexpected firmware transport status: state ${status.state}, '
        '${status.receivedBytes}/${status.expectedBytes} bytes',
      );
    }
  }

  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _connectionStateController.close();
  }
}
