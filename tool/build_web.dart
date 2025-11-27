// tool/build_web.dart
import 'dart:io';

void main() async {
  // 1. Tạo chuỗi version dựa trên thời gian thực
  // Ví dụ: "1.0.20231127.1430" (NămThángNgày.GiờPhút)
  final now = DateTime.now();
  final String buildTime = "${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}.${_twoDigits(now.hour)}${_twoDigits(now.minute)}";
  final String versionString = "Ver: 1.0.$buildTime";

  print("🔄 Đang cập nhật version thành: $versionString");

  // 2. Ghi đè vào file lib/version_info.dart
  final File versionFile = File('lib/version_info.dart');
  await versionFile.writeAsString('const String appVersion = "$versionString";');

  print("✅ Đã cập nhật file version_info.dart");

  // 3. Chạy lệnh Flutter Build (Đã kèm tham số --base-href cho IIS)
  print("🚀 Bắt đầu Build Web...");
  
  var process = await Process.start(
    'flutter.bat', // Nếu dùng Mac/Linux thì đổi thành 'flutter'
    ['build', 'web', '--release', '--base-href', '/chamcong/'],
    runInShell: true,
  );

  stdout.addStream(process.stdout);
  stderr.addStream(process.stderr);

  final exitCode = await process.exitCode;
  if (exitCode == 0) {
    print("🎉 BUILD THÀNH CÔNG! (Version: $versionString)");
  } else {
    print("❌ Build thất bại.");
  }
}

String _twoDigits(int n) {
  if (n >= 10) return "$n";
  return "0$n";
}