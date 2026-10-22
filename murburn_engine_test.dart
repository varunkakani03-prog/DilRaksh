import 'package:flutter_test/flutter_test.dart';
import '../lib/murburn_engine.dart';

void main() {
  group('MurburnEngine Physiological Calibration & Threshold Tests', () {
    late MurburnEngine engine;

    setUp(() {
      engine = MurburnEngine();
    });

    test('Default user profile is Age 18 (Teenager) with Normal BMI -> 72.0 BPM Baseline & 202 Max Ceiling', () {
      final now = DateTime.now();
      expect(engine.userProfile.age, 18);
      expect(engine.userProfile.bmiCategory, BmiCategory.normal);
      expect(engine.userProfile.isTeenager, isTrue);
      expect(engine.baseRestingHr, closeTo(72.0, 0.01));
      expect(engine.maxHrCeiling, closeTo(202.0, 0.01));
      expect(engine.getPredictedBpm(now), closeTo(72.0, 0.01));
    });

    test('Demographic Age Baselines, Caffeine Spikes, and Heat Multipliers', () {
      // 1. Child (<13y, e.g. age 6)
      engine.setUserProfile(const UserProfile(age: 6, bmiCategory: BmiCategory.normal));
      expect(engine.baseRestingHr, closeTo(80.0, 0.01));
      expect(engine.caffeineSpikeAmplitude, 15.0);
      expect(engine.heatMultiplier, 2.0);
      expect(engine.maxHrCeiling, 214.0);

      // 2. Teenager (13-19y, default 18)
      engine.setUserProfile(const UserProfile(age: 18, bmiCategory: BmiCategory.normal));
      expect(engine.baseRestingHr, closeTo(72.0, 0.01));
      expect(engine.caffeineSpikeAmplitude, 10.0);
      expect(engine.heatMultiplier, 1.5);
      expect(engine.maxHrCeiling, 202.0);

      // 3. Adult (20-64y, e.g. age 35)
      engine.setUserProfile(const UserProfile(age: 35, bmiCategory: BmiCategory.normal));
      expect(engine.baseRestingHr, closeTo(68.0, 0.01));
      expect(engine.caffeineSpikeAmplitude, 8.0);
      expect(engine.heatMultiplier, 1.5);
      expect(engine.maxHrCeiling, 185.0);

      // 4. Older Adult (65+y, e.g. age 70)
      engine.setUserProfile(const UserProfile(age: 70, bmiCategory: BmiCategory.normal));
      expect(engine.baseRestingHr, closeTo(70.0, 0.01));
      expect(engine.caffeineSpikeAmplitude, 6.0);
      expect(engine.heatMultiplier, 2.0);
      expect(engine.maxHrCeiling, 150.0);
    });

    test('BMI Adjustments (+0, +4, +8) and Sensitivity Factors (1.0x, 1.1x, 1.2x)', () {
      // Normal BMI
      engine.setUserProfile(const UserProfile(age: 18, bmiCategory: BmiCategory.normal));
      expect(engine.bmiOffset, 0.0);
      expect(engine.bmiSensitivityFactor, 1.0);
      expect(engine.baseRestingHr, closeTo(72.0, 0.01));

      // Overweight BMI (+4 BPM, 1.1x)
      engine.setBmiCategory(BmiCategory.overweight);
      expect(engine.bmiOffset, 4.0);
      expect(engine.bmiSensitivityFactor, 1.1);
      expect(engine.baseRestingHr, closeTo(76.0, 0.01));

      // Obese BMI (+8 BPM, 1.2x)
      engine.setBmiCategory(BmiCategory.obese);
      expect(engine.bmiOffset, 8.0);
      expect(engine.bmiSensitivityFactor, 1.2);
      expect(engine.baseRestingHr, closeTo(80.0, 0.01));
    });

    test('Thermoregulatory Load with 24°C Thermo-neutral Threshold', () {
      final now = DateTime.now();
      engine.setUserProfile(const UserProfile(age: 18, bmiCategory: BmiCategory.normal));

      // At 24°C: 0 BPM added
      engine.setExternalTemp(24.0);
      expect(engine.getPredictedBpm(now), closeTo(72.0, 0.01));

      // Below 24°C (e.g. 20°C): 0 BPM added
      engine.setExternalTemp(20.0);
      expect(engine.getPredictedBpm(now), closeTo(72.0, 0.01));

      // At 30°C for Teenager (+1.5 BPM/°C * 6°C = +9.0 BPM)
      engine.setExternalTemp(30.0);
      expect(engine.getPredictedBpm(now), closeTo(72.0 + 9.0, 0.01));

      // At 30°C for Older Adult (+2.0 BPM/°C * 6°C = +12.0 BPM)
      engine.setUserProfile(const UserProfile(age: 70, bmiCategory: BmiCategory.normal));
      expect(engine.getPredictedBpm(now), closeTo(70.0 + 12.0, 0.01));
    });

    test('Meal Digestion Splanchnic Load (Light +4 @30m, Medium +8 @45m, Heavy +14 @60m)', () {
      final baseTime = DateTime.now();

      // Light Meal (Size 1) Peak at 30 min
      engine.logMeal(1, timestamp: baseTime);
      final lightPeakTime = baseTime.add(const Duration(minutes: 30));
      expect(engine.getPredictedBpm(lightPeakTime), closeTo(72.0 + 4.0, 0.05));

      // Reset & Medium Meal (Size 2) Peak at 45 min
      engine.reset();
      engine.logMeal(2, timestamp: baseTime);
      final medPeakTime = baseTime.add(const Duration(minutes: 45));
      expect(engine.getPredictedBpm(medPeakTime), closeTo(72.0 + 8.0, 0.05));

      // Reset & Heavy Meal (Size 3) Peak at 60 min
      engine.reset();
      engine.logMeal(3, timestamp: baseTime);
      final heavyPeakTime = baseTime.add(const Duration(minutes: 60));
      expect(engine.getPredictedBpm(heavyPeakTime), closeTo(72.0 + 14.0, 0.05));

      // Older Adult Blunted Peak (+10 BPM maximum on heavy meal)
      engine.reset();
      engine.setUserProfile(const UserProfile(age: 70, bmiCategory: BmiCategory.normal));
      engine.logMeal(3, timestamp: baseTime);
      expect(engine.getPredictedBpm(heavyPeakTime), closeTo(70.0 + 10.0, 0.05));
    });

    test('Pharmacokinetic Caffeine Load with Teenager (+10 BPM) & BMI scaling', () {
      final baseTime = DateTime.now();

      // Teenager (Age 18) Normal BMI: Peak at 30 minutes is +10.0 BPM
      engine.logCaffeine(1, timestamp: baseTime);
      final peakTime = baseTime.add(const Duration(minutes: 30));
      expect(engine.getPredictedBpm(peakTime), closeTo(72.0 + 10.0, 0.05));

      // Teenager Obese BMI: Peak at 30 minutes is +10.0 * 1.2 = +12.0 BPM
      final obeseEngine = MurburnEngine();
      obeseEngine.setUserProfile(const UserProfile(age: 18, bmiCategory: BmiCategory.obese));
      obeseEngine.logCaffeine(1, timestamp: baseTime);
      expect(obeseEngine.getPredictedBpm(peakTime), closeTo(80.0 + 12.0, 0.05));
    });

    test('Kinetic Load (Physical Activity) & Absolute HR Ceiling Clamping', () {
      final baseTime = DateTime.now();

      // Moderate Activity (+50 BPM) for 18y Teenager (Ceiling = 202 BPM)
      engine.setPhysicalActivity(KineticIntensity.moderate, timestamp: baseTime);
      expect(engine.getPredictedBpm(baseTime), closeTo(72.0 + 50.0, 0.01));

      // Absolute Ceiling test: 70y Older Adult (Ceiling = 220 - 70 = 150 BPM)
      final olderEngine = MurburnEngine();
      olderEngine.setUserProfile(const UserProfile(age: 70, bmiCategory: BmiCategory.obese));
      // Base resting HR is 70 + 8 = 78 BPM.
      // Heavy Activity: +80 BPM * 1.2 (Obese) = +96 BPM.
      // 78 + 96 = 174 BPM, which exceeds the 150 BPM ceiling.
      olderEngine.setPhysicalActivity(KineticIntensity.heavy, timestamp: baseTime);
      expect(olderEngine.getPredictedBpm(baseTime), closeTo(150.0, 0.01));
    });
  });
}
