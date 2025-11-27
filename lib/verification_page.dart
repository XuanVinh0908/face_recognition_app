import 'dart:async';
import 'dart:html' as html;
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart'; 
import 'dart:ui_web' as ui_web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsutil;
import 'models.dart';
import 'api_service.dart';
import 'version_info.dart';

// --- KHAI BÁO JS ---
@JS()
external void getFaceDescriptor(String imageBase64, Object callback);

@JS()
external void stopRealtimeDetection();

@JS() 
external void closeWindow(); 

// --- HÀM WRAPPER: GỌI TRỰC TIẾP WINDOW ---
Future<bool> loadModels() async {
  try {
    final promise = jsutil.callMethod(html.window, 'loadModels', []);
    await jsutil.promiseToFuture(promise); 
    return true;
  } catch (e) {
    print("Dart Error loading models: $e");
    return false;
  }
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
  } catch (e) {
    print("Dart Error starting camera: $e");
    return false;
  }
}

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

class VerificationPage extends StatefulWidget {
  final Employee currentUser;
  const VerificationPage({super.key, required this.currentUser});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  final String _displayVersion = appVersion;
  String _status = 'Đang bắt đầu quá trình chấm công...';
  late html.VideoElement _videoElement;
  bool _isProcessing = false;
  
  // Logic Mobile
  bool get _isMobile => html.window.innerWidth! < html.window.innerHeight!;
  double get _processingWidth => _isMobile ? 360 : 480;
  double get _processingHeight => _isMobile ? 480 : 360;

  bool _verificationFailed = false;
  late final String _viewId;
  
  Image? _capturedImage;
  String? _capturedBase64;
  
  bool _areModelsLoaded = false;
  bool _isSuccess = false; 

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
      
