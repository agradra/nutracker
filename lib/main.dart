import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const NutrackerApp());
}

// ============================================================================
// 1. APP THEME & ROOT
// ============================================================================

class NutrackerApp extends StatelessWidget {
  const NutrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nutracker',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
        },
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.white,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Color(0xFF00E676),
          surface: Color(0xFF111111),
        ),
        fontFamily: 'Pretendard',
        dividerColor: const Color(0xFF222222),
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ============================================================================
// 2. MODELS & ENUMS
// ============================================================================

enum NutrientType {
  calories('열량', 'kcal', false, Color(0xFF00E676)),
  carbs('탄수화물', 'g', false, Color(0xFF38BDF8)),
  sugar('당류', 'g', true, Color(0xFF7DD3FC)), // 탄수화물 하위
  protein('단백질', 'g', false, Color(0xFFA855F7)),
  fat('지방', 'g', false, Color(0xFFF59E0B)),
  saturatedFat('포화지방', 'g', true, Color(0xFFFBBF24)), // 지방 하위
  transFat('트랜스지방', 'g', true, Color(0xFFF87171)), // 지방 하위
  sodium('나트륨', 'mg', false, Color(0xFFEC4899)),
  cholesterol('콜레스테롤', 'mg', false, Color(0xFF14B8A6));

  final String label;
  final String unit;
  final bool isSubItem;
  final Color pointColor;

  const NutrientType(this.label, this.unit, this.isSubItem, this.pointColor);
}

/// 날짜별 목표 도달 3단계 상태
enum GoalStatus {
  wellReached('잘 도달', Color(0xFF00E676), Icons.check_circle_rounded),
  partiallyReached('일부 도달', Color(0xFFFBBF24), Icons.timelapse_rounded),
  notReached('미도달', Color(0xFF555555), Icons.radio_button_unchecked_rounded);

  final String label;
  final Color color;
  final IconData icon;
  const GoalStatus(this.label, this.color, this.icon);
}

/// 영양소별 설정 모델 (활성화 여부 및 허용값 min/max)
class NutrientConfig {
  bool enabled;
  double? min;
  double? max;

  NutrientConfig({this.enabled = true, this.min, this.max});

  Map<String, dynamic> toJson() => {'enabled': enabled, 'min': min, 'max': max};

  factory NutrientConfig.fromJson(Map<String, dynamic> json) => NutrientConfig(
    enabled: json['enabled'] ?? true,
    min: json['min'] != null ? (json['min'] as num).toDouble() : null,
    max: json['max'] != null ? (json['max'] as num).toDouble() : null,
  );
}

/// 음식 정보 모델
class FoodItem {
  final String id;
  final String name;
  final DateTime timestamp;
  final Map<NutrientType, double> nutrients;

  FoodItem({
    required this.id,
    required this.name,
    required this.timestamp,
    required this.nutrients,
  });

  double get calories => nutrients[NutrientType.calories] ?? 0;

  FoodItem copyWith({
    String? id,
    String? name,
    DateTime? timestamp,
    Map<NutrientType, double>? nutrients,
  }) {
    return FoodItem(
      id: id ?? this.id,
      name: name ?? this.name,
      timestamp: timestamp ?? this.timestamp,
      nutrients: nutrients ?? Map.from(this.nutrients),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'timestamp': timestamp.toIso8601String(),
    'nutrients': nutrients.map((k, v) => MapEntry(k.name, v)),
  };

  factory FoodItem.fromJson(Map<String, dynamic> json) {
    final rawNutrients = json['nutrients'] as Map<String, dynamic>? ?? {};
    final parsedNutrients = <NutrientType, double>{};
    for (var type in NutrientType.values) {
      parsedNutrients[type] =
          (rawNutrients[type.name] as num?)?.toDouble() ?? 0.0;
    }
    return FoodItem(
      id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] ?? '이름 없는 음식',
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      nutrients: parsedNutrients,
    );
  }
}

// ============================================================================
// 3. STATE MANAGEMENT & CONTROLLER
// ============================================================================

class NutrackerController extends ChangeNotifier {
  String apiKey = '';
  String modelName = 'gemini-3.8-flash';
  TimeOfDay resetTime = const TimeOfDay(hour: 4, minute: 0); // 기본값 AM 4시

  late DateTime selectedDate;
  final Map<NutrientType, NutrientConfig> nutrientConfigs = {};
  final Map<String, List<FoodItem>> dailyLogs = {}; // key: 'yyyy-MM-dd'
  final List<FoodItem> favorites = [];

  NutrackerController() {
    _initDefaultConfigs();
    selectedDate = getLogicalToday();
    _loadFromPrefs();
  }

  void _initDefaultConfigs() {
    nutrientConfigs[NutrientType.calories] = NutrientConfig(
      enabled: true,
      min: 1800,
      max: 2200,
    );
    nutrientConfigs[NutrientType.carbs] = NutrientConfig(
      enabled: true,
      min: 200,
      max: 300,
    );
    nutrientConfigs[NutrientType.sugar] = NutrientConfig(
      enabled: true,
      max: 50,
    );
    nutrientConfigs[NutrientType.protein] = NutrientConfig(
      enabled: true,
      min: 80,
      max: 150,
    );
    nutrientConfigs[NutrientType.fat] = NutrientConfig(
      enabled: true,
      min: 40,
      max: 70,
    );
    nutrientConfigs[NutrientType.saturatedFat] = NutrientConfig(
      enabled: true,
      max: 15,
    );
    nutrientConfigs[NutrientType.transFat] = NutrientConfig(
      enabled: true,
      max: 2,
    );
    nutrientConfigs[NutrientType.sodium] = NutrientConfig(
      enabled: true,
      max: 2000,
    );
    nutrientConfigs[NutrientType.cholesterol] = NutrientConfig(
      enabled: true,
      max: 300,
    );
  }

  /// 리셋 시간을 반영한 현재 '논리적 오늘 날짜' 계산
  DateTime getLogicalToday() {
    final now = DateTime.now();
    final shifted = now.subtract(
      Duration(hours: resetTime.hour, minutes: resetTime.minute),
    );
    return DateTime(shifted.year, shifted.month, shifted.day);
  }

