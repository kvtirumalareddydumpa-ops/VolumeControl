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
import 'package:flutter/physics.dart';
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
  String? _error;

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
    // Read the pixel ratio before any await, while context is safe to use.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // The overlay reads side + height from here and positions itself.
    _offset = _offset.clamp(-_maxOffset, _maxOffset);
    await _saveSettings();
    // showOverlay takes raw pixels on this plugin version, so convert from dp.
    // (The overlay double-checks its real size on start and corrects it.)
    await FlutterOverlayWindow.showOverlay(
      width: (Dock.handleWidth * dpr).round(),
      height: (Dock.handleHeight * dpr).round(),
      alignment: _side == DockSide.right
          ? OverlayAlignment.centerRight
          : OverlayAlignment.centerLeft,
      // Pinned flush to the edge: no free dragging, no half-hidden snapping.
      enableDrag: false,
      positionGravity: PositionGravity.none,
      flag: OverlayFlag.defaultFlag, // touches outside pass through
      visibility: NotificationVisibility.visibilityPublic,
      overlayTitle: 'Volume Dock',
      overlayContent: 'Swipe the edge handle to change volume',
    );
  }

  Future<void> _withBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the handle: $e');
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SelectableText(
                  _error!,
                  style: const TextStyle(color: Dock.warn, fontSize: 12),
                ),
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
                      'open the panel. It follows your finger.'),
                  const _Tip('Tap anywhere outside the panel, or swipe it '
                      'back toward the edge, to close it.'),
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
//
// How it works:
//  • Closed: the overlay window is just the handle (small, at the edge).
//  • The moment you touch to open, the window becomes full-screen and
//    transparent. Everything after that — the panel following your finger,
//    the spring, the dimmed backdrop — is pure Flutter animation, so it's
//    smooth. Tapping the backdrop closes it.
//  • When the panel is fully closed, the window shrinks back to the handle.

class VolumeOverlay extends StatefulWidget {
  const VolumeOverlay({super.key});

  @override
  State<VolumeOverlay> createState() => _VolumeOverlayState();
}

class _VolumeOverlayState extends State<VolumeOverlay>
    with SingleTickerProviderStateMixin {
  static const _autoCloseAfter = Duration(seconds: 6);

  // Fast, near-critically damped spring: quick to settle, no wobble.
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 0.92,
  );

  final MixerController _mixer = MixerController();

  /// 0 = panel fully hidden, 1 = fully open. Drives every animation.
  late final AnimationController _reveal = AnimationController(vsync: this);

  DockSide _side = DockSide.right;
  double _offset = 0; // handle height, dp from screen centre

  /// The window's real size in dp, as Flutter sees it.
  Size _window = Size.zero;

  /// dp → unit the plugin's resize/move expects (1.0 = dp, ~2.75 = pixels).
  double _unit = 1.0;

  bool _ready = false; // calibration finished
  bool _handleHidden = true; // hidden while the window changes shape
  bool _pulse = true; // glow on start so the handle is easy to spot
  bool _exiting = false;
  Future<void>? _entering;
  Timer? _idleTimer;

  bool get _onRight => _side == DockSide.right;
  bool get _isFull => _window.width >= Dock.panelWidth + 24;

  @override
  void initState() {
    super.initState();
    FlutterVolumeController.updateShowSystemUI(false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _setUp());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _reveal.dispose();
    _mixer.dispose();
    super.dispose();
  }

  // ── Start-up ─────────────────────────────────────────────────────────────

  Future<void> _setUp() async {
    final s = await DockSettings.load();
    _side = s.side;
    _offset = s.offset;
    await _calibrate();
    await _resizeTo(Dock.handleWidth, Dock.handleHeight);
    await _moveToOffset();
    if (!mounted) return;
    setState(() {
      _ready = true;
      _handleHidden = false;
    });
    Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _pulse = false);
    });
  }

  /// Resize to a probe height that differs from the current one, wait for
  /// Flutter to see the new size, and derive the plugin's unit from it.
  Future<void> _calibrate() async {
    const probe = 200;
    final before = _window.height;
    try {
      await FlutterOverlayWindow.resizeOverlay(Dock.handleWidth, probe, false);
      final changed = await _waitFor(
        () => (_window.height - before).abs() > 2,
        timeout: const Duration(milliseconds: 1500),
      );
      if (changed && _window.height > 1) {
        _unit = probe / _window.height; // ≈1 for dp, ≈pixel ratio for px
        if ((_unit - 1).abs() < 0.08) _unit = 1;
      }
    } catch (_) {
      // Keep 1.0 and carry on; better a handle than none.
    }
  }

  Future<bool> _waitFor(
    bool Function() test, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (test()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return test();
  }

  Future<void> _resizeTo(int widthDp, int heightDp) =>
      FlutterOverlayWindow.resizeOverlay(
        (widthDp * _unit).round(),
        (heightDp * _unit).round(),
        false,
      );

  Future<void> _moveToOffset() async {
    if (_offset.abs() <= 1) return;
    try {
      await FlutterOverlayWindow.moveOverlay(
        OverlayPosition(0, _offset * _unit),
      );
    } catch (_) {}
  }

  Size _screenDp() {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isNotEmpty) {
      final d = displays.first;
      return d.size / d.devicePixelRatio;
    }
    return const Size(400, 900);
  }

  // ── Window shape changes ─────────────────────────────────────────────────

  /// Make the window full-screen (only once, even if called repeatedly).
  Future<void> _enterFull() => _entering ??= _doEnterFull();

  Future<void> _doEnterFull() async {
    if (_isFull) return;
    _mixer.refresh(); // don't wait for it; never block the animation
    _mixer.startPolling();
    try {
      if (_offset.abs() > 1) {
        await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, 0));
      }
      final screen = _screenDp();
      await _resizeTo(screen.width.ceil(), screen.height.ceil());
      if (!await _waitFor(() => _isFull)) {
        // Fallback: ask for "match parent" if the explicit size didn't take.
        await FlutterOverlayWindow.resizeOverlay(-1, -1, false);
        await _waitFor(() => _isFull);
      }
    } catch (_) {}
  }

  Future<void> _exitFull() async {
    if (_exiting) return;
    _exiting = true;
    _idleTimer?.cancel();
    _mixer.stopPolling();
    setState(() => _handleHidden = true);
    try {
      await _resizeTo(Dock.handleWidth, Dock.handleHeight);
      await _moveToOffset();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    } catch (_) {}
    _entering = null;
    _exiting = false;
    if (mounted) setState(() => _handleHidden = false);
  }

  // ── Open / close ─────────────────────────────────────────────────────────

  Future<void> _settle(double target, {double velocity = 0}) async {
    if (target == 1) {
      await _enterFull();
      if (!_isFull) return _exitFull(); // couldn't grow; stay closed
    }
    _idleTimer?.cancel();
    await _reveal.animateWith(
      SpringSimulation(_spring, _reveal.value, target, velocity),
    );
    if (!mounted) return;
    if (target == 0) {
      await _exitFull();
    } else {
      _armIdleTimer();
    }
  }

  void _open() {
    if (!_ready || _exiting) return;
    HapticFeedback.lightImpact();
    _settle(1);
  }

  void _close() => _settle(0);

  Future<void> _turnOff() async {
    _idleTimer?.cancel();
    HapticFeedback.mediumImpact();
    await FlutterOverlayWindow.closeOverlay();
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_autoCloseAfter, _close);
  }

  void _onSliderActivity(bool active) {
    if (active) {
      _idleTimer?.cancel();
    } else {
      _armIdleTimer();
    }
  }

  // ── Swipe: the panel tracks the finger, then springs open or shut ────────

  bool _swiping = false;
  bool _crossedHalf = false;

  void _onSwipeStart(DragStartDetails d) {
    if (!_ready || _exiting) return;
    _swiping = true;
    _crossedHalf = _reveal.value > 0.5;
    _reveal.stop();
    _idleTimer?.cancel();
    _enterFull();
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    if (!_swiping) return;
    final dx = d.delta.dx;
    // Ignore the one-off jump when the window changes shape mid-swipe.
    if (dx.abs() > 80) return;
    final inward = _onRight ? -dx : dx;
    _reveal.value =
        (_reveal.value + inward / Dock.panelWidth).clamp(0.0, 1.0);
    final half = _reveal.value > 0.5;
    if (half != _crossedHalf) {
      _crossedHalf = half;
      HapticFeedback.selectionClick();
    }
  }

  void _onSwipeEnd(DragEndDetails? d) {
    if (!_swiping) return;
    _swiping = false;
    final vx = d?.primaryVelocity ?? 0;
    final inwardV = _onRight ? -vx : vx; // dp per second, + means opening
    final double target;
    if (inwardV > 350) {
      target = 1;
    } else if (inwardV < -350) {
      target = 0;
    } else {
      target = _reveal.value > 0.4 ? 1 : 0;
    }
    _settle(target, velocity: inwardV / Dock.panelWidth);
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _window = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onSwipeStart,
            onHorizontalDragUpdate: _onSwipeUpdate,
            onHorizontalDragEnd: _onSwipeEnd,
            onHorizontalDragCancel: () => _onSwipeEnd(null),
            child: _isFull ? _buildFull(constraints.biggest) : _buildHandleOnly(),
          );
        },
      ),
    );
  }

  Widget _handle() => AnimatedOpacity(
        opacity: _handleHidden ? 0 : 1,
        duration: const Duration(milliseconds: 140),
        child: _EdgeHandle(side: _side, highlight: _pulse, onTap: _open),
      );

  Widget _buildHandleOnly() => Align(
        alignment: _onRight ? Alignment.centerRight : Alignment.centerLeft,
        child: _handle(),
      );

  Widget _buildFull(Size size) {
    final h = size.height;
    final handleTop = h / 2 + _offset - Dock.handleHeight / 2;
    final maxTop = math.max(32.0, h - Dock.panelHeight - 32);
    final panelTop =
        (h / 2 + _offset - Dock.panelHeight / 2).clamp(32.0, maxTop);
    final travel = Dock.panelWidth + 24.0;

    return Stack(
      children: [
        // Dimmed backdrop: tap anywhere outside the panel to close.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: AnimatedBuilder(
              animation: _reveal,
              builder: (context, _) => ColoredBox(
                color: Color.fromRGBO(0, 0, 0, 0.32 * _reveal.value),
              ),
            ),
          ),
        ),
        // The handle stays put underneath, fading as the panel comes in.
        Positioned(
          top: handleTop,
          right: _onRight ? 0 : null,
          left: _onRight ? null : 0,
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, child) => Opacity(
              opacity: (1 - _reveal.value * 3).clamp(0.0, 1.0),
              child: child,
            ),
            child: _handle(),
          ),
        ),
        // The panel slides in from the edge, tracking the finger.
        Positioned(
          top: panelTop,
          right: _onRight ? 10 : null,
          left: _onRight ? null : 10,
          width: Dock.panelWidth.toDouble(),
          height: Dock.panelHeight.toDouble(),
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, child) {
              final v = _reveal.value;
              return Transform.translate(
                offset: Offset((_onRight ? 1 : -1) * (1 - v) * travel, 0),
                child: child,
              );
            },
            child: RepaintBoundary(
              child: _SoundPanel(
                mixer: _mixer,
                onActivity: _onSliderActivity,
                onTurnOff: _turnOff,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The thin translucent bar on the screen edge.
class _EdgeHandle extends StatefulWidget {
  const _EdgeHandle({
    required this.side,
    required this.onTap,
    this.highlight = false,
  });

  final DockSide side;
  final VoidCallback onTap;
  final bool highlight;

  @override
  State<_EdgeHandle> createState() => _EdgeHandleState();
}

class _EdgeHandleState extends State<_EdgeHandle> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final onRight = widget.side == DockSide.right;
    final lit = _pressed || widget.highlight;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTap: () {
        _set(false);
        widget.onTap();
      },
      child: SizedBox(
        width: Dock.handleWidth.toDouble(),
        height: Dock.handleHeight.toDouble(),
        child: Align(
          alignment: onRight ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: lit ? 8 : 6,
              height: lit ? 108 : 96,
              decoration: BoxDecoration(
                color: lit ? Dock.accent : const Color(0xB3FFFFFF),
                borderRadius: BorderRadius.circular(4),
                // A dark outline keeps it visible on white screens too.
                border: Border.all(color: const Color(0x59000000), width: 0.8),
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
    required this.onActivity,
    required this.onTurnOff,
  });

  final MixerController mixer;
  final ValueChanged<bool> onActivity;
  final VoidCallback onTurnOff;

  @override
  Widget build(BuildContext context) {
    return Container(
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