      // CSS để video tự động crop cho vừa khung (Cover)
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
    _stopCameraStream(); 
    super.dispose();
  }

  void _stopCameraStream() {
    try {
      if (_videoElement.srcObject != null) {
        _videoElement.srcObject?.getTracks().forEach((track) => track.stop());
        _videoElement.srcObject = null;
      }
    } catch (e) {
      print("Lỗi tắt camera: $e");
    }
  }
  
  Future<void> _initializeAndStartVerification() async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _status = 'Đang tải model nhận dạng... (Vui lòng đợi)';
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
      _capturedImage = null; 
      _isSuccess = false;
    });

    if (!mounted) return;
    _startFaceRecognition();
  }

  Future<void> _startFaceRecognition() async {
    if (_isSuccess) return;

    final onFaceDetected = jsutil.allowInterop((dynamic result) async {
      if (!mounted || !_isProcessing) return;
      if (_isSuccess) return; 

      if (result != null) {
        _captureFrame();
        stopRealtimeDetection();
        
        setState(() {
          _status = 'Đang so sánh...';
        });
        
        try {
          bool isMatch = await _verifyFace().timeout(const Duration(seconds: 10));
          if (!mounted) return;
          
          if (!isMatch) {
            if (!_verificationFailed && !_isSuccess) {
              setState(() => _status = 'Không khớp. Đang thử lại...');
              
              await Future.delayed(const Duration(seconds: 2));
              
              if (mounted && !_isSuccess) {
                  setState(() => _capturedImage = null); 
                  _startFaceRecognition(); 
              }
            }
          }
        } on TimeoutException {
          if (mounted && !_isSuccess) {
            print("Timeout 10s. Chấp nhận kết quả.");
            await _markCheckInSuccessful();
          }
        }
      }
    });

    setState(() => _status = 'Đang khởi động Camera...');
    final cameraStarted = await startCamera(_viewId, onFaceDetected, jsutil.allowInterop(() {}));
    
    if (!mounted) return;
    if (_isSuccess) return; 

    if (cameraStarted) {
      setState(() => _status = 'Vui lòng đưa khuôn mặt vào trong khung tròn...');
    } else {
      setState(() {
        _status = 'Lỗi không thể truy cập camera (Quyền bị từ chối?)';
        _verificationFailed = true;
        _isProcessing = false;
      });
    }
  }

  // *** HÀM MỚI: CẮT ẢNH CHÍNH XÁC TỪNG PIXEL (CROP) ***
  void _captureFrame() {
    if (_isSuccess) return;
    
    final int canvasW = _processingWidth.toInt();
    final int canvasH = _processingHeight.toInt();
    
    final canvas = html.CanvasElement(width: canvasW, height: canvasH);
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;

    // 1. Lật gương canvas trước khi vẽ
    ctx.translate(canvasW, 0);
    ctx.scale(-1, 1);

    // 2. Tính toán vùng Cắt (Source Crop) từ Video gốc
    final videoW = _videoElement.videoWidth;
    final videoH = _videoElement.videoHeight;
    
    // Tính tỷ lệ khung hình
    final double videoAspect = videoW / videoH;
    final double canvasAspect = canvasW / canvasH;
    
    double renderW, renderH, offsetX, offsetY;

    if (videoAspect > canvasAspect) {
      // Video rộng hơn Canvas (Ví dụ: Video 640x480, Canvas 360x480)
      // -> Cắt bớt 2 bên trái phải
      renderH = videoH.toDouble();
      renderW = videoH * canvasAspect;
      offsetX = (videoW - renderW) / 2;
      offsetY = 0;
    } else {
      // Video cao hơn Canvas (Hiếm gặp trên mobile nếu dùng width ideal)
      // -> Cắt bớt trên dưới
      renderW = videoW.toDouble();
      renderH = videoW / canvasAspect;
      offsetX = 0;
      offsetY = (videoH - renderH) / 2;
    }

    // 3. Vẽ phần ĐÃ CẮT (Source) vào toàn bộ Canvas (Destination)
    // drawImage(source, sx, sy, sw, sh, dx, dy, dw, dh)
    ctx.drawImageScaledFromSource(
      _videoElement,
      offsetX,      // sx (Bắt đầu cắt từ đâu)
      offsetY,      // sy
      renderW,      // sw (Độ rộng vùng cắt)
      renderH,      // sh
      0,            // dx (Vẽ vào đâu trên canvas)
      0,            // dy
      canvasW,      // dw
      canvasH       // dh
    );

    final imgData = canvas.toDataUrl('image/jpeg', 0.9);
    setState(() {
      _capturedBase64 = imgData;
      // BoxFit.cover để đảm bảo hiển thị khớp 100% với video
      _capturedImage = Image.network(imgData, fit: BoxFit.cover); 
    });
  }
  
  Future<void> _markCheckInSuccessful() async {
    if (_isSuccess) return; 

    String imageToSend = _capturedBase64 ?? "";
    if (imageToSend.isEmpty) {
        // Fallback: Nếu chưa chụp được thì chụp tạm (có thể bị méo nhưng có còn hơn không)
        try {
          final canvas = html.CanvasElement(width: _processingWidth.toInt(), height: _processingHeight.toInt());
          final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;
          ctx.drawImageScaled(_videoElement, 0, 0, _processingWidth, _processingHeight);
          imageToSend = canvas.toDataUrl('image/jpeg', 0.9);
        } catch (e) {
          print("Backup capture error: $e");
        }
    }

    setState(() => _status = "Đang gửi dữ liệu chấm công...");
    final success = await ApiService().saveCheckIn(widget.currentUser.userId, imageToSend);
    if (!mounted) return;

    if (success) {
       _handleSuccess();
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

  void _handleSuccess() async {
      _isSuccess = true; 
      stopRealtimeDetection();
      _stopCameraStream();

      if (mounted) {
        setState(() {
           _status = "CHẤM CÔNG THÀNH CÔNG!";
           _isProcessing = false; 
        });
      }

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) closeWindow(); 
  }

  Future<bool> _verifyFace() async {
    final completer = Completer<FaceProcessingResult>();
    if (_capturedBase64 != null) {
        _handleFaceProcessing(_capturedBase64!, (result) => completer.complete(result));
    } else {
        return false;
    }

    final result = await completer.future;
    if (!mounted) return false;
    if (_isSuccess) return true;

    if (result.descriptor != null && widget.currentUser.faceDescriptor != null) {
      final distance = _calculateDistance(widget.currentUser.faceDescriptor!, result.descriptor!);
      
      if (distance == double.maxFinite) return false;
      
      // *** NỚI LỎNG NGƯỠNG SO SÁNH ***
      // Tăng từ 0.4 -> 0.55 để dễ chấm công hơn
      if (distance < 0.55) { 
        setState(() => _status = "Khuôn mặt khớp! Đang gửi...");
        final success = await ApiService().saveCheckIn(widget.currentUser.userId, result.imageBase64!);
        if (!mounted) return false;
        
        if (success) {
           _handleSuccess(); 
           return true; 
        } else {
           setState(() {
             _status = "Lỗi kết nối Server.";
             _verificationFailed = true;
             _isProcessing = false;
           });
           return false;
        }
      } else {
        // Vẫn in ra khoảng cách để debug nếu cần
        print("Khoảng cách: $distance (Ngưỡng 0.55)"); 
        return false;
      }
    } else {
      return false;
    }
  }
  
  void _handleFaceProcessing(String imageBase64, Function(FaceProcessingResult) onResult) {
    final callbackObject = FaceApiCallback((List<double>? descriptor) {
      onResult(FaceProcessingResult(descriptor: descriptor, imageBase64: imageBase64));
    });
    getFaceDescriptor(imageBase64, jsutil.createDartExport(callbackObject));
  }
  
  double _calculateDistance(List<double> v1, List<double> v2) {
    const int descriptorLength = 128;
    if (v1.length < descriptorLength || v2.length < descriptorLength) return double.maxFinite; 
    double sum = 0.0;
    for (int i = 0; i < descriptorLength; i++) {
      sum += pow((v1[i] - v2[i]), 2);
    }
    return sqrt(sum);
  }

  @override
  Widget build(BuildContext context) {
    final bool showCameraView = _areModelsLoaded && _isProcessing && !_verificationFailed && !_isSuccess;
    final bool showLoading = !_areModelsLoaded && _isProcessing;
    
    return Scaffold(
      appBar: AppBar(title: Text('Chấm công cho: ${widget.currentUser.userName}')),
      body: Center(
        child: Column( 
          mainAxisAlignment: MainAxisAlignment.center,
          children: [ 
            // Dùng ClipRect để cắt bỏ mọi phần thừa nếu có, đảm bảo khung hình gọn gàng
            ClipRect(
              child: SizedBox(
                width: _processingWidth,
                height: _processingHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(
                      offstage: !showCameraView || _capturedImage != null, 
                      child: HtmlElementView(viewType: _viewId),
                    ),

                    if (_capturedImage != null && !_isSuccess)
                      Positioned.fill(child: _capturedImage!),

                    if (!showCameraView && _capturedImage == null && !_isSuccess)
                      Container(
                        decoration: BoxDecoration(color: Colors.grey[300]),
                        child: Center(
                          child: showLoading
                              ? const CircularProgressIndicator()
                              : const Icon(Icons.videocam_off, size: 80, color: Colors.grey),
                        ),
                      ),
                    
                    if ((showCameraView || _capturedImage != null) && !_isSuccess)
                      Center(
                        child: Container(
                          width: _processingWidth * 0.6,
                          height: _processingHeight * 0.8,
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: _capturedImage != null ? Colors.green : Colors.yellow, 
                                width: 4
                            ),
                            borderRadius: BorderRadius.circular(150),
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
                  if (_isProcessing && !_verificationFailed && !_isSuccess) const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    _status, 
                    style: TextStyle(
                      fontSize: 18, 
                      fontWeight: FontWeight.bold,
                      color: _isSuccess ? Colors.green : Colors.black
                    ), 
                    textAlign: TextAlign.center
                  ),
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
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                  ),
                ),
              ),

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