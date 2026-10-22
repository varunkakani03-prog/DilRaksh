import 'dart:math' as math;

/// BMI categories for demographic calibration.
enum BmiCategory {
  normal,
  overweight,
  obese,
}

/// Demographic profile data class.
class UserProfile {
  final int age;
  final BmiCategory bmiCategory;

  const UserProfile({
    this.age = 18, // Default age 18 (teenager demographic threshold)
    this.bmiCategory = BmiCategory.normal,
  });

  UserProfile copyWith({
    int? age,
    BmiCategory? bmiCategory,
  }) {
    return UserProfile(
      age: age ?? this.age,
      bmiCategory: bmiCategory ?? this.bmiCategory,
    );
  }

  String get bmiLabel {
    switch (bmiCategory) {
      case BmiCategory.normal:
        return 'Normal';
      case BmiCategory.overweight:
        return 'Overweight';
      case BmiCategory.obese:
        return 'Obese';
    }
  }

  bool get isChild => age < 13;
  bool get isTeenager => age >= 13 && age <= 19;
  bool get isAdult => age >= 20 && age <= 64;
  bool get isOlderAdult => age >= 65;

  /// Absolute HR Ceiling strictly follows (220 - Age) formula.
  double get maxHrCeiling => (220 - age).toDouble();
}

/// Kinetic load (physical activity) intensity tiers.
enum KineticIntensity {
  resting,  // 0 BPM
  light,    // +20 BPM (Walking, casual movement)
  moderate, // +50 BPM (Jogging, carrying objects)
  heavy,    // +80 BPM (Sprinting, weightlifting)
}

/// Represents a logged physical activity event.
class KineticLog {
  final String id;
  final DateTime timestamp;
  final KineticIntensity intensity;

  KineticLog({
    required this.id,
    required this.timestamp,
    required this.intensity,
  });

  double get peakBpm {
    switch (intensity) {
      case KineticIntensity.resting:
        return 0.0;
      case KineticIntensity.light:
        return 20.0;
      case KineticIntensity.moderate:
        return 50.0;
      case KineticIntensity.heavy:
        return 80.0;
    }
  }

  String get label {
    switch (intensity) {
      case KineticIntensity.resting:
        return 'Resting';
      case KineticIntensity.light:
        return 'Light Activity';
      case KineticIntensity.moderate:
        return 'Moderate Exercise';
      case KineticIntensity.heavy:
        return 'Heavy Exercise';
    }
  }
}

/// Represents a logged meal stressor event.
class MealLog {
  final String id;
  final DateTime timestamp;
  final int size; // 1 = Light, 2 = Medium, 3 = Heavy

  MealLog({
    required this.id,
    required this.timestamp,
    required this.size,
  });

  String get label {
    switch (size) {
      case 1:
        return 'Light Meal';
      case 2:
        return 'Medium Meal';
      case 3:
        return 'Heavy Meal';
      default:
        return 'Meal';
    }
  }
}

/// Represents a logged caffeine intake event.
class CaffeineLog {
  final String id;
  final DateTime timestamp;
  final int cups;

  CaffeineLog({
    required this.id,
    required this.timestamp,
    required this.cups,
  });
}

/// Details of an active stressor for user interface displays.
class StressorStatus {
  final String id;
  final String type; // "Meal", "Caffeine", or "Activity"
  final String description;
  final double bpmContribution;
  final double elapsedMinutes;
  final double remainingMinutes;
  final String trend; // "Rising", "Decaying", "Active", "Resolving", "Post-Exercise Recovery"

  StressorStatus({
    required this.id,
    required this.type,
    required this.description,
    required this.bpmContribution,
    required this.elapsedMinutes,
    required this.remainingMinutes,
    required this.trend,
  });
}

/// The Murburn Mathematical Engine calculates the predicted heart rate
/// with demographic calibration, BMI scaling, kinetic load, and thermoregulation.
class MurburnEngine {
  // User profile with defaults (age 18, normal BMI)
  UserProfile _userProfile = const UserProfile(
    age: 18,
    bmiCategory: BmiCategory.normal,
  );

  // Environmental temperature in Celsius (baseline threshold is 24.0°C)
  double _externalTemp = 24.0;

