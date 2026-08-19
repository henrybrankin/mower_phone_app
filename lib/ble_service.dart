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
  final Duration elapsed;
  final int mtu;
  final int payloadBytesPerChunk;

  const OtaTransportTestResult({
    required this.bytesTransferred,
    required this.crc32,
    required this.elapsed,
    required this.mtu,
    required this.payloadBytesPerChunk,
  });

  double get bytesPerSecond => elapsed.inMicroseconds == 0
      ? 0
      : bytesTransferred * 1000000 / elapsed.inMicroseconds;
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
    if (_otaStatusChar != null) {
      await _otaStatusChar!.setNotifyValue(true);
    }
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
  }) => _runOtaTransfer(
    startCommand: 0x01,
    payload: _makeTestPayload(),
    onProgress: onProgress,
  );

  Future<OtaTransportTestResult> runOtaSecondarySlotFlashTest({
    void Function(double progress)? onProgress,
  }) => _runOtaTransfer(
    startCommand: 0x04,
    payload: _makeTestPayload(),
    onProgress: onProgress,
  );

  Future<OtaTransportTestResult> stageOtaImage(
    List<int> image, {
    void Function(double progress)? onProgress,
  }) => _runOtaTransfer(
    startCommand: 0x05,
    payload: image,
    onProgress: onProgress,
  );

  Future<OtaTransportTestResult> _runOtaTransfer({
    required int startCommand,
    required List<int> payload,
    void Function(double progress)? onProgress,
  }) async {
    final control = _otaControlChar;
    final data = _otaDataChar;
    final status = _otaStatusChar;
    if (control == null || data == null || status == null) {
      throw StateError('Firmware transport characteristics not found');
    }

    final crc = _crc32(payload);
    final mtu = _device?.mtuNow ?? 23;
    var payloadBytesPerChunk = (mtu - 7).clamp(16, 240).toInt();
    payloadBytesPerChunk -= payloadBytesPerChunk % 4;
    const acknowledgementWindowBytes = 256;
    final start = <int>[
      startCommand,
      ..._uint32Le(payload.length),
      ..._uint32Le(crc),
    ];

    try {
      final stopwatch = Stopwatch()..start();
      var statusFuture = _waitForOtaStatus(
        status,
        (value) =>
            value.result != 0 ||
            (value.state == 1 &&
                value.receivedBytes == 0 &&
                value.expectedBytes == payload.length),
      );
      await control.write(start, withoutResponse: false);
      var current = await statusFuture;
      _requireOtaStatus(
        current,
        expectedState: 1,
        expectedBytes: payload.length,
      );

      var offset = 0;
      while (offset < payload.length) {
        final windowStart = offset;
        final windowTarget =
            (windowStart + acknowledgementWindowBytes < payload.length)
            ? windowStart + acknowledgementWindowBytes
            : payload.length;
        statusFuture = _waitForOtaWindowStatus(
          status,
          expectedBytes: payload.length,
          windowStart: windowStart,
          windowTarget: windowTarget,
        );
        do {
          final end = (offset + payloadBytesPerChunk < payload.length)
              ? offset + payloadBytesPerChunk
              : payload.length;
          final packet = <int>[
            ..._uint32Le(offset),
            ...payload.sublist(offset, end),
          ];
          // WinRT's MTU-23 path needs explicit controller flow control. This
          // 64-byte cadence is the configuration proven over a complete image.
          // iOS keeps the faster no-response path and can use its larger MTU.
          final requiresWindowsFlowControl =
              Platform.isWindows && startCommand != 0x01 && end % 64 == 0;
          await _writeOtaPacket(
            data,
            packet,
            withoutResponse: !requiresWindowsFlowControl,
          );
          offset = end;
        } while (offset < payload.length &&
            offset - windowStart < acknowledgementWindowBytes);

        current = await statusFuture;
        _requireOtaStatus(
          current,
          expectedState: 1,
          expectedBytes: payload.length,
        );
        if (current.receivedBytes > offset) {
          throw StateError('Firmware reported an impossible transfer offset');
        }
        // A partial status that settles below the target is a recoverable
        // NACK. Resume at the first byte the Arduino did not accept.
        offset = current.receivedBytes;
        onProgress?.call(offset / payload.length);
      }

      statusFuture = _waitForOtaStatus(
        status,
        (value) =>
            value.result != 0 ||
            (value.state == 2 &&
                value.receivedBytes == payload.length &&
                value.expectedBytes == payload.length),
      );
      await control.write([0x02], withoutResponse: false);
      final completed = await statusFuture;
      _requireOtaStatus(
        completed,
        expectedState: 2,
        expectedBytes: payload.length,
        expectedReceivedBytes: payload.length,
      );
      stopwatch.stop();
      return OtaTransportTestResult(
        bytesTransferred: payload.length,
        crc32: crc,
        elapsed: stopwatch.elapsed,
        mtu: mtu,
        payloadBytesPerChunk: payloadBytesPerChunk,
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

  static List<int> _makeTestPayload() => List<int>.generate(
    1024,
    (index) => (index * 37 + 11) & 0xff,
    growable: false,
  );

  static Future<void> _writeOtaPacket(
    BluetoothCharacteristic characteristic,
    List<int> packet, {
    required bool withoutResponse,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await characteristic.write(packet, withoutResponse: withoutResponse);
        return;
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 100 * (attempt + 1)),
          );
        }
      }
    }
    throw StateError('BLE write failed after 3 attempts: $lastError');
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

  static _OtaStatus _parseOtaStatus(List<int> bytes) {
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

  static Future<_OtaStatus> _waitForOtaStatus(
    BluetoothCharacteristic characteristic,
    bool Function(_OtaStatus status) matches,
  ) => characteristic.onValueReceived
      .map(_parseOtaStatus)
      .where(matches)
      .first
      .timeout(const Duration(seconds: 30));

  static Future<_OtaStatus> _waitForOtaWindowStatus(
    BluetoothCharacteristic characteristic, {
    required int expectedBytes,
    required int windowStart,
    required int windowTarget,
  }) async {
    final completer = Completer<_OtaStatus>();
    _OtaStatus? latestPartial;
    int? latestPartialOffset;
    Timer? settleTimer;
    late final StreamSubscription<List<int>> subscription;

    void complete(_OtaStatus value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    subscription = characteristic.onValueReceived.listen(
      (bytes) {
        final value = _parseOtaStatus(bytes);
        if (value.result != 0 ||
            (value.state == 1 &&
                value.expectedBytes == expectedBytes &&
                value.receivedBytes >= windowTarget)) {
          complete(value);
          return;
        }
        if (value.state != 1 ||
            value.expectedBytes != expectedBytes ||
            value.receivedBytes < windowStart) {
          return;
        }

        latestPartial = value;
        if (latestPartialOffset != value.receivedBytes) {
          latestPartialOffset = value.receivedBytes;
          settleTimer?.cancel();
          settleTimer = Timer(const Duration(seconds: 2), () {
            final partial = latestPartial;
            if (partial != null) complete(partial);
          });
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );

    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      settleTimer?.cancel();
      await subscription.cancel();
    }
  }

  static void _requireOtaStatus(
    _OtaStatus status, {
    required int expectedState,
    required int expectedBytes,
    int? expectedReceivedBytes,
  }) {
    if (status.result != 0) {
      throw StateError(
        'Firmware transport rejected data (${status.result}) at '
        '${status.receivedBytes}/${status.expectedBytes} bytes',
      );
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
