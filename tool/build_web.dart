import 'dart:io';

void main() async {
  // 1. TẠO VERSION
  final now = DateTime.now();
  // Format: NămThángNgày.GiờPhút (Ví dụ: 20251127.1630)
  final String buildTime = "${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}.${_twoDigits(now.hour)}${_twoDigits(now.minute)}";
  
  // Chuỗi hiển thị trong App: "Ver: 1.0.20251127.1630"
  final String versionString = "Ver: 1.0.$buildTime";
  
  // Tên file ZIP: "web_v1.0.20251127.1630.zip" (Dùng cho tên file nên bỏ khoảng trắng)
  final String zipFileName = "web_v1.0.$buildTime.zip";

  print("🔄 [1/3] Đang cập nhật version: $versionString");

  // 2. GHI FILE VERSION
  final File versionFile = File('lib/version_info.dart');
  await versionFile.writeAsString('const String appVersion = "$versionString";');

  // 3. BUILD FLUTTER
  print("🚀 [2/3] Bắt đầu Build Web (Release Mode)...");
  
  // Xác định lệnh chạy tùy theo hệ điều hành
  var shell = Platform.isWindows ? 'cmd' : 'sh';
  var args = Platform.isWindows ? ['/c', 'flutter build web --release --base-href /chamcong/'] : ['-c', 'flutter build web --release --base-href /chamcong/'];

  var buildProcess = await Process.start(
    shell,
    args,
    runInShell: true,
  );

  // In log ra màn hình để theo dõi tiến độ
  stdout.addStream(buildProcess.stdout);
  stderr.addStream(buildProcess.stderr);

  final buildExitCode = await buildProcess.exitCode;

  if (buildExitCode == 0) {
    print("✅ Build xong. Bắt đầu nén...");
    
    // 4. NÉN THÀNH ZIP (Sử dụng lệnh tar có sẵn trên Mac/Win10+)
    print("📦 [3/3] Đang nén thư mục 'build/web' thành '$zipFileName'...");

    // Lệnh nén: tar -c -a -f [TênFileZip] -C [ThưMụcChứa] [ThưMụcCầnNén]
    // -C build: Chuyển vào thư mục build
    // web: Chỉ nén thư mục web
    var zipArgs = <String>[];
    if (Platform.isWindows) {
       // Windows: tar -a -c -f output.zip -C build web
       zipArgs = ['/c', 'tar -a -c -f $zipFileName -C build web'];
    } else {
       // Mac/Linux: tar -czf output.zip -C build web
       zipArgs = ['-c', 'tar -czf $zipFileName -C build web'];
    }

    var zipProcess = await Process.start(shell, zipArgs);
    await zipProcess.exitCode;

    print("🎉 HOÀN TẤT! File nén nằm tại:");
    print("👉 ${Directory.current.path}/$zipFileName");
  } else {
    print("❌ Build thất bại. Không tạo file nén.");
  }
}

String _twoDigits(int n) {
  if (n >= 10) return "$n";
  return "0$n";
}