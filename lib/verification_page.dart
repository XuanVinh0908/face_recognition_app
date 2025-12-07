import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math; // Import chuẩn
import 'dart:ui' as ui;
import 'package:flutter/material.dart'; 
import 'dart:ui_web' as ui_web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsutil;
import 'models.dart';
import 'api_service.dart';
import 'version_info.dart';

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
  String _status = 'Đang khởi tạo...';
  Color _statusColor = Colors.black;

  // Debug info
  String _debugInfo = "";

  late html.VideoElement _videoElement;
  late final String _viewId;
  
  bool _areModelsLoaded = false;
  bool _isSuccess = false; 
  bool _isProcessingFrame = false;
  bool _isDisposed = false;

  // Logic Mobile
  bool get _isMobile => html.window.innerWidth! < html.window.innerHeight!;
  double get _processingWidth => _isMobile ? 360 : 480;
  double get _processingHeight => _isMobile ? 480 : 360;

  @override
  void initState() {
    super.initState();
    String modeName = widget.attendanceMode == 0 ? "VÀO" : "RA";
    _status = 'Chuẩn bị chấm công $modeName...';

    _viewId = 'video-view-ver-${DateTime.now().millisecondsSinceEpoch}';
    
    // Config Video Element cho iPhone
    _videoElement = html.VideoElement()
      ..id = _viewId
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true');
    
    _videoElement.style
      ..transform = 'scaleX(-1)'
      ..objectFit = 'cover'
      ..width = '100%'
      ..height = '100%'
      ..position = 'absolute'
      ..left = '0'
      ..top = '0';

    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAndStart();
    });
  }
  
  @override
  void dispose() {
    _isDisposed = true;
    stopRealtimeDetection();
    try { _videoElement.srcObject?.getTracks().forEach((track) => track.stop()); } catch (e) {}
    super.dispose();
  }
  
  void _safeSetState(VoidCallback fn) {
    if (mounted && !_isDisposed) setState(fn);
  }
  
  Future<void> _initializeAndStart() async {
    _safeSetState(() => _status = "Đang tải Model AI...");
    _areModelsLoaded = await loadModels();
    
    if (!_areModelsLoaded) {
      _safeSetState(() {
        _status = 'Lỗi tải AI. Vui lòng tải lại trang.';
        _statusColor = Colors.red;
      });
      return;
    }
    
    _startRealtimeScan();
  }
  
  Future<void> _startRealtimeScan() async {
    // 1. TRẠNG THÁI CHỜ CAMERA (Chưa hiện "Tìm khuôn mặt" vội)
    _safeSetState(() {
      _isSuccess = false;
      _isProcessingFrame = false;
      _status = "Đang khởi động Camera..."; // Thông báo chờ camera
      _statusColor = Colors.black;
      _debugInfo = "";
    });

    if (_videoElement.srcObject != null) {
       try { _videoElement.play(); } catch(e) {}
    }

    final onVectorDetected = jsutil.allowInterop((dynamic descriptorJS) async {
      if (_isDisposed || _isSuccess) return;

      if (descriptorJS == null) {
        // Chỉ khi JS chạy ổn định và trả về null (không có mặt), ta mới chắc chắn camera đã lên
        if (!_isProcessingFrame && !_isSuccess) {
             // Cập nhật trạng thái nhẹ nhàng (debounce)
             // Lưu ý: Không setState liên tục để tránh giật UI
        }
        return;
      }
      _processVector(descriptorJS);
    });

    // 2. GỌI CAMERA
    final cameraStarted = await startCamera(_viewId, onVectorDetected, jsutil.allowInterop(() {}));
    
    // 3. CAMERA LÊN XONG -> MỚI ĐỔI TRẠNG THÁI THÀNH "ĐƯA MẶT VÀO"
    if (cameraStarted) {
      _safeSetState(() {
        _status = "Đưa khuôn mặt vào khung tròn..."; 
      });
    } else {
      _safeSetState(() {
        _status = 'Lỗi bật Camera. Hãy cấp quyền.';
        _statusColor = Colors.red;
      });
    }
  }

  void _processVector(dynamic descriptorJS) async {
    if (_isProcessingFrame || _isSuccess) return;
    _isProcessingFrame = true;

    try {
      final List<double> currentVector = (jsutil.dartify(descriptorJS) as List)
          .map((e) => (e as num).toDouble())
          .toList();

      if (widget.currentUser.faceDescriptor == null) {
         _safeSetState(() {
            _status = "Lỗi: User chưa có dữ liệu gốc.";
            _statusColor = Colors.red;
         });
         return;
      }

      final double distance = _calculateDistance(widget.currentUser.faceDescriptor!, currentVector);
      
      // Hiển thị thông số debug
      if (!_isSuccess) {
        _safeSetState(() {
          _debugInfo = "Sai số: ${distance.toStringAsFixed(3)} (Ngưỡng 0.5)";
        });
      }

      if (distance < 0.5) {
        // === KHỚP ===
        _isSuccess = true;
        stopRealtimeDetection();
        
        _safeSetState(() {
          _status = "Đang chấm công...";
          _statusColor = Colors.blue;
        });

        final success = await ApiService().saveCheckIn(widget.currentUser.userId, widget.attendanceMode);
        
        if (success) {
           _handleSuccess();
        } else {
           _isSuccess = false; 
           _safeSetState(() {
             _status = "Lỗi Server. Đang thử lại...";
             _statusColor = Colors.red;
           });
           await Future.delayed(const Duration(seconds: 2));
        }

      } else {
        // === KHÔNG KHỚP ===
        if (!_isSuccess) {
          _safeSetState(() {
            _status = "Chưa khớp... Đang quét tiếp";
            _statusColor = Colors.orange; // Màu cam cảnh báo nhẹ
          });
        }
      }

    } catch (e) {
      print("Error: $e");
    } finally {
      if (!_isSuccess) _isProcessingFrame = false; 
    }
  }

  void _handleSuccess() {
      try { _videoElement.pause(); } catch(e){}
      _safeSetState(() {
          _status = "CHẤM CÔNG THÀNH CÔNG!";
          _statusColor = Colors.green;
      });
      
      Future.delayed(const Duration(seconds: 2), () {
         if (!_isDisposed) closeWindow();
      });
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
    // Chỉ ẩn video khi ĐÃ THÀNH CÔNG (để hiện màn hình trắng tích xanh)
    final bool showCameraView = _areModelsLoaded && !_isSuccess;
    
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
                    // 1. LAYER VIDEO (Dưới cùng)
                    Offstage(
                      offstage: !showCameraView, 
                      child: HtmlElementView(viewType: _viewId),
                    ),

                    // 2. LAYER LOADING (Khi chưa có video)
                    if (!showCameraView && !_isSuccess)
                      Container(
                        decoration: BoxDecoration(color: Colors.grey[300]),
                        child: Center(child: const CircularProgressIndicator()),
                      ),
                    
                    // 3. LAYER VÒNG TRÒN (LUÔN HIỆN KHI ĐANG QUÉT)
                    // Tôi đã tách ra khỏi điều kiện showCameraView để đảm bảo nó luôn hiển thị khung
                    if (!_isSuccess)
                      Center(
                        child: Container(
                          width: _processingWidth * 0.85,
                          height: _processingHeight * 0.85,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle, 
                            border: Border.all(
                                // Xanh: Đang xử lý frame | Vàng: Chờ
                                color: _isProcessingFrame ? Colors.blue : Colors.yellow, 
                                width: 8
                            ),
                          ),
                        ),
                      ),
                      
                    // 4. LAYER THÀNH CÔNG (Trên cùng - Che tất cả)
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
              child: Text(
                _status, 
                style: TextStyle(
                  fontSize: 18, 
                  fontWeight: FontWeight.bold,
                  color: _isSuccess ? Colors.green : _statusColor 
                ), 
                textAlign: TextAlign.center
              ),
            ),
            
            // Debug info
            if (!_isSuccess && _debugInfo.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(_debugInfo, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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

            const Spacer(),
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