  String dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// 리셋 시간이 지났는지 체크하여 오늘 블럭 갱신
  void checkResetTimeAndRefresh() {
    final today = getLogicalToday();
    final todayKey = dateKey(today);
    if (!dailyLogs.containsKey(todayKey)) {
      dailyLogs[todayKey] = [];
      notifyListeners();
    }
  }

  void selectDate(DateTime date) {
    selectedDate = DateTime(date.year, date.month, date.day);
    notifyListeners();
  }

  List<FoodItem> getFoodsForDate(DateTime date) {
    return dailyLogs[dateKey(date)] ?? [];
  }

  /// 특정 날짜의 영양소 총합 계산
  Map<NutrientType, double> getTotalsForDate(DateTime date) {
    final foods = getFoodsForDate(date);
    final totals = {for (var t in NutrientType.values) t: 0.0};
    for (var food in foods) {
      for (var t in NutrientType.values) {
        totals[t] = (totals[t] ?? 0) + (food.nutrients[t] ?? 0);
      }
    }
    return totals;
  }

  /// 날짜별 블럭 3단계 목표 도달 판정
  GoalStatus getGoalStatusForDate(DateTime date) {
    final foods = getFoodsForDate(date);
    if (foods.isEmpty) return GoalStatus.notReached;

    final totals = getTotalsForDate(date);
    int activeGoals = 0;
    int metGoals = 0;

    for (var type in NutrientType.values) {
      final cfg = nutrientConfigs[type];
      if (cfg == null || !cfg.enabled) continue;
      if (cfg.min == null && cfg.max == null) continue;

      activeGoals++;
      final val = totals[type] ?? 0;
      bool minOk = cfg.min == null || val >= cfg.min!;
      bool maxOk = cfg.max == null || val <= cfg.max!;

      if (minOk && maxOk) {
        metGoals++;
      }
    }

    if (activeGoals == 0) return GoalStatus.wellReached;
    final ratio = metGoals / activeGoals;
    if (ratio >= 0.7) return GoalStatus.wellReached;
    if (ratio >= 0.3) return GoalStatus.partiallyReached;
    return GoalStatus.notReached;
  }

  /// 음식 추가 (다중 추가 지원)
  void addFoodsToSelectedDate(List<FoodItem> items) {
    final key = dateKey(selectedDate);
    dailyLogs.putIfAbsent(key, () => []);
    dailyLogs[key]!.addAll(items);

    _pruneOldLogs();

    _saveToPrefs();
    notifyListeners();
  }

  void _pruneOldLogs() {
    final today = getLogicalToday();
    final cutoffDate = today.subtract(const Duration(days: 730));

    // 키(날짜 문자열 'yyyy-MM-dd')를 기준으로 730일 이전 날짜 필터링
    final keysToRemove = <String>[];
    dailyLogs.forEach((dateStr, _) {
      final date = DateTime.tryParse(dateStr);
      if (date != null && date.isBefore(cutoffDate)) {
        keysToRemove.add(dateStr);
      }
    });

    for (var k in keysToRemove) {
      dailyLogs.remove(k);
    }
  }

  /// 음식 수정
  void updateFood(DateTime date, FoodItem updated) {
    final key = dateKey(date);
    final list = dailyLogs[key];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == updated.id);
    if (idx != -1) {
      list[idx] = updated;
      _saveToPrefs();
      notifyListeners();
    }
  }

  /// 음식 삭제
  void deleteFood(DateTime date, String id) {
    final key = dateKey(date);
    dailyLogs[key]?.removeWhere((e) => e.id == id);
    _saveToPrefs();
    notifyListeners();
  }

  /// 즐겨찾기 추가 (동일 이름 존재 시 추가하지 않음)
  bool addToFavorites(FoodItem item) {
    final exists = favorites.any(
      (f) => f.name.trim().toLowerCase() == item.name.trim().toLowerCase(),
    );
    if (exists) return false;

    favorites.add(
      item.copyWith(id: DateTime.now().microsecondsSinceEpoch.toString()),
    );
    _saveToPrefs();
    notifyListeners();
    return true;
  }

  void removeFromFavorites(String id) {
    favorites.removeWhere((f) => f.id == id);
    _saveToPrefs();
    notifyListeners();
  }

  void updateSettings({
    required String newApiKey,
    required String newModelName,
    required TimeOfDay newResetTime,
    required Map<NutrientType, NutrientConfig> newConfigs,
  }) {
    apiKey = newApiKey.trim();
    modelName = newModelName.trim().isEmpty
        ? 'gemini-3.8-flash'
        : newModelName.trim();
    resetTime = newResetTime;
    for (var entry in newConfigs.entries) {
      nutrientConfigs[entry.key] = entry.value;
    }
    _saveToPrefs();
    notifyListeners();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey = prefs.getString('apiKey') ?? '';
    modelName = prefs.getString('modelName') ?? 'gemini-3.8-flash';
    final rHour = prefs.getInt('resetHour') ?? 4;
    final rMin = prefs.getInt('resetMinute') ?? 0;
    resetTime = TimeOfDay(hour: rHour, minute: rMin);
    selectedDate = getLogicalToday();

    final cfgStr = prefs.getString('nutrientConfigs');
    if (cfgStr != null) {
      final decoded = jsonDecode(cfgStr) as Map<String, dynamic>;
      for (var t in NutrientType.values) {
        if (decoded.containsKey(t.name)) {
          nutrientConfigs[t] = NutrientConfig.fromJson(decoded[t.name]);
        }
      }
    }

    final logsStr = prefs.getString('dailyLogs');
    if (logsStr != null) {
      final decoded = jsonDecode(logsStr) as Map<String, dynamic>;
      dailyLogs.clear();
      decoded.forEach((k, v) {
        dailyLogs[k] = (v as List).map((e) => FoodItem.fromJson(e)).toList();
      });
    }

    final favStr = prefs.getString('favorites');
    if (favStr != null) {
      final decoded = jsonDecode(favStr) as List;
      favorites.clear();
      favorites.addAll(decoded.map((e) => FoodItem.fromJson(e)));
    }
    _pruneOldLogs();

    checkResetTimeAndRefresh();
    notifyListeners();
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', apiKey);
    await prefs.setString('modelName', modelName);
    await prefs.setInt('resetHour', resetTime.hour);
    await prefs.setInt('resetMinute', resetTime.minute);

    final cfgMap = nutrientConfigs.map((k, v) => MapEntry(k.name, v.toJson()));
    await prefs.setString('nutrientConfigs', jsonEncode(cfgMap));

    final logsMap = dailyLogs.map(
      (k, v) => MapEntry(k, v.map((e) => e.toJson()).toList()),
    );
    await prefs.setString('dailyLogs', jsonEncode(logsMap));

    final favList = favorites.map((e) => e.toJson()).toList();
    await prefs.setString('favorites', jsonEncode(favList));
  }
}

