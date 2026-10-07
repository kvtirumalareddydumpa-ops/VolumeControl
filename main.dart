// Volume Dock — an ad-free floating volume control for Android.
//
// This file has two entry points:
//   main()        -> the normal app: grant permission, start/stop the dock.
//   overlayMain() -> runs in a separate Flutter engine inside the overlay
//                    window that floats above every other app.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:volume_controller/volume_controller.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Design tokens
// ═══════════════════════════════════════════════════════════════════════════

class Dock {
  Dock._();

  // Overlay window sizes, in dp. The bubble and the panel share one width so
  // the window only ever grows vertically and never slides off the screen
  // edge it is snapped to.
  static const int windowWidth = 68;
  static const int bubbleHeight = 68;
  static const int panelHeight = 380;

  static const Color background = Color(0xFF101319);
  static const Color surface = Color(0xFF1A1D25);
  static const Color overlaySurface = Color(0xF21A1D25); // ~95% opaque
  static const Color raised = Color(0xFF242833);
  static const Color track = Color(0xFF2A2F3B);
  static const Color stroke = Color(0x1AFFFFFF);
  static const Color textMuted = Color(0xFF9097A6);
  static const Color accent = Color(0xFF9AA8FF); // periwinkle fill
  static const Color onAccent = Color(0xFF101319);
  static const Color ok = Color(0xFF7FD8A6);
  static const Color warn = Color(0xFFFFC27A);

  static IconData iconFor(double v) {
    if (v <= 0.001) return Icons.volume_off_rounded;
    if (v < 0.34) return Icons.volume_mute_rounded;
    if (v < 0.67) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  static String percent(double v) => '${(v * 100).round()}%';
}

// ═══════════════════════════════════════════════════════════════════════════
//  Entry points
// ═══════════════════════════════════════════════════════════════════════════

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VolumeDockApp());
}

/// Called by flutter_overlay_window. The name must stay exactly `overlayMain`
/// and the pragma stops the release build from tree-shaking it away.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: VolumeOverlay(),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Shared: volume syncing + the brightness-style slider
// ═══════════════════════════════════════════════════════════════════════════

/// Keeps a widget in sync with the system media volume, and pushes changes
/// back without flooding the audio service while the user drags.
class VolumeSync {
  VolumeSync({required this.onSystemChange});

  final ValueChanged<double> onSystemChange;
  bool _userDragging = false;
  double _lastSent = -1;

  void start() {
    // Don't pop the system volume dialog every time we change the level.
    VolumeController.instance.showSystemUI = false;
    VolumeController.instance.addListener(
      (v) {
        // Ignore echoes from the system while the finger is on the slider,
        // otherwise the bar would jitter between finger and system steps.
        if (!_userDragging) onSystemChange(v);
      },
      fetchInitialVolume: true,
    );
  }

  Future<double> read() => VolumeController.instance.getVolume();

  void beginDrag() => _userDragging = true;
  void endDrag() => _userDragging = false;

  void set(double value) {
    final v = value.clamp(0.0, 1.0);
    if (v == _lastSent) return;
    final atEdge = v == 0.0 || v == 1.0;
    if (!atEdge && (v - _lastSent).abs() < 0.01) return;
    _lastSent = v;
    VolumeController.instance.setVolume(v);
  }

  void dispose() => VolumeController.instance.removeListener();
}

/// A thick vertical pill that fills from the bottom, like the Android 12
/// brightness bar. Drag anywhere on it, or tap to jump to a level.
class VolumeSlider extends StatefulWidget {
  const VolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.width = 64,
    this.radius = 24,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;
  final double width;
  final double radius;

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  bool _dragging = false;
  int _lastTick = -1;

  void _update(Offset local, double height) {
    final v = (1 - local.dy / height).clamp(0.0, 1.0);
    // A light haptic tick every 10%, so you can feel the level change.
    final tick = (v * 10).floor();
    if (tick != _lastTick) {
      _lastTick = tick;
      HapticFeedback.selectionClick();
    }
    widget.onChanged(v);
  }

  void _start() {
    setState(() => _dragging = true);
    widget.onChangeStart?.call();
  }

  void _end() {
    setState(() => _dragging = false);
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) {
            _start();
            _update(d.localPosition, h);
          },
          onVerticalDragUpdate: (d) => _update(d.localPosition, h),
          onVerticalDragEnd: (_) => _end(),
          onVerticalDragCancel: _end,
          onTapDown: (d) {
            widget.onChangeStart?.call();
            _update(d.localPosition, h);
          },
          onTapUp: (_) => widget.onChangeEnd?.call(),
          child: AnimatedScale(
            scale: _dragging ? 1.03 : 1.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: widget.value),
              // Follow the finger instantly; glide when the system changes it.
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => _paint(v, h),
            ),
          ),
        );
      },
    );
  }

  Widget _paint(double v, double h) {
    final fillHeight = h * v;
    final iconOnFill = fillHeight > 44;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.width,
        height: h,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Dock.track)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: fillHeight,
              child: const ColoredBox(color: Dock.accent),
            ),
            // Grip line at the top edge of the fill — shows where to grab.
            if (fillHeight > 64)
              Positioned(
                left: 0,
                right: 0,
                bottom: math.max(fillHeight - 14, 0),
                child: Center(
                  child: Container(
                    width: widget.width * 0.36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0x66101319),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Icon(
                Dock.iconFor(v),
                size: 24,
                color: iconOnFill ? Dock.onAccent : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small press-to-shrink wrapper for buttons.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PART 1 — Main app: permission + start/stop the dock
// ═══════════════════════════════════════════════════════════════════════════

class VolumeDockApp extends StatelessWidget {
  const VolumeDockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Volume Dock',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Dock.accent,
        scaffoldBackgroundColor: Dock.background,
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
  late final VolumeSync _sync = VolumeSync(
    onSystemChange: (v) {
      if (mounted) setState(() => _volume = v);
    },
  );

  double _volume = 0.5;
  bool _hasPermission = false;
  bool _dockRunning = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync.start();
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync.dispose();
    super.dispose();
  }

  // Coming back from the Settings screen? Re-check the permission.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    final running = await FlutterOverlayWindow.isActive();
    if (!mounted) return;
    setState(() {
      _hasPermission = granted;
      _dockRunning = running;
    });
  }

  Future<void> _grantPermission() async {
    await FlutterOverlayWindow.requestPermission();
    await _refreshStatus();
  }

  Future<void> _toggleDock() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_dockRunning) {
        await FlutterOverlayWindow.closeOverlay();
      } else {
        await FlutterOverlayWindow.showOverlay(
          width: Dock.windowWidth,
          height: Dock.bubbleHeight,
          alignment: OverlayAlignment.centerRight,
          positionGravity: PositionGravity.auto, // snap to nearest edge
          enableDrag: true,
          flag: OverlayFlag.defaultFlag, // touches outside pass through
          visibility: NotificationVisibility.visibilityPublic,
          overlayTitle: 'Volume Dock',
          overlayContent: 'Floating volume control is on',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      await _refreshStatus();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
          children: [
            Text(
              'Volume Dock',
              style: text.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A floating volume slider for when the buttons stop working.',
              style: text.bodyMedium?.copyWith(color: Dock.textMuted),
            ),
            const SizedBox(height: 24),

            // Live preview: the same slider the dock uses.
            _Section(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  SizedBox(
                    height: 220,
                    child: VolumeSlider(
                      value: _volume,
                      width: 72,
                      radius: 26,
                      onChangeStart: _sync.beginDrag,
                      onChangeEnd: _sync.endDrag,
                      onChanged: (v) {
                        setState(() => _volume = v);
                        _sync.set(v);
                      },
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          Dock.percent(_volume),
                          style: text.displaySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          'Media volume',
                          style: text.titleSmall
                              ?.copyWith(color: Dock.textMuted),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Drag the bar to try it. The floating dock works '
                          'the same way, over any app.',
                          style: text.bodySmall?.copyWith(
                            color: Dock.textMuted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            _Section(
              child: Column(
                children: [
                  _StatusRow(
                    label: 'Display over other apps',
                    ok: _hasPermission,
                    okText: 'Allowed',
                    badText: 'Not allowed',
                  ),
                  const Divider(height: 1, color: Dock.stroke),
                  _StatusRow(
                    label: 'Floating dock',
                    ok: _dockRunning,
                    okText: 'On',
                    badText: 'Off',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            if (!_hasPermission)
              _BigButton(
                icon: Icons.layers_rounded,
                label: 'Allow display over other apps',
                onPressed: _grantPermission,
              )
            else
              _BigButton(
                icon: _dockRunning
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline_rounded,
                label: _dockRunning ? 'Turn off dock' : 'Turn on dock',
                tonal: _dockRunning,
                busy: _busy,
                onPressed: _toggleDock,
              ),
            const SizedBox(height: 24),

            _Section(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Using the dock', style: text.titleSmall),
                  const SizedBox(height: 10),
                  const _Tip('Drag the bubble to move it. Let go and it '
                      'snaps to the nearest edge.'),
                  const _Tip('Tap the bubble to open the slider. It '
                      'tucks itself away after 4 seconds.'),
                  const _Tip('The power icon in the panel turns the '
                      'dock off.'),
                  const SizedBox(height: 14),
                  Text('Keep it alive on realme UI', style: text.titleSmall),
                  const SizedBox(height: 10),
                  const _Tip('Settings › Battery › App battery management › '
                      'Volume Dock: allow background activity and auto launch.'),
                  const _Tip('In Recents, lock the Volume Dock card so '
                      'cleaning memory doesn\'t close it.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Dock.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Dock.stroke),
      ),
      child: child,
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.ok,
    required this.okText,
    required this.badText,
  });

  final String label;
  final bool ok;
  final String okText;
  final String badText;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Dock.ok : Dock.warn;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            ok ? okText : badText,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tonal = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool tonal;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(58),
      backgroundColor: tonal ? Dock.raised : Dock.accent,
      foregroundColor: tonal ? Colors.white : Dock.onAccent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
    return FilledButton.icon(
      style: style,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
      label: Text(label),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: 10),
            child: SizedBox(
              width: 5,
              height: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Dock.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Dock.textMuted, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PART 2 — Overlay UI: draggable bubble ⇄ expanded vertical slider panel
// ═══════════════════════════════════════════════════════════════════════════

class VolumeOverlay extends StatefulWidget {
  const VolumeOverlay({super.key});

  @override
  State<VolumeOverlay> createState() => _VolumeOverlayState();
}

class _VolumeOverlayState extends State<VolumeOverlay> {
  static const _autoMinimizeAfter = Duration(seconds: 4);
  static const _step = 1 / 15; // Android's default media volume step count

  late final VolumeSync _sync = VolumeSync(
    onSystemChange: (v) {
      if (mounted) setState(() => _volume = v);
    },
  );

  double _volume = 0.5;
  bool _expanded = false;
  bool _resizing = false;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _sync.start();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _sync.dispose();
    super.dispose();
  }

  // Grow the window first, then show the panel inside it. Dragging the
  // window is switched off while open so the slider gets the vertical drags.
  Future<void> _expand() async {
    if (_expanded || _resizing) return;
    _resizing = true;
    HapticFeedback.lightImpact();
    try {
      await FlutterOverlayWindow.resizeOverlay(
        Dock.windowWidth,
        Dock.panelHeight,
        false,
      );
      final v = await _sync.read();
      if (!mounted) return;
      setState(() {
        _volume = v;
        _expanded = true;
      });
      _armIdleTimer();
    } finally {
      _resizing = false;
    }
  }

  // Animate the panel out first, then shrink the window back to the bubble.
  Future<void> _minimize() async {
    if (!_expanded || _resizing) return;
    _resizing = true;
    _idleTimer?.cancel();
    try {
      setState(() => _expanded = false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await FlutterOverlayWindow.resizeOverlay(
        Dock.windowWidth,
        Dock.bubbleHeight,
        true,
      );
    } finally {
      _resizing = false;
    }
  }

  Future<void> _close() async {
    _idleTimer?.cancel();
    HapticFeedback.mediumImpact();
    await FlutterOverlayWindow.closeOverlay();
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_autoMinimizeAfter, _minimize);
  }

  void _onSliderStart() {
    _idleTimer?.cancel();
    _sync.beginDrag();
  }

  void _onSliderChanged(double v) {
    setState(() => _volume = v);
    _sync.set(v);
  }

  void _onSliderEnd() {
    _sync.endDrag();
    _armIdleTimer();
  }

  void _nudge(int direction) {
    final stepped = ((_volume / _step).round() + direction) * _step;
    final v = stepped.clamp(0.0, 1.0);
    HapticFeedback.selectionClick();
    setState(() => _volume = v);
    _sync.set(v);
    _armIdleTimer();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Only show the panel once the window has actually grown, so it
          // never renders squashed during the resize.
          final showPanel =
              _expanded && constraints.maxHeight >= Dock.panelHeight * 0.85;

          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1).animate(anim),
                child: child,
              ),
            ),
            child: showPanel
                ? SizedBox.expand(
                    key: const ValueKey('panel'),
                    child: _DockPanel(
                      volume: _volume,
                      onChangeStart: _onSliderStart,
                      onChanged: _onSliderChanged,
                      onChangeEnd: _onSliderEnd,
                      onUp: () => _nudge(1),
                      onDown: () => _nudge(-1),
                      onMinimize: _minimize,
                      onClose: _close,
                    ),
                  )
                : Center(
                    key: const ValueKey('bubble'),
                    child: _DockBubble(volume: _volume, onTap: _expand),
                  ),
          );
        },
      ),
    );
  }
}

/// Collapsed state: a compact bubble with a ring showing the current level.
/// The window itself is dragged natively by flutter_overlay_window.
class _DockBubble extends StatelessWidget {
  const _DockBubble({required this.volume, required this.onTap});

  final double volume;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Dock.overlaySurface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Dock.stroke),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: volume),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => CircularProgressIndicator(
                  value: v,
                  strokeWidth: 3.5,
                  strokeCap: StrokeCap.round,
                  backgroundColor: Dock.track,
                  valueColor: const AlwaysStoppedAnimation(Dock.accent),
                ),
              ),
            ),
            Icon(Dock.iconFor(volume), size: 18, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

/// Expanded state: level readout, step buttons and the big slider.
class _DockPanel extends StatelessWidget {
  const _DockPanel({
    required this.volume,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onUp,
    required this.onDown,
    required this.onMinimize,
    required this.onClose,
  });

  final double volume;
  final VoidCallback onChangeStart;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      decoration: BoxDecoration(
        color: Dock.overlaySurface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Dock.stroke),
      ),
      child: Column(
        children: [
          Text(
            Dock.percent(volume),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          _StepButton(icon: Icons.add_rounded, onTap: onUp),
          const SizedBox(height: 8),
          Expanded(
            child: VolumeSlider(
              value: volume,
              width: 48,
              radius: 18,
              onChangeStart: onChangeStart,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
          const SizedBox(height: 8),
          _StepButton(icon: Icons.remove_rounded, onTap: onDown),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _TinyIcon(icon: Icons.power_settings_new_rounded, onTap: onClose),
              _TinyIcon(icon: Icons.keyboard_arrow_down_rounded, onTap: onMinimize),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 34,
        decoration: BoxDecoration(
          color: Dock.raised,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }
}

class _TinyIcon extends StatelessWidget {
  const _TinyIcon({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      child: SizedBox(
        width: 24,
        height: 28,
        child: Icon(icon, size: 18, color: Dock.textMuted),
      ),
    );
  }
}
