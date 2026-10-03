import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:window_size/window_size.dart';

import 'about_diagnostics_screen.dart';
import 'ble_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    setWindowTitle('Mower EMU');
    const phoneSize = Size(390, 844);
    setWindowMinSize(phoneSize);
    setWindowMaxSize(phoneSize);
    setWindowFrame(const Rect.fromLTWH(100, 100, 390, 844));
  }

  runApp(const MowerApp());
}

class MowerApp extends StatelessWidget {
  const MowerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mower EMU',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green.shade700),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _telemetryTimeout = Duration(seconds: 3);

  final _bleService = MowerBleService();
  StreamSubscription<List<int>>? _bleSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Timer? _telemetryWatchdog;
  DateTime? _lastTelemetryAt;
  TelemetryData? _last;
  bool _connected = false;
  bool _handlingConnectionLoss = false;
  String? _firmwareVersion;
  String _status = 'Disconnected';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectionSub = _bleService.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && _connected) {
        unawaited(_handleConnectionLoss('Bluetooth connection closed'));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _telemetryWatchdog?.cancel();
    _bleSub?.cancel();
    _connectionSub?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkTelemetryFreshness();
    }
  }

  Future<void> _connect() async {
    setState(() => _status = 'Scanning...');
    try {
      final device = await _bleService.startScan();
      setState(() => _status = 'Found ${device.advertisementData.advName}');
      await _bleService.connectAndDiscover();
      final firmwareVersion = await _bleService.readFirmwareVersion();
      setState(() {
        _firmwareVersion = firmwareVersion;
        _status = 'Connected';
      });
      _bleSub = _bleService.subscribeTelemetry().listen(
        _onTelemetryReceived,
        onError: (error) {
          unawaited(_handleConnectionLoss('Telemetry error: $error'));
        },
      );
      _lastTelemetryAt = DateTime.now();
      _startTelemetryWatchdog();
      setState(() => _connected = true);
    } catch (error) {
      setState(() => _status = 'Connect failed: $error');
    }
  }

  Future<void> _disconnect() async {
    _telemetryWatchdog?.cancel();
    _telemetryWatchdog = null;
    _lastTelemetryAt = null;
    await _bleSub?.cancel();
    _bleSub = null;
    await _bleService.disconnect();
    setState(() {
      _connected = false;
      _status = 'Disconnected';
      _last = null;
      _firmwareVersion = null;
    });
  }

  void _onTelemetryReceived(List<int> bytes) {
    if (bytes.length < 4) return;

    _lastTelemetryAt = DateTime.now();

    final roll = bytes[0].toSigned(8);
    final pitch = bytes[1].toSigned(8);
    setState(() {
      _last = TelemetryData(
        ts: DateTime.now(),
        rollDeg: roll.toDouble(),
        pitchDeg: pitch.toDouble(),
      );
    });
  }

  void _startTelemetryWatchdog() {
    _telemetryWatchdog?.cancel();
    _telemetryWatchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkTelemetryFreshness(),
    );
  }

  void _checkTelemetryFreshness() {
    final lastTelemetryAt = _lastTelemetryAt;
    if (!_connected || lastTelemetryAt == null) return;

    if (_bleService.otaTransferInProgress) {
      // OTA status and BLE connection events provide liveness while ordinary
      // telemetry is intentionally silent. Keep a fresh grace period for when
      // telemetry resumes after the transfer finishes or aborts.
      _lastTelemetryAt = DateTime.now();
      return;
    }

    if (DateTime.now().difference(lastTelemetryAt) > _telemetryTimeout) {
      unawaited(_handleConnectionLoss('No telemetry received'));
    }
  }

  Future<void> _handleConnectionLoss(String reason) async {
    if (_handlingConnectionLoss || !_connected) return;
    _handlingConnectionLoss = true;

    _telemetryWatchdog?.cancel();
    _telemetryWatchdog = null;
    _lastTelemetryAt = null;

    if (mounted) {
      setState(() {
        _connected = false;
        _status = 'Connection lost: $reason';
        _last = null;
        _firmwareVersion = null;
      });
    }

    await _bleSub?.cancel();
    _bleSub = null;
    try {
      await _bleService.disconnect();
    } catch (_) {
      // The peripheral may already have disappeared after an abrupt reset.
    } finally {
      _handlingConnectionLoss = false;
    }
  }

  Future<void> _requestZero() async {
    if (!_connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Not connected to mower')));
      return;
    }

    try {
      await _bleService.sendZeroCommand();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zero command sent to mower')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send zero command: $error')),
      );
    }
  }

  void _openHeatmap() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Heatmap is not available for BLE mode yet'),
      ),
    );
  }

  void _openAboutDiagnostics() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AboutDiagnosticsScreen(
          mowerConnected: _connected,
          mowerFirmwareVersion: _firmwareVersion,
          bleService: _bleService,
          onShowMap: _openHeatmap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mower EMU'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _openAboutDiagnostics,
            icon: const Icon(Icons.info_outline),
            tooltip: 'About and diagnostics',
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
                StatusPanel(
                  connected: _connected,
                  firmwareVersion: _firmwareVersion,
                ),
                const SizedBox(height: 10),
                SafetySummary(
                  connected: _connected,
                  telemetryAvailable: _last != null,
                ),
                const SizedBox(height: 10),
                SensorStatusPanel(
                  connected: _connected,
                  rollDeg: _last?.rollDeg,
                  pitchDeg: _last?.pitchDeg,
                ),
                const SizedBox(height: 10),
                const Row(
                  children: [
                    Expanded(
                      child: CompactInstrument(
                        icon: Icons.speed,
                        label: 'ENGINE RPM',
                        unit: 'rpm',
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: CompactInstrument(
                        icon: Icons.thermostat,
                        label: 'ENGINE TEMP',
                        unit: '°C',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _connected ? _disconnect : _connect,
                      icon: Icon(
                        _connected ? Icons.link_off : Icons.wifi_tethering,
                      ),
                      label: Text(_connected ? 'Disconnect' : 'Connect'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _connected ? _requestZero : null,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Zero mower'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_last != null)
                  AttitudeIndicator(
                    rollDeg: _last!.rollDeg,
                    pitchDeg: _last!.pitchDeg,
                  ),
                if (_last == null)
                  const _WaitingForAttitude(),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
          ),
        ),
      ),
    );
  }
}

class StatusPanel extends StatelessWidget {
  final bool connected;
  final String? firmwareVersion;

  const StatusPanel({super.key, required this.connected, this.firmwareVersion});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [Colors.green.shade600, Colors.green.shade400],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.grass, size: 48, color: Colors.white),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? 'Connected' : 'Disconnected',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 2),
                Text(
                  'EMU firmware: ${firmwareVersion ?? 'Unknown'}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SafetySummary extends StatelessWidget {
  final bool connected;
  final bool telemetryAvailable;

  const SafetySummary({
    super.key,
    required this.connected,
    required this.telemetryAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final label = !connected
        ? 'EMU DISCONNECTED'
        : telemetryAvailable
        ? 'MONITORING — PRESSURE INPUT PENDING'
        : 'WAITING FOR TELEMETRY';
    final color = connected ? Colors.blueGrey.shade700 : Colors.grey.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.health_and_safety : Icons.sensors_off,
            color: Colors.white,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SensorStatusPanel extends StatelessWidget {
  final bool connected;
  final double? rollDeg;
  final double? pitchDeg;

  const SensorStatusPanel({
    super.key,
    required this.connected,
    this.rollDeg,
    this.pitchDeg,
  });

  @override
  Widget build(BuildContext context) {
    final hasAttitude = rollDeg != null && pitchDeg != null;
    final combinedTilt = hasAttitude
        ? math.acos(
                (math.cos(rollDeg! * math.pi / 180) *
                        math.cos(pitchDeg! * math.pi / 180))
                    .clamp(-1.0, 1.0),
              ) *
              180 /
              math.pi
        : null;
    final tiltLabel = combinedTilt == null
        ? 'Unavailable'
        : combinedTilt >= 45
        ? 'DANGER'
        : combinedTilt >= 35
        ? 'WARNING'
        : 'SAFE';
    final tiltColor = combinedTilt == null
        ? Colors.grey
        : combinedTilt >= 45
        ? Colors.red
        : combinedTilt >= 35
        ? Colors.orange
        : Colors.green;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            _StatusLine(
              icon: Icons.oil_barrel_outlined,
              label: 'Oil pressure',
              value: connected ? 'Awaiting A6 input' : 'Unavailable',
              color: Colors.grey,
            ),
            const Divider(height: 12),
            _StatusLine(
              icon: Icons.landscape_outlined,
              label: 'Tilt risk',
              value: tiltLabel,
              color: tiltColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatusLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class CompactInstrument extends StatelessWidget {
  final IconData icon;
  final String label;
  final String unit;
  final double? value;
  final double minimum;
  final double maximum;

  const CompactInstrument({
    super.key,
    required this.icon,
    required this.label,
    required this.unit,
    this.value,
    this.minimum = 0,
    this.maximum = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: Colors.black54),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 62,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CompactGaugePainter(
                        value: value,
                        minimum: minimum,
                        maximum: maximum,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 15),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          value == null ? '—' : value!.round().toString(),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(unit, style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactGaugePainter extends CustomPainter {
  final double? value;
  final double minimum;
  final double maximum;

  const _CompactGaugePainter({
    required this.value,
    required this.minimum,
    required this.maximum,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(12, 7, size.width - 24, size.height * 1.15);
    const start = math.pi;
    const sweep = math.pi;
    final track = Paint()
      ..color = Colors.grey.shade300
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, track);
    if (value == null || maximum <= minimum) return;
    final fraction = ((value! - minimum) / (maximum - minimum)).clamp(0.0, 1.0);
    final active = Paint()
      ..color = Colors.green.shade600
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep * fraction, false, active);
  }

  @override
  bool shouldRepaint(covariant _CompactGaugePainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.minimum != minimum ||
      oldDelegate.maximum != maximum;
}

class _WaitingForAttitude extends StatelessWidget {
  const _WaitingForAttitude();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: SizedBox(
        height: 120,
        child: Center(child: Text('Connect to display mower attitude')),
      ),
    );
  }
}

class AttitudeIndicator extends StatelessWidget {
  final double rollDeg;
  final double pitchDeg;

  const AttitudeIndicator({
    super.key,
    required this.rollDeg,
    required this.pitchDeg,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Attitude',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text('Roll ${_formatSigned(rollDeg)}°'),
                const SizedBox(width: 12),
                Text('Pitch ${_formatSigned(pitchDeg)}°'),
              ],
            ),
            const SizedBox(height: 10),
            Center(
              child: SizedBox(
                width: 190,
                height: 190,
                child: CustomPaint(
                  painter: _AttitudePainter(
                    rollDeg: rollDeg,
                    pitchDeg: pitchDeg,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttitudePainter extends CustomPainter {
  final double rollDeg;
  final double pitchDeg;

  _AttitudePainter({required this.rollDeg, required this.pitchDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;

    final clipPath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.save();
    canvas.clipPath(clipPath);

    canvas.translate(center.dx, center.dy);
    canvas.rotate(-rollDeg * math.pi / 180.0);

    final pxPerDeg = radius / 35.0;
    final pitchOffset = pitchDeg * pxPerDeg;

    final skyPaint = Paint()..color = const Color(0xFF4A90E2);
    final groundPaint = Paint()..color = const Color(0xFF8D6E63);

    canvas.drawRect(
      Rect.fromLTWH(
        -radius * 2,
        -radius * 2 + pitchOffset,
        radius * 4,
        radius * 2,
      ),
      skyPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(-radius * 2, pitchOffset, radius * 4, radius * 2),
      groundPaint,
    );

    final horizonPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.0;
    canvas.drawLine(
      Offset(-radius * 1.6, pitchOffset),
      Offset(radius * 1.6, pitchOffset),
      horizonPaint,
    );

    final ladderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1.5;
    for (int deg = -30; deg <= 30; deg += 10) {
      if (deg == 0) continue;
      final y = pitchOffset + (deg * pxPerDeg);
      final halfWidth = (deg % 20 == 0) ? radius * 0.28 : radius * 0.18;
      canvas.drawLine(Offset(-halfWidth, y), Offset(halfWidth, y), ladderPaint);

      final label = deg.abs().toString();
      final labelStyle = TextStyle(
        color: Colors.white.withValues(alpha: 0.85),
        fontSize: 10,
        fontWeight: FontWeight.w700,
      );
      final leftLabel = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      leftLabel.paint(
        canvas,
        Offset(-halfWidth - leftLabel.width - 6, y - leftLabel.height / 2),
      );

      final rightLabel = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      rightLabel.paint(
        canvas,
        Offset(halfWidth + 6, y - rightLabel.height / 2),
      );
    }

    canvas.restore();

    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.black87;
    canvas.drawCircle(center, radius - 1.5, rimPaint);

    final aircraftPaint = Paint()
      ..color = Colors.amber.shade700
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(center.dx - radius * 0.26, center.dy),
      Offset(center.dx + radius * 0.26, center.dy),
      aircraftPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy),
      Offset(center.dx, center.dy + radius * 0.10),
      aircraftPaint,
    );
    canvas.drawCircle(center, 4, aircraftPaint);

    final bankTickPaint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 2.0;
    for (final tick in const [0, 30, 60, -30, -60]) {
      final rad = tick * math.pi / 180.0;
      final outer = Offset(
        center.dx + math.sin(rad) * (radius - 8),
        center.dy - math.cos(rad) * (radius - 8),
      );
      final inner = Offset(
        center.dx + math.sin(rad) * (radius - 18),
        center.dy - math.cos(rad) * (radius - 18),
      );
      canvas.drawLine(inner, outer, bankTickPaint);

      if (tick != 0) {
        final label = tick.abs().toString();
        final labelPos = Offset(
          center.dx + math.sin(rad) * (radius - 28),
          center.dy - math.cos(rad) * (radius - 28),
        );
        final labelPainter = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        labelPainter.paint(
          canvas,
          Offset(
            labelPos.dx - labelPainter.width / 2,
            labelPos.dy - labelPainter.height / 2,
          ),
        );
      }
    }

    final rollRad = rollDeg * math.pi / 180.0;
    final pointerCenter = Offset(
      center.dx + math.sin(rollRad) * (radius - 10),
      center.dy - math.cos(rollRad) * (radius - 10),
    );
    final tangent = Offset(math.cos(rollRad), math.sin(rollRad));
    final radial = Offset(math.sin(rollRad), -math.cos(rollRad));
    final movingPointer = Path()
      ..moveTo(
        pointerCenter.dx + radial.dx * 2,
        pointerCenter.dy + radial.dy * 2,
      )
      ..lineTo(
        pointerCenter.dx - radial.dx * 8 + tangent.dx * 6,
        pointerCenter.dy - radial.dy * 8 + tangent.dy * 6,
      )
      ..lineTo(
        pointerCenter.dx - radial.dx * 8 - tangent.dx * 6,
        pointerCenter.dy - radial.dy * 8 - tangent.dy * 6,
      )
      ..close();
    canvas.drawPath(movingPointer, Paint()..color = Colors.white);

    final pointerPath = Path()
      ..moveTo(center.dx, center.dy - radius + 7)
      ..lineTo(center.dx - 8, center.dy - radius + 20)
      ..lineTo(center.dx + 8, center.dy - radius + 20)
      ..close();
    canvas.drawPath(pointerPath, Paint()..color = Colors.amber.shade700);
  }

  @override
  bool shouldRepaint(covariant _AttitudePainter oldDelegate) {
    return oldDelegate.rollDeg != rollDeg || oldDelegate.pitchDeg != pitchDeg;
  }
}

String _formatSigned(double value) {
  final normalized = value.abs() < 0.05 ? 0.0 : value;
  final text = normalized.toStringAsFixed(1);
  return normalized >= 0 ? '+$text' : text;
}

class HeatmapScreen extends StatelessWidget {
  final List<List<MapCell>> map;

  const HeatmapScreen({super.key, required this.map});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Failure Heatmap')),
      body: Column(
        children: [
          Expanded(child: HeatmapView(map: map)),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _downloadMap(context),
                  icon: const Icon(Icons.download),
                  label: const Text('Download Map'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _downloadMap(BuildContext context) {
    // For now show as CSV in a dialog — later app can write to file or use share plugin
    final rows = <String>[];
    rows.add('roll_index,pitch_index,visits,min_psi,max_psi');
    for (var r = 0; r < map.length; r++) {
      for (var c = 0; c < map[r].length; c++) {
        final cell = map[r][c];
        if (cell.visits == 0) continue;
        rows.add(
          '$r,$c,${cell.visits},${cell.minPressure.toStringAsFixed(1)},${cell.maxPressure.toStringAsFixed(1)}',
        );
      }
    }
    final csv = rows.join('\n');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Map CSV (copy)'),
        content: SingleChildScrollView(child: SelectableText(csv)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class HeatmapView extends StatelessWidget {
  final List<List<MapCell>> map;

  const HeatmapView({super.key, required this.map});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _HeatmapPainter(map)),
          ),
        );
      },
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final List<List<MapCell>> map;
  _HeatmapPainter(this.map);

  @override
  void paint(Canvas canvas, Size size) {
    final rows = map.length;
    final cols = map.isNotEmpty ? map[0].length : 0;
    if (rows == 0 || cols == 0) return;
    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final paint = Paint();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final cell = map[r][c];
        final intensity = (cell.visits / 10).clamp(0.0, 1.0);
        paint.color = Color.lerp(Colors.white, Colors.red, intensity)!;
        canvas.drawRect(
          Rect.fromLTWH(c * cellW, r * cellH, cellW, cellH),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class MapCell {
  int visits;
  double minPressure;
  double maxPressure;

  MapCell({
    this.visits = 0,
    this.minPressure = double.infinity,
    this.maxPressure = 0,
  });
}

// --- Mock telemetry service and models ---

class TelemetryData {
  final DateTime ts;
  final double rollDeg;
  final double pitchDeg;

  TelemetryData({
    required this.ts,
    required this.rollDeg,
    required this.pitchDeg,
  });
}
