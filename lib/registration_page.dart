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
import 'version_info.dart'; // Import file version

// --- KHAI BÁO JS INTEROP (CHỈ GIỮ LẠI CÁI CẦN THIẾT) ---
@JS()
external void getFaceDescriptor(String imageBase64, Object callback);

@JS()
external void stopRealtimeDetection();

@JS() 
external void closeWindow(); 

// --- CÁC HÀM WRAPPER GỌI JS AN TOÀN (GIỐNG TRANG CHẤM CÔNG) ---
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

class RegistrationPage extends StatefulWidget {
  final Employee currentUser;
  const RegistrationPage({super.key, required this.currentUser});

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final String _displayVersion = appVersion;
  String _status = 'Vui lòng chọn phương thức đăng ký...';
  late html.VideoElement _videoElement;
  bool _isProcessing = false;
  late final String _viewId;

  // --- LOGIC MOBILE & KÍCH THƯỚC ĐỘNG ---
  bool get _isMobile => html.window.innerWidth! < html.window.innerHeight!;
  double get _processingWidth => _isMobile ? 360 : 480;
  double get _processingHeight => _isMobile ? 480 : 360;

  // Biến trạng thái
  bool _showCamera = false;
  String? _uploadedImageBase64;
  String? _capturedCameraBase64; // Chỉ lưu base64, không cần Image widget
  
  bool _areModelsLoaded = false;
  bool _cameraStarted = false;

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
      
