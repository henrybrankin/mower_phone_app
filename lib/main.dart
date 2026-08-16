import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:window_size/window_size.dart';

import 'about_diagnostics_screen.dart';
import 'ble_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    setWindowTitle('Mower Phone');
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
      title: 'Mower Phone',
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

class _HomeScreenState extends State<HomeScreen> {
  final _bleService = MowerBleService();
  StreamSubscription<List<int>>? _bleSub;
  TelemetryData? _last;
  bool _connected = false;
  String? _firmwareVersion;
  String _status = 'Disconnected';

  @override
  void dispose() {
    _bleSub?.cancel();
    _bleService.dispose();
    super.dispose();
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
          setState(() => _status = 'Telemetry error: $error');
        },
      );
      setState(() => _connected = true);
    } catch (error) {
      setState(() => _status = 'Connect failed: $error');
    }
  }

  Future<void> _disconnect() async {
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

    final roll = bytes[0].toSigned(8);
    final pitch = bytes[1].toSigned(8);
    final pressure = bytes[2] * (360.0 / 255.0);
    final temp = bytes[3].toSigned(8).toDouble();

    setState(() {
      _last = TelemetryData(
        ts: DateTime.now(),
        rollDeg: roll.toDouble(),
        pitchDeg: pitch.toDouble(),
        oilPressure: pressure,
        oilTemp: temp,
      );
    });
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mower Phone'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _openHeatmap,
            icon: const Icon(Icons.map),
            tooltip: 'Open failure heatmap',
          ),
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
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                StatusPanel(
                  connected: _connected,
                  firmwareVersion: _firmwareVersion,
                ),
                const SizedBox(height: 8),
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
                      onPressed: _requestZero,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Zero mower'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _openHeatmap,
                      icon: const Icon(Icons.map),
                      label: const Text('Show map'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_last != null) LiveReadout(data: _last!),
                if (_last != null) const SizedBox(height: 12),
                if (_last != null)
                  AttitudeIndicator(
                    rollDeg: _last!.rollDeg,
                    pitchDeg: _last!.pitchDeg,
                    headingDeg: _last!.oilPressure,
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: Center(
                    child: Text(
                      'Status: $_status',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
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
                const Text(
                  'Mower',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  connected ? 'Connected' : 'Disconnected',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 2),
                Text(
                  'Firmware: ${firmwareVersion ?? 'Unknown'}',
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

class LiveReadout extends StatelessWidget {
  final TelemetryData data;

  const LiveReadout({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _infoColumn('Heading', _formatHeading(data.oilPressure)),
            _infoColumn('Gyro Z', _formatSigned(data.oilTemp)),
            _infoColumn('Roll', _formatSigned(data.rollDeg)),
            _infoColumn('Pitch', _formatSigned(data.pitchDeg)),
          ],
        ),
      ),
    );
  }

  Widget _infoColumn(String label, String value) => Column(
    children: [
      Text(label, style: const TextStyle(color: Colors.black54)),
      const SizedBox(height: 6),
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    ],
  );
}

class AttitudeIndicator extends StatelessWidget {
  final double rollDeg;
  final double pitchDeg;
  final double headingDeg;

  const AttitudeIndicator({
    super.key,
    required this.rollDeg,
    required this.pitchDeg,
    required this.headingDeg,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Attitude',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Center(
              child: SizedBox(
                width: 210,
                height: 210,
                child: CustomPaint(
                  painter: _AttitudePainter(
                    rollDeg: rollDeg,
                    pitchDeg: pitchDeg,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: HeadingTape(headingDeg: headingDeg),
            ),
          ],
        ),
      ),
    );
  }
}

class HeadingTape extends StatelessWidget {
  final double headingDeg;

  const HeadingTape({super.key, required this.headingDeg});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _HeadingTapePainter(headingDeg: headingDeg));
  }
}

class _HeadingTapePainter extends CustomPainter {
  final double headingDeg;

  _HeadingTapePainter({required this.headingDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    final bgPaint = Paint()..color = const Color(0xFF10151D);
    canvas.drawRRect(rect, bgPaint);

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final pxPerDeg = size.width / 120.0;
    final majorPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    final minorPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.2;

    final wrapped = _wrapHeading(headingDeg);
    final anchor = (wrapped / 5.0).floor() * 5.0;

    for (int step = -24; step <= 24; step++) {
      final tickHeading = anchor + (step * 5.0);
      final delta = tickHeading - wrapped;
      final x = centerX + delta * pxPerDeg;
      if (x < 0 || x > size.width) continue;

      final roundedTick = _wrapHeading(tickHeading).round() % 360;
      final isMajor = roundedTick % 10 == 0;
      final tickTop = isMajor ? 8.0 : 14.0;
      final tickBottom = isMajor ? 24.0 : 22.0;
      canvas.drawLine(
        Offset(x, tickTop),
        Offset(x, tickBottom),
        isMajor ? majorPaint : minorPaint,
      );

      if (roundedTick % 30 == 0) {
        final value = _wrapHeading(tickHeading);
        final label = _headingLabel(value);
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, 28));
      }
    }

    final pointerPath = Path()
      ..moveTo(centerX, 4)
      ..lineTo(centerX - 7, 14)
      ..lineTo(centerX + 7, 14)
      ..close();
    canvas.drawPath(pointerPath, Paint()..color = Colors.amber.shade700);

    final boxRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centerX, centerY + 4),
        width: 56,
        height: 20,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(boxRect, Paint()..color = const Color(0xFF1B2430));

    final headingText = TextPainter(
      text: TextSpan(
        text: _formatHeading(headingDeg),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    headingText.paint(
      canvas,
      Offset(
        centerX - headingText.width / 2,
        centerY - headingText.height / 2 + 4,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _HeadingTapePainter oldDelegate) {
    return oldDelegate.headingDeg != headingDeg;
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

double _wrapHeading(double value) {
  double wrapped = value % 360.0;
  if (wrapped < 0) wrapped += 360.0;
  return wrapped;
}

String _formatHeading(double value) {
  final wrapped = _wrapHeading(value).round() % 360;
  return '${wrapped.toString().padLeft(3, '0')}°';
}

String _headingLabel(double heading) {
  final rounded = _wrapHeading(heading).round() % 360;
  if (rounded == 0) return 'N';
  if (rounded == 90) return 'E';
  if (rounded == 180) return 'S';
  if (rounded == 270) return 'W';
  return (rounded ~/ 10).toString().padLeft(2, '0');
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
  final double oilPressure; // psi
  final double oilTemp; // C

  TelemetryData({
    required this.ts,
    required this.rollDeg,
    required this.pitchDeg,
    required this.oilPressure,
    required this.oilTemp,
  });
}