// ============================================================================
// 4. GEMINI AI SERVICE (항상 JSON 배열 [{...}, {...}] 형태로 반환)
// ============================================================================

class GeminiService {
  static Future<List<FoodItem>> analyzeFood({
    required String apiKey,
    required String modelName,
    String? userPrompt,
    List<Uint8List>? images,
  }) async {
    if (apiKey.isEmpty) {
      throw Exception('설정에서 Gemini API Key를 먼저 입력해주세요.');
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );

    const systemInstruction = '''
당신은 전문 영양 분석 AI입니다.
사용자가 제공한 이미지(1장 또는 여러 장)나 텍스트 설명에서 음식들을 식별하고 영양성분을 추론하세요.
반드시 아래 규칙을 지키세요:
1. 음식이 1개여도 무조건 JSON 배열 형태 `[{...}]` 로 반환하고, 여러 개면 `[{...}, {...}]` 로 반환하세요.
2. 각 객체는 다음 키를 가집니다:
   - "name": 음식 이름 (문자열, 예: "닭가슴살 샐러드")
   - "calories": 열량 (kcal, 숫자)
   - "carbs": 탄수화물 (g, 숫자)
   - "sugar": 당류 (g, 숫자)
   - "protein": 단백질 (g, 숫자)
   - "fat": 지방 (g, 숫자)
   - "saturatedFat": 포화지방 (g, 숫자)
   - "transFat": 트랜스지방 (g, 숫자)
   - "sodium": 나트륨 (mg, 숫자)
   - "cholesterol": 콜레스테롤 (mg, 숫자)
3. 추측하기 어려운 영양성분은 0으로 두세요.
4. 마크다운 코드블럭 없이 순수 JSON 배열만 출력하세요.
''';

    final parts = <Map<String, dynamic>>[
      {'text': systemInstruction},
    ];

    if (userPrompt != null && userPrompt.trim().isNotEmpty) {
      parts.add({'text': '사용자 설명: $userPrompt'});
    }

    if (images != null && images.isNotEmpty) {
      for (var imgBytes in images) {
        parts.add({
          'inline_data': {
            'mime_type': 'image/jpeg',
            'data': base64Encode(imgBytes),
          },
        });
      }
    }

    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'temperature': 0.2,
      },
    });

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Gemini API 오류 (${response.statusCode}):${response.body}',
      );
    }

    final data = jsonDecode(response.body);
    final text =
        data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;

    if (text == null || text.isEmpty) {
      throw Exception('AI 응답이 비어있습니다.');
    }

    final cleaned = text.replaceAll('```json', '').replaceAll('```', '').trim();
    final decoded = jsonDecode(cleaned);
    final List<dynamic> rawList = decoded is List ? decoded : [decoded];

    final now = DateTime.now();
    return rawList.asMap().entries.map((entry) {
      final idx = entry.key;
      final item = entry.value as Map<String, dynamic>;
      double parseNum(dynamic v) =>
          (v is num) ? v.toDouble() : (double.tryParse('$v') ?? 0.0);

      return FoodItem(
        id: '${now.microsecondsSinceEpoch}_$idx',
        name: (item['name'] ?? '').toString(),
        timestamp: now,
        nutrients: {
          NutrientType.calories: parseNum(item['calories']),
          NutrientType.carbs: parseNum(item['carbs']),
          NutrientType.sugar: parseNum(item['sugar']),
          NutrientType.protein: parseNum(item['protein']),
          NutrientType.fat: parseNum(item['fat']),
          NutrientType.saturatedFat: parseNum(item['saturatedFat']),
          NutrientType.transFat: parseNum(item['transFat']),
          NutrientType.sodium: parseNum(item['sodium']),
          NutrientType.cholesterol: parseNum(item['cholesterol']),
        },
      );
    }).toList();
  }
}

// ============================================================================
// 5. REUSABLE COMPONENTS (재사용 컴포넌트 분리)
// ============================================================================

/// [컴포넌트 1] 영양정보 대시보드 및 그래프 블럭
class NutrientDashboardBlock extends StatelessWidget {
  final Map<NutrientType, double> totals;
  final Map<NutrientType, NutrientConfig> configs;

  const NutrientDashboardBlock({
    super.key,
    required this.totals,
    required this.configs,
  });

  @override
  Widget build(BuildContext context) {
    final calConfig = configs[NutrientType.calories]!;
    final calValue = totals[NutrientType.calories] ?? 0;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E0E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF222222), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (calConfig.enabled) ...[
            _buildMainCalorieHero(calValue, calConfig),
            const SizedBox(height: 24),
            const Divider(color: Color(0xFF1F1F1F), height: 1),
            const SizedBox(height: 20),
          ],
          ...NutrientType.values
              .where(
                (t) =>
                    t != NutrientType.calories && (configs[t]?.enabled ?? true),
              )
              .map((t) => _buildNutrientRow(t, totals[t] ?? 0, configs[t]!)),
        ],
      ),
    );
  }

  /// 메인 열량 대형 그래프
  Widget _buildMainCalorieHero(double value, NutrientConfig cfg) {
    final target = cfg.max ?? cfg.min ?? 2000;
    final progress = target > 0 ? (value / target).clamp(0.0, 1.0) : 0.0;
    final isOver = cfg.max != null && value > cfg.max!;
    final remaining = math.max(0.0, target - value);

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: isOver
                          ? const Color(0xFFF87171)
                          : NutrientType.calories.pointColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '열량 (Calories)',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: value),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, val, _) => RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: val.toStringAsFixed(0),
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -1,
                        ),
                      ),
                      const TextSpan(
                        text: ' kcal',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white54,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _buildGoalHelperText(value, cfg, 'kcal', remaining),
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 86,
          height: 86,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeOutCubic,
            builder: (context, animVal, _) => Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 86,
                  height: 86,
                  child: CircularProgressIndicator(
                    value: animVal,
                    strokeWidth: 8,
                    backgroundColor: const Color(0xFF1F1F1F),
                    strokeCap: StrokeCap.round,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isOver
                          ? const Color(0xFFF87171)
                          : NutrientType.calories.pointColor,
                    ),
                  ),
                ),
                Text(
                  '${(animVal * 100).toInt()}%',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 일반 영양소 및 하위 영양소(들여쓰기) 그래프 행
  Widget _buildNutrientRow(
    NutrientType type,
    double value,
    NutrientConfig cfg,
  ) {
    final target = cfg.max ?? cfg.min ?? 100.0;
    final ratio = target > 0 ? (value / target).clamp(0.0, 1.0) : 0.0;
    final isOver = cfg.max != null && value > cfg.max!;
    final isSub = type.isSubItem;

    return Padding(
      padding: EdgeInsets.only(
        left: isSub ? 20.0 : 0.0,
        bottom: isSub ? 12.0 : 16.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  if (isSub)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Text(
                        '└',
                        style: TextStyle(color: Colors.white30, fontSize: 12),
                      ),
                    ),
                  Text(
                    type.label,
                    style: TextStyle(
                      fontSize: isSub ? 13 : 14,
                      fontWeight: isSub ? FontWeight.w400 : FontWeight.w600,
                      color: isSub ? Colors.white60 : Colors.white,
                    ),
                  ),
                ],
              ),
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: _formatNumber(value),
                      style: TextStyle(
                        fontSize: isSub ? 13 : 14,
                        fontWeight: FontWeight.w700,
                        color: isOver ? const Color(0xFFF87171) : Colors.white,
                      ),
                    ),
                    TextSpan(
                      text: ' / ${_formatGoalRange(cfg)}${type.unit}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: ratio),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, animVal, _) => LinearProgressIndicator(
                value: animVal,
                minHeight: isSub ? 4 : 6,
                backgroundColor: const Color(0xFF1C1C1C),
                valueColor: AlwaysStoppedAnimation<Color>(
                  isOver ? const Color(0xFFF87171) : type.pointColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  String _formatGoalRange(NutrientConfig cfg) {
    if (cfg.min != null && cfg.max != null) {
      return '${_formatNumber(cfg.min!)}~${_formatNumber(cfg.max!)}';
    } else if (cfg.max != null) {
      return '${_formatNumber(cfg.max!)} ';
    } else if (cfg.min != null) {
      return '최소 ${_formatNumber(cfg.min!)} ';
    }
    return '자유 ';
  }

  String _buildGoalHelperText(
    double val,
    NutrientConfig cfg,
    String unit,
    double rem,
  ) {
    if (cfg.min != null && cfg.max != null) {
      return '목표 ${_formatNumber(cfg.min!)}~${_formatNumber(cfg.max!)}$unit · 남은 열량 ${_formatNumber(rem)}$unit';
    } else if (cfg.max != null) {
      return '목표 최대 ${_formatNumber(cfg.max!)}$unit · 남은 열량 ${_formatNumber(rem)}$unit';
    } else if (cfg.min != null) {
      return '목표 최소 ${_formatNumber(cfg.min!)}$unit';
    }
    return '설정된 목표치가 없습니다';
  }
}

/// [컴포넌트 2] 선(Divider) 구분 스타일의 음식 아이템 (메인 하단 및 즐겨찾기 공통 사용)
class FoodLineItem extends StatelessWidget {
  final FoodItem food;
  final VoidCallback onTap;
  final bool showTime;
  final Widget? trailingAction;

  const FoodLineItem({
    super.key,
    required this.food,
    required this.onTap,
    this.showTime = true,
    this.trailingAction,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr =
        '${food.timestamp.hour.toString().padLeft(2, '0')}:${food.timestamp.minute.toString().padLeft(2, '0')}';

    return InkWell(
      onTap: onTap,
      splashColor: Colors.white10,
      highlightColor: Colors.white10,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFF222222), width: 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    food.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (showTime) ...[
                    const SizedBox(height: 4),
                    Text(
                      timeStr,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              '${food.calories.toStringAsFixed(0)} kcal',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (trailingAction != null) ...[
              const SizedBox(width: 8),
              trailingAction!,
            ] else ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white30,
                size: 20,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// [컴포넌트 3] 음식 추가/수정 멀티 카드 탭 모달 (단일/다중 음식 공통 처리)
class MultiFoodFormSheet extends StatefulWidget {
  final List<FoodItem> initialDrafts;
  final String title;
  final void Function(List<FoodItem> savedItems) onSave;

  const MultiFoodFormSheet({
    super.key,
    required this.initialDrafts,
    required this.title,
    required this.onSave,
  });

  @override
  State<MultiFoodFormSheet> createState() => _MultiFoodFormSheetState();
}

class _MultiFoodFormSheetState extends State<MultiFoodFormSheet> {
  final List<GlobalKey<FormState>> _formKeys = [];
  late List<_FoodDraftControllers> _drafts;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _drafts = widget.initialDrafts
        .map((e) => _FoodDraftControllers.fromFoodItem(e))
        .toList();
    if (_drafts.isEmpty) {
      _drafts.add(_FoodDraftControllers.empty());
    }
    for (var i = 0; i < _drafts.length; i++) {
      _formKeys.add(GlobalKey<FormState>());
    }
  }

  @override
  void dispose() {
    for (var d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  void _addNewCard() {
    setState(() {
      _drafts.add(_FoodDraftControllers.empty());
      _formKeys.add(GlobalKey<FormState>());
      _currentIndex = _drafts.length - 1;
    });
  }

  void _removeCurrentCard() {
    if (_drafts.length <= 1) return;
    setState(() {
      _drafts[_currentIndex].dispose();
      _drafts.removeAt(_currentIndex);
      _formKeys.removeAt(_currentIndex);
      if (_currentIndex >= _drafts.length) {
        _currentIndex = _drafts.length - 1;
      }
    });
  }

  void _submit() {
    for (var i = 0; i < _drafts.length; i++) {
      final d = _drafts[i];
      if (d.nameCtrl.text.trim().isEmpty) {
        setState(() => _currentIndex = i);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${i + 1}번째 음식의 이름을 입력해주세요.')));
        return;
      }
      for (var t in NutrientType.values) {
        final txt = d.nutrientCtrls[t]!.text.trim();
        if (txt.isEmpty || double.tryParse(txt) == null) {
          setState(() => _currentIndex = i);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${i + 1}번째 음식의 ${t.label} 값을 숫자로 입력해주세요.')),
          );
          return;
        }
      }
    }

    final results = _drafts.map((d) => d.toFoodItem()).toList();
    widget.onSave(results);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final currentDraft = _drafts[_currentIndex];

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: const BoxDecoration(
        color: Color(0xFF0C0C0C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: Color(0xFF262626))),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                TextButton(
                  onPressed: _submit,
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text(
                    '저장',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          // 다중 음식 카드 탭 영역
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                ...List.generate(_drafts.length, (idx) {
                  final isSelected = idx == _currentIndex;
                  final title = _drafts[idx].nameCtrl.text.trim().isEmpty
                      ? '음식 ${idx + 1}'
                      : _drafts[idx].nameCtrl.text.trim();
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _currentIndex = idx),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF333333),
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.black
                                    : Colors.white70,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            if (_drafts.length > 1 && isSelected) ...[
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: _removeCurrentCard,
                                child: const Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                ActionChip(
                  onPressed: _addNewCard,
                  backgroundColor: const Color(0xFF161616),
                  side: const BorderSide(color: Color(0xFF2E2E2E)),
                  label: const Text(
                    '+ 카드 추가',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Color(0xFF1F1F1F), height: 1),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: SingleChildScrollView(
                key: ValueKey(_currentIndex),
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  MediaQuery.of(context).viewInsets.bottom + 32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTextField(
                      label: '음식 이름 *',
                      controller: currentDraft.nameCtrl,
                      isNumber: false,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),

                    InkWell(
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(
                            currentDraft.timestamp,
                          ),
                        );
                        if (picked != null) {
                          setState(() {
                            final old = currentDraft.timestamp;
                            currentDraft.timestamp = DateTime(
                              old.year,
                              old.month,
                              old.day,
                              picked.hour,
                              picked.minute,
                            );
                          });
                        }
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141414),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF262626)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '섭취 시간 *',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                            Row(
                              children: [
                                Text(
                                  '${currentDraft.timestamp.hour.toString().padLeft(2, '0')}:${currentDraft.timestamp.minute.toString().padLeft(2, '0')}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.access_time_rounded,
                                  color: Colors.white54,
                                  size: 18,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '영양성분 정보 (모든 필드 필수, 기본값 0)',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...NutrientType.values.map((t) {
                      return Padding(
                        padding: EdgeInsets.only(
                          left: t.isSubItem ? 18.0 : 0.0,
                          bottom: 12.0,
                        ),
                        child: _buildTextField(
                          label:
                              '${t.isSubItem ? "└ " : ""}${t.label} (${t.unit}) *',
                          controller: currentDraft.nutrientCtrls[t]!,
                          isNumber: true,
                          accentColor: t.pointColor,
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required bool isNumber,
    Color? accentColor,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: accentColor ?? Colors.white60,
          fontSize: 13,
        ),
        filled: true,
        fillColor: const Color(0xFF141414),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF262626)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: accentColor ?? Colors.white,
            width: 1.4,
          ),
        ),
      ),
    );
  }
}

class _FoodDraftControllers {
  final String id;
  DateTime timestamp;
  final TextEditingController nameCtrl;
  final Map<NutrientType, TextEditingController> nutrientCtrls;

  _FoodDraftControllers({
    required this.id,
    required this.timestamp,
    required this.nameCtrl,
    required this.nutrientCtrls,
  });

  factory _FoodDraftControllers.empty() {
    return _FoodDraftControllers(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      nameCtrl: TextEditingController(text: ''),
      nutrientCtrls: {
        for (var t in NutrientType.values) t: TextEditingController(text: '0'),
      },
    );
  }

  factory _FoodDraftControllers.fromFoodItem(FoodItem item) {
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return _FoodDraftControllers(
      id: item.id,
      timestamp: item.timestamp,
      nameCtrl: TextEditingController(text: item.name),
      nutrientCtrls: {
        for (var t in NutrientType.values)
          t: TextEditingController(text: fmt(item.nutrients[t] ?? 0)),
      },
    );
  }

  FoodItem toFoodItem() {
    return FoodItem(
      id: id,
      name: nameCtrl.text.trim(),
      timestamp: timestamp,
      nutrients: {
        for (var t in NutrientType.values)
          t: double.tryParse(nutrientCtrls[t]!.text.trim()) ?? 0.0,
      },
    );
  }

  void dispose() {
    nameCtrl.dispose();
    for (var c in nutrientCtrls.values) {
      c.dispose();
    }
  }
}

/// [컴포넌트 4] 6개 버튼으로 분리되는 애니메이션 플로팅 액션 버튼 (Expandable FAB)
class ExpandableNutrackerFab extends StatefulWidget {
  final VoidCallback onManualWrite;
  final VoidCallback onFavorites;
  final VoidCallback onAiCamera;
  final VoidCallback onAiImage;
  final VoidCallback onAiChat;

  const ExpandableNutrackerFab({
    super.key,
    required this.onManualWrite,
    required this.onFavorites,
    required this.onAiCamera,
    required this.onAiImage,
    required this.onAiChat,
  });

  @override
  State<ExpandableNutrackerFab> createState() => _ExpandableNutrackerFabState();
}

class _ExpandableNutrackerFabState extends State<ExpandableNutrackerFab>
    with SingleTickerProviderStateMixin {
  bool _isOpen = false;
  late AnimationController _animCtrl;
  late Animation<double> _expandAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _expandAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutBack);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _isOpen = !_isOpen;
      if (_isOpen) {
        _animCtrl.forward();
      } else {
        _animCtrl.reverse();
      }
    });
  }

  void _handleAction(VoidCallback callback) {
    _toggle();
    callback();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 펼쳐지는 5개의 기능 버튼 + 하단 닫기(V) 버튼으로 총 6개 버튼 분리 구성
        SizeTransition(
          sizeFactor: _expandAnim,
          alignment: Alignment.centerRight,
          child: FadeTransition(
            opacity: _expandAnim,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildSubFab(
                    label: '직접 작성',
                    icon: const Icon(
                      Icons.edit_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    onTap: () => _handleAction(widget.onManualWrite),
                  ),
                  const SizedBox(height: 10),
                  _buildSubFab(
                    label: '즐겨찾기',
                    icon: const Icon(
                      Icons.star_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    onTap: () => _handleAction(widget.onFavorites),
                  ),
                  const SizedBox(height: 10),
                  _buildSubFab(
                    label: 'AI 카메라',
                    icon: const Icon(
                      Icons.camera_alt_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    onTap: () => _handleAction(widget.onAiCamera),
                  ),
                  const SizedBox(height: 10),
                  _buildSubFab(
                    label: 'AI 이미지',
                    icon: const Icon(
                      Icons.image_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    onTap: () => _handleAction(widget.onAiImage),
                  ),
                  const SizedBox(height: 10),
                  _buildSubFab(
                    label: 'AI 채팅',
                    icon: const GeminiFourStarIcon(
                      size: 20,
                      color: Colors.black,
                    ),
                    onTap: () => _handleAction(widget.onAiChat),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 6번째 버튼: 닫기(열렸을 때 V 모양 아래쪽 화살표) / 열기(기본 + 모양)
        GestureDetector(
          onTap: _toggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: _isOpen ? const Color(0xFF222222) : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 1),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: _isOpen
                    ? const Icon(
                        Icons.keyboard_arrow_down_rounded, // V 모양의 아래쪽 화살표(닫기)
                        key: ValueKey('close_v'),
                        color: Colors.white,
                        size: 32,
                      )
                    : const Icon(
                        Icons.add_rounded, // 기본 동그라미 + 아이콘
                        key: ValueKey('open_plus'),
                        color: Colors.black,
                        size: 30,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubFab({
    required String label,
    required Widget icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF333333)),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Center(child: icon),
          ),
        ],
      ),
    );
  }
}

/// 제미나이 스타일의 4별(Four-Star Sparkle) 구조 커스텀 아이콘
class GeminiFourStarIcon extends StatelessWidget {
  final double size;
  final Color color;

  const GeminiFourStarIcon({
    super.key,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _FourStarPainter(color),
    );
  }
}

class _FourStarPainter extends CustomPainter {
  final Color color;
  _FourStarPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    void drawSparkle(Offset center, double radius) {
      final path = Path();
      path.moveTo(center.dx, center.dy - radius);
      path.quadraticBezierTo(
        center.dx,
        center.dy,
        center.dx + radius,
        center.dy,
      );
      path.quadraticBezierTo(
        center.dx,
        center.dy,
        center.dx,
        center.dy + radius,
      );
      path.quadraticBezierTo(
        center.dx,
        center.dy,
        center.dx - radius,
        center.dy,
      );
      path.quadraticBezierTo(
        center.dx,
        center.dy,
        center.dx,
        center.dy - radius,
      );
      path.close();
      canvas.drawPath(path, paint);
    }

    // 4개의 별 구조 배치
    drawSparkle(
      Offset(size.width * 0.42, size.height * 0.42),
      size.width * 0.36,
    );
    drawSparkle(
      Offset(size.width * 0.78, size.height * 0.24),
      size.width * 0.16,
    );
    drawSparkle(
      Offset(size.width * 0.76, size.height * 0.76),
      size.width * 0.15,
    );
    drawSparkle(
      Offset(size.width * 0.22, size.height * 0.78),
      size.width * 0.13,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ============================================================================
// 6. MAIN SCREEN (홈 화면)
// ============================================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final NutrackerController _controller = NutrackerController();
  final ImagePicker _picker = ImagePicker();
  final ScrollController _dateScrollCtrl = ScrollController();
  bool _isLoadingAi = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onStateChanged);
    // 첫 렌더링 후 날짜 리스트의 가장 오른쪽('오늘' 블럭)으로 자동 스크롤
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_dateScrollCtrl.hasClients) {
        _dateScrollCtrl.jumpTo(_dateScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onStateChanged);
    _dateScrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 앱 복귀 시 리셋 시간이 지났는지 체크하여 새 오늘 블럭 생성
      _controller.checkResetTimeAndRefresh();
    }
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  List<DateTime> _getRecentDates() {
    final today = _controller.getLogicalToday();
    final todayKey = _controller.dateKey(today);

    // 저장된 기록이 있는 날짜들과 오늘 날짜만 합쳐서 정렬
    final dateKeys = <String>{..._controller.dailyLogs.keys, todayKey};
    final dates = dateKeys
        .map((k) => DateTime.tryParse(k))
        .whereType<DateTime>()
        .toList();

    dates.sort((a, b) => a.compareTo(b));
    return dates;
  }

  void _openFoodFormModal(
    List<FoodItem> drafts, {
    required String title,
    FoodItem? editingOriginal,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiFoodFormSheet(
        initialDrafts: drafts,
        title: title,
        onSave: (savedItems) {
          if (editingOriginal != null && savedItems.isNotEmpty) {
            _controller.updateFood(_controller.selectedDate, savedItems.first);
          } else {
            _controller.addFoodsToSelectedDate(savedItems);
          }
        },
      ),
    );
  }

  Future<void> _handleAiCamera() async {
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );
    if (photo == null) return;
    final bytes = await photo.readAsBytes();
    await _runAiAnalysis(images: [bytes], title: 'AI 카메라 분석 결과');
  }

  Future<void> _handleAiImages() async {
    final List<XFile> photos = await _picker.pickMultiImage(imageQuality: 80);
    if (photos.isEmpty) return;
    final bytesList = <Uint8List>[];
    for (var p in photos) {
      bytesList.add(await p.readAsBytes());
    }
    await _runAiAnalysis(
      images: bytesList,
      title: 'AI 이미지 분석 (${photos.length}장)',
    );
  }

  Future<void> _handleAiChat() async {
    final promptCtrl = TextEditingController();
    final prompt = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                GeminiFourStarIcon(size: 20, color: Colors.white),
                SizedBox(width: 8),
                Text(
                  'AI 식단 채팅 입력',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '먹은 음식들을 자유롭게 적어주세요. 여러 음식을 말하면 자동으로 여러 카드 탭으로 분리됩니다.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: promptCtrl,
              maxLines: 3,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '예: 서브웨이 로스트치킨 15cm 하나랑 아메리카노, 프로틴바 1개 먹었어',
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF1A1A1A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, promptCtrl.text),
                child: const Text(
                  'AI로 영양성분 추론하기',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (prompt == null || prompt.trim().isEmpty) return;
    await _runAiAnalysis(userPrompt: prompt, title: 'AI 채팅 분석 결과');
  }

  Future<void> _runAiAnalysis({
    String? userPrompt,
    List<Uint8List>? images,
    required String title,
  }) async {
    setState(() => _isLoadingAi = true);
    try {
      final results = await GeminiService.analyzeFood(
        apiKey: _controller.apiKey,
        modelName: _controller.modelName,
        userPrompt: userPrompt,
        images: images,
      );
      if (!mounted) return;
      _openFoodFormModal(results, title: title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _isLoadingAi = false);
    }
  }

  /// 먹은 음식 클릭 시 상세 영양성분 표 + 수정/삭제/즐겨찾기 추가 모달
  void _showFoodDetailSheet(FoodItem food) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0E0E0E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) {
        final timeStr =
            '${food.timestamp.hour.toString().padLeft(2, '0')}:${food.timestamp.minute.toString().padLeft(2, '0')}';

        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          food.name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '섭취 시간 · $timeStr',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 즐겨찾기 추가 버튼 (중복 이름 방지)
                  OutlinedButton.icon(
                    onPressed: () {
                      final added = _controller.addToFavorites(food);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            added
                                ? '\'${food.name}\'이(가) 즐겨찾기에 추가되었습니다.'
                                : '이미 동일한 이름의 음식이 즐겨찾기에 있습니다.',
                          ),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.star_border_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                    label: const Text(
                      '즐겨찾기 추가',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF333333)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Divider(color: Color(0xFF222222), height: 1),
              const SizedBox(height: 14),
              // 상세 영양성분 표
              ...NutrientType.values.map((t) {
                final val = food.nutrients[t] ?? 0;
                return Padding(
                  padding: EdgeInsets.only(
                    left: t.isSubItem ? 16.0 : 0.0,
                    bottom: 8.0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${t.isSubItem ? "└ " : ""}${t.label}',
                        style: TextStyle(
                          color: t.isSubItem ? Colors.white54 : Colors.white,
                          fontSize: t.isSubItem ? 13 : 14,
                          fontWeight: t.isSubItem
                              ? FontWeight.w400
                              : FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${val == val.roundToDouble() ? val.toInt() : val.toStringAsFixed(1)} ${t.unit}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openFoodFormModal(
                          [food],
                          title: '음식 정보 수정',
                          editingOriginal: food,
                        );
                      },
                      icon: const Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: Colors.white,
                      ),
                      label: const Text(
                        '수정',
                        style: TextStyle(color: Colors.white),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: const BorderSide(color: Color(0xFF333333)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        _controller.deleteFood(
                          _controller.selectedDate,
                          food.id,
                        );
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      label: const Text(
                        '삭제',
                        style: TextStyle(color: Colors.white),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2B1212),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final selDate = _controller.selectedDate;
    final foods = _controller.getFoodsForDate(selDate);
    final totals = _controller.getTotalsForDate(selDate);
    final recentDates = _getRecentDates();

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                // 1. 상단 헤더: Nutracker 타이틀, 날짜, 설정 버튼
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 14, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Nutracker',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.8,
                          color: Colors.white,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF141414),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF292929),
                              ),
                            ),
                            child: Text(
                              '${selDate.year}.${selDate.month.toString().padLeft(2, '0')}.${selDate.day.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      SettingsScreen(controller: _controller),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.settings_outlined,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 2. 날짜별 블럭 영역 (드래그 이동 및 3단계 목표 도달 시각적 분리)
                SizedBox(
                  height: 76,
                  child: ListView.builder(
                    controller: _dateScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    itemCount: recentDates.length,
                    itemBuilder: (context, idx) {
                      final d = recentDates[idx];
                      final isSelected =
                          _controller.dateKey(d) ==
                          _controller.dateKey(selDate);
                      final status = _controller.getGoalStatusForDate(d);
                      final isToday =
                          _controller.dateKey(d) ==
                          _controller.dateKey(_controller.getLogicalToday());

                      return GestureDetector(
                        onTap: () => _controller.selectDate(d),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: 52,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF111111),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.white
                                  : status.color.withAlpha(140),
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                isToday ? '오늘' : '${d.month}/${d.day}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isSelected
                                      ? Colors.black
                                      : Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Icon(status.icon, size: 16, color: status.color),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // 3. 메인 스크롤 영역 (영양정보 블럭 + 먹은 음식 스택 리스트)
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        NutrientDashboardBlock(
                          totals: totals,
                          configs: _controller.nutrientConfigs,
                        ),
                        const SizedBox(height: 28),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '오늘 먹은 음식',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              '총 ${foods.length}건',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Divider(color: Color(0xFF222222), height: 1),
                        if (foods.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 42),
                            child: Center(
                              child: Text(
                                '아직 기록된 음식이 없습니다.\n우측 하단 + 버튼을 눌러 식단을 추가해보세요.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white30,
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          )
                        else
                          // 밑에서부터 쌓이는 스택 구조 표현 (최신순/역순 나열 및 선 구분)
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: foods.length,
                            itemBuilder: (context, index) {
                              final item = foods[foods.length - 1 - index];
                              return FoodLineItem(
                                food: item,
                                onTap: () => _showFoodDetailSheet(item),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // AI 분석 로딩 오버레이
          if (_isLoadingAi)
            Container(
              color: Colors.black87,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Gemini AI가 음식과 영양성분을 분석하고 있습니다...',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: ExpandableNutrackerFab(
        onManualWrite: () => _openFoodFormModal([], title: '직접 음식 작성'),
        onFavorites: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FavoritesScreen(controller: _controller),
            ),
          );
        },
        onAiCamera: _handleAiCamera,
        onAiImage: _handleAiImages,
        onAiChat: _handleAiChat,
      ),
    );
  }
}

// ============================================================================
// 7. FAVORITES SCREEN (즐겨찾기 화면 - 추가 버튼 없음, 메인과 동일한 선 구분 리스트)
// ============================================================================

class FavoritesScreen extends StatefulWidget {
  final NutrackerController controller;

  const FavoritesScreen({super.key, required this.controller});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final favs = widget.controller.favorites;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          '즐겨찾기 음식',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
      ),
      body: favs.isEmpty
          ? const Center(
              child: Text(
                '저장된 즐겨찾기 음식이 없습니다.\n메인 화면 하단의 먹은 음식을 클릭하여\n즐겨찾기에 추가할 수 있습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: favs.length,
              itemBuilder: (context, idx) {
                final item = favs[idx];
                return FoodLineItem(
                  food: item,
                  showTime: false,
                  onTap: () {
                    final cloned = item.copyWith(
                      id: DateTime.now().microsecondsSinceEpoch.toString(),
                      timestamp: DateTime.now(),
                    );
                    widget.controller.addFoodsToSelectedDate([cloned]);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('\'${item.name}\'이(가) 오늘 식단에 추가되었습니다.'),
                      ),
                    );
                  },
                  trailingAction: IconButton(
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.white38,
                      size: 20,
                    ),
                    onPressed: () =>
                        widget.controller.removeFromFavorites(item.id),
                  ),
                );
              },
            ),
    );
  }
}

// ============================================================================
// 8. SETTINGS SCREEN (Gemini API, 리셋 시간, 영양정보별 활성화 및 min/max 설정)
// ============================================================================

class SettingsScreen extends StatefulWidget {
  final NutrackerController controller;

  const SettingsScreen({super.key, required this.controller});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _modelCtrl;
  late TimeOfDay _resetTime;

  final Map<NutrientType, bool> _enabledMap = {};
  final Map<NutrientType, TextEditingController> _minCtrls = {};
  final Map<NutrientType, TextEditingController> _maxCtrls = {};

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController(text: widget.controller.apiKey);
    _modelCtrl = TextEditingController(text: widget.controller.modelName);
    _resetTime = widget.controller.resetTime;

    for (var t in NutrientType.values) {
      final cfg = widget.controller.nutrientConfigs[t]!;
      _enabledMap[t] = cfg.enabled;
      _minCtrls[t] = TextEditingController(
        text: cfg.min != null ? cfg.min!.toStringAsFixed(0) : '',
      );
      _maxCtrls[t] = TextEditingController(
        text: cfg.max != null ? cfg.max!.toStringAsFixed(0) : '',
      );
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    for (var c in _minCtrls.values) {
      c.dispose();
    }
    for (var c in _maxCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _saveSettings() {
    final newConfigs = <NutrientType, NutrientConfig>{};
    for (var t in NutrientType.values) {
      final minVal = double.tryParse(_minCtrls[t]!.text.trim());
      final maxVal = double.tryParse(_maxCtrls[t]!.text.trim());
      newConfigs[t] = NutrientConfig(
        enabled: _enabledMap[t] ?? true,
        min: minVal,
        max: maxVal,
      );
    }

    widget.controller.updateSettings(
      newApiKey: _apiKeyCtrl.text,
      newModelName: _modelCtrl.text,
      newResetTime: _resetTime,
      newConfigs: newConfigs,
    );

    Navigator.pop(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('설정이 저장되었습니다.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          '설정',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _saveSettings,
            child: const Text(
              '저장',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          const Text(
            'Gemini AI 연동 설정',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Gemini AI API Key',
              filled: true,
              fillColor: const Color(0xFF121212),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: InputDecoration(
              labelText: 'Gemini 모델명 (예: gemini-3.8-flash)',
              filled: true,
              fillColor: const Color(0xFF121212),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Divider(color: Color(0xFF222222)),
          const SizedBox(height: 16),

          // 리셋 시간 설정 (기본값 AM 4:00)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '일일 리셋 시간 설정',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '지정된 시간이 지나면 새 날짜 블럭이 생성됩니다.',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: _resetTime,
                  );
                  if (picked != null) {
                    setState(() => _resetTime = picked);
                  }
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF333333)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  _resetTime.format(context),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
          const Divider(color: Color(0xFF222222)),
          const SizedBox(height: 16),
          const Text(
            '영양정보 표시 및 목표치 (Min / Max) 설정',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            '비활성화 시 홈 화면에 표시되지 않습니다. Min/Max는 둘 중 하나만 입력하거나 모두 비워둘 수 있습니다.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),

          ...NutrientType.values.map((t) {
            final isEnabled = _enabledMap[t] ?? true;
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF222222)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: t.pointColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${t.label} (${t.unit})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      Switch(
                        value: isEnabled,
                        activeColor: Colors.white,
                        activeTrackColor: t.pointColor,
                        onChanged: (v) => setState(() => _enabledMap[t] = v),
                      ),
                    ],
                  ),
                  if (isEnabled) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _minCtrls[t],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: '최소 (Min)',
                              hintText: '미설정',
                              isDense: true,
                              filled: true,
                              fillColor: const Color(0xFF1A1A1A),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _maxCtrls[t],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: '최대 (Max)',
                              hintText: '미설정',
                              isDense: true,
                              filled: true,
                              fillColor: const Color(0xFF1A1A1A),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
