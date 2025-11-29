import 'package:flutter/material.dart';
import 'dart:html' as html; // Dùng để đọc URL trình duyệt
import 'app_initializer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Recognition App',
      theme: ThemeData(primarySwatch: Colors.blue),
      // QUAN TRỌNG: Gọi MainRouter chứ KHÔNG gọi AppInitializer trực tiếp
      home: const MainRouter(), 
    );
  }
}

// Widget trung gian để xử lý URL trước khi vào App
class MainRouter extends StatefulWidget {
  const MainRouter({super.key});

  @override
  State<MainRouter> createState() => _MainRouterState();
}

class _MainRouterState extends State<MainRouter> {
  // Mặc định là 0 (Chấm VÀO)
  int attendanceMode = 0; 

  @override
  void initState() {
    super.initState();
    _checkUrlForMode();
  }

  void _checkUrlForMode() {
    // Lấy toàn bộ đường dẫn hiện tại
    final currentUrl = html.window.location.href;
    
    // Logic xác định chế độ:
    // Nếu link chứa 'verifyOut' -> Chế độ 1 (RA)
    // Ngược lại -> Chế độ 0 (VÀO)
    if (currentUrl.contains('verifyOut')) {
      attendanceMode = 1; 
    } else {
      attendanceMode = 0; 
    }
    
    print("MainRouter: Phát hiện chế độ chấm công = $attendanceMode (${attendanceMode == 0 ? 'Vào' : 'Ra'})");
  }

  @override
  Widget build(BuildContext context) {
    // Truyền tham số bắt buộc attendanceMode vào AppInitializer
    return AppInitializer(attendanceMode: attendanceMode);
  }
}