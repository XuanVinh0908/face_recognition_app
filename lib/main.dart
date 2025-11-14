import 'package:flutter/material.dart';
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
      // Điểm khởi đầu của ứng dụng là AppInitializer
      // Nó sẽ quyết định hiển thị trang nào dựa trên URL
      home: const AppInitializer(), 
    );
  }
}