import 'package:flutter/material.dart';
import 'models.dart';
import 'api_service.dart';
import 'registration_page.dart';
import 'verification_page.dart';
import 'package:js/js.dart';

// Khai báo hàm JS loadModels chỉ ở đây
@JS()
external Future<bool> loadModels();

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ApiService _apiService = ApiService();
  Employee? _currentUser;
  String _status = "Đang khởi tạo ứng dụng...";
  // Biến mới để theo dõi trạng thái sẵn sàng của toàn hệ thống
  bool _isSystemReady = false; 

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  // Hàm khởi tạo mới: Tải tuần tự để dễ kiểm soát
  Future<void> _initializeApp() async {
    // Bước 1: Tải dữ liệu người dùng trước
    setState(() => _status = "Bước 1/2: Đang tải dữ liệu người dùng...");
    final userLoaded = await _loadUserData();
    
    if (!mounted) return;
    if (!userLoaded) {
      setState(() => _status = "Lỗi: Không thể tải dữ liệu người dùng từ server.");
      return;
    }

    // Bước 2: Nếu tải user thành công, tiếp tục tải model AI
    setState(() => _status = "Bước 2/2: Đang tải model nhận dạng...");
    final modelsLoaded = await loadModels();

    if (!mounted) return;
    if (modelsLoaded) {
      setState(() {
        _isSystemReady = true;
        _status = "Hệ thống đã sẵn sàng!";
      });
    } else {
      setState(() => _status = "Lỗi: Không thể tải model nhận dạng.");
    }
  }

  Future<bool> _loadUserData() async {
    final params = Uri.base.queryParameters;
    final userId = params['id'];
    if (userId == null) {
      return false;
    }
    
    final user = await _apiService.getUserData(userId);
    if (mounted && user != null) {
      setState(() => _currentUser = user);
      return true;
    }
    return false;
  }

  void _navigateToRegistration() async {
    if (_currentUser == null || !_isSystemReady) return;
    
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => RegistrationPage(
          currentUser: _currentUser!,
          apiService: _apiService,
        ),
      ),
    );

    if (result == true && mounted) {
      setState(() { _status = "Đang cập nhật dữ liệu mới..."; });
      final userLoaded = await _loadUserData();
       if (mounted && userLoaded) {
         setState(() { _status = "Hệ thống đã sẵn sàng!"; });
       }
    }
  }

  void _navigateToVerification() {
    if (_currentUser == null || !_isSystemReady) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VerificationPage(
          currentUser: _currentUser!,
          apiService: _apiService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trang Chấm Công'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_isSystemReady && !_status.contains("Lỗi")) const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _isSystemReady && _currentUser != null
                ? "Xin chào, ${_currentUser!.userName}"
                : _status,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            if (_isSystemReady && _currentUser != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  _currentUser!.faceDescriptor == null
                    ? "Bạn chưa đăng ký khuôn mặt."
                    : "Hệ thống đã sẵn sàng.",
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              icon: const Icon(Icons.person_add),
              label: const Text('Đăng Ký / Cập Nhật Khuôn Mặt'),
              onPressed: _isSystemReady ? _navigateToRegistration : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.touch_app),
              label: const Text('Thực Hiện Chấm Công'),
              onPressed: _isSystemReady && _currentUser?.faceDescriptor != null ? _navigateToVerification : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}