  // Active stressor log stores
  final List<MealLog> _meals = [];
  final List<CaffeineLog> _caffeineList = [];
  final List<KineticLog> _kineticLogs = [];
  KineticIntensity _currentActivity = KineticIntensity.resting;

  // Getters
  UserProfile get userProfile => _userProfile;
  double get externalTemp => _externalTemp;
  KineticIntensity get currentActivity => _currentActivity;
  List<MealLog> get meals => List.unmodifiable(_meals);
  List<CaffeineLog> get caffeineList => List.unmodifiable(_caffeineList);
  List<KineticLog> get kineticLogs => List.unmodifiable(_kineticLogs);

  // --- Dynamic Demographic Baseline Calculations ---

  /// Dynamic resting baseline based on age tiers:
  /// - Child (<13): 80 BPM (calibrated within 75–115 BPM range)
  /// - Teenager (13–19, default 18): 72 BPM (calibrated within 60–100 BPM range)
  /// - Adult (20–64): 68 BPM (calibrated within 60–100 BPM range)
  /// - Older Adult (65+): 70 BPM (calibrated within 60–90 BPM range)
  double getAgeBaselineHr(int age) {
    if (age < 13) return 80.0;
    if (age <= 19) return 72.0;
    if (age <= 64) return 68.0;
    return 70.0;
  }

  /// BMI offsets to baseline HR:
  /// - Normal (<25): +0 BPM
  /// - Overweight (25–29.9): +4 BPM (+3 to +5)
  /// - Obese (>30): +8 BPM (+7 to +10)
  double get bmiOffset {
    switch (_userProfile.bmiCategory) {
      case BmiCategory.normal:
        return 0.0;
      case BmiCategory.overweight:
        return 4.0;
      case BmiCategory.obese:
        return 8.0;
    }
  }

  /// Dynamic resting baseline = Age Baseline + BMI offset.
  double get baseRestingHr => getAgeBaselineHr(_userProfile.age) + bmiOffset;

  /// Absolute Maximum Heart Rate Ceiling strictly bounded by (220 - Age).
  double get maxHrCeiling => (220 - _userProfile.age).toDouble();

  /// Stressor sensitivity multiplier based on BMI:
  /// - Normal (<25): 1.0x (Baseline)
  /// - Overweight (25–29.9): 1.1x (+10%)
  /// - Obese (>30): 1.2x (+20%)
  double get bmiSensitivityFactor {
    switch (_userProfile.bmiCategory) {
      case BmiCategory.normal:
        return 1.0;
      case BmiCategory.overweight:
        return 1.1;
      case BmiCategory.obese:
        return 1.2;
    }
  }

  /// Demographic caffeine spike amplitude:
  /// - Child (~6y): +15 BPM
  /// - Teenager (13–19y): +10 BPM
  /// - Adult (20–64y): +8 BPM
  /// - Older Adult (65+y): +6 BPM
  double get caffeineSpikeAmplitude {
    if (_userProfile.isChild) return 15.0;
    if (_userProfile.isTeenager) return 10.0;
    if (_userProfile.isAdult) return 8.0;
    return 6.0;
  }

  /// Heat multiplier per 1°C above 24°C threshold:
  /// - Adults & Teenagers: +1.5 BPM/°C
  /// - Children & Older Adults: +2.0 BPM/°C (less efficient peripheral vasodilation & sweating)
  double get heatMultiplier {
    if (_userProfile.isChild || _userProfile.isOlderAdult) {
      return 2.0;
    }
    return 1.5;
  }

  /// Caffeine exponential clearance rate (per minute):
  /// - Average Adults: k = 0.003 / min (half-life ~4h)
  /// - Teenagers: k = 0.0035 / min (metabolize slightly faster)
  /// - Older Adults: k = 0.0018 / min (prolonged clearance stretching over 6–8h)
  /// - Children: k = 0.0040 / min
  double get caffeineDecayK {
    if (_userProfile.isOlderAdult) return 0.0018;
    if (_userProfile.isTeenager) return 0.0035;
    if (_userProfile.isChild) return 0.0040;
    return 0.0030;
  }

  /// Estimated subject weight in kg calibrated by BMI category.
  double get estimatedWeightKg {
    switch (_userProfile.bmiCategory) {
      case BmiCategory.normal:
        return 70.0;
      case BmiCategory.overweight:
        return 82.0;
      case BmiCategory.obese:
        return 98.0;
    }
  }

