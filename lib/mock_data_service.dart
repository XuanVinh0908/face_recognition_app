import 'dart:convert';
import 'dart:html' as html;
import 'package:geolocator/geolocator.dart';

// Lớp CheckInResult để đóng gói dữ liệu chấm công
class CheckInResult {
  final List<double> faceDescriptor;
  final DateTime timestamp;
  final double latitude;
  final double longitude;

  CheckInResult({
    required this.faceDescriptor,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
  });

  Map<String, dynamic> toJson() {
    return {
      'faceDescriptor': faceDescriptor,
      'timestamp': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
    };
  }
  
  factory CheckInResult.fromJson(Map<String, dynamic> json) {
    return CheckInResult(
      faceDescriptor: List<double>.from(json['faceDescriptor'].map((x) => (x as num).toDouble())),
      timestamp: DateTime.parse(json['timestamp']),
      latitude: json['latitude'],
      longitude: json['longitude'],
    );
  }
}

// Lớp Employee đại diện cho cấu trúc dữ liệu của một nhân viên
class Employee {
  final String userId;
  final String userName;
  List<double>? faceDescriptor;
  double allowedLatitude;
  double allowedLongitude;
  double allowedDistance;
  List<CheckInResult> checkInHistory;

  Employee({
    required this.userId,
    required this.userName,
    this.faceDescriptor,
    required this.allowedLatitude,
    required this.allowedLongitude,
    required this.allowedDistance,
    List<CheckInResult>? checkInHistory,
  }) : checkInHistory = checkInHistory ?? [];

  factory Employee.fromJson(Map<String, dynamic> json) {
    var historyFromJson = json['checkInHistory'] as List<dynamic>?;
    List<CheckInResult> historyList = historyFromJson != null
        ? historyFromJson.map((i) => CheckInResult.fromJson(i)).toList()
        : [];

    return Employee(
      userId: json['userId'],
      userName: json['userName'],
      faceDescriptor: json['faceDescriptor'] != null
          ? List<double>.from(json['faceDescriptor'].map((x) => (x as num).toDouble()))
          : null,
      allowedLatitude: json['allowedLatitude'],
      allowedLongitude: json['allowedLongitude'],
      allowedDistance: json['allowedDistance'],
      checkInHistory: historyList,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'userName': userName,
      'faceDescriptor': faceDescriptor,
      'allowedLatitude': allowedLatitude,
      'allowedLongitude': allowedLongitude,
      'allowedDistance': allowedDistance,
      'checkInHistory': checkInHistory.map((i) => i.toJson()).toList(),
    };
  }
}

// Lớp dịch vụ quản lý "cơ sở dữ liệu giả lập"
class MockDataService {
  static const _storageKey = 'mock_employee_db';
  Map<String, Employee> _database = {};

  MockDataService() {
    _loadDatabase();
  }

  void _loadDatabase() {
    final String? jsonData = html.window.localStorage[_storageKey];
    if (jsonData != null && jsonData.isNotEmpty) {
      final Map<String, dynamic> decodedData = jsonDecode(jsonData);
      _database = decodedData.map(
        (key, value) => MapEntry(key, Employee.fromJson(value)),
      );
    } else {
      _createInitialData();
      _saveDatabase();
    }
  }

  void _saveDatabase() {
    final Map<String, dynamic> encodableData = _database.map(
      (key, value) => MapEntry(key, value.toJson()),
    );
    html.window.localStorage[_storageKey] = jsonEncode(encodableData);
  }

  void _createInitialData() {
    _database['NV001'] = Employee(
      userId: 'NV001',
      userName: 'Nguyễn Văn A',
      allowedLatitude: 20.8561,
      allowedLongitude: 106.6822,
      allowedDistance: 20000,
    );
    _database['NV002'] = Employee(
      userId: 'NV002',
      userName: 'Trần Thị B',
      allowedLatitude: 21.0285,
      allowedLongitude: 105.8542,
      allowedDistance: 500,
    );
  }
  
  Employee? getEmployeeById(String userId) {
    return _database[userId];
  }

  // Hàm để lưu đồng thời cả khuôn mặt và vị trí
  void registerFaceAndLocation(String userId, List<double> descriptor, Position position) {
    if (_database.containsKey(userId)) {
      final user = _database[userId]!;
      user.faceDescriptor = descriptor;
      user.allowedLatitude = position.latitude;
      user.allowedLongitude = position.longitude;
      
      _saveDatabase();
      print('Đã đăng ký khuôn mặt và vị trí cho nhân viên ${userId}');
    }
  }

  // Hàm để thêm một lượt chấm công cho nhân viên
  void addCheckIn(String userId, CheckInResult result) {
    if (_database.containsKey(userId)) {
      _database[userId]!.checkInHistory.add(result);
      _saveDatabase();
      print('Đã ghi nhận chấm công cho ${userId} vào database giả lập.');
      print('Tổng số lượt chấm công: ${_database[userId]!.checkInHistory.length}');
    }
  }
}