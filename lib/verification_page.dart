import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart'; 
import 'dart:ui_web' as ui_web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsutil;
import 'models.dart';
import 'api_service.dart';
import 'version_info.dart';

@JS()
external void getFaceDescriptor(String imageBase64, Object callback);

@JS()
external void stopRealtimeDetection();

@JS() 
external void closeWindow(); 

// --- WRAPPERS ---
Future<bool> loadModels() async {
  try {
    final promise = jsutil.callMethod(html.window, 'loadModels', []);
    await jsutil.promiseToFuture(promise); 
    return true;
  } catch (e) { return false; }
}

Future<bool> startCamera(String videoElementId, Function onFaceDetected, Function onBlinkDetected) async {
  try {
    final promise = jsutil.callMethod(html.window, 'startCamera', [
      videoElementId, 
      onFaceDetected, 
      onBlinkDetected
    ]);
    await jsutil.promiseToFuture(promise);
    return true;
  } catch (e) { return false; }
}

class VerificationPage extends StatefulWidget {
  final Employee currentUser;
  final int attendanceMode; 

  const VerificationPage({super.key, required this.currentUser, required this.attendanceMode});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  final String _displayVersion = appVersion;
  String _status = 'Khởi tạo...';
  Color _statusColor = Colors.black;

  // LOG DEBUG HIỂN THỊ TRÊN MÀN HÌNH
  String _debugText = "";

  late html.VideoElement _videoElement;
  
  // Biến này chỉ dùng để chặn xử lý chồng chéo (1 frame xử lý xong mới nhận frame tiếp)
  bool _isProcessingFrame = false; 

  // Logic Mobile
  bool get _isMobile => html.window.innerWidth! < html.window.innerHeight!;
  double get _processingWidth => _isMobile ? 360 : 480;
  double get _processingHeight => _isMobile ? 480 : 360;

  late final String _viewId;
  
  // Chỉ dùng để hiển thị ảnh khi ĐÃ THÀNH CÔNG
  Image? _capturedWidget; 
  String? _capturedBase64; 
  
  bool _areModelsLoaded = false;
  bool _isSuccess = false; 
  
  // Chỉ hiện nút thử lại khi có lỗi kỹ thuật (Camera, Model), không phải lỗi do mặt sai
  bool _isTechnicalError = false;

  @override
  void initState() {
    super.initState();
    String modeName = widget.attendanceMode == 0 ? "VÀO" : "RA";
    _status = 'Chấm công $modeName...';

    _viewId = 'video-view-ver-${DateTime.now().millisecondsSinceEpoch}';
    _videoElement = html.VideoElement()
      ..id = _viewId
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true')
      ..style.transform = 'scaleX(-1)'; 
      
      _videoElement.style.objectFit = 'cover'; 
      _videoElement.style.width = '100%';
      _videoElement.style.height = '100%';

    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAndStartVerification();
    });
  }
  
  @override
  void dispose() {
    stopRealtimeDetection();
    try { _videoElement.srcObject?.getTracks().forEach((track) => track.stop()); } catch (e) {}
    super.dispose();
  }
  
  Future<void> _initializeAndStartVerification() async {
    setState(() {
      _isProcessingFrame = true; // Chặn tạm thời
      _status = 'Đang tải dữ liệu...';
    });
    
    _areModelsLoaded = await loadModels();
    
    if (!mounted) return;
    if (!_areModelsLoaded) {
      setState(() {
        _status = 'Lỗi! Không thể tải AI.';
        _isTechnicalError = true;
        _isProcessingFrame = false;
      });
      return;
    }
    
    // Mở khóa
    setState(() => _isProcessingFrame = false);
    _startVerificationProcess();
  }
  
  // --- HÀM KHỞI ĐỘNG ---
  Future<void> _startVerificationProcess() async {
    if (_videoElement.srcObject != null) {
       try { _videoElement.play(); } catch(e) {}
    }

    setState(() {
      _isTechnicalError = false; 
      _isSuccess = false;
      _isProcessingFrame = false; // Sẵn sàng nhận Frame
      _capturedWidget = null; 
      _capturedBase64 = null;
      _statusColor = Colors.black;
      _status = "Đưa mặt vào khung tròn...";
      _debugText = "";
    });

    if (!mounted) return;
    _runRealtimeLoop();
  }

  Future<void> _runRealtimeLoop() async {
    if (_isSuccess) return;

    final onVectorDetected = jsutil.allowInterop((dynamic descriptorJS) async {
      // Nếu đang xử lý frame trước, hoặc đã xong, hoặc lỗi kỹ thuật -> Bỏ qua frame này
      if (!mounted || _isSuccess || _isProcessingFrame || _isTechnicalError) return;

      if (descriptorJS != null) {
        // === CÓ VECTOR TỪ JS TRẢ VỀ ===
        _processVector(descriptorJS);
      } else {
        // JS vẫn đang chạy nhưng chưa bắt được mặt (hoặc mặt chưa rõ)
        // Ta chỉ cập nhật trạng thái nhẹ nhàng, KHÔNG DỪNG
        // setState(() => _status = "Đang tìm khuôn mặt...");
      }
    });

    final cameraStarted = await startCamera(_viewId, onVectorDetected, jsutil.allowInterop(() {}));
    
    if (!mounted) return;
    if (_isSuccess) return; 

    if (!cameraStarted) {
      setState(() {
        _status = 'Lỗi Camera.';
        _isTechnicalError = true;
      });
    }
  }

  // --- XỬ LÝ VECTOR (LIÊN TỤC) ---
  void _processVector(dynamic descriptorJS) async {
    // Khóa lại để xử lý frame này
    setState(() => _isProcessingFrame = true);

    try {
      // 1. Parse Vector
      final List<double> currentVector = (jsutil.dartify(descriptorJS) as List)
          .map((e) => (e as num).toDouble())
          .toList();

      if (widget.currentUser.faceDescriptor == null) {
         setState(() {
            _status = "Lỗi: User chưa có dữ liệu gốc.";
            _isTechnicalError = true;
         });
         return;
      }

      // 2. So sánh
      final distance = _calculateDistance(widget.currentUser.faceDescriptor!, currentVector);
      
      // Cập nhật Debug Info (Real-time)
      setState(() => _debugText = "Sai số: ${distance.toStringAsFixed(3)}");

      // 3. Kiểm tra kết quả
      if (distance < 0.5) {
        // === KHỚP ===
        // CHỈ DỪNG KHI KHỚP
        _isSuccess = true;
        stopRealtimeDetection(); // Dừng JS
        
        // Chụp một bức ảnh cuối cùng để làm bằng chứng (nếu cần) và để UI đẹp
        _captureFrameAndShow();

        setState(() {
           _status = "Khớp (${distance.toStringAsFixed(2)})! Đang chấm công...";
           _statusColor = Colors.blue;
        });
        
        // Gọi API
        final success = await ApiService().saveCheckIn(widget.currentUser.userId, widget.attendanceMode);
        
        if (!mounted) return;

        if (success) {
           _handleSuccess(); 
        } else {
           // Lỗi Server -> Dừng lại báo lỗi
           setState(() {
             _status = "Lỗi kết nối Server.";
             _isTechnicalError = true; 
             _isSuccess = false; // Reset success để cho phép thử lại
           });
        }

      } else {
        // === KHÔNG KHỚP ===
        // QUAN TRỌNG: KHÔNG DỪNG LẠI.
        // Chỉ hiện thông báo và MỞ KHÓA để nhận frame tiếp theo ngay lập tức
        setState(() {
          _status = "Chưa khớp... Đang quét tiếp";
          _statusColor = Colors.orange;
          _isProcessingFrame = false; // MỞ KHÓA NGAY
        });
      }

    } catch (e) {
      print("Lỗi xử lý vector: $e");
      setState(() => _isProcessingFrame = false); // Mở khóa nếu lỗi
    }
  }

  void _captureFrameAndShow() {
    final int canvasW = _processingWidth.toInt();
    final int canvasH = _processingHeight.toInt();
    final canvas = html.CanvasElement(width: canvasW, height: canvasH);
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;

    ctx.translate(canvasW, 0);
    ctx.scale(-1, 1);

    // Vẽ video hiện tại vào canvas
    ctx.drawImageScaled(_videoElement, 0, 0, canvasW, canvasH);

    final imgData = canvas.toDataUrl('image/jpeg', 0.9);
    
    setState(() {
      _capturedBase64 = imgData;
      _capturedWidget = Image.network(imgData, fit: BoxFit.fill, gaplessPlayback: true);
    });
  }

  void _handleSuccess() async {
      if (!mounted) return;
      
      String modeName = widget.attendanceMode == 0 ? "VÀO" : "RA";
      setState(() {
           _status = "CHẤM CÔNG $modeName THÀNH CÔNG!";
           _statusColor = Colors.green;
      });
      
      // Tắt camera
      try { _videoElement.srcObject?.getTracks().forEach((track) => track.stop()); } catch(e){}

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) closeWindow(); 
  }
  
  double _calculateDistance(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) return 10.0;
    double sum = 0.0;
    for (int i = 0; i < v1.length; i++) {
      sum += math.pow((v1[i] - v2[i]), 2);
    }
    return math.sqrt(sum);
  }

  @override
  Widget build(BuildContext context) {
    // Chỉ ẩn video khi ĐÃ THÀNH CÔNG hoặc có lỗi kỹ thuật
    final bool showCameraView = _areModelsLoaded && !_isSuccess && !_isTechnicalError;
    
    return Scaffold(
      appBar: AppBar(title: Text('Chấm công: ${widget.currentUser.userName}')),
      body: Center(
        child: Column( 
          mainAxisAlignment: MainAxisAlignment.center,
          children: [ 
            ClipRect(
              child: SizedBox(
                width: _processingWidth,
                height: _processingHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Video luôn chạy cho đến khi thành công
                    Offstage(
                      offstage: !showCameraView, 
                      child: HtmlElementView(viewType: _viewId),
                    ),

                    // Chỉ hiện ảnh tĩnh khi đã thành công
                    if (_capturedWidget != null && (_isSuccess || _isTechnicalError))
                      Positioned.fill(child: _capturedWidget!),

                    if (!showCameraView && !_isSuccess && !_isTechnicalError)
                      Container(
                        decoration: BoxDecoration(color: Colors.grey[300]),
                        child: Center(child: const CircularProgressIndicator()),
                      ),
                    
                    // Khung tròn quét
                    if (showCameraView)
                      Center(
                        child: Container(
                          width: _processingWidth * 0.85,
                          height: _processingHeight * 0.85,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle, 
                            border: Border.all(
                                // Màu vàng: Đang quét | Màu xanh: Khớp
                                color: _isProcessingFrame ? Colors.blue : Colors.yellow, 
                                width: 8
                            ),
                          ),
                        ),
                      ),
                      
                    if (_isSuccess)
                      Container(
                        color: Colors.white, 
                        child: const Center(
                          child: Icon(Icons.check_circle, color: Colors.green, size: 100),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column( 
                children: [ 
                  Text(
                    _status, 
                    style: TextStyle(
                      fontSize: 18, 
                      fontWeight: FontWeight.bold,
                      color: _isSuccess ? Colors.green : _statusColor 
                    ), 
                    textAlign: TextAlign.center
                  ),
                  // Hiển thị sai số thực tế (nếu có)
                  if (_debugText.isNotEmpty && !_isSuccess)
                    Text(_debugText, style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            
            const SizedBox(height: 10),
            
            if (_isSuccess)
               Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text('Đóng Tab Ngay'),
                  onPressed: () => closeWindow(), 
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[700], foregroundColor: Colors.white),
                ),
              ),

            // Nút Thử Lại chỉ hiện khi có LỖI KỸ THUẬT
            if(_isTechnicalError)
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('THỬ LẠI'),
                onPressed: _startVerificationProcess, 
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),

            const SizedBox(height: 30),
            Text(
              _displayVersion,
              style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}