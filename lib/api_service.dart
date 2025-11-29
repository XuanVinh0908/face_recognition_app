import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'models.dart';

class ApiService {
  final String _baseUrl = 'https://enumberjsc.com:8080/API'; 

  Future<Employee?> getUserData(String userId) async {
    try {
      final uri = Uri.parse('$_baseUrl/LAY_FACEID?nhanvien=$userId');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return Employee.fromJson(data, defaultUserId: userId);
      } else {
        print('Lỗi user: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('Exception user: $e');
      return null;
    }
  }

  // Hàm đăng ký (Vẫn nhận ảnh String)
  Future<bool> registerFaceAndLocation(String userId, List<double> descriptor, String imageBase64) async {
    try {
      final hexFaceId = _encodeFaceDescriptorToHex(descriptor);
      final uri = Uri.parse('$_baseUrl/DANGKY');
      
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'nhanvien': int.tryParse(userId) ?? 0,
          'fileName': hexFaceId,
          'anhDangKyBase64': imageBase64,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // --- QUAN TRỌNG: HÀM NÀY PHẢI NHẬN INT STATUS ---
  Future<bool> saveCheckIn(String userId, int status) async {
    try {
      final uri = Uri.parse('$_baseUrl/PUT_CHAMCONG');
      
      print("API: Chấm công NV $userId - Trạng thái: $status");

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'nhanvien': int.tryParse(userId) ?? 0,
          'trangthai': status, // Gửi 0 hoặc 1
        }),
      );

      print("Response: ${response.statusCode}");
      return response.statusCode == 200;
    } catch (e) {
      print('Exception checkin: $e');
      return false;
    }
  }
  // ------------------------------------------------

  Future<bool> updateThreshold(String userId, double newThreshold) async {
     // ... (Giữ nguyên logic cập nhật nếu có)
     return true;
  }

  String _encodeFaceDescriptorToHex(List<double> descriptor) {
    final byteData = ByteData(descriptor.length * 4);
    for (int i = 0; i < descriptor.length; i++) {
      byteData.setFloat32(i * 4, descriptor[i], Endian.little);
    }
    final bytes = byteData.buffer.asUint8List();
    return '0x${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join('')}'.toUpperCase();
  }
}