  // --- Profile & Stressor Modifiers ---

  void setUserProfile(UserProfile profile) {
    _userProfile = profile;
  }

  void setAge(int age) {
    _userProfile = _userProfile.copyWith(age: age);
  }

  void setBmiCategory(BmiCategory category) {
    _userProfile = _userProfile.copyWith(bmiCategory: category);
  }

  void setExternalTemp(double temp) {
    _externalTemp = temp;
  }

  /// Logs or updates the kinetic load (physical activity).
  void setPhysicalActivity(KineticIntensity intensity, {DateTime? timestamp}) {
    _currentActivity = intensity;
    if (intensity != KineticIntensity.resting) {
      final id = 'kinetic_${DateTime.now().microsecondsSinceEpoch}';
      _kineticLogs.add(KineticLog(
        id: id,
        timestamp: timestamp ?? DateTime.now(),
        intensity: intensity,
      ));
    }
  }

  void logMeal(int size, {DateTime? timestamp}) {
    if (size < 1 || size > 3) return;
    final id = 'meal_${DateTime.now().microsecondsSinceEpoch}';
    _meals.add(MealLog(id: id, timestamp: timestamp ?? DateTime.now(), size: size));
  }

  void logCaffeine(int cups, {DateTime? timestamp}) {
    if (cups < 1) return;
    final id = 'caff_${DateTime.now().microsecondsSinceEpoch}';
    _caffeineList.add(CaffeineLog(id: id, timestamp: timestamp ?? DateTime.now(), cups: cups));
  }

  void removeMeal(String id) {
    _meals.removeWhere((m) => m.id == id);
  }

  void removeCaffeine(String id) {
    _caffeineList.removeWhere((c) => c.id == id);
  }

  void removeKinetic(String id) {
    _kineticLogs.removeWhere((k) => k.id == id);
    if (_kineticLogs.isEmpty) {
      _currentActivity = KineticIntensity.resting;
    }
  }

  void reset() {
    _meals.clear();
    _caffeineList.clear();
    _kineticLogs.clear();
    _currentActivity = KineticIntensity.resting;
    _externalTemp = 24.0;
    _userProfile = const UserProfile(age: 18, bmiCategory: BmiCategory.normal);
  }

  // --- Theoretical Model Computation ---

  /// Calculates the predicted heart rate (BPM) at the given [currentTime]
  /// with an optional lookahead forecasting horizon in [lookaheadMinutes] (e.g. 2.5 minutes),
  /// strictly bounding the result by the absolute HR ceiling (220 - Age).
  double getPredictedBpm(DateTime currentTime, {double lookaheadMinutes = 0.0}) {
    final effectiveTime = lookaheadMinutes == 0.0
        ? currentTime
        : currentTime.add(Duration(milliseconds: (lookaheadMinutes * 60000).round()));

    // 1. Dynamic Resting Baseline (Age baseline + BMI offset)
    double predictedBpm = baseRestingHr;

    // 2. Heat Exposure (Thermoregulatory Load > 24°C)
    // Thermo-neutral threshold: 24°C. No compensation below this ambient temperature.
    if (_externalTemp > 24.0) {
      double tempDelta = _externalTemp - 24.0;
      predictedBpm += tempDelta * heatMultiplier * bmiSensitivityFactor;
    }

    // 3. Meal Digestion (Splanchnic Load)
    // - Light Meal: +4 BPM peak at 30 min, decaying over 1 hour
    // - Medium Meal: +8 BPM peak at 45 min, decaying over 2 hours
    // - Heavy Meal: +14 BPM peak at 60 min, decaying over 3.5 hours
    // - Older adults exhibit a blunted peak (+10 BPM max) with extended load
    for (var meal in _meals) {
      double dtMinutes = effectiveTime.difference(meal.timestamp).inMilliseconds / (1000.0 * 60.0);
      double contribution = calculateMealBpm(meal.size, dtMinutes);
      predictedBpm += contribution;
    }

    // 4. Caffeine Intake (Pharmacokinetic Load)
    // Pre-Intake: 0 BPM
    // Post-Intake Peak: Occurs 15–45 min after ingestion (centered at ~30 min)
    // Clearance: Exponential clearance k per minute
    for (var caffeine in _caffeineList) {
      double dtMinutes = effectiveTime.difference(caffeine.timestamp).inMilliseconds / (1000.0 * 60.0);
      double contribution = calculateCaffeineBpm(caffeine.cups, dtMinutes);
      predictedBpm += contribution;
    }

    // 5. Kinetic Load (Physical Activity)
    // Light: +20 BPM, Moderate: +50 BPM, Heavy: +80 BPM
    // Scaled by BMI factor; 10-minute post-exercise recovery curve
    for (var kinetic in _kineticLogs) {
      double dtMinutes = effectiveTime.difference(kinetic.timestamp).inMilliseconds / (1000.0 * 60.0);
      if (dtMinutes >= 0.0 && dtMinutes <= 10.0) {
        double exponent = -3.0 * (dtMinutes / 10.0);
        double kineticContribution = kinetic.peakBpm * bmiSensitivityFactor * math.exp(exponent);
        predictedBpm += kineticContribution;
      }
    }

    // 6. Absolute HR Ceiling Enforcement:
    // "Maximum achievable HR strictly follows the (220 - Age) formula.
    // BMI escalations apply heavily here; an obese individual performing
    // moderate work will hit their maximum HR ceiling significantly faster."
    if (predictedBpm > maxHrCeiling) {
      predictedBpm = maxHrCeiling;
    }

    return predictedBpm;
  }