      // CSS Cover chuẩn
      _videoElement.style.objectFit = 'cover'; 
      _videoElement.style.width = '100%';
      _videoElement.style.height = '100%';

    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement);
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

  Future<bool> _ensureModelsLoaded() async {
    if (_areModelsLoaded) return true;
    setState(() {
      _isProcessing = true;
      _status = 'Đang tải model nhận dạng...';
    });
    
    _areModelsLoaded = await loadModels();
    
    if (!mounted) return false;

    if (!_areModelsLoaded) {
      setState(() {
        _status = 'Lỗi! Không thể tải model nhận dạng.';
        _isProcessing = false;
      });
      return false;
    }
    return true;
  }

  // --- CHUYỂN ĐỔI CHẾ ĐỘ ---
  Future<void> _setMode(bool useCamera) async {
    if (_isProcessing) return;

    final modelsLoaded = await _ensureModelsLoaded();
    if (!modelsLoaded) return;

    setState(() {
      _showCamera = useCamera;
      _uploadedImageBase64 = null;
      _capturedCameraBase64 = null;
      _status = useCamera ? 'Đang khởi tạo camera...' : 'Vui lòng chọn ảnh từ thư viện...';
      _isProcessing = false; 
    });

    if (useCamera) {
      await _initializeCamera();
    } else {
      stopRealtimeDetection();
      _stopCameraStream();
      _cameraStarted = false;
    }
  }

  // --- LOGIC CAMERA (ĐÃ CẬP NHẬT THEO VERIFICATION PAGE) ---
  Future<void> _initializeCamera() async {
    if (_cameraStarted) {
       // Nếu đang pause thì play lại
       if (_videoElement.paused) _videoElement.play();
       setState(() => _status = 'Vui lòng đưa khuôn mặt vào khung hình bầu dục...');
       return;
    }

    final onFaceDetected = jsutil.allowInterop((dynamic result) {
      if (!mounted || _isProcessing || !_showCamera) return;
      if (result != null) {
        // 1. Dừng hình video (Tạo cảm giác chụp mượt)
        _videoElement.pause();
        
        // 2. Cắt ảnh ngầm (Crop chính xác)
        _captureCameraFrame();
        
        stopRealtimeDetection();
        
        setState(() => _status = "Đã chụp ảnh. Đang xử lý...");
        
        // 3. Tiến hành đăng ký
        _registerFaceFromCamera();
      }
    });

    final onBlinkDetected = jsutil.allowInterop((){});

    final success = await startCamera(_viewId, onFaceDetected, onBlinkDetected);
    
    if (!mounted) return;
    if (success) {
      _cameraStarted = true;
      setState(() => _status = 'Vui lòng đưa khuôn mặt vào khung hình bầu dục...');
    } else {
      setState(() => _status = 'Lỗi không thể truy cập camera.');
    }
  }

  // --- HÀM CẮT ẢNH CHUẨN (OBJECT-FIT: COVER) ---
  void _captureCameraFrame() {
    final int canvasW = _processingWidth.toInt();
    final int canvasH = _processingHeight.toInt();
    
    final canvas = html.CanvasElement(width: canvasW, height: canvasH);
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;

    ctx.translate(canvasW, 0);
    ctx.scale(-1, 1);

    final videoW = _videoElement.videoWidth;
    final videoH = _videoElement.videoHeight;
    final double videoAspect = videoW / videoH;
    final double canvasAspect = canvasW / canvasH;
    
    double renderW, renderH, offsetX, offsetY;

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

    _capturedCameraBase64 = canvas.toDataUrl('image/jpeg', 0.9);
  }

  // --- LOGIC CHỌN ẢNH TỪ THƯ VIỆN (GIỮ NGUYÊN) ---
  Future<void> _pickImage() async {
    if (_isProcessing) return;

    final modelsLoaded = await _ensureModelsLoaded();
    if (!modelsLoaded) return;
    
    setState(() => _isProcessing = false);

    final html.FileUploadInputElement uploadInput = html.FileUploadInputElement();
    uploadInput.accept = 'image/*';
    uploadInput.click();

    uploadInput.onChange.listen((e) {
      if (uploadInput.files!.isEmpty) return;
      final file = uploadInput.files![0];
      final reader = html.FileReader();

      reader.readAsDataUrl(file);
      reader.onLoadEnd.listen((e) {
        setState(() {
          _uploadedImageBase64 = reader.result as String;
          _status = 'Đã tải ảnh. Nhấn "Đăng ký" để xử lý.';
        });
      });
    });
  }

  // --- CÁC HÀM XỬ LÝ ĐĂNG KÝ ---

  Future<void> _registerFaceFromCamera() async {
    if (_capturedCameraBase64 == null) return;
    await _handleFaceProcessing(_capturedCameraBase64!, isCamera: true);
  }

  Future<void> _registerFaceFromUpload() async {
    if (_uploadedImageBase64 == null) return;
    setState(() {
      _isProcessing = true;
      _status = "Đang xử lý ảnh tải lên...";
    });
    await _handleFaceProcessing(_uploadedImageBase64!, isCamera: false);
  }

  Future<void> _handleFaceProcessing(String imageBase64, {required bool isCamera}) async {
    final completer = Completer<List<double>?>();
    
    final callbackObject = FaceApiCallback((List<double>? descriptor) {
      completer.complete(descriptor);
    });
    
    // Gọi hàm JS trích xuất vector
    getFaceDescriptor(imageBase64, jsutil.createDartExport(callbackObject));
    final descriptor = await completer.future;

    if (!mounted) return;

    if (descriptor != null) {
      setState(() => _status = "Đã có dữ liệu, đang gửi về server...");
      
      final success = await ApiService().registerFaceAndLocation(widget.currentUser.userId, descriptor, imageBase64);

      if (!mounted) return;
      if (success) {
        setState(() => _status = "Đăng ký thành công! Tab sẽ đóng sau 2 giây.");
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) closeWindow();
      } else {
        setState(() {
           _status = "Đăng ký thất bại: Lỗi Server.";
           _isProcessing = false;
           // Nếu là camera, cho phép chụp lại nhưng không tự restart ngay để user đọc lỗi
           if(isCamera) _videoElement.play(); 
        });
      }
    } else {
      setState(() {
        _status = "Không tìm thấy khuôn mặt rõ ràng. Vui lòng thử lại.";
        _isProcessing = false;
        if(isCamera) {
            // Restart lại quy trình sau 2s
            Future.delayed(const Duration(seconds: 2), () {
               if(mounted && _showCamera) _initializeCamera();
            });
        }
      });
    }
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
                      onPressed: _isProcessing ? null : () => _setMode(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _showCamera ? Colors.blue : Colors.grey[700],
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Tải Ảnh Lên'),
                      onPressed: _isProcessing ? null : () => _setMode(false),
                       style: ElevatedButton.styleFrom(
                        backgroundColor: !_showCamera ? Colors.blue : Colors.grey[700],
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 16),

              // --- KHUNG HIỂN THỊ ---
              if (_showCamera)
                ClipRect( // Cắt gọn phần thừa
                  child: SizedBox(
                    width: _processingWidth,
                    height: _processingHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Video (Khi chụp xong sẽ Pause, tạo cảm giác ảnh tĩnh)
                        HtmlElementView(viewType: _viewId),

                        // Khung Bầu Dục (OVAL)
                        Center(
                          child: Container(
                            width: _processingWidth * 0.6,
                            height: _processingHeight * 0.8,
                            decoration: ShapeDecoration(
                              shape: OvalBorder(
                                side: BorderSide(
                                  // Xanh khi pause (chụp xong), Vàng khi đang tìm
                                  color: _videoElement.paused ? Colors.green : Colors.yellow,
                                  width: 4,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              
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
                               onPressed: _isProcessing ? null : _pickImage,
                             )
                          ],
                        )
                      )
                    : Image.network(
                        _uploadedImageBase64!,
                        fit: BoxFit.contain,
                      ),
                ),
              
              if (!_showCamera && _uploadedImageBase64 != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.app_registration),
                    label: const Text('Bắt Đầu Đăng Ký Bằng Ảnh'),
                    onPressed: _isProcessing ? null : _registerFaceFromUpload,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),

              // TRẠNG THÁI
              const SizedBox(height: 20),
              _isProcessing 
                ? Column(children: [
                    if(!_status.contains("thành công")) const CircularProgressIndicator(),
                    const SizedBox(height: 8), 
                    Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))
                  ])
                : Text(_status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),

              const SizedBox(height: 30),
              ElevatedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Đóng Tab'),
                onPressed: _isProcessing ? null : () => closeWindow(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[600],
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                ),
              ),
              
              // HIỂN THỊ VERSION
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