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

class RegistrationPage extends StatefulWidget {
  final Employee currentUser;
  const RegistrationPage({super.key, required this.currentUser});

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final String _displayVersion = appVersion;
  String _status = 'Vui lòng chọn phương thức đăng ký...';
  Color _statusColor = Colors.black;

  late html.VideoElement _videoElement;
  late final String _viewId;

  // Logic Mobile
  bool get _isMobile => html.window.innerWidth! < html.window.innerHeight!;
  double get _processingWidth => _isMobile ? 360 : 480;
  double get _processingHeight => _isMobile ? 480 : 360;

  // Biến trạng thái
  bool _showCamera = false;      // Đang ở chế độ Camera hay Upload
  bool _isBlocking = false;      // Cờ chặn (đang xử lý)
  bool _registrationFailed = false; // Hiện nút thử lại
  bool _isSuccess = false;

  // Dữ liệu
  String? _uploadedImageBase64;  // Ảnh từ thư viện
  String? _capturedBase64;       // Ảnh chụp từ camera
  Image? _capturedWidget;        // Widget ảnh để hiển thị đè lên video

  bool _areModelsLoaded = false;

  @override
  void initState() {
    super.initState();
    _viewId = 'video-view-reg-${DateTime.now().millisecondsSinceEpoch}';
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
  }

  @override
  void dispose() {
    stopRealtimeDetection();
    try { _videoElement.srcObject?.getTracks().forEach((track) => track.stop()); } catch(e){}
    super.dispose();
  }

  // --- CHUYỂN ĐỔI CHẾ ĐỘ ---
  Future<void> _setMode(bool useCamera) async {
    if (_isBlocking) return;

    // Tải model trước nếu chưa tải
    if (!_areModelsLoaded) {
      setState(() => _status = "Đang tải Model...");
      bool loaded = await loadModels();
      if (!loaded) {
        setState(() {
           _status = "Lỗi tải AI.";
           _statusColor = Colors.red;
        });
        return;
      }
      _areModelsLoaded = true;
    }

    setState(() {
      _showCamera = useCamera;
      _status = useCamera ? 'Đang khởi tạo camera...' : 'Vui lòng chọn ảnh từ thư viện...';
      _statusColor = Colors.black;
      
      // Reset các biến dữ liệu
      _uploadedImageBase64 = null;
      _capturedBase64 = null;
      _capturedWidget = null;
      _isSuccess = false;
      _registrationFailed = false;
      _isBlocking = false;
    });

    if (useCamera) {
      _startCameraScan();
    } else {
      stopRealtimeDetection();
      try { _videoElement.pause(); } catch(e){}
    }
  }

  // --- 1. LOGIC CAMERA (GIỐNG TRANG CHẤM CÔNG) ---
  Future<void> _startCameraScan() async {
    if (_videoElement.srcObject != null) {
       try { _videoElement.play(); } catch(e) {}
    }

    setState(() {
      _isSuccess = false;
      _registrationFailed = false;
      _isBlocking = false;
      _capturedWidget = null;
      _capturedBase64 = null;
      _status = "Đưa mặt vào khung tròn...";
      _statusColor = Colors.black;
    });

    if (!mounted) return;

    // Callback nhận Vector từ JS
    final onVectorDetected = jsutil.allowInterop((dynamic descriptorJS) async {
      if (!mounted || _isSuccess || _isBlocking || _registrationFailed) return;

      if (descriptorJS != null) {
        // BẮT ĐẦU XỬ LÝ
        _isBlocking = true; 
        
        setState(() => _status = "Giữ nguyên khuôn mặt...");
        await Future.delayed(const Duration(milliseconds: 500)); // Ổn định
        
        if (!mounted || _isSuccess) return;

        stopRealtimeDetection(); 
        _captureFrameAndShow();
        await Future.delayed(const Duration(milliseconds: 100));

        setState(() => _status = "Đang đăng ký...");

        // Convert Vector
        try {
          final List<double> vector = (jsutil.dartify(descriptorJS) as List)
              .map((e) => (e as num).toDouble())
              .toList();
              
          // Gọi API Đăng ký
          await _registerLogic(vector, _capturedBase64!);

        } catch (e) {
           setState(() {
             _status = "Lỗi xử lý vector.";
             _statusColor = Colors.red;
             _registrationFailed = true;
             _isBlocking = false;
           });
        }
      }
    });

    final cameraStarted = await startCamera(_viewId, onVectorDetected, jsutil.allowInterop(() {}));
    
    if (!mounted) return;
    if (!cameraStarted) {
      setState(() {
        _status = 'Lỗi Camera.';
        _statusColor = Colors.red;
      });
    }
  }

