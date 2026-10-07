// Volume Dock 2 — an ad-free edge volume panel for Android.
//
// A thin translucent handle sits on the edge of the screen. Swipe inward
// (or tap it) and a translucent panel slides out with four sliders:
// media, ringtone, notification and alarm.
//
// This file has two entry points:
//   main()        -> the normal app: permissions, handle position, on/off.
//   overlayMain() -> runs in a separate Flutter engine inside the overlay
//                    window that floats above every other app.

import 'dart:async';
import 'dart:math' as math;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Design tokens
// ═══════════════════════════════════════════════════════════════════════════

class Dock {
  Dock._();

  // Overlay window sizes, in dp.
  static const int handleWidth = 22;
  static const int handleHeight = 120;
  static const int panelWidth = 320;
  static const int panelHeight = 380;

  static const Color background = Color(0xFF101319);
  static const Color surface = Color(0xFF1A1D25);
  static const Color glass = Color(0xD9171A21); // translucent panel, ~85%
  static const Color raised = Color(0xFF242833);
  static const Color track = Color(0x33FFFFFF);
  static const Color stroke = Color(0x1FFFFFFF);
  static const Color textMuted = Color(0xFF9AA1B0);
  static const Color accent = Color(0xFF9AA8FF); // periwinkle fill
  static const Color onAccent = Color(0xFF101319);
  static const Color ok = Color(0xFF7FD8A6);
  static const Color warn = Color(0xFFFFC27A);

  static String percent(double v) => '${(v * 100).round()}%';
}

enum DockSide { left, right }

/// The four Android volume streams shown in the panel.
enum SoundChannel {
  media('Media', AudioStream.music),
  ring('Ringtone', AudioStream.ring),
  notification('Notification', AudioStream.notification),
  alarm('Alarm', AudioStream.alarm);

  const SoundChannel(this.label, this.stream);

  final String label;
  final AudioStream stream;

  IconData iconFor(double v) {
    final silent = v <= 0.001;
    return switch (this) {
      SoundChannel.media =>
        silent ? Icons.volume_off_rounded : Icons.music_note_rounded,
      // Ringtone at zero puts the phone on vibrate.
      SoundChannel.ring =>
        silent ? Icons.vibration_rounded : Icons.ring_volume_rounded,
      SoundChannel.notification => silent
          ? Icons.notifications_off_rounded
          : Icons.notifications_rounded,
      SoundChannel.alarm =>
        silent ? Icons.alarm_off_rounded : Icons.alarm_rounded,
    };
  }
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
//  Shared: settings, volume state, slider widgets
// ═══════════════════════════════════════════════════════════════════════════

/// Handle placement, saved on the phone so both the app and the overlay
/// (which runs in its own engine) read the same values.
class DockSettings {
  const DockSettings({required this.side, required this.offset});

  final DockSide side;

  /// Vertical offset of the handle from the middle of the screen, in dp.
  /// Negative is higher, positive is lower.
  final double offset;

  static const _sideKey = 'dock_side';
  static const _offsetKey = 'dock_offset';

  static Future<DockSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // pick up changes written by the other engine
    final side = prefs.getString(_sideKey) == 'left'
        ? DockSide.left
        : DockSide.right;
    return DockSettings(side: side, offset: prefs.getDouble(_offsetKey) ?? 0);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sideKey, side.name);
    await prefs.setDouble(_offsetKey, offset);
  }
}

/// Holds the level of all four streams, keeps them fresh while visible,
/// and writes changes back without flooding the audio service.
class MixerController extends ChangeNotifier {
  final Map<SoundChannel, double> _values = {
    for (final c in SoundChannel.values) c: 0.5,
  };
  final Map<SoundChannel, double> _lastSent = {};
  final Set<SoundChannel> _blocked = {};
  SoundChannel? _dragging;
  Timer? _poll;
  Timer? _noticeTimer;
  bool _refreshing = false;
  bool _disposed = false;

  /// A short message shown in the panel, e.g. when DND blocks a change.
  String? notice;

  double valueOf(SoundChannel c) => _values[c] ?? 0;

  /// Reads every stream from the system. The stream under the finger is
  /// skipped so the slider doesn't jump back while you drag.
  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    var changed = false;
    try {
      for (final c in SoundChannel.values) {
        if (c == _dragging) continue;
        try {
          final v = await FlutterVolumeController.getVolume(stream: c.stream);
          if (v != null && (v - valueOf(c)).abs() > 0.001) {
            _values[c] = v;
            changed = true;
          }
        } catch (_) {
          // Ignore a single failed read; the next poll will try again.
        }
      }
    } finally {
      _refreshing = false;
    }
    if (changed && !_disposed) notifyListeners();
  }

  /// Polling keeps all four bars in sync with changes made elsewhere,
  /// e.g. ringtone and notification volume being linked on some phones.
  void startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => refresh(),
    );
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void beginDrag(SoundChannel c) => _dragging = c;

  void endDrag(SoundChannel c) {
    if (_dragging == c) _dragging = null;
    if (_blocked.remove(c)) refresh();
  }

  void set(SoundChannel c, double value) {
    if (_blocked.contains(c)) return;
    final v = value.clamp(0.0, 1.0);
    _values[c] = v;
    notifyListeners();

    final last = _lastSent[c] ?? -1;
    if (v == last) return;
    final atEdge = v == 0.0 || v == 1.0;
    if (!atEdge && (v - last).abs() < 0.01) return;
    _lastSent[c] = v;
    _apply(c, v);
  }

  Future<void> _apply(SoundChannel c, double v) async {
    try {
      await FlutterVolumeController.setVolume(v, stream: c.stream);
    } catch (_) {
      // Android refuses ringtone/notification changes in silent or DND mode
      // unless the app has "Do Not Disturb access".
      _blocked.add(c);
      _lastSent.remove(c);
      _flash('${c.label} is locked by Do Not Disturb. '
          'Allow access in the Volume Dock app.');
      final dragging = _dragging;
      _dragging = null;
      await refresh();
      _dragging = dragging;
    }
  }

  void _flash(String message) {
    notice = message;
    notifyListeners();
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      notice = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _noticeTimer?.cancel();
    super.dispose();
  }
}

/// A thick vertical pill that fills from the bottom, like the Android 12
/// brightness bar. Drag anywhere on it, or tap to jump to a level.
class VolumeSlider extends StatefulWidget {
  const VolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.iconFor,
    this.onChangeStart,
    this.onChangeEnd,
    this.width = 52,
    this.radius = 18,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final IconData Function(double value) iconFor;
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
            scale: _dragging ? 1.04 : 1.0,
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
                bottom: math.max(fillHeight - 14, 0.0),
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
                widget.iconFor(v),
                size: 22,
                color: iconOnFill ? Dock.onAccent : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Four sliders side by side: media, ringtone, notification, alarm.
class MixerRow extends StatelessWidget {
  const MixerRow({
    super.key,
    required this.mixer,
    this.sliderWidth = 50,
    this.onActivity,
  });

  final MixerController mixer;
  final double sliderWidth;

  /// true when a finger goes down on a slider, false when it lifts.
  final ValueChanged<bool>? onActivity;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mixer,
      builder: (context, _) => Row(
        children: [
          for (final (i, c) in SoundChannel.values.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _channel(c)),
          ],
        ],
      ),
    );
  }

  Widget _channel(SoundChannel c) {
    final v = mixer.valueOf(c);
    return Column(
      children: [
        Text(
          Dock.percent(v),
          style: const TextStyle(
            color: Dock.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: VolumeSlider(
            value: v,
            width: sliderWidth,
            iconFor: c.iconFor,
            onChangeStart: () {
              mixer.beginDrag(c);
              onActivity?.call(true);
            },
            onChanged: (x) => mixer.set(c, x),
            onChangeEnd: () {
              mixer.endDrag(c);
              onActivity?.call(false);
            },
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 16,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              c.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
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
        scale: _down ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PART 1 — Main app: permissions, handle placement, on/off
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
  final MixerController _mixer = MixerController();

  DockSide _side = DockSide.right;
  double _offset = 0;
  double _maxOffset = 200;
  bool _hasPermission = false;
  bool _dockRunning = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterVolumeController.updateShowSystemUI(false);
    _mixer.refresh();
    _mixer.startPolling();
    _loadSettings();
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mixer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatus(); // e.g. coming back from the permission screen
      _mixer.refresh();
      _mixer.startPolling();
    } else if (state == AppLifecycleState.paused) {
      _mixer.stopPolling();
    }
  }

  Future<void> _loadSettings() async {
    final s = await DockSettings.load();
    if (!mounted) return;
    setState(() {
      _side = s.side;
      _offset = s.offset;
    });
  }

  Future<void> _saveSettings() =>
      DockSettings(side: _side, offset: _offset).save();

  Future<void> _refreshStatus() async {
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    final running = await FlutterOverlayWindow.isActive();
    if (!mounted) return;
    setState(() {
      _hasPermission = granted;
      _dockRunning = running;
    });
  }

  Future<void> _grantOverlay() async {
    await FlutterOverlayWindow.requestPermission();
    await _refreshStatus();
  }

  Future<void> _openDndAccess() async {
    const intent = AndroidIntent(
      action: 'android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS',
    );
    await intent.launch();
  }

  Future<void> _showDock() async {
    await _saveSettings(); // the overlay reads the side from here
    await FlutterOverlayWindow.showOverlay(
      width: Dock.handleWidth,
      height: Dock.handleHeight,
      alignment: _side == DockSide.right
          ? OverlayAlignment.centerRight
          : OverlayAlignment.centerLeft,
      // Pinned flush to the edge: no free dragging, no half-hidden snapping.
      enableDrag: false,
      positionGravity: PositionGravity.none,
      startPosition: OverlayPosition(0, _offset.clamp(-_maxOffset, _maxOffset)),
      flag: OverlayFlag.defaultFlag, // touches outside pass through
      visibility: NotificationVisibility.visibilityPublic,
      overlayTitle: 'Volume Dock',
      overlayContent: 'Swipe the edge handle to change volume',
    );
  }

  Future<void> _withBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      await _refreshStatus();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleDock() => _withBusy(() async {
        if (_dockRunning) {
          await FlutterOverlayWindow.closeOverlay();
        } else {
          await _showDock();
        }
      });

  /// Placement changes apply by restarting the handle in its new spot.
  Future<void> _applyPlacement() async {
    await _saveSettings();
    if (!_dockRunning) return;
    await _withBusy(() async {
      await FlutterOverlayWindow.closeOverlay();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _showDock();
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Keep the open panel fully on screen wherever the handle sits.
    _maxOffset = math.max(
      0.0,
      MediaQuery.sizeOf(context).height / 2 - Dock.panelHeight / 2 - 24,
    );

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
              'Swipe the handle on the edge of your screen to open these '
              'sliders over any app.',
              style: text.bodyMedium?.copyWith(color: Dock.textMuted),
            ),
            const SizedBox(height: 24),

            // Live preview: the same sliders the panel uses.
            _Section(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              child: Column(
                children: [
                  SizedBox(
                    height: 280,
                    child: MixerRow(mixer: _mixer, sliderWidth: 54),
                  ),
                  ListenableBuilder(
                    listenable: _mixer,
                    builder: (context, _) => _mixer.notice == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _mixer.notice!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Dock.warn,
                                fontSize: 12,
                              ),
                            ),
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
                    label: 'Edge handle',
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
                onPressed: _grantOverlay,
              )
            else
              _BigButton(
                icon: _dockRunning
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline_rounded,
                label: _dockRunning ? 'Turn off edge handle' : 'Turn on edge handle',
                tonal: _dockRunning,
                busy: _busy,
                onPressed: _toggleDock,
              ),
            const SizedBox(height: 20),

            // Handle placement
            _Section(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Handle position', style: text.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'realme\'s Smart Sidebar uses the left edge, so the right '
                    'edge avoids clashing with it.',
                    style: text.bodySmall?.copyWith(color: Dock.textMuted),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<DockSide>(
                      segments: const [
                        ButtonSegment(
                          value: DockSide.left,
                          label: Text('Left edge'),
                          icon: Icon(Icons.align_horizontal_left_rounded),
                        ),
                        ButtonSegment(
                          value: DockSide.right,
                          label: Text('Right edge'),
                          icon: Icon(Icons.align_horizontal_right_rounded),
                        ),
                      ],
                      selected: {_side},
                      onSelectionChanged: (s) {
                        setState(() => _side = s.first);
                        _applyPlacement();
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('Higher',
                          style: text.bodySmall?.copyWith(color: Dock.textMuted)),
                      Expanded(
                        child: Slider(
                          min: -_maxOffset,
                          max: _maxOffset,
                          value: _offset.clamp(-_maxOffset, _maxOffset),
                          onChanged: (v) => setState(() => _offset = v),
                          onChangeEnd: (_) => _applyPlacement(),
                        ),
                      ),
                      Text('Lower',
                          style: text.bodySmall?.copyWith(color: Dock.textMuted)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Do Not Disturb access
            _Section(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ringtone in silent mode', style: text.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Android blocks apps from changing ringtone and '
                    'notification volume while the phone is silent or on Do '
                    'Not Disturb, unless you allow it.',
                    style: text.bodySmall
                        ?.copyWith(color: Dock.textMuted, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _openDndAccess,
                    icon: const Icon(Icons.do_not_disturb_on_outlined),
                    label: const Text('Allow Do Not Disturb access'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            _Section(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Using the handle', style: text.titleSmall),
                  const SizedBox(height: 10),
                  const _Tip('Swipe inward from the handle, or tap it, to '
                      'open the panel.'),
                  const _Tip('Swipe the panel back toward the edge to close '
                      'it. It also closes by itself after 5 seconds.'),
                  const _Tip('The power icon in the panel turns the handle '
                      'off.'),
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
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(58),
        backgroundColor: tonal ? Dock.raised : Dock.accent,
        foregroundColor: tonal ? Colors.white : Dock.onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
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
//  PART 2 — Overlay UI: edge handle ⇄ translucent sound panel
// ═══════════════════════════════════════════════════════════════════════════

class VolumeOverlay extends StatefulWidget {
  const VolumeOverlay({super.key});

  @override
  State<VolumeOverlay> createState() => _VolumeOverlayState();
}

class _VolumeOverlayState extends State<VolumeOverlay> {
  static const _autoHideAfter = Duration(seconds: 5);

  final MixerController _mixer = MixerController();
  DockSide _side = DockSide.right;
  bool _expanded = false;
  bool _resizing = false;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    FlutterVolumeController.updateShowSystemUI(false);
    _loadSide();
  }

  Future<void> _loadSide() async {
    final s = await DockSettings.load();
    if (mounted) setState(() => _side = s.side);
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _mixer.dispose();
    super.dispose();
  }

  // Read the levels, grow the window inward from the edge, then show the
  // panel inside it.
  Future<void> _open() async {
    if (_expanded || _resizing) return;
    _resizing = true;
    HapticFeedback.lightImpact();
    try {
      await _mixer.refresh();
      await FlutterOverlayWindow.resizeOverlay(
        Dock.panelWidth,
        Dock.panelHeight,
        false,
      );
      if (!mounted) return;
      setState(() => _expanded = true);
      _mixer.startPolling();
      _armIdleTimer();
    } finally {
      _resizing = false;
    }
  }

  // Slide the panel out first, then shrink the window back to the handle.
  Future<void> _hide() async {
    if (!_expanded || _resizing) return;
    _resizing = true;
    _idleTimer?.cancel();
    _mixer.stopPolling();
    try {
      setState(() => _expanded = false);
      await Future<void>.delayed(const Duration(milliseconds: 240));
      await FlutterOverlayWindow.resizeOverlay(
        Dock.handleWidth,
        Dock.handleHeight,
        false,
      );
    } finally {
      _resizing = false;
    }
  }

  Future<void> _turnOff() async {
    _idleTimer?.cancel();
    HapticFeedback.mediumImpact();
    await FlutterOverlayWindow.closeOverlay();
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_autoHideAfter, _hide);
  }

  void _onActivity(bool active) {
    if (active) {
      _idleTimer?.cancel();
    } else {
      _armIdleTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final edge = _side == DockSide.right
        ? Alignment.centerRight
        : Alignment.centerLeft;

    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Only show the panel once the window has actually grown, so it
          // never renders squashed during the resize.
          final showPanel = _expanded &&
              constraints.maxWidth >= Dock.panelWidth * 0.85 &&
              constraints.maxHeight >= Dock.panelHeight * 0.85;

          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(
              alignment: edge,
              children: [...previous, if (current != null) current],
            ),
            transitionBuilder: (child, anim) {
              final dx = _side == DockSide.right ? 0.2 : -0.2;
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(dx, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              );
            },
            child: showPanel
                ? SizedBox.expand(
                    key: const ValueKey('panel'),
                    child: _SoundPanel(
                      mixer: _mixer,
                      side: _side,
                      onActivity: _onActivity,
                      onHide: _hide,
                      onTurnOff: _turnOff,
                    ),
                  )
                : Align(
                    key: const ValueKey('handle'),
                    alignment: edge,
                    child: _EdgeHandle(side: _side, onOpen: _open),
                  ),
          );
        },
      ),
    );
  }
}

/// The thin translucent bar on the screen edge. Swipe inward or tap.
class _EdgeHandle extends StatefulWidget {
  const _EdgeHandle({required this.side, required this.onOpen});

  final DockSide side;
  final VoidCallback onOpen;

  @override
  State<_EdgeHandle> createState() => _EdgeHandleState();
}

class _EdgeHandleState extends State<_EdgeHandle> {
  double _dx = 0;
  bool _active = false;
  bool _fired = false;

  void _setActive(bool v) {
    if (_active != v) setState(() => _active = v);
  }

  @override
  Widget build(BuildContext context) {
    final onRight = widget.side == DockSide.right;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setActive(true),
      onTapCancel: () => _setActive(false),
      onTap: () {
        _setActive(false);
        widget.onOpen();
      },
      onHorizontalDragStart: (_) {
        _dx = 0;
        _fired = false;
        _setActive(true);
      },
      onHorizontalDragUpdate: (d) {
        _dx += d.delta.dx;
        final inward = onRight ? -_dx : _dx;
        if (!_fired && inward > 10) {
          _fired = true;
          widget.onOpen();
        }
      },
      onHorizontalDragEnd: (_) => _setActive(false),
      onHorizontalDragCancel: () => _setActive(false),
      child: SizedBox(
        width: Dock.handleWidth.toDouble(),
        height: Dock.handleHeight.toDouble(),
        child: Align(
          alignment: onRight ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              width: _active ? 7 : 5,
              height: _active ? 104 : 92,
              decoration: BoxDecoration(
                color: _active ? const Color(0xD9FFFFFF) : const Color(0x8CFFFFFF),
                borderRadius: BorderRadius.circular(4),
                // A faint dark outline keeps it visible on white screens.
                border: Border.all(color: const Color(0x33000000), width: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The translucent panel with the four sliders.
class _SoundPanel extends StatelessWidget {
  const _SoundPanel({
    required this.mixer,
    required this.side,
    required this.onActivity,
    required this.onHide,
    required this.onTurnOff,
  });

  final MixerController mixer;
  final DockSide side;
  final ValueChanged<bool> onActivity;
  final VoidCallback onHide;
  final VoidCallback onTurnOff;

  @override
  Widget build(BuildContext context) {
    final onRight = side == DockSide.right;
    return GestureDetector(
      // Fling the panel back toward its edge to close it.
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if ((onRight && v > 250) || (!onRight && v < -250)) onHide();
      },
      child: Container(
        margin: EdgeInsets.only(left: onRight ? 0 : 8, right: onRight ? 8 : 0),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: Dock.glass,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Dock.stroke),
        ),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  'Sound',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                _TinyIcon(
                  icon: Icons.power_settings_new_rounded,
                  onTap: onTurnOff,
                ),
                const SizedBox(width: 4),
                _TinyIcon(
                  icon: onRight
                      ? Icons.chevron_right_rounded
                      : Icons.chevron_left_rounded,
                  onTap: onHide,
                ),
              ],
            ),
            ListenableBuilder(
              listenable: mixer,
              builder: (context, _) => mixer.notice == null
                  ? const SizedBox(height: 10)
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        mixer.notice!,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Dock.warn, fontSize: 11),
                      ),
                    ),
            ),
            Expanded(
              child: MixerRow(
                mixer: mixer,
                sliderWidth: 50,
                onActivity: onActivity,
              ),
            ),
          ],
        ),
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
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          color: Color(0x14FFFFFF),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }
}
