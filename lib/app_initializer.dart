import 'package:flutter/material.dart';
import 'package:js/js.dart';
import 'models.dart';
import 'api_service.dart';
import 'registration_page.dart';
import 'verification_page.dart';

@JS()
external Future<bool> loadModels();

class AppInitializer extends StatefulWidget {
  final int attendanceMode; // Nhận từ Main
  final String? userId; // Nhận từ Main (nếu có)

  const AppInitializer({
    super.key, 
    required this.attendanceMode,
    this.userId, // Có thể null nếu logic check ở Main
  });

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer> {
  String _status = "Đang khởi tạo...";

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final uri = Uri.base;
    final pathString = uri.toString(); 
    
    // Ưu tiên lấy ID từ widget truyền vào, nếu không có thì lấy từ URL
    final userId = widget.userId ?? uri.queryParameters['id'];

    if (userId == null) {
      setState(() => _status = "Lỗi: Thiếu ID nhân viên trên URL.");
      return;
    }
    
    setState(() => _status = "Bước 1/2: Đang tải dữ liệu người dùng...");
    final employee = await ApiService().getUserData(userId);
    
    if (!mounted) return;
    if (employee == null) {
      setState(() => _status = "Lỗi: Không thể tải dữ liệu người dùng.");
      return;
    }

    setState(() => _status = "Bước 2/2: Đang tải model nhận dạng...");
    final modelsLoaded = await loadModels();

    if (!mounted) return;
    if (!modelsLoaded) {
      setState(() => _status = "Lỗi: Không thể tải model nhận dạng.");
      return;
    }
    
    // Điều hướng
    if (pathString.contains('register')) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => RegistrationPage(currentUser: employee)),
      );
    } else {
      // --- SỬA LỖI TẠI ĐÂY ---
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => VerificationPage(
          currentUser: employee,
          // Phải truyền tham số này vào:
          attendanceMode: widget.attendanceMode, 
        )),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_status.contains("Lỗi")) const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status, style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}