  // --- 2. LOGIC UPLOAD ẢNH ---
  Future<void> _pickImage() async {
    if (_isBlocking) return;
    
    final html.FileUploadInputElement uploadInput = html.FileUploadInputElement();
    uploadInput.accept = 'image/*';
    uploadInput.click();

    uploadInput.onChange.listen((e) {
      if (uploadInput.files!.isEmpty) return;
      
      setState(() {
         _isBlocking = true;
         _status = "Đang xử lý ảnh...";
      });

      final file = uploadInput.files![0];
      final reader = html.FileReader();

      reader.readAsDataUrl(file);
      reader.onLoadEnd.listen((e) {
        final base64 = reader.result as String;
        setState(() => _uploadedImageBase64 = base64);
        
        // Gửi đi lấy vector
        _processUploadedImage(base64);
      });
    });
  }

  Future<void> _processUploadedImage(String base64) async {
    final completer = Completer<List<double>?>();
    
    final callbackObject = FaceApiCallback((List<double>? descriptor) {
      completer.complete(descriptor);
    });
    
    getFaceDescriptor(base64, jsutil.createDartExport(callbackObject));
    
    try {
       final descriptor = await completer.future;
       
       if (descriptor != null) {
          // Có vector -> Gọi API đăng ký
          await _registerLogic(descriptor, base64);
       } else {
          setState(() {
             _status = "Không tìm thấy khuôn mặt trong ảnh.";
             _statusColor = Colors.red;
             _isBlocking = false;
          });
       }
    } catch (e) {
       setState(() {
          _status = "Lỗi xử lý ảnh.";
          _statusColor = Colors.red;
          _isBlocking = false;
       });
    }
  }

  // --- HÀM GỌI API ĐĂNG KÝ CHUNG ---
  Future<void> _registerLogic(List<double> vector, String imageBase64) async {
      setState(() => _status = "Đang gửi dữ liệu lên Server...");
      
      final success = await ApiService().registerFaceAndLocation(
          widget.currentUser.userId, 
          vector, 
          imageBase64
      );

      if (!mounted) return;

      if (success) {
        setState(() {
           _isSuccess = true;
           _status = "ĐĂNG KÝ THÀNH CÔNG!";
           _statusColor = Colors.green;
           _isBlocking = false;
        });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) closeWindow();
      } else {
        setState(() {
           _status = "Đăng ký thất bại (Lỗi Server).";
           _statusColor = Colors.red;
           _registrationFailed = true; // Hiện nút thử lại (cho camera)
           _isBlocking = false;
        });
      }
  }

  // --- HÀM CẮT ẢNH TỪ VIDEO ---
  void _captureFrameAndShow() {
    final int canvasW = _processingWidth.toInt();
    final int canvasH = _processingHeight.toInt();
    final canvas = html.CanvasElement(width: canvasW, height: canvasH);
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;

    ctx.translate(canvasW, 0);
    ctx.scale(-1, 1);

    final videoW = _videoElement.videoWidth;
    final videoH = _videoElement.videoHeight;
    
    // Logic Object-Fit: Cover
    double renderW, renderH, offsetX, offsetY;
    final double videoAspect = videoW / videoH;
    final double canvasAspect = canvasW / canvasH;

    if (videoAspect > canvasAspect) {
      renderH = videoH.toDouble();
      renderW = videoH * canvasAspect;
      offsetX = (videoW - renderW) / 2;
      offsetY = 0;
    } else {
      renderW = videoW.toDouble();
      renderH = videoW / canvasAspect;
      offsetX = 0;
      offsetY = (videoH - renderH) / 2;
    }

    ctx.drawImageScaledFromSource(
      _videoElement, offsetX, offsetY, renderW, renderH, 0, 0, canvasW, canvasH
    );

    final imgData = canvas.toDataUrl('image/jpeg', 0.9);
    
    setState(() {
      _capturedBase64 = imgData;
      _capturedWidget = Image.network(imgData, fit: BoxFit.fill, gaplessPlayback: true);
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Đăng ký: ${widget.currentUser.userName}')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // THANH CHỌN CHẾ ĐỘ
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Dùng Camera'),
                      onPressed: _isBlocking ? null : () => _setMode(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _showCamera ? Colors.blue : Colors.grey[700],
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Tải Ảnh Lên'),
                      onPressed: _isBlocking ? null : () => _setMode(false),
                       style: ElevatedButton.styleFrom(
                        backgroundColor: !_showCamera ? Colors.blue : Colors.grey[700],
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 16),

              // KHUNG HIỂN THỊ CAMERA
              if (_showCamera)
                ClipRect(
                  child: SizedBox(
                    width: _processingWidth,
                    height: _processingHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Video
                        Offstage(
                          offstage: false, 
                          child: HtmlElementView(viewType: _viewId),
                        ),

                        // Ảnh chụp
                        if (_capturedWidget != null)
                          Positioned.fill(child: _capturedWidget!),

                        // Khung tròn (Circle)
                        Center(
                          child: Container(
                            width: _processingWidth * 0.85,
                            height: _processingHeight * 0.85,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle, 
                              border: Border.all(
                                  // Xanh: OK/Đang chặn, Vàng: Đang tìm, Đỏ: Lỗi
                                  color: _isSuccess ? Colors.green : (_registrationFailed ? Colors.red : Colors.yellow), 
                                  width: 8
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              
              // KHUNG HIỂN THỊ UPLOAD
              if (!_showCamera)
                Container(
                  width: _processingWidth,
                  height: _processingHeight,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    border: Border.all(color: Colors.grey),
                  ),
                  child: _uploadedImageBase64 == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                             const Icon(Icons.photo_library, size: 80, color: Colors.white),
                             const SizedBox(height: 16),
                             ElevatedButton.icon(
                               icon: const Icon(Icons.upload_file),
                               label: const Text('Bấm để chọn ảnh...'),
                               onPressed: _isBlocking ? null : _pickImage,
                             )
                          ],
                        )
                      )
                    : Image.network(
                        _uploadedImageBase64!,
                        fit: BoxFit.contain,
                      ),
                ),
              
              // NÚT ĐĂNG KÝ (CHỈ HIỆN KHI UPLOAD VÀ CÓ ẢNH)
              if (!_showCamera && _uploadedImageBase64 != null && !_isSuccess)
                Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Xác nhận đăng ký ảnh này'),
                    onPressed: _isBlocking ? null : () => _processUploadedImage(_uploadedImageBase64!),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),

              const SizedBox(height: 20),
              
              // TRẠNG THÁI
              _isBlocking 
                ? Column(children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 8), 
                    Text(_status, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _statusColor))
                  ])
                : Text(_status, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _statusColor), textAlign: TextAlign.center),

              const SizedBox(height: 30),
              
              if (_isSuccess)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.exit_to_app),
                    label: const Text('Đóng Tab Ngay'),
                    onPressed: () => closeWindow(), 
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                    ),
                  ),

              // NÚT THỬ LẠI (CHO CAMERA)
              if (_registrationFailed && _showCamera)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('THỬ LẠI'),
                    onPressed: _startCameraScan, 
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
              
              const SizedBox(height: 20),
              Text(
                _displayVersion,
                style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}