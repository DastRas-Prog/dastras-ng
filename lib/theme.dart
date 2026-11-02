import 'dart:math' as math;
import 'package:flutter/material.dart';

const kBg0 = Color(0xFF080D1F);
const kBg1 = Color(0xFF121B3D);
const kAccent = Color(0xFF5B8CFF);
const kCyan = Color(0xFF4DD6E8);
const kGreen = Color(0xFF2EE59D);
const kOrange = Color(0xFFFFB020);
const kGlass = Color(0x14FFFFFF);
const kGlassBorder = Color(0x22FFFFFF);

class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: Image.asset('assets/logo.png', width: size, height: size, fit: BoxFit.cover),
      );
}

/// Dark gradient with a faint, slowly rotating wire globe behind the content.
class Backdrop extends StatefulWidget {
  final Widget child;
  const Backdrop({super.key, required this.child});
  @override
  State<Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<Backdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 90))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [kBg0, kBg1],
        ),
      ),
      child: Stack(children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) => CustomPaint(painter: GlobePainter(_c.value * 2 * math.pi)),
              ),
            ),
          ),
        ),
        widget.child,
      ]),
    );
  }
}

class GlobePainter extends CustomPainter {
  final double angle;
  GlobePainter(this.angle);

  static final List<List<double>> _dots = () {
    final r = math.Random(11);
    return List.generate(140, (_) => [r.nextDouble() * 2 * math.pi, math.asin(r.nextDouble() * 2 - 1)]);
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.36);
    final r = size.shortestSide * 0.62;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color.fromRGBO(120, 170, 255, 0.10);

    canvas.drawCircle(c, r, line);
    for (var k = 0; k < 8; k++) {
      final a = angle + k * math.pi / 8;
      final rx = r * math.cos(a).abs();
      canvas.drawOval(Rect.fromCenter(center: c, width: rx * 2, height: r * 2), line);
    }
    for (final lat in [-60, -30, 0, 30, 60]) {
      final rad = lat * math.pi / 180;
      final y = c.dy - r * math.sin(rad);
      final rr = r * math.cos(rad);
      canvas.drawOval(Rect.fromCenter(center: Offset(c.dx, y), width: rr * 2, height: rr * 0.32), line);
    }
    final dot = Paint()..style = PaintingStyle.fill;
    for (final d in _dots) {
      final lon = d[0] + angle;
      final lat = d[1];
      final z = math.cos(lat) * math.cos(lon);
      if (z <= 0) continue;
      final x = c.dx + r * math.cos(lat) * math.sin(lon);
      final y = c.dy - r * math.sin(lat);
      dot.color = Color.fromRGBO(140, 200, 255, 0.28 * z);
      canvas.drawCircle(Offset(x, y), 1.8, dot);
    }
  }

  @override
  bool shouldRepaint(GlobePainter old) => old.angle != angle;
}

class PowerButton extends StatelessWidget {
  final bool on;
  final bool loading;
  final VoidCallback onTap;
  const PowerButton({super.key, required this.on, required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = on ? kGreen : (loading ? kOrange : kAccent);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 260,
        height: 260,
        child: Stack(alignment: Alignment.center, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 60, spreadRadius: 4)],
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(colors: [
                color.withValues(alpha: 0.9),
                color.withValues(alpha: 0.12),
                color.withValues(alpha: 0.6),
                color.withValues(alpha: 0.12),
                color.withValues(alpha: 0.9),
              ]),
            ),
          ),
          Container(
            width: 232,
            height: 232,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: kBg0),
          ),
          Container(
            width: 206,
            height: 206,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1C2750), Color(0xFF0E1530)],
              ),
              boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 12))],
            ),
          ),
          if (loading)
            SizedBox(
              width: 206,
              height: 206,
              child: CircularProgressIndicator(strokeWidth: 3, color: color),
            ),
          CustomPaint(size: const Size(78, 78), painter: PowerPainter(color)),
        ]),
      ),
    );
  }
}

class PowerPainter extends CustomPainter {
  final Color color;
  PowerPainter(this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.085
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromLTWH(0, 0, s.width, s.height).deflate(p.strokeWidth);
    canvas.drawArc(rect, -math.pi / 2 + 0.55, 2 * math.pi - 1.1, false, p);
    canvas.drawLine(Offset(s.width / 2, 0), Offset(s.width / 2, s.height * 0.45), p);
  }

  @override
  bool shouldRepaint(PowerPainter old) => old.color != color;
}