  /// Calculates meal splanchnic load BPM at [dtMinutes] post-ingestion.
  double calculateMealBpm(int size, double dtMinutes) {
    if (dtMinutes < 0.0) return 0.0;

    double peakMinutes;
    double durationMinutes;
    double rawPeakBpm;

    if (size == 1) {
      // Light meal: +4 BPM peak at 30 min, decay over 1 hour (60 min)
      peakMinutes = 30.0;
      durationMinutes = 60.0;
      rawPeakBpm = 4.0;
    } else if (size == 2) {
      // Medium meal: +8 BPM peak at 45 min, decay over 2 hours (120 min)
      peakMinutes = 45.0;
      durationMinutes = 120.0;
      rawPeakBpm = 8.0;
    } else {
      // Heavy meal: +14 BPM peak at 60 min, decay over 3.5 hours (210 min)
      peakMinutes = 60.0;
      durationMinutes = 210.0;
      rawPeakBpm = 14.0;
    }

    // Age modification: Older adults exhibit a blunted peak (+10 BPM max) but extended load
    if (_userProfile.isOlderAdult) {
      if (rawPeakBpm > 10.0) rawPeakBpm = 10.0;
      durationMinutes *= 1.4; // extended load
    }

    if (dtMinutes > durationMinutes) return 0.0;

    // Smooth asymmetric rise and decay curve centered on peakMinutes
    double curve;
    if (dtMinutes <= peakMinutes) {
      curve = math.sin((dtMinutes / peakMinutes) * (math.pi / 2.0));
    } else {
      double decaySpan = durationMinutes - peakMinutes;
      double elapsedDecay = dtMinutes - peakMinutes;
      curve = math.cos((elapsedDecay / decaySpan) * (math.pi / 2.0));
    }

    if (curve < 0.0) curve = 0.0;
    return rawPeakBpm * curve * bmiSensitivityFactor;
  }

  /// Calculates caffeine pharmacokinetic BPM at [dtMinutes] post-ingestion.
  double calculateCaffeineBpm(int cups, double dtMinutes) {
    if (dtMinutes < 0.0) return 0.0;

    // Peak occurs 15–45 min after ingestion (absorption peak at ~30 min)
    // Clearance: exponential clearance k per min
    double absorptionFactor;
    if (dtMinutes < 30.0) {
      absorptionFactor = dtMinutes / 30.0; // Linear smooth rise to peak
    } else {
      absorptionFactor = 1.0;
    }

    double elapsedDecayMinutes = math.max(0.0, dtMinutes - 30.0);
    double decayFactor = math.exp(-caffeineDecayK * elapsedDecayMinutes);

    double totalMagnitude = caffeineSpikeAmplitude * cups * bmiSensitivityFactor;
    return totalMagnitude * absorptionFactor * decayFactor;
  }

  /// Estimates Cellular Oxygen Consumption Rate (VO2) in mL/min.
  double estimateVO2(double bpm) {
    if (bpm <= 0) return 0.0;
    double mets = bpm / baseRestingHr;
    return 3.5 * estimatedWeightKg * mets;
  }

