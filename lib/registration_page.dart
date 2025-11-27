import 'dart:async';
import 'dart:html' as html;
import 'dart:math'; // Để dùng pi
import 'package:flutter/material.dart';
import 'dart:ui_web' as ui_web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsutil;
import 'models.dart';
import 'api_service.dart';

@JS()
external Future<bool> loadModels();
@JS()
external Future<bool> startCamera(String videoElementId, Function onFaceDetected, Function onBlinkDetected);

// Hàm này nhận vào CanvasElement hoặc String Base64
@JS()
external void getFaceDescriptor(Object canvasOrBase64, Object callback);

@JS()
external void stopRealtimeDetection();
@JS()
external void closeWindow();

// --- CLASS CALLBACK ĐỂ SỬA LỖI JS INTEROP ---
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
// ---------------------------------------------

class RegistrationPage extends StatefulWidget {
  final Employee currentUser;
  const RegistrationPage({super.key, required this.currentUser});

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  String _status = 'Vui lòng chọn một phương thức đăng ký...';
  late html.VideoElement _videoElement;
  bool _isProcessing = false;
  final double _processingWidth = 480;
  final double _processingHeight = 360;
  late final String _viewId;

  bool _showCamera = false;
  String? _uploadedImageBase64;
  html.ImageElement? _uploadedImage;
  bool _isCameraInitialized = false;
  bool _areModelsLoaded = false;
  
  // Biến lưu ảnh chụp từ camera và khung mặt
  Image? _capturedCameraImage;
  String? _capturedCameraBase64;
  Rect? _faceRect;

  @override
  void initState() {
    super.initState();
    // ID phải chứa chuỗi "video-view" để khớp với JS
    _viewId = 'video-view-reg-${DateTime.now().millisecondsSinceEpoch}';
    _videoElement = html.VideoElement()
      ..id = _viewId
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true')
      // Lật ngược và set kích thước
      ..style.transform = 'scaleX(-1)'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';

    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement);
  }

  @override
  void dispose() {
    stopRealtimeDetection();
    _videoElement.srcObject?.getTracks().forEach((track) => track.stop());
    super.dispose();
  }

  Future<bool> _ensureModelsLoaded() async {
    if (_areModelsLoaded) return true;
    
    setState(() {
      _isProcessing = true;
      _status = 'Đang tải model nhận dạng...';
    });
    // Chờ một chút cho UI cập nhật
    await Future.delayed(const Duration(milliseconds: 100));

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

  Future<void> _setMode(bool useCamera) async {
    if (_isProcessing) return;

    final modelsLoaded = await _ensureModelsLoaded();
    if (!modelsLoaded) return;

    setState(() {
      _showCamera = useCamera;
      _uploadedImageBase64 = null;
      _uploadedImage = null;
      _capturedCameraImage = null; // Reset ảnh chụp
      _capturedCameraBase64 = null;
      _faceRect = null;
      _status = useCamera ? 'Đang khởi tạo camera...' : 'Vui lòng chọn ảnh từ thư viện...';
      _isProcessing = false; 
    });

    if (useCamera) {
      await _initializeCamera();
    } else {
      stopRealtimeDetection();
      _videoElement.srcObject?.getTracks().forEach((track) => track.stop());
      _isCameraInitialized = false;
    }
  }

  Future<void> _initializeCamera() async {
    if (_isCameraInitialized) {
       setState(() => _status = 'Vui lòng giữ nguyên khuôn mặt trong khung hình...');
       return;
    }
    
    // Chờ 1s để đảm bảo DOM render thẻ video
    await Future.delayed(const Duration(seconds: 1));

    final onFaceDetected = jsutil.allowInterop((dynamic result) {
      if (!mounted || _isProcessing || !_showCamera) return;
      if (result != null) {
        // Dừng camera
        stopRealtimeDetection();
        
        // Chụp ảnh
        _captureCameraFrame();

        // Lấy tọa độ để vẽ khung
        try {
          final x = (jsutil.getProperty(result, 'x') as num).toDouble();
          final y = (jsutil.getProperty(result, 'y') as num).toDouble();
          final width = (jsutil.getProperty(result, 'width') as num).toDouble();
          final height = (jsutil.getProperty(result, 'height') as num).toDouble();
          setState(() => _faceRect = Rect.fromLTWH(x, y, width, height));
        } catch(e) {
           print("Lỗi đọc tọa độ JS: $e");
        }

        // Tiến hành đăng ký với ảnh đã chụp
        _registerFaceFromCamera();
      }
    });
    final onBlinkDetected = jsutil.allowInterop((){});

    final cameraStarted = await startCamera(_viewId, onFaceDetected, onBlinkDetected);
    
    if (!mounted) return;
    if (cameraStarted) {
      _isCameraInitialized = true;
      setState(() => _status = 'Vui lòng giữ nguyên khuôn mặt trong khung hình...');
    } else {
      setState(() => _status = 'Lỗi không thể truy cập camera: Vui lòng kiểm tra quyền truy cập.');
    }
  }

  // Hàm chụp ảnh từ camera
  void _captureCameraFrame() {
    final canvas = html.CanvasElement(width: _processingWidth.toInt(), height: _processingHeight.toInt());
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;
    // Lật ngược canvas
    ctx.translate(_processingWidth, 0);
    ctx.scale(-1, 1);
    ctx.drawImageScaled(_videoElement, 0, 0, _processingWidth, _processingHeight);
    
    _capturedCameraBase64 = canvas.toDataUrl('image/jpeg', 0.9);
    _capturedCameraImage = Image.network(_capturedCameraBase64!);
  }

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
        final String base64Data = reader.result as String;
        final html.ImageElement img = html.ImageElement();
        img.src = base64Data;
        img.onLoad.listen((_) {
          setState(() {
            _uploadedImageBase64 = base64Data;
            _uploadedImage = img;
            _status = 'Đã tải ảnh. Nhấn "Đăng ký" để xử lý.';
          });
        });
      });
    });
  }

  Future<void> _registerFaceFromCamera() async {
    if (_isProcessing) return;
    if (_capturedCameraBase64 == null) {
        _initializeCamera(); // Nếu chưa có ảnh thì khởi tạo lại camera
        return;
    }
    setState(() {
      _isProcessing = true;
      _status = "Đã chụp ảnh. Đang xử lý...";
    });
    
    // Sử dụng chuỗi Base64 đã chụp
    await _handleFaceProcessing(_capturedCameraBase64!, isCamera: true);
  }

  Future<void> _registerFaceFromUpload() async {
    if (_uploadedImageBase64 == null || _isProcessing) {
       setState(() => _status = 'Vui lòng chọn ảnh trước.');
       return;
    }
    setState(() {
      _isProcessing = true;
      _status = "Đang xử lý ảnh tải lên...";
    });

    // Sử dụng chuỗi Base64 đã upload
    await _handleFaceProcessing(_uploadedImageBase64!, isCamera: false);
  }

  // Hàm xử lý chung, nhận vào chuỗi Base64
  Future<void> _handleFaceProcessing(String imageBase64, {required bool isCamera}) async {
    final completer = Completer<List<double>?>();
    
    // SỬ DỤNG CLASS CALLBACK
    final callbackObject = FaceApiCallback((List<double>? descriptor) {
      completer.complete(descriptor);
    });
    
    // Gọi hàm JS với chuỗi Base64
    getFaceDescriptor(imageBase64, jsutil.createDartExport(callbackObject));
    final descriptor = await completer.future;

    if (!mounted) return;

    if (descriptor != null) {
      setState(() => _status = "Đã có dữ liệu, đang gửi về server...");
      // Gọi API đăng ký
      final success = await ApiService().registerFaceAndLocation(widget.currentUser.userId, descriptor, imageBase64);

      if (!mounted) return;
      if (success) {
        setState(() => _status = "Đăng ký thành công! Tab sẽ đóng sau 2 giây.");
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          closeWindow();
        }
      } else {
        setState(() {
           _status = "Đăng ký thất bại: Lỗi khi gửi dữ liệu về server.";
           _isProcessing = false;
        });
      }
    } else {
      setState(() {
        _status = "Đăng ký thất bại: Không tìm thấy khuôn mặt hợp lệ. Vui lòng thử lại.";
        _isProcessing = false;
        // Nếu là camera thì tự động khởi động lại để chụp lại
        if(isCamera) {
             _capturedCameraImage = null;
             _capturedCameraBase64 = null;
             _faceRect = null;
            _initializeCamera();
        }
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Đăng ký cho: ${widget.currentUser.userName}')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // --- THANH CHỌN CHẾ ĐỘ ---
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

              // --- KHUNG HIỂN THỊ (CAMERA HOẶC ẢNH) ---
              if (_showCamera)
                SizedBox(
                  width: _processingWidth,
                  height: _processingHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 1. Video gốc (ẩn khi có ảnh chụp)
                      Offstage(
                        offstage: _capturedCameraImage != null,
                        child: HtmlElementView(viewType: _viewId)
                      ),

                      // 2. Ảnh chụp (hiện đè lên video)
                      if (_capturedCameraImage != null)
                        Positioned.fill(child: _capturedCameraImage!),

                      // 3. Viền và khung mặt
                      Center(
                        child: Container(
                          width: _processingWidth * 0.6,
                          height: _processingHeight * 0.8,
                          decoration: BoxDecoration(
                            border: Border.all(color: _faceRect != null ? Colors.green : Colors.yellow, width: 4),
                            borderRadius: BorderRadius.circular(150),
                          ),
                        ),
                      ),
                      
                      // 4. Vẽ khung mặt nếu có (không lật ngược nếu là ảnh chụp)
                      if (_faceRect != null)
                        Transform(
                          alignment: Alignment.center,
                          transform: _capturedCameraImage != null ? Matrix4.identity() : Matrix4.rotationY(pi),
                          child: CustomPaint(painter: FaceBoxPainter(rect: _faceRect!)),
                        ),
                    ],
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

              // --- TRẠNG THÁI VÀ NÚT ĐÓNG ---
              const SizedBox(height: 20),
              _isProcessing 
                ? Column(children: [
                    if(!_status.contains("THÀNH CÔNG")) const CircularProgressIndicator(),
                    const SizedBox(height: 8), 
                    Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))
                  ])
                : Text(_status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,),

              const SizedBox(height: 30),
              ElevatedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Đóng Tab'),
                onPressed: _isProcessing ? null : () {
                  closeWindow(); 
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[600],
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// (Class FaceBoxPainter dùng chung, nếu đã có ở file khác thì không cần copy lại)
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