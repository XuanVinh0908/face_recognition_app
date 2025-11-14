import 'package:flutter/material.dart';
import 'package:js/js.dart';
import 'models.dart';
import 'api_service.dart';
import 'registration_page.dart';
import 'verification_page.dart';

@JS()
external Future<bool> loadModels();

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

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

  // --- HÀM KHỞI TẠO ĐÃ ĐƯỢC TÁI CẤU TRÚC ĐỂ CHẠY TUẦN TỰ ---
  Future<void> _initializeApp() async {
    final uri = Uri.base;
    final path = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final userId = uri.queryParameters['id'];

    if (userId == null) {
      setState(() => _status = "Lỗi: Thiếu ID nhân viên trên URL.");
      return;
    }
    
    // Bước 1: Tải dữ liệu người dùng trước
    setState(() => _status = "Bước 1/2: Đang tải dữ liệu người dùng...");
    final employee = await ApiService().getUserData(userId);
    
    if (!mounted) return;
    if (employee == null) {
      // Nếu không tải được user, dừng lại và báo lỗi
      setState(() => _status = "Lỗi: Không thể tải dữ liệu người dùng từ server. Vui lòng kiểm tra lại API.");
      return;
    }

    // Bước 2: Nếu tải user thành công, tiếp tục tải model AI
    setState(() => _status = "Bước 2/2: Đang tải model nhận dạng...");
    final modelsLoaded = await loadModels();

    if (!mounted) return;
    if (!modelsLoaded) {
      setState(() => _status = "Lỗi: Không thể tải model nhận dạng.");
      return;
    }
    
    // Nếu tất cả thành công, điều hướng đến trang phù hợp
    if (path.toLowerCase() == 'register') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => RegistrationPage(currentUser: employee)),
      );
    } else if (path.toLowerCase() == 'verify') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => VerificationPage(currentUser: employee)),
      );
    } else {
      setState(() => _status = "Lỗi: Chức năng không hợp lệ. URL phải là /register hoặc /verify.");
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