import 'dart:typed_data';

// Lớp mới để chứa cả vector khuôn mặt và ảnh Base64
class FaceProcessingResult {
  final List<double>? descriptor;
  final String? imageBase64;

  FaceProcessingResult({this.descriptor, this.imageBase64});
}

// ĐÃ KHÔI PHỤC LẠI: Lớp này cần thiết cho các tính năng khác
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

  @override
  String toString() {
    return 'CheckInResult(timestamp: $timestamp, location: $latitude,$longitude)';
  }
}

class Employee {
  final String userId;
  final String userName;
  List<double>? faceDescriptor;
  double allowedLatitude;
  double allowedLongitude;
  double allowedDistance;

  Employee({
    required this.userId,
    required this.userName,
    this.faceDescriptor,
    required this.allowedLatitude,
    required this.allowedLongitude,
    required this.allowedDistance,
  });

  factory Employee.fromJson(Map<String, dynamic> json, {String? defaultUserId}) {
    return Employee(
      userId: defaultUserId ?? json['id']?.toString() ?? 'Unknown',
      userName: json['userName'] ?? defaultUserId ?? 'Unknown',
      faceDescriptor: decodeFaceDescriptorFromHex(json['anhdangky']),
      allowedLatitude: (json['x'] as num).toDouble(),
      allowedLongitude: (json['y'] as num).toDouble(),
      allowedDistance: (json['distance'] as num?)?.toDouble() ?? 2000.0,
    );
  }
}

List<double>? decodeFaceDescriptorFromHex(String? hexString) {
  if (hexString == null || hexString.isEmpty || hexString.toLowerCase() == "null") {
    return null;
  }
  try {
    final cleanHex = hexString.startsWith('0x') ? hexString.substring(2) : hexString;
    final bytes = <int>[];
    for (int i = 0; i < cleanHex.length; i += 2) {
      bytes.add(int.parse(cleanHex.substring(i, i + 2), radix: 16));
    }
    final byteData = Uint8List.fromList(bytes).buffer.asByteData();
    
    final descriptor = <double>[];
    for (int i = 0; i < byteData.lengthInBytes; i += 4) {
      descriptor.add(byteData.getFloat32(i, Endian.little));
    }
    return descriptor;
  } catch (e) {
    print("Lỗi khi giải mã faceid hex: $e");
    return null;
  }
}