import 'dart:async';
import 'dart:html' as html;
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart'; 
import 'dart:ui_web' as ui_web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsutil;
import 'package:geolocator/geolocator.dart';
import 'models.dart';
import 'api_service.dart';

@JS()
external Future<bool> loadModels();
@JS()
external Future<bool> startCamera(String videoElementId, Function onFaceDetected, Function onBlinkDetected);

// --- KHÔI PHỤC LẠI CÁC HÀM JS ---
@JS()
external void getFaceDescriptor(String imageBase64, Object callback);

@JS()
external void stopRealtimeDetection();
@JS()
external void closeWindow();

@JSExport()
class FaceApiCallback {
  final Function(List<double>?) _onResult;
  FaceApiCallback(this._onResult);

  @JSExport('onDescriptorResult')
  void onDescriptorResult(dynamic descriptorJS) {
    if (descriptorJS != null) {
      final descriptor = (jsutil.dartify(descriptorJS) as List)
          .map((e) => (e as num).toDouble())
          .toList();
      _onResult(descriptor);
    } else {
      _onResult(null);
    }
  }
}
// --- HẾT PHẦN KHÔI PHỤC ---

class VerificationPage extends StatefulWidget {
  final Employee currentUser;
  const VerificationPage({super.key, required this.currentUser});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  String _status = 'Đang bắt đầu quá trình chấm công...';
  late html.VideoElement _videoElement;
  bool _isProcessing = false;
  final double _processingWidth = 480;
  final double _processingHeight = 360;
  Rect? _faceRect;
  bool _verificationFailed = false;
  late final String _viewId;
  Position? _currentPosition;
  
  final int _maxLocationAttempts = 2;
  final int _locationAttemptDelay = 5;
  final int _firstAttemptTimeout = 10;
  bool _areModelsLoaded = false;

  @override
  void initState() {
    super.initState();
    _viewId = 'video-view-ver-${DateTime.now().millisecondsSinceEpoch}';
    _videoElement = html.VideoElement()
      ..id = _viewId
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true')
      ..style.transform = 'scaleX(-1)';
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAndStartVerification();
    });
  }
  
  @override
  void dispose() {
    stopRealtimeDetection();
    _videoElement.srcObject?.getTracks().forEach((track) => track.stop());
    super.dispose();
  }
  
  Future<void> _initializeAndStartVerification() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _status = 'Đang tải model nhận dạng...';
    });
    
    _areModelsLoaded = await loadModels();
    if (!mounted) return;
    
    if (!_areModelsLoaded) {
      setState(() {
        _status = 'Lỗi! Không thể tải model nhận dạng.';
        _verificationFailed = true;
        _isProcessing = false;
      });
      return;
    }
    
    setState(() => _isProcessing = false);
    _startVerificationProcess();
  }
  
  Future<void> _startVerificationProcess() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _verificationFailed = false;
      _currentPosition = null;
    });

    bool locationVerified = false; 
    
    for (int i = 1; i <= _maxLocationAttempts; i++) {
      if (!mounted) return;
      
      setState(() => _status = 'Đang kiểm tra vị trí... (Lần $i/$_maxLocationAttempts)');
      await Future.delayed(const Duration(milliseconds: 50)); 
      
      try {
        Position? position = await _checkLocation().timeout(Duration(seconds: _firstAttemptTimeout));
        if (position != null) {
          locationVerified = true;
          break; 
        }
      } on TimeoutException {
        if (i == 1) {
           if (!mounted) return;
           setState(() => _status = 'Lấy vị trí quá $_firstAttemptTimeout giây. Bỏ qua kiểm tra...');
           locationVerified = true; 
           break; 
        }
        print("Lỗi timeout ở lần thử $i");
      } catch (e) {
        print("Lỗi khi kiểm tra vị trí: $e");
      }

      if (i < _maxLocationAttempts) {
        if (!mounted) return;
        setState(() => _status = 'Vị trí không hợp lệ. Sẽ thử lại sau $_locationAttemptDelay giây...');
        await Future.delayed(Duration(seconds: _locationAttemptDelay));
      }
    }

    if (!mounted) return;
    _startFaceRecognition();
  }

  Future<void> _startFaceRecognition() async {
    // ===================================================================
    // THAY ĐỔI LOGIC TIMEOUT 5 GIÂY TẠI ĐÂY
    // ===================================================================
    final onFaceDetected = jsutil.allowInterop((dynamic result) async { // Thêm async
      if (!mounted || !_isProcessing) return;
      if (result != null) {
        // 1. Dừng camera ngay khi phát hiện
        stopRealtimeDetection();
        
        final box = Map<String, dynamic>.from(jsutil.dartify(result) as Map);
        setState(() {
          _faceRect = Rect.fromLTWH(
            (box['x'] as num).toDouble(), (box['y'] as num).toDouble(),
            (box['width'] as num).toDouble(), (box['height'] as num).toDouble(),
          );
          _status = 'Đã phát hiện. Đang so sánh... (5s)';
        });
        
        // 2. Bắt đầu so sánh VÀ đặt đồng hồ 5 giây
        try {
          // _verifyFace() sẽ trả về true nếu khớp, false nếu không khớp/lỗi
          bool isMatch = await _verifyFace().timeout(const Duration(seconds: 5));

          if (!mounted) return;
          
          if (isMatch) {
            // Trường hợp 1: Khớp (trong 5s) - Hàm _verifyFace đã xử lý
          } else {
            // Trường hợp 2: Không khớp (trong 5s)
            if (!_verificationFailed) {
              // Nếu không phải lỗi nghiêm trọng, tự động thử lại
              setState(() => _status = 'Không khớp. Tự động thử lại...');
              await Future.delayed(const Duration(seconds: 2));
              if (mounted) _startFaceRecognition(); // Chạy lại camera
            }
            // Nếu _verificationFailed = true (lỗi server/dữ liệu), nút "Thử Lại" sẽ xuất hiện
          }
          
        } on TimeoutException {
          // Trường hợp 3: Quá 5 giây
          if (!mounted) return;
          print("So sánh quá 5 giây. Mặc định thành công.");
          await _markCheckInSuccessful();
        }

      } else {
        setState(() => _faceRect = null);
      }
    });
    // ===================================================================

    final cameraStarted = await startCamera(_viewId, onFaceDetected, jsutil.allowInterop(() {}));
    if (!mounted) return;
    if (cameraStarted) {
      setState(() => _status = 'Vui lòng đưa khuôn mặt vào trong khung...');
    } else {
      setState(() {
        _status = 'Lỗi không thể truy cập camera.';
        _verificationFailed = true;
        _isProcessing = false;
      });
    }
  }
  
  // Hàm này dùng khi QUÁ 5 GIÂY (timeout)
  Future<void> _markCheckInSuccessful() async {
    final canvas = html.CanvasElement(width: _processingWidth.toInt(), height: _processingHeight.toInt());
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;
    ctx.drawImageScaled(_videoElement, 0, 0, _processingWidth, _processingHeight);
    final imageBase64 = canvas.toDataUrl('image/jpeg', 0.9);

    setState(() => _status = "Hết giờ so sánh. Đang gửi dữ liệu...");
    
    final success = await ApiService().saveCheckIn(widget.currentUser.userId, imageBase64);
    if (!mounted) return;

    if (success) {
       setState(() => _status = "CHẤM CÔNG THÀNH CÔNG!");
       await Future.delayed(const Duration(seconds: 2));
       if (mounted) closeWindow();
    } else {
       setState(() {
         _status = "CHẤM CÔNG THẤT BẠI!\n(Lỗi khi gửi dữ liệu về server)";
         _verificationFailed = true;
       });
    }
    
    if (mounted) {
      setState(() => _isProcessing = false);
    }
  }

  // ===================================================================
  // KHÔI PHỤC LẠI LOGIC SO SÁNH
  // ===================================================================
  Future<bool> _verifyFace() async { // Trả về bool (true = khớp, false = lỗi/không khớp)
    setState(() => _status = "Đang so sánh dữ liệu khuôn mặt...");
    await Future.delayed(Duration.zero);

    final completer = Completer<FaceProcessingResult>();
    _handleFaceProcessing((result) => completer.complete(result));
    final result = await completer.future;

    if (!mounted) return false;
    
    if (result.descriptor != null && result.imageBase64 != null && widget.currentUser.faceDescriptor != null) {
      
      final distance = _calculateDistance(widget.currentUser.faceDescriptor!, result.descriptor!);
      
      if (distance == double.maxFinite) {
         setState(() {
          _status = "CHẤM CÔNG THẤT BẠI!\n(Dữ liệu khuôn mặt gốc bị lỗi)";
          _verificationFailed = true;
          _isProcessing = false; // Dừng hẳn
        });
        return false;
      }
      else if (distance < 0.4) { 
        setState(() => _status = "Khuôn mặt khớp! Đang gửi dữ liệu...");
        final success = await ApiService().saveCheckIn(widget.currentUser.userId, result.imageBase64!);
        if (!mounted) return false;
        if (success) {
           setState(() => _status = "CHẤM CÔNG THÀNH CÔNG!");
           await Future.delayed(const Duration(seconds: 2));
           if (mounted) closeWindow();
           _isProcessing = false; // Dừng hẳn
           return true; // THÀNH CÔNG
        } else {
           setState(() {
             _status = "CHẤM CÔNG THẤT BẠI!\n(Lỗi khi gửi dữ liệu về server)";
             _verificationFailed = true;
             _isProcessing = false; // Dừng hẳn
           });
           return false;
        }
      } else {
        // KHÔNG KHỚP - Sẽ tự động thử lại
        return false;
      }
    } else {
      setState(() {
        _status = "Chấm công thất bại: Không thể xử lý khuôn mặt.";
        _verificationFailed = true;
        _isProcessing = false; // Dừng hẳn
      });
      return false;
    }
  }
  
  void _handleFaceProcessing(Function(FaceProcessingResult) onResult) {
    final canvas = html.CanvasElement(width: _processingWidth.toInt(), height: _processingHeight.toInt());
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;
    ctx.drawImageScaled(_videoElement, 0, 0, _processingWidth, _processingHeight);

    final imageBase64 = canvas.toDataUrl('image/jpeg', 0.9);

    final callback = jsutil.allowInterop((dynamic descriptorJS) {
      final List<double>? descriptor = descriptorJS != null
          ? (jsutil.dartify(descriptorJS) as List).map((e) => (e as num).toDouble()).toList()
          : null;
      onResult(FaceProcessingResult(descriptor: descriptor, imageBase64: imageBase64));
    });
    
    // Gửi Base64 (an toàn cho Safari)
    getFaceDescriptor(imageBase64, jsutil.createDartExport(callback));
  }
  
  double _calculateDistance(List<double> v1, List<double> v2) {
    const int descriptorLength = 128;
    if (v1.length < descriptorLength || v2.length < descriptorLength) {
      print("Lỗi Descriptor: Kích thước không đúng. V1: ${v1.length}, V2: ${v2.length}");
      return double.maxFinite; 
    }
    double sum = 0.0;
    for (int i = 0; i < descriptorLength; i++) {
      sum += pow((v1[i] - v2[i]), 2);
    }
    return sqrt(sum);
  }
  // ===================================================================
  // HẾT PHẦN KHÔI PHỤC
  // ===================================================================
  
  Future<Position?> _checkLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
          return null;
        }
      }
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      
      if (mounted) setState(() => _currentPosition = position);
      
      final distanceInMeters = Geolocator.distanceBetween(
        position.latitude, position.longitude,
        widget.currentUser.allowedLatitude, widget.currentUser.allowedLongitude,
      );
      
      return (distanceInMeters <= widget.currentUser.allowedDistance) ? position : null;
    } catch (e) {
      print('Lỗi khi lấy vị trí: $e');
      if (mounted) setState(() => _currentPosition = null);
      return null;
    }
  }


  @override
  Widget build(BuildContext context) {
    // Logic hiển thị giữ nguyên
    final bool showCamera = _areModelsLoaded && _isProcessing && ! _verificationFailed && (_status.contains("khuôn mặt") || _status.contains("so sánh") || _status.contains("Không khớp") );
    final bool showLoading = !_areModelsLoaded && _isProcessing;
    
    return Scaffold(
      appBar: AppBar(title: Text('Chấm công cho: ${widget.currentUser.userName}')),
      body: Center(
        child: Column( 
          mainAxisAlignment: MainAxisAlignment.center,
          children: [ 
            SizedBox(
              width: _processingWidth,
              height: _processingHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: !showCamera,
                    child: HtmlElementView(viewType: _viewId),
                  ),
                  if (!showCamera)
                    Container(
                      decoration: BoxDecoration(color: Colors.grey[300]),
                      child: Center(
                        child: showLoading
                            ? const CircularProgressIndicator()
                            : const Icon(Icons.location_on, size: 80, color: Colors.white),
                      ),
                    ),
                  if (showCamera && _faceRect != null)
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.rotationY(pi),
                      child: CustomPaint(painter: FaceBoxPainter(rect: _faceRect!)),
                    ),
                  if(showCamera)
                    Center(
                      child: Container(
                        width: _processingWidth * 0.6,
                        height: _processingHeight * 0.8,
                        decoration: BoxDecoration(
                          border: Border.all(color: _faceRect != null ? Colors.green : Colors.yellow, width: 4),
                          borderRadius: BorderRadius.circular(150),
                        ),
                      ),
                    )
                ],
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column( 
                children: [ 
                  if (_isProcessing && !_verificationFailed) const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                ],
              ),
            ),
            
            if (_isProcessing || _verificationFailed)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column( 
                  children: [ 
                     Text(
                      'Vị trí cho phép (từ server): \nLat: ${widget.currentUser.allowedLatitude.toStringAsFixed(6)}, Lon: ${widget.currentUser.allowedLongitude.toStringAsFixed(6)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _currentPosition != null 
                        ? 'Vị trí hiện tại (từ thiết bị): \nLat: ${_currentPosition!.latitude.toStringAsFixed(6)}, Lon: ${_currentPosition!.longitude.toStringAsFixed(6)}'
                        : 'Vị trí hiện tại (từ thiết bị): Đang lấy...',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 10),
            if(_verificationFailed)
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Thử Lại Chấm Công'),
                onPressed: _isProcessing ? null : _initializeAndStartVerification,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              )
          ],
        ),
      ),
    );
  }
}

class FaceBoxPainter extends CustomPainter {
  final Rect rect;
  FaceBoxPainter({required this.rect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.lightGreenAccent..style = PaintingStyle.stroke..strokeWidth = 4.0;
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}