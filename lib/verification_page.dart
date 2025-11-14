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
external Future<bool> startCamera(String videoElementId, Function onFaceDetected, Function onBlinkDetected);
@JS()
external void getFaceDescriptor(html.CanvasElement canvas, Function onResult);
@JS()
external void stopRealtimeDetection();
@JS()
external void closeWindow();

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
  final int _locationAttemptDelay = 5; // Giây
  final int _firstAttemptTimeout = 10; // Giây

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
      _startVerificationProcess();
    });
  }
  
  @override
  void dispose() {
    stopRealtimeDetection();
    _videoElement.srcObject?.getTracks().forEach((track) => track.stop());
    super.dispose();
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
      
      // 1. CẬP NHẬT GIAO DIỆN
      setState(() => _status = 'Đang kiểm tra vị trí... (Lần $i/$_maxLocationAttempts)');
      
      // *** SỬA LỖI 1: Thêm nhịp nghỉ 50ms ***
      // Đảm bảo UI kịp vẽ lại trước khi AWAIT tiếp theo
      await Future.delayed(const Duration(milliseconds: 50)); 
      
      try {
        // *** SỬA LỖI 2: Áp dụng timeout cho TẤT CẢ các lần thử ***
        Position? position = await _checkLocation().timeout(Duration(seconds: _firstAttemptTimeout));
        
        if (position != null) {
          locationVerified = true;
          break; 
        }
        
      } on TimeoutException {
        // Chỉ ghi nhận lỗi timeout ở lần đầu, các lần sau chỉ tiếp tục lặp
        if (i == 1) {
           if (!mounted) return;
           setState(() => _status = 'Lấy vị trí quá $_firstAttemptTimeout giây. Bỏ qua kiểm tra...');
           locationVerified = true; 
           break; 
        }
        // Nếu timeout ở các lần sau, nó sẽ bị bắt bởi catch (e)
        print("Lỗi timeout ở lần thử $i");

      } catch (e) {
        print("Lỗi khi kiểm tra vị trí: $e");
        // Nếu có lỗi (ví dụ từ chối quyền, hoặc timeout ở lần 2+), 
        // vòng lặp sẽ tự động chạy tiếp
      }

      // Đợi 10 giây trước khi thử lại
      if (i < _maxLocationAttempts) {
        if (!mounted) return;
        // Cập nhật UI trạng thái chờ
        setState(() => _status = 'Vị trí không hợp lệ. Sẽ thử lại sau $_locationAttemptDelay giây...');
        await Future.delayed(Duration(seconds: _locationAttemptDelay));
      }
    }

    if (!mounted) return;
    
    //if (!locationVerified) {
    //  setState(() => _status = 'Không thể xác định vị trí. Bỏ qua và tiếp tục...');
    //  await Future.delayed(const Duration(seconds: 1)); 
    //}
    
    _startFaceRecognition();
  }

  Future<void> _startFaceRecognition() async {
    setState(() => _status = 'Đang khởi tạo camera...');
    
    final onFaceDetected = jsutil.allowInterop((dynamic result) {
      if (!mounted || !_isProcessing) return;
      if (result != null) {
        final box = Map<String, dynamic>.from(jsutil.dartify(result) as Map);
        setState(() {
          _faceRect = Rect.fromLTWH(
            (box['x'] as num).toDouble(), (box['y'] as num).toDouble(),
            (box['width'] as num).toDouble(), (box['height'] as num).toDouble(),
          );
          _status = 'Đã thấy khuôn mặt. Đang xử lý...';
        });
        stopRealtimeDetection();
        _verifyFace();
      } else {
        setState(() => _faceRect = null);
      }
    });

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

  Future<void> _verifyFace() async {
    setState(() => _status = "Đang so sánh dữ liệu khuôn mặt...");
    await Future.delayed(Duration.zero);

    final completer = Completer<FaceProcessingResult>();
    _handleFaceProcessing((result) => completer.complete(result));
    final result = await completer.future;

    if (!mounted) return;
    if (result.descriptor != null && result.imageBase64 != null && widget.currentUser.faceDescriptor != null) {
      final distance = _calculateDistance(widget.currentUser.faceDescriptor!, result.descriptor!);
      if (distance < 0.4) { 
        setState(() => _status = "Khuôn mặt khớp! Đang gửi dữ liệu...");
        final success = await ApiService().saveCheckIn(widget.currentUser.userId, result.imageBase64!);
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
      } else {
        setState(() {
          _status = "CHẤM CÔNG THẤT BẠI!\n(Khuôn mặt không khớp)";
          _verificationFailed = true;
        });
      }
    } else {
      setState(() {
        _status = "Chấm công thất bại: Không thể xử lý khuôn mặt.";
        _verificationFailed = true;
      });
    }
    
    if (mounted) {
      setState(() => _isProcessing = false);
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
    getFaceDescriptor(canvas, callback);
  }

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

  double _calculateDistance(List<double> v1, List<double> v2) {
    double sum = 0.0;
    for (int i = 0; i < v1.length; i++) sum += pow((v1[i] - v2[i]), 2);
    return sqrt(sum);
  }

  @override
  Widget build(BuildContext context) {
    final bool showCamera = _isProcessing && ! _verificationFailed && _status.contains("khuôn mặt");
    
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
                      child: const Center(child: Icon(Icons.location_on, size: 80, color: Colors.white)),
                    ),
                  if (showCamera && _faceRect != null)
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.rotationY(pi),
                      child: CustomPaint(painter: FaceBoxPainter(rect: _faceRect!)),
                    ),
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
                onPressed: _isProcessing ? null : _startVerificationProcess,
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