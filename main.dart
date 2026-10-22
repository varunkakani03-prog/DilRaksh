import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'murburn_engine.dart';
import 'udp_receiver.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => DashboardState(),
      child: const HemodynamicTwinApp(),
    ),
  );
}

class HemodynamicTwinApp extends StatelessWidget {
  const HemodynamicTwinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseCRM Pro - Hemodynamic Digital Twin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080B11),
        cardColor: const Color(0xFF111724),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF2D55),
          surface: Color(0xFF111724),
          background: Color(0xFF080B11),
        ),
      ),
      home: const MainLayoutScreen(),
    );
  }
}

/// Represents a single time-sliced sample of the twin state.
class TimeDataPoint {
  final DateTime timestamp;
  final double actualBpm;
  final double predictedBpm;
  final double spo2;

  TimeDataPoint(this.timestamp, this.actualBpm, this.predictedBpm, this.spo2);
}

/// State Manager combining Murburn calculations, UDP receiver, and UI state updates.
class DashboardState extends ChangeNotifier {
  final MurburnEngine engine = MurburnEngine();
  late UdpReceiver _udpReceiver;
  Timer? _timer;

  double _latestActualBpm = 0.0;
  double _latestSpO2 = 0.0;
  DateTime? _lastPacketTime;
  String? _socketError;
  int _selectedNavIndex = 0; // 0=All, 1=Biometrics, 2=Stressors, 3=Waveforms, 4=Demographics, 5=Thermo, 6=UDP
  final List<String> _udpLogs = ['[UDP:4210] Ingestion socket initialized on 0.0.0.0:4210'];

  // Physiological decoupled actual pulse & simulation state
  double _simulatedActualHr = 72.0;
  bool _isManualOverride = false;
  bool _adaptiveTracking = true;
  bool _isAlarmSilenced = false;
  final math.Random _random = math.Random();

  final List<TimeDataPoint> _history = [];
  static const int maxHistorySeconds = 60;

  // Getters
  double get latestActualBpm => _latestActualBpm;
  double get latestSpO2 => _latestSpO2;
  String? get socketError => _socketError;
  List<TimeDataPoint> get history => _history;
  int get selectedNavIndex => _selectedNavIndex;
  List<String> get udpLogs => List.unmodifiable(_udpLogs);

  bool get isOnline {
    if (_lastPacketTime == null) return false;
    return DateTime.now().difference(_lastPacketTime!).inSeconds <= 3;
  }

  // Decoupled Real-Time & Predictive Outputs
  double get currentActualHr => isOnline ? _latestActualBpm : _simulatedActualHr;
  double get currentPredictedHr => engine.getPredictedBpm(DateTime.now(), lookaheadMinutes: 2.5);
  double get hrDiscrepancy => currentActualHr - currentPredictedHr;
  bool get isAlarmActive => hrDiscrepancy.abs() >= 12.0 && !_isAlarmSilenced;
  bool get isAlarmSilenced => _isAlarmSilenced;
  bool get isManualOverride => _isManualOverride;
  bool get adaptiveTracking => _adaptiveTracking;

