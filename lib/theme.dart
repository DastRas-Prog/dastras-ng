import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'pal.dart';

class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: Image.asset('assets/logo.png', width: size, height: size, fit: BoxFit.cover),
      );
}

/// Soft glass card used all over the app.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.radius = 18, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? Pal.card,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Pal.cardBorder),
          boxShadow: Pal.dark ? null : [BoxShadow(color: Pal.shadow, blurRadius: 14, offset: const Offset(0, 4))],
        ),
        child: child,
      );
}

/// Gradient background with a faint, slowly rotating wire globe.
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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Pal.bg0, Pal.bg1],
        ),
      ),
      child: Stack(children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) => CustomPaint(painter: GlobePainter(_c.value * 2 * math.pi, Pal.globe, Pal.dot)),
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
  final Color line, dotColor;
  GlobePainter(this.angle, this.line, this.dotColor);

  static final List<List<double>> _dots = () {
    final r = math.Random(11);
    return List.generate(140, (_) => [r.nextDouble() * 2 * math.pi, math.asin(r.nextDouble() * 2 - 1)]);
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.36);
    final r = size.shortestSide * 0.62;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = line;
    canvas.drawCircle(c, r, p);
    for (var k = 0; k < 8; k++) {
      final a = angle + k * math.pi / 8;
      final rx = r * math.cos(a).abs();
      canvas.drawOval(Rect.fromCenter(center: c, width: rx * 2, height: r * 2), p);
    }
    for (final lat in [-60, -30, 0, 30, 60]) {
      final rad = lat * math.pi / 180;
      final y = c.dy - r * math.sin(rad);
      final rr = r * math.cos(rad);
      canvas.drawOval(Rect.fromCenter(center: Offset(c.dx, y), width: rr * 2, height: rr * 0.32), p);
    }
    final dot = Paint()..style = PaintingStyle.fill;
    for (final d in _dots) {
      final lon = d[0] + angle;
      final lat = d[1];
      final z = math.cos(lat) * math.cos(lon);
      if (z <= 0) continue;
      final x = c.dx + r * math.cos(lat) * math.sin(lon);
      final y = c.dy - r * math.sin(lat);
      dot.color = dotColor.withValues(alpha: 0.28 * z);
      canvas.drawCircle(Offset(x, y), 1.8, dot);
    }
  }

  @override
  bool shouldRepaint(GlobePainter old) => old.angle != angle || old.line != line;
}

/// Mini live graph of the last seconds of download speed.
class Sparkline extends StatelessWidget {
  final List<int> values;
  final Color color;
  const Sparkline(this.values, this.color, {super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SparkPainter(values, color), size: Size.infinite);
}

class _SparkPainter extends CustomPainter {
  final List<int> v;
  final Color color;
  _SparkPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size s) {
    if (v.length < 2) return;
    final mx = math.max(v.reduce(math.max), 50 * 1024).toDouble();
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = i / (v.length - 1) * s.width;
      final y = s.height - (v[i] / mx) * (s.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, s.width, s.height)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.v != v || o.color != color;
}

/// Gentle fade + scale entrance.
class Pop extends StatelessWidget {
  final Widget child;
  const Pop({super.key, required this.child});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutBack,
        builder: (_, v, c) => Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.85 + 0.15 * v, child: c),
        ),
        child: child,
      );
}

/// The connect orb: ripples while connecting, a calm breathing glow when connected.
class PowerButton extends StatefulWidget {
  final bool on;
  final bool loading;
  final VoidCallback onTap;
  const PowerButton({super.key, required this.on, required this.loading, required this.onTap});
  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  bool get _active => widget.on || widget.loading;

  @override
  void initState() {
    super.initState();
    if (_active) _c.repeat();
  }

  @override
  void didUpdateWidget(PowerButton old) {
    super.didUpdateWidget(old);
    if (_active && !_c.isAnimating) {
      _c.repeat();
    } else if (!_active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.on ? Pal.green : (widget.loading ? Pal.orange : Pal.accent);
    final dark = Pal.dark;
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          final breathe = widget.on ? 1 + 0.018 * math.sin(t * 2 * math.pi) : 1.0;
          return Transform.scale(
            scale: breathe,
            child: SizedBox(
              width: 260,
              height: 260,
              child: Stack(alignment: Alignment.center, children: [
                if (_active)
                  CustomPaint(size: const Size(260, 260), painter: _RipplePainter(t, color, widget.loading)),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: color.withValues(alpha: dark ? 0.35 : 0.30), blurRadius: 60, spreadRadius: 4)],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [
                      color.withValues(alpha: 0.95),
                      color.withValues(alpha: 0.15),
                      color.withValues(alpha: 0.65),
                      color.withValues(alpha: 0.15),
                      color.withValues(alpha: 0.95),
                    ]),
                  ),
                ),
                Container(width: 232, height: 232, decoration: BoxDecoration(shape: BoxShape.circle, color: Pal.bg0)),
                Container(
                  width: 206,
                  height: 206,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? const [Color(0xFF1C2750), Color(0xFF0E1530)]
                          : const [Color(0xFFFFFFFF), Color(0xFFE6ECFC)],
                    ),
                    boxShadow: [BoxShadow(color: Pal.shadow, blurRadius: 24, offset: const Offset(0, 12))],
                  ),
                ),
                if (widget.loading)
                  SizedBox(width: 206, height: 206, child: CircularProgressIndicator(strokeWidth: 3, color: color)),
                CustomPaint(size: const Size(78, 78), painter: PowerPainter(color)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final double t;
  final Color color;
  final bool fast;
  _RipplePainter(this.t, this.color, this.fast);

  @override
  void paint(Canvas canvas, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    for (var k = 0; k < 3; k++) {
      final p = ((t * (fast ? 1.6 : 1.0)) + k / 3) % 1.0;
      final r = 108 + p * 22;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - p) * 0.38),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter o) => o.t != t || o.color != color;
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