  /// Estimates Metabolic Heat Generation Rate in kcal/hr.
  double estimateHeatGeneration(double vo2) {
    double o2LitersPerHour = (vo2 / 1000.0) * 60.0;
    return o2LitersPerHour * 4.83;
  }

  /// Estimates Splanchnic Blood Flow Allocation (%).
  double estimateSplanchnicAllocation(DateTime currentTime) {
    double baseSplanchnic = 22.0;
    double mealEffect = 0.0;

    for (var meal in _meals) {
      double dtMinutes = currentTime.difference(meal.timestamp).inMilliseconds / (1000.0 * 60.0);
      double bpm = calculateMealBpm(meal.size, dtMinutes);
      // Proportionate splanchnic dilation
      mealEffect += (bpm / 14.0) * 15.0;
    }

    return math.min(45.0, baseSplanchnic + mealEffect);
  }

  /// Calculates individual contributions and status of active stressors.
  List<StressorStatus> getActiveStressorStatuses(DateTime currentTime) {
    final List<StressorStatus> statuses = [];

    // Evaluate Meals
    for (var meal in _meals) {
      double dtMinutes = currentTime.difference(meal.timestamp).inMilliseconds / (1000.0 * 60.0);
      double totalDuration = meal.size == 1 ? 60.0 : (meal.size == 2 ? 120.0 : 210.0);
      if (_userProfile.isOlderAdult) totalDuration *= 1.4;

      if (dtMinutes >= 0.0 && dtMinutes <= totalDuration) {
        double contribution = calculateMealBpm(meal.size, dtMinutes);
        double peakMin = meal.size == 1 ? 30.0 : (meal.size == 2 ? 45.0 : 60.0);
        String trend = dtMinutes < peakMin ? 'Rising Demand' : 'Digesting / Resolving';

        statuses.add(StressorStatus(
          id: meal.id,
          type: 'Meal',
          description: '${meal.label} (Size ${meal.size})',
          bpmContribution: contribution,
          elapsedMinutes: dtMinutes,
          remainingMinutes: math.max(0.0, totalDuration - dtMinutes),
          trend: trend,
        ));
      }
    }

    // Evaluate Caffeine
    for (var caffeine in _caffeineList) {
      double dtMinutes = currentTime.difference(caffeine.timestamp).inMilliseconds / (1000.0 * 60.0);
      // Max active window ~6 hours for adult/teen, 8 hours for older adult
      double maxWindow = _userProfile.isOlderAdult ? 480.0 : 360.0;

      if (dtMinutes >= 0.0 && dtMinutes <= maxWindow) {
        double contribution = calculateCaffeineBpm(caffeine.cups, dtMinutes);
        String trend = dtMinutes < 30.0 ? 'Absorption Phase (15-45m)' : 'Exponential Clearance';

        statuses.add(StressorStatus(
          id: caffeine.id,
          type: 'Caffeine',
          description: '${caffeine.cups} Cup(s) Caffeine (+${caffeineSpikeAmplitude.toInt()} BPM base)',
          bpmContribution: contribution,
          elapsedMinutes: dtMinutes,
          remainingMinutes: math.max(0.0, maxWindow - dtMinutes),
          trend: trend,
        ));
      }
    }

    // Evaluate Kinetic Load (Physical Activity)
    for (var kinetic in _kineticLogs) {
      double dtMinutes = currentTime.difference(kinetic.timestamp).inMilliseconds / (1000.0 * 60.0);
      if (dtMinutes >= 0.0 && dtMinutes <= 10.0) {
        double exponent = -3.0 * (dtMinutes / 10.0);
        double contribution = kinetic.peakBpm * bmiSensitivityFactor * math.exp(exponent);

        statuses.add(StressorStatus(
          id: kinetic.id,
          type: 'Activity',
          description: '${kinetic.label} (+${kinetic.peakBpm.toInt()} BPM)',
          bpmContribution: contribution,
          elapsedMinutes: dtMinutes,
          remainingMinutes: math.max(0.0, 10.0 - dtMinutes),
          trend: '10m Post-Exercise Recovery',
        ));
      }
    }

    // Sort by largest contribution first
    statuses.sort((a, b) => b.bpmContribution.compareTo(a.bpmContribution));
    return statuses;
  }
}