  DashboardState() {
    _udpReceiver = UdpReceiver(
      port: 4210,
      onDataReceived: (bpm, spo2) {
        _latestActualBpm = bpm;
        _latestSpO2 = spo2;
        _lastPacketTime = DateTime.now();
        _socketError = null;
        _isAlarmSilenced = false;
        _addUdpLog('Broadcast packet received: "$bpm,$spo2"');
        notifyListeners();
      },
      onError: (err) {
        _socketError = err;
        _addUdpLog('Socket Error: $err');
        notifyListeners();
      },
    );
    _udpReceiver.start();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now();
      // Lookahead predicted target (2.5 minutes ahead)
      final predicted = engine.getPredictedBpm(now, lookaheadMinutes: 2.5);

      if (isOnline) {
        // Real-time hardware telemetry active
      } else if (_isManualOverride) {
        // Manual test override active - preserve slider value
      } else if (_adaptiveTracking) {
        // Natural physiological inertia: ~4% progress per second towards predicted target
        const inertiaRate = 0.04;
        _simulatedActualHr += (predicted - _simulatedActualHr) * inertiaRate;
        // Minor physiological HRV micro-fluctuations
        _simulatedActualHr += (_random.nextDouble() - 0.5) * 0.4;
        _simulatedActualHr = _simulatedActualHr.clamp(45.0, engine.maxHrCeiling);
      }

      final actual = isOnline ? _latestActualBpm : _simulatedActualHr;
      final spo2 = isOnline ? _latestSpO2 : (98.2 + (_random.nextDouble() * 0.8));

      _history.add(TimeDataPoint(now, actual, predicted, spo2));
      if (_history.length > maxHistorySeconds) {
        _history.removeAt(0);
      }
      notifyListeners();
    });
  }

  void _addUdpLog(String msg) {
    final timeStr = DateTime.now().toIso8601String().substring(11, 19);
    _udpLogs.add('[$timeStr] $msg');
    if (_udpLogs.length > 20) _udpLogs.removeAt(0);
  }

  void injectMockPacket() {
    final bpm = (70.0 + (DateTime.now().second % 15)).toDouble();
    const spo2 = 98.6;
    _latestActualBpm = bpm;
    _latestSpO2 = spo2;
    _lastPacketTime = DateTime.now();
    _socketError = null;
    _isAlarmSilenced = false;
    _addUdpLog('Simulated hardware packet injected: "$bpm,$spo2"');
    notifyListeners();
  }

  void setNavIndex(int index) {
    _selectedNavIndex = index;
    notifyListeners();
  }

  // Simulation & Mismatch Testing Methods
  void setManualActualHr(double val) {
    _simulatedActualHr = val;
    _isManualOverride = true;
    _adaptiveTracking = false;
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void triggerMismatchBradycardia() {
    _simulatedActualHr = math.max(45.0, currentPredictedHr - 18.0);
    _isManualOverride = true;
    _adaptiveTracking = false;
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void triggerMismatchTachycardia() {
    _simulatedActualHr = math.min(engine.maxHrCeiling, currentPredictedHr + 22.0);
    _isManualOverride = true;
    _adaptiveTracking = false;
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void resumeAdaptiveTracking() {
    _isManualOverride = false;
    _adaptiveTracking = true;
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void toggleAlarmSilence() {
    _isAlarmSilenced = !_isAlarmSilenced;
    notifyListeners();
  }

  // Engine delegations
  double get currentTemp => engine.externalTemp;
  int get userAge => engine.userProfile.age;
  BmiCategory get userBmi => engine.userProfile.bmiCategory;
  KineticIntensity get currentActivity => engine.currentActivity;
  double get baseRestingHr => engine.baseRestingHr;
  double get maxHrCeiling => engine.maxHrCeiling;
  double get bmiOffset => engine.bmiOffset;
  double get bmiSensitivityFactor => engine.bmiSensitivityFactor;
  double get caffeineSpikeAmplitude => engine.caffeineSpikeAmplitude;
  double get heatMultiplier => engine.heatMultiplier;
  bool get isTeenager => engine.userProfile.isTeenager;

  List<StressorStatus> getActiveStressors() => engine.getActiveStressorStatuses(DateTime.now());

  void setAge(int age) {
    engine.setAge(age);
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void setBmiCategory(BmiCategory category) {
    engine.setBmiCategory(category);
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void setPhysicalActivity(KineticIntensity intensity) {
    engine.setPhysicalActivity(intensity);
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void setTemperature(double temp) {
    engine.setExternalTemp(temp);
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void logCaffeine() {
    engine.logCaffeine(1);
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void logMeal(int size) {
    engine.logMeal(size);
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void removeStressor(String id, String type) {
    if (type == 'Meal') {
      engine.removeMeal(id);
    } else if (type == 'Caffeine') {
      engine.removeCaffeine(id);
    } else if (type == 'Activity') {
      engine.removeKinetic(id);
    }
    _isAlarmSilenced = false;
    notifyListeners();
  }

  void resetSimulation() {
    engine.reset();
    _history.clear();
    _latestActualBpm = 0.0;
    _latestSpO2 = 0.0;
    _lastPacketTime = null;
    _selectedNavIndex = 0;
    _simulatedActualHr = 72.0;
    _isManualOverride = false;
    _adaptiveTracking = true;
    _isAlarmSilenced = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _udpReceiver.stop();
    super.dispose();
  }
}

/// Main layout with PulseCRM Pro sidebar navigation and prominent dual output banner.
class MainLayoutScreen extends StatelessWidget {
  const MainLayoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<DashboardState>(context);
    final isWide = MediaQuery.of(context).size.width > 900;

    return Scaffold(
      body: Row(
        children: [
          // Left Sidebar (PulseCRM Pro style)
          if (isWide) _buildPulseSidebar(context, state),
          
          // Main Content Area
          Expanded(
            child: Column(
              children: [
                // Top App Bar
                _buildTopHeader(context, state),

                // Top Tab Pills Bar
                _buildTabPillsBar(context, state),

                // Main Scrollable Dashboard with View Switching
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Connection Ingestion Notification
                        _buildConnectionBanner(state),
                        const SizedBox(height: 14),

                        // CRITICAL ALERT ALARM BANNER (Displays when discrepancy >= 12 BPM)
                        if (state.isAlarmActive) ...[
                          _buildCriticalAlarmBanner(context, state),
                          const SizedBox(height: 18),
                        ],

                        // PROMINENT DUAL OUTPUT HERO BANNER: CURRENT VS PREDICTED
                        _buildDualOutputHeroBanner(context, state),
                        const SizedBox(height: 18),

                        // SIMULATION & ALARM TESTING CONTROLS
                        _buildAlarmSimulationControls(context, state),
                        const SizedBox(height: 18),

                        // Always present Top KPI row
                        _buildKpiMetricsRow(context, state),
                        const SizedBox(height: 22),

                        // Dynamic Section Body based on selectedNavIndex
                        ..._buildSelectedViewSections(context, state),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Critical Alert Alarm Banner displayed when actual physical HR does not match predicted target
  Widget _buildCriticalAlarmBanner(BuildContext context, DashboardState state) {
    final gap = state.hrDiscrepancy;
    final isUnder = gap < 0;
    final assessment = isUnder
        ? 'Autonomic / Chronotropic Incompetence (Under-Responding by ${gap.toStringAsFixed(1)} BPM)'
        : 'Unexplained Tachycardia / Arrhythmic Drift (Over-Responding by +${gap.toStringAsFixed(1)} BPM)';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF2E0911),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF2D55), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF2D55).withOpacity(0.35),
            blurRadius: 20,
            spreadRadius: 1,
          )
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFF2D55).withOpacity(0.2),
            ),
            child: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF2D55), size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF2D55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'CRITICAL MISMATCH ALARM',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.8),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Discrepancy: ${gap >= 0 ? "+" : ""}${gap.toStringAsFixed(1)} BPM',
                      style: const TextStyle(fontFamily: 'Courier', fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFFFF2D55)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.3),
                    children: [
                      const TextSpan(text: 'Physical Pulse ('),
                      TextSpan(
                        text: '${state.currentActualHr.toStringAsFixed(0)} BPM',
                        style: const TextStyle(color: Color(0xFFFF2D55), fontWeight: FontWeight.bold),
                      ),
                      const TextSpan(text: ') does NOT match Predicted Target ('),
                      TextSpan(
                        text: '${state.currentPredictedHr.toStringAsFixed(1)} BPM',
                        style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold),
                      ),
                      const TextSpan(text: ') after 2–3 min lookahead horizon! Clinical Assessment: '),
                      TextSpan(
                        text: assessment,
                        style: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF2D55),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.notifications_off, size: 14),
            label: const Text('Silence Alarm', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
            onPressed: () => state.toggleAlarmSilence(),
          ),
        ],
      ),
    );
  }

  /// Simulation & Alarm Diagnostic Test Panel
  Widget _buildAlarmSimulationControls(BuildContext context, DashboardState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111724),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1B2333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.science, color: Color(0xFF00E5FF), size: 16),
                  SizedBox(width: 8),
                  Text('HEMODYNAMIC DISCREPANCY & ALARM TESTING LAB', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white70)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: state.adaptiveTracking ? const Color(0xFF34C759).withOpacity(0.12) : Colors.orange.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  state.adaptiveTracking ? 'MODE: ADAPTIVE TRACKING (~4%/s inertia)' : 'MODE: MANUAL MISMATCH INJECTION',
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: state.adaptiveTracking ? const Color(0xFF34C759) : Colors.orangeAccent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('MANUAL PHYSICAL HR OVERRIDE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white38)),
                        Text('${state.currentActualHr.toStringAsFixed(0)} BPM', style: const TextStyle(fontFamily: 'Courier', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFFF2D55))),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFFFF2D55),
                        thumbColor: const Color(0xFFFF2D55),
                      ),
                      child: Slider(
                        value: state.currentActualHr.clamp(45.0, 210.0),
                        min: 45.0,
                        max: 210.0,
                        divisions: 165,
                        onChanged: (val) => state.setManualActualHr(val),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 7,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E293B),
                        foregroundColor: const Color(0xFFFF2D55),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.arrow_downward, size: 14),
                      label: const Text('Mismatch: Bradycardia (-18)', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: () => state.triggerMismatchBradycardia(),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E293B),
                        foregroundColor: const Color(0xFFFF2D55),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.arrow_upward, size: 14),
                      label: const Text('Mismatch: Tachycardia (+22)', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: () => state.triggerMismatchTachycardia(),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF).withOpacity(0.15),
                        foregroundColor: const Color(0xFF00E5FF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.autorenew, size: 14),
                      label: const Text('Resume Adaptive Tracking', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      onPressed: () => state.resumeAdaptiveTracking(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Prominent Dual Output Hero Banner: Output 1 (Current) vs Output 2 (Predicted 2–3m Lookahead)
  Widget _buildDualOutputHeroBanner(BuildContext context, DashboardState state) {
    final predicted = state.currentPredictedHr;
    final actual = state.currentActualHr;
    final gap = state.hrDiscrepancy;
    final absGap = gap.abs();
    final isAlarm = absGap >= 12.0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111724),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isAlarm ? const Color(0xFFFF2D55) : const Color(0xFF1E293B),
          width: isAlarm ? 2.0 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: isAlarm ? const Color(0xFFFF2D55).withOpacity(0.25) : Colors.black.withOpacity(0.4),
            blurRadius: isAlarm ? 25 : 20,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        bool isWide = constraints.maxWidth > 700;
        if (!isWide) {
          return Column(
            children: [
              _buildSingleOutputCard(
                badgeLabel: 'OUTPUT 1: CURRENT (ACTUAL SENSOR)',
                value: actual.toStringAsFixed(0),
                unit: 'BPM',
                title: 'Current Physical Heart Rate',
                sub: state.isOnline ? 'MAX30102 Live Telemetry • UDP 4210' : (state.adaptiveTracking ? 'Biological Inertia Tracking • ~4%/s lag' : 'Manual Telemetry Injection'),
                color: const Color(0xFFFF2D55),
              ),
              const SizedBox(height: 12),
              _buildVsCenterTag(gap, absGap),
              const SizedBox(height: 12),
              _buildSingleOutputCard(
                badgeLabel: 'OUTPUT 2: PREDICTED (DIGITAL TWIN - 2.5m LOOKAHEAD)',
                value: predicted.toStringAsFixed(1),
                unit: 'BPM',
                title: 'Predicted Digital Twin Target Rate',
                sub: 'Murburn Model • 2.5m Forward Projection',
                color: const Color(0xFF00E5FF),
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(
              child: _buildSingleOutputCard(
                badgeLabel: 'OUTPUT 1: CURRENT (ACTUAL SENSOR)',
                value: actual.toStringAsFixed(0),
                unit: 'BPM',
                title: 'Current Physical Heart Rate',
                sub: state.isOnline ? 'MAX30102 Live Telemetry • UDP 4210' : (state.adaptiveTracking ? 'Biological Inertia Tracking • ~4%/s lag' : 'Manual Telemetry Injection'),
                color: const Color(0xFFFF2D55),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildVsCenterTag(gap, absGap),
            ),
            Expanded(
              child: _buildSingleOutputCard(
                badgeLabel: 'OUTPUT 2: PREDICTED (DIGITAL TWIN - 2.5m LOOKAHEAD)',
                value: predicted.toStringAsFixed(1),
                unit: 'BPM',
                title: 'Predicted Digital Twin Target Rate',
                sub: 'Murburn Model • 2.5m Forward Projection',
                color: const Color(0xFF00E5FF),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildSingleOutputCard({
    required String badgeLabel,
    required String value,
    required String unit,
    required String title,
    required String sub,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F17),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Text(
              badgeLabel,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: color, letterSpacing: 0.8),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'Courier',
                  color: color,
                  shadows: [Shadow(color: color.withOpacity(0.4), blurRadius: 12)],
                ),
              ),
              const SizedBox(width: 8),
              Text(unit, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.white38)),
            ],
          ),
          const SizedBox(height: 6),
          Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
          Text(sub, style: const TextStyle(fontSize: 10, color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _buildVsCenterTag(double gap, double absGap) {
    Color gapColor;
    String statusLabel;
    if (absGap <= 5.0) {
      gapColor = const Color(0xFF34C759);
      statusLabel = 'HOMEOSTASIS';
    } else if (absGap < 12.0) {
      gapColor = Colors.orangeAccent;
      statusLabel = 'ADAPTIVE LAG';
    } else {
      gapColor = const Color(0xFFFF2D55);
      statusLabel = 'CRITICAL DRIFT';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF151D2C),
            border: Border.all(color: gapColor.withOpacity(0.5)),
          ),
          child: const Center(
            child: Text('VS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.white54)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Δ ${gap >= 0 ? "+" : ""}${gap.toStringAsFixed(1)} BPM',
          style: TextStyle(fontFamily: 'Courier', fontSize: 13, fontWeight: FontWeight.w900, color: gapColor),
        ),
        Container(
          margin: const EdgeInsets.top(4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: gapColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: gapColor.withOpacity(0.4)),
          ),
          child: Text(
            statusLabel,
            style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: gapColor),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSelectedViewSections(BuildContext context, DashboardState state) {
    int idx = state.selectedNavIndex;

    // 0: Overview (Shows all sections in sequence)
    if (idx == 0) {
      return [
        _buildDemographicSection(context, state),
        const SizedBox(height: 22),
        _buildStressorInputsSection(context, state),
        const SizedBox(height: 22),
        _buildWaveformAndMetabolicSection(context, state),
        const SizedBox(height: 22),
        _buildActiveStressorsSection(context, state),
        const SizedBox(height: 22),
        _buildPhysiologicalSpecSection(state),
      ];
    }

    // 1: Biometrics Feed (Dedicated View)
    if (idx == 1) {
      return [
        _buildBiometricsFeedSection(context, state),
        const SizedBox(height: 22),
        _buildWaveformAndMetabolicSection(context, state),
      ];
    }

    // 2: Stressor Inputs (Dedicated View)
    if (idx == 2) {
      return [
        _buildStressorInputsSection(context, state),
        const SizedBox(height: 22),
        _buildActiveStressorsSection(context, state),
      ];
    }

    // 3: Twin Waveforms Analytics (Dedicated View)
    if (idx == 3) {
      return [
        _buildWaveformAndMetabolicSection(context, state),
        const SizedBox(height: 22),
        _buildPhysiologicalSpecSection(state),
      ];
    }

    // 4: Demographic & BMI Calibration (Dedicated View)
    if (idx == 4) {
      return [
        _buildDemographicSection(context, state),
        const SizedBox(height: 22),
        _buildPhysiologicalSpecSection(state),
      ];
    }

    // 5: Thermodynamics & Heat (Dedicated View)
    if (idx == 5) {
      return [
        _buildThermodynamicsSection(context, state),
        const SizedBox(height: 22),
        _buildWaveformAndMetabolicSection(context, state),
      ];
    }

    // 6: UDP Ingestion (Dedicated View)
    if (idx == 6) {
      return [
        _buildUdpConsoleSection(context, state),
      ];
    }

    return [_buildDemographicSection(context, state)];
  }

  Widget _buildPulseSidebar(BuildContext context, DashboardState state) {
    return Container(
      width: 250,
      decoration: const BoxDecoration(
        color: Color(0xFF0C101A),
        border: Border(right: BorderSide(color: Color(0xFF1B2333), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00E5FF).withOpacity(0.4),
                        blurRadius: 12,
                      )
                    ],
                  ),
                  child: const Center(
                    child: Text(
                      'P',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF080B11)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('PulseCRM', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white)),
                        SizedBox(width: 6),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Color(0xFF34C759),
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                          ),
                          child: Text('PRO', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.black)),
                        ),
                      ],
                    ),
                    Text('Digital Twin Cybernetics', style: TextStyle(fontSize: 10, color: Colors.white38)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(color: Color(0xFF1B2333), height: 1),
          const SizedBox(height: 12),

          _buildSidebarCategory('HEMODYNAMICS'),
          _buildSidebarItem(0, Icons.grid_view_rounded, 'Overview Dashboard', state),
          _buildSidebarItem(1, Icons.favorite_rounded, 'Biometrics Feed', state),
          _buildSidebarItem(2, Icons.stream_rounded, 'Stressor Modifiers', state),
          _buildSidebarItem(3, Icons.show_chart_rounded, 'Twin Waveforms', state),

          const SizedBox(height: 14),
          _buildSidebarCategory('TWIN CORE'),
          _buildSidebarItem(4, Icons.tune_rounded, 'Demographic & BMI', state),
          _buildSidebarItem(5, Icons.thermostat_rounded, 'Thermodynamics', state),
          _buildSidebarItem(6, Icons.wifi_tethering_rounded, 'UDP Ingestion', state),

          const Spacer(),
          GestureDetector(
            onTap: () => state.setNavIndex(4),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFF1B2333))),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0xFF00E5FF).withOpacity(0.2),
                    child: Text('${state.userAge}', style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Teenager (${state.userAge}y)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                        Text('BMI: ${state.userBmi.name.toUpperCase()} (+${state.bmiOffset.toInt()})', style: const TextStyle(fontSize: 10, color: Colors.white38)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarCategory(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Text(
        title,
        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Colors.white24),
      ),
    );
  }

  Widget _buildSidebarItem(int index, IconData icon, String title, DashboardState state) {
    bool isSelected = state.selectedNavIndex == index;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF162133) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: isSelected ? Border.all(color: const Color(0xFF00E5FF).withOpacity(0.35)) : null,
      ),
      child: ListTile(
        dense: true,
        leading: Icon(icon, size: 18, color: isSelected ? const Color(0xFF00E5FF) : Colors.white54),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? Colors.white : Colors.white60,
          ),
        ),
        onTap: () => state.setNavIndex(index),
      ),
    );
  }

  Widget _buildTopHeader(BuildContext context, DashboardState state) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0C101A),
        border: Border(bottom: BorderSide(color: Color(0xFF1B2333))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Hemodynamic Digital Twin Dashboard', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              Text('Cybernetic Physiological Modeling, Demographic Scaling & Real-Time Metabolic Prediction', style: TextStyle(fontSize: 10, color: Colors.white38)),
            ],
          ),
          Row(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF9500),
                  side: const BorderSide(color: Color(0xFFFF9500)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reset Twin', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: () => state.resetSimulation(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabPillsBar(BuildContext context, DashboardState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      decoration: const BoxDecoration(
        color: Color(0xFF080B11),
        border: Border(bottom: BorderSide(color: Color(0xFF1B2333))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildTabPill('🌐 Overview', 0, state),
            _buildTabPill('❤️ Biometrics Feed', 1, state),
            _buildTabPill('⚡ Stressor Modifiers', 2, state),
            _buildTabPill('📈 Twin Waveforms', 3, state),
            _buildTabPill('🧬 Demographic & BMI', 4, state),
            _buildTabPill('🔥 Thermodynamics', 5, state),
            _buildTabPill('📡 UDP Ingestion', 6, state),
          ],
        ),
      ),
    );
  }

  Widget _buildTabPill(String title, int index, DashboardState state) {
    bool active = state.selectedNavIndex == index;
    return GestureDetector(
      onTap: () => state.setNavIndex(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF111724) : Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          border: active ? Border.all(color: const Color(0xFF1B2333)) : null,
        ),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.w600,
            color: active ? const Color(0xFF00E5FF) : Colors.white60,
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionBanner(DashboardState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: state.isOnline ? const Color(0xFF34C759).withOpacity(0.1) : Colors.amber.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: state.isOnline ? const Color(0xFF34C759).withOpacity(0.3) : Colors.amber.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: state.isOnline ? const Color(0xFF34C759) : Colors.amber,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                state.isOnline ? 'HARDWARE TELEMETRY ACTIVE (UDP PORT 4210)' : 'STANDALONE DIGITAL TWIN SIMULATION READY',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: state.isOnline ? const Color(0xFF34C759) : Colors.amber),
              ),
            ],
          ),
          Text(state.isOnline ? 'PACKET SYNCED' : 'OFFLINE SIMULATOR ACTIVE', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _buildKpiMetricsRow(BuildContext context, DashboardState state) {
    final predicted = state.currentPredictedHr;
    final actual = state.currentActualHr;
    final errorGap = state.hrDiscrepancy;
    final isOnline = state.isOnline;

    return LayoutBuilder(builder: (context, constraints) {
      int crossAxisCount = constraints.maxWidth > 1100 ? 6 : (constraints.maxWidth > 700 ? 3 : 2);
      return GridView.count(
        crossAxisCount: crossAxisCount,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.7,
        children: [
          _buildKpiCard('1. CURRENT OUTPUT', actual.toStringAsFixed(0), 'BPM', isOnline ? 'Live Sensor' : (state.adaptiveTracking ? 'Simulated Inertia' : 'Manual Override'), const Color(0xFFFF2D55), Icons.favorite),
          _buildKpiCard('2. PREDICTED OUTPUT', predicted.toStringAsFixed(1), 'BPM', '2.5m Lookahead Twin', const Color(0xFF00E5FF), Icons.memory),
          _buildKpiCard('CYBERNETIC GAP', (errorGap >= 0 ? '+${errorGap.toStringAsFixed(1)}' : errorGap.toStringAsFixed(1)), 'ΔBPM', errorGap.abs() <= 5.0 ? 'Homeostasis' : (errorGap.abs() < 12.0 ? 'Adaptive Drift' : 'MISMATCH ALARM'), errorGap.abs() <= 5.0 ? const Color(0xFF34C759) : (errorGap.abs() < 12.0 ? Colors.orangeAccent : const Color(0xFFFF2D55)), Icons.sync_alt),
          _buildKpiCard('BLOOD OXYGEN', (isOnline ? state.latestSpO2 : 98.5).toStringAsFixed(1), '% SPO₂', 'Normoxic Saturation', const Color(0xFF34C759), Icons.air),
          _buildKpiCard('RESTING BASELINE', state.baseRestingHr.toStringAsFixed(1), 'BPM', '${state.userAge}y + ${state.userBmi.name}', const Color(0xFF8E99B0), Icons.person_pin),
          _buildKpiCard('MAX HR CEILING', state.maxHrCeiling.toStringAsFixed(0), 'BPM', '220 - Age Cap', const Color(0xFFFF3B30), Icons.vertical_align_top),
        ],
      );
    });
  }

  Widget _buildKpiCard(String title, String value, String unit, String delta, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111724),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1B2333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white38)),
              Icon(icon, size: 14, color: color.withOpacity(0.8)),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, fontFamily: 'Courier', color: color)),
              const SizedBox(width: 4),
              Text(unit, style: const TextStyle(fontSize: 10, color: Colors.white38, fontWeight: FontWeight.bold)),
            ],
          ),
          Text(delta, style: const TextStyle(fontSize: 9, color: Colors.white38)),
        ],
      ),
    );
  }

  // Section: Biometrics Feed (Dedicated)
  Widget _buildBiometricsFeedSection(BuildContext context, DashboardState state) {
    final actual = state.currentActualHr;
    final sysBp = (110 + (actual - 60) * 0.4).round();
    final diaBp = (72 + (actual - 60) * 0.15).round();
    final cardiacOutput = ((actual * 70.0) / 1000.0).toStringAsFixed(2);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111724),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1B2333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('BIOMETRICS FEED & HEMODYNAMIC TENSION', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.white70)),
              Text('LIVE SENSOR STREAM', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF34C759))),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildBioGaugeBox('CURRENT PULSE RATE', '${actual.toInt()} BPM', 'Photoplethysmography', const Color(0xFFFF2D55)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildBioGaugeBox('ARTERIAL BP', '$sysBp / $diaBp', 'Estimated mmHg', const Color(0xFF00E5FF)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildBioGaugeBox('CARDIAC OUTPUT', '$cardiacOutput L/min', 'Stroke Vol x HR', const Color(0xFF34C759)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBioGaugeBox(String label, String value, String sub, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF080B11),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1B2333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white38)),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontSize: 20, fontFamily: 'Courier', fontWeight: FontWeight.w900, color: color)),
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(fontSize: 9, color: Colors.white38)),
        ],
      ),
    );
  }

  // Section 1: Demographic Section
  Widget _buildDemographicSection(BuildContext context, DashboardState state) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111724),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1B2333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.tune, color: Color(0xFF00E5FF), size: 18),
                  SizedBox(width: 8),
                  Text('SECTION 1: DEMOGRAPHIC & BMI CALIBRATION PROFILE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white70)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
                ),
                child: Text(
                  'ACTIVE: ${state.isTeenager ? "TEENAGER (13-19y)" : (state.userAge < 13 ? "CHILD" : "ADULT")}',
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFF00E5FF)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('AGE (DEMOGRAPHIC THRESHOLD)', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white38)),
                        Text('${state.userAge} YEARS OLD', style: const TextStyle(fontSize: 13, fontFamily: 'Courier', fontWeight: FontWeight.bold, color: Color(0xFF00E5FF))),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFF00E5FF),
                        inactiveTrackColor: const Color(0xFF080B10),
                        thumbColor: const Color(0xFF00E5FF),
                      ),
                      child: Slider(
                        value: state.userAge.toDouble(),
                        min: 6.0,
                        max: 85.0,
                        divisions: 79,
                        label: '${state.userAge} yrs',
                        onChanged: (val) => state.setAge(val.round()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('BMI SCALING (COMPOUNDING CARDIOVASCULAR STRAIN)', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white38)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildBmiButton('Normal (<25)\n+0 BPM | 1.0x', state.userBmi == BmiCategory.normal, () => state.setBmiCategory(BmiCategory.normal)),
                        const SizedBox(width: 8),
                        _buildBmiButton('Overweight (25-30)\n+4 BPM | 1.1x', state.userBmi == BmiCategory.overweight, () => state.setBmiCategory(BmiCategory.overweight)),
                        const SizedBox(width: 8),
                        _buildBmiButton('Obese (>30)\n+8 BPM | 1.2x', state.userBmi == BmiCategory.obese, () => state.setBmiCategory(BmiCategory.obese)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBmiButton(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF00E5FF).withOpacity(0.15) : const Color(0xFF080B10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? const Color(0xFF00E5FF) : const Color(0xFF1B2333), width: selected ? 1.5 : 1),
          ),
          child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: selected ? const Color(0xFF00E5FF) : Colors.white60)),
        ),
      ),
    );
  }

  // Section 2: Four Stressor Inputs with Realistic Images
  Widget _buildStressorInputsSection(BuildContext context, DashboardState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.dashboard_customize, color: Color(0xFF00E5FF), size: 18),
            SizedBox(width: 8),
            Text('SECTION 2: PHYSIOLOGICAL STRESSOR INPUTS (REALISTIC PHOTOMETRIC CARDS)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white70)),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, constraints) {
          int count = constraints.maxWidth > 1050 ? 4 : (constraints.maxWidth > 550 ? 2 : 1);
          return GridView.count(
            crossAxisCount: count,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: 0.85,
            children: [
              _buildStressorCard(
                imagePath: 'assets/physical_activity.jpg',
                title: 'PHYSICAL ACTIVITY',
                badgeText: state.currentActivity == KineticIntensity.resting ? 'Resting' : state.currentActivity.name.toUpperCase(),
                badgeColor: const Color(0xFFFF9500),
                description: 'Kinetic load (+20, +50, +80 BPM) with 10m post-exercise decay.',
                child: Column(
                  children: [
                    Row(
                      children: [
                        _buildSmallBtn('Rest', state.currentActivity == KineticIntensity.resting, () => state.setPhysicalActivity(KineticIntensity.resting)),
                        const SizedBox(width: 4),
                        _buildSmallBtn('+20 Light', state.currentActivity == KineticIntensity.light, () => state.setPhysicalActivity(KineticIntensity.light)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _buildSmallBtn('+50 Mod', state.currentActivity == KineticIntensity.moderate, () => state.setPhysicalActivity(KineticIntensity.moderate)),
                        const SizedBox(width: 4),
                        _buildSmallBtn('+80 Heavy', state.currentActivity == KineticIntensity.heavy, () => state.setPhysicalActivity(KineticIntensity.heavy)),
                      ],
                    ),
                  ],
                ),
              ),
              _buildStressorCard(
                imagePath: 'assets/caffeine.jpg',
                title: 'CAFFEINE INTAKE',
                badgeText: '+${state.caffeineSpikeAmplitude.toInt()} BPM / cup',
                badgeColor: const Color(0xFFE0A96D),
                description: 'Pharmacokinetics: 15-45m peak, exponential decay.',
                child: SizedBox(
                  width: double.infinity,
                  height: 38,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE0A96D), foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    icon: const Icon(Icons.coffee, size: 16),
                    label: Text('Log 1 Cup (+${state.caffeineSpikeAmplitude.toInt()} BPM)', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                    onPressed: () => state.logCaffeine(),
                  ),
                ),
              ),
              _buildStressorCard(
                imagePath: 'assets/meal.jpg',
                title: 'MEAL DIGESTION',
                badgeText: 'Splanchnic Shift',
                badgeColor: const Color(0xFF00E5FF),
                description: 'Light (+4), Medium (+8), Heavy (+14) splanchnic shift.',
                child: Row(
                  children: [
                    _buildSmallBtn('Light (+4)', false, () => state.logMeal(1)),
                    const SizedBox(width: 4),
                    _buildSmallBtn('Med (+8)', false, () => state.logMeal(2)),
                    const SizedBox(width: 4),
                    _buildSmallBtn('Heavy (+14)', false, () => state.logMeal(3)),
                  ],
                ),
              ),
              _buildStressorCard(
                imagePath: 'assets/heat_exposure.jpg',
                title: 'HEAT EXPOSURE',
                badgeText: '${state.currentTemp.toStringAsFixed(1)} °C',
                badgeColor: const Color(0xFFFF2D55),
                description: 'Threshold 24°C: +${state.heatMultiplier} BPM/°C.',
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(activeTrackColor: const Color(0xFFFF2D55), thumbColor: const Color(0xFFFF2D55)),
                  child: Slider(
                    value: state.currentTemp,
                    min: 15.0,
                    max: 42.0,
                    divisions: 54,
                    onChanged: (val) => state.setTemperature(val),
                  ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildStressorCard({required String imagePath, required String title, required String badgeText, required Color badgeColor, required String description, required Widget child}) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(imagePath, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: const Color(0xFF162133), child: const Center(child: Icon(Icons.image, color: Colors.white24, size: 36)))),
                Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xFF111724)]))),
                Positioned(top: 10, right: 10, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(6), border: Border.all(color: badgeColor.withOpacity(0.5))), child: Text(badgeText, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: badgeColor)))),
                Positioned(bottom: 8, left: 14, child: Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description, style: const TextStyle(fontSize: 9, color: Colors.white38, height: 1.2), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 10),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallBtn(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(color: active ? const Color(0xFF00E5FF).withOpacity(0.2) : const Color(0xFF080B10), borderRadius: BorderRadius.circular(6), border: Border.all(color: active ? const Color(0xFF00E5FF) : const Color(0xFF1B2333))),
          child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: active ? const Color(0xFF00E5FF) : Colors.white70)),
        ),
      ),
    );
  }

  // Section 3: Waveform & Metabolic Telemetry
  Widget _buildWaveformAndMetabolicSection(BuildContext context, DashboardState state) {
    final now = DateTime.now();
    final predicted = state.currentPredictedHr;
    final actual = state.currentActualHr;
    final actualVO2 = state.engine.estimateVO2(actual);
    final predictedVO2 = state.engine.estimateVO2(predicted);
    final actualHeat = state.engine.estimateHeatGeneration(actualVO2);
    final predictedHeat = state.engine.estimateHeatGeneration(predictedVO2);
    final splanchnicAlloc = state.engine.estimateSplanchnicAllocation(now);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: Container(
            height: 290,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('HEMODYNAMIC DRIFT WAVEFORM', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white70)),
                    Row(
                      children: [
                        _buildLegendPill('Current (Physical)', const Color(0xFFFF2D55)),
                        const SizedBox(width: 12),
                        _buildLegendPill('Predicted (Twin)', const Color(0xFF00E5FF)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: true),
                      titlesData: const FlTitlesData(topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false))),
                      borderData: FlBorderData(show: false),
                      minY: 40,
                      maxY: 200,
                      lineBarsData: [
                        LineChartBarData(spots: _generateSpots(state.history, isActual: true), isCurved: true, color: const Color(0xFFFF2D55), barWidth: 2.5, dotData: const FlDotData(show: false)),
                        LineChartBarData(spots: _generateSpots(state.history, isActual: false), isCurved: true, color: const Color(0xFF00E5FF), barWidth: 2.5, dotData: const FlDotData(show: false)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 4,
          child: Container(
            height: 290,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('METABOLIC ESTIMATES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white70)),
                const SizedBox(height: 14),
                _buildMetabolicRow('VO₂ Ventilation', actualVO2.toStringAsFixed(0), predictedVO2.toStringAsFixed(0), 'mL/min'),
                const Divider(color: Color(0xFF182030), height: 16),
                _buildMetabolicRow('Heat Generation', actualHeat.toStringAsFixed(1), predictedHeat.toStringAsFixed(1), 'kcal/hr'),
                const Divider(color: Color(0xFF182030), height: 16),
                _buildMetabolicRow('Splanchnic Flow', '--', '${splanchnicAlloc.toStringAsFixed(1)}%', 'allocation'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<FlSpot> _generateSpots(List<TimeDataPoint> history, {required bool isActual}) {
    List<FlSpot> spots = [];
    int start = 60 - history.length;
    for (int i = 0; i < history.length; i++) {
      double val = isActual ? history[i].actualBpm : history[i].predictedBpm;
      spots.add(FlSpot((start + i).toDouble(), val > 0 ? val : 0.0));
    }
    while (spots.length < 60) {
      double idx = (59 - spots.length).toDouble();
      spots.insert(0, FlSpot(idx, isActual ? 0.0 : 72.0));
    }
    return spots;
  }

  Widget _buildLegendPill(String title, Color color) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(fontSize: 9, color: Colors.white60, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildMetabolicRow(String title, String actual, String predicted, String unit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white60)),
            Text(unit, style: const TextStyle(fontSize: 9, color: Colors.white30)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Current: $actual', style: const TextStyle(fontSize: 11, fontFamily: 'Courier', color: Color(0xFFFF2D55), fontWeight: FontWeight.bold)),
            Text('Predicted: $predicted', style: const TextStyle(fontSize: 13, fontFamily: 'Courier', color: Color(0xFF00E5FF), fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  // Section 4: Thermodynamics (Dedicated)
  Widget _buildThermodynamicsSection(BuildContext context, DashboardState state) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('THERMODYNAMICS & HEAT DISSIPATION', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white70)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildBioGaugeBox('AMBIENT HEAT', '${state.currentTemp.toStringAsFixed(1)} °C', 'Cutaneous Vasodilation', const Color(0xFFFF2D55)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildBioGaugeBox('HEAT MULTIPLIER', '+${state.heatMultiplier} BPM/°C', state.userAge >= 65 ? 'Compounded Vasodilation' : 'Standard Cutaneous', const Color(0xFF00E5FF)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Section 5: UDP Ingestion Console (Dedicated)
  Widget _buildUdpConsoleSection(BuildContext context, DashboardState state) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('UDP BROADCAST INGESTION TERMINAL (PORT 4210)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white70)),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black),
                icon: const Icon(Icons.bolt, size: 14),
                label: const Text('Inject Test Packet', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                onPressed: () => state.injectMockPacket(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            height: 180,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF05070B), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF141C2B))),
            child: ListView.builder(
              itemCount: state.udpLogs.length,
              itemBuilder: (context, idx) => Text(
                state.udpLogs[idx],
                style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xFF38BDF8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Section 6: Active Stressors Queue
  Widget _buildActiveStressorsSection(BuildContext context, DashboardState state) {
    final stressors = state.getActiveStressors();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.history, color: Color(0xFFFF9500), size: 18),
                  SizedBox(width: 8),
                  Text('ACTIVE STRESSORS TELEMETRY QUEUE & RECOVERY TIMERS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white70)),
                ],
              ),
              Text('${stressors.length} ACTIVE EVENT(S)', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white38)),
            ],
          ),
          const SizedBox(height: 14),
          if (stressors.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(color: const Color(0xFF080B10), borderRadius: BorderRadius.circular(8)),
              child: const Center(
                child: Text('No active stressors in physiological queue. Body resting at demographic baseline.', style: TextStyle(fontSize: 11, color: Colors.white38)),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: stressors.length,
              itemBuilder: (context, index) {
                final item = stressors[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: const Color(0xFF080B10), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF1B2333))),
                  child: Row(
                    children: [
                      Icon(item.type == 'Caffeine' ? Icons.coffee : (item.type == 'Activity' ? Icons.directions_run : Icons.restaurant), color: const Color(0xFF00E5FF), size: 18),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.description, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                            Text('Phase: ${item.trend}  |  ${item.remainingMinutes.toStringAsFixed(0)}m remaining', style: const TextStyle(fontSize: 9, color: Colors.white38)),
                          ],
                        ),
                      ),
                      Text('+${item.bpmContribution.toStringAsFixed(1)} BPM', style: const TextStyle(fontSize: 13, fontFamily: 'Courier', fontWeight: FontWeight.bold, color: Color(0xFF00E5FF))),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                        onPressed: () => state.removeStressor(item.id, item.type),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  // Section 7: Theoretical Specs Panel
  Widget _buildPhysiologicalSpecSection(DashboardState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF111724), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1B2333))),
      child: const ExpansionTile(
        title: Text('PHYSIOLOGICAL THRESHOLDS & CLINICAL CALIBRATION STANDARDS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF00E5FF), letterSpacing: 0.8)),
        tilePadding: EdgeInsets.zero,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '• Child (<13y): Resting 80 BPM, Caffeine +15 BPM, Heat +2.0 BPM/°C\n'
              '• Teenager (13–19y, default 18y): Resting 72 BPM, Caffeine +10 BPM, Heat +1.5 BPM/°C\n'
              '• Adult (20–64y): Resting 68 BPM, Caffeine +8 BPM, Heat +1.5 BPM/°C, k=0.003/min\n'
              '• Older Adult (65+y): Resting 70 BPM, Caffeine +6 BPM, Heat +2.0 BPM/°C, 6–8h clearance\n'
              '• BMI Offsets: Normal (+0 BPM, 1.0x), Overweight (+4 BPM, 1.1x), Obese (+8 BPM, 1.2x)\n'
              '• Absolute HR Ceiling: HR_max = (220 - Age) strictly caps cardiac frequency.',
              style: TextStyle(fontSize: 10, color: Colors.white54, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
