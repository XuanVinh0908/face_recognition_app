import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'dart:ui_web' as ui_web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsutil;
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
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement);
  }

  @override
  void dispose() {
    stopRealtimeDetection();
    _videoElement.srcObject?.getTracks().forEach((track) => track.stop());
    super.dispose();
  }

  Future<void> _setMode(bool useCamera) async {
    if (_isProcessing) return;
    
    setState(() {
      _showCamera = useCamera;
      _uploadedImageBase64 = null;
      _uploadedImage = null;
      _status = useCamera ? 'Đang khởi tạo camera...' : 'Vui lòng chọn ảnh từ thư viện...';
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

    final onFaceDetected = jsutil.allowInterop((dynamic result) {
      if (!mounted || _isProcessing || !_showCamera) return;
      if (result != null) {
        stopRealtimeDetection();
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

  Future<void> _pickImage() async {
    if (_isProcessing) return;

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
    setState(() {
      _isProcessing = true;
      _status = "Đã tìm thấy khuôn mặt. Đang xử lý...";
    });
    
    await _handleFaceProcessing(_videoElement, isCamera: true);
  }

  Future<void> _registerFaceFromUpload() async {
    if (_uploadedImage == null || _isProcessing) {
       setState(() => _status = 'Vui lòng chọn ảnh trước.');
       return;
    }
    setState(() {
      _isProcessing = true;
      _status = "Đang xử lý ảnh tải lên...";
    });

    await _handleFaceProcessing(_uploadedImage!, isCamera: false);
  }

  Future<void> _handleFaceProcessing(html.CanvasImageSource imageSource, {required bool isCamera}) async {
    final canvas = html.CanvasElement(width: _processingWidth.toInt(), height: _processingHeight.toInt());
    final ctx = canvas.getContext('2d') as html.CanvasRenderingContext2D;
    
    if (isCamera) {
      ctx.translate(_processingWidth, 0);
      ctx.scale(-1, 1);
    }
    
    ctx.drawImageScaled(imageSource, 0, 0, _processingWidth, _processingHeight);

    final String imageBase64 = isCamera ? canvas.toDataUrl('image/jpeg', 0.9) : _uploadedImageBase64!;

    final completer = Completer<List<double>?>();
    final callback = jsutil.allowInterop((dynamic descriptorJS) {
      final List<double>? descriptor = descriptorJS != null
          ? (jsutil.dartify(descriptorJS) as List).map((e) => (e as num).toDouble()).toList()
          : null;
      completer.complete(descriptor);
    });
    
    getFaceDescriptor(canvas, callback);
    final descriptor = await completer.future;

    if (!mounted) return;

    if (descriptor != null) {
      setState(() => _status = "Đã có dữ liệu, đang đồng bộ về server...");
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
        _status = "Đăng ký thất bại: Không thể xử lý khuôn mặt. Vui lòng thử lại.";
        _isProcessing = false;
        if(isCamera) _initializeCamera();
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
                // *** THAY ĐỔI: ĐỔI TỪ ROW SANG COLUMN ***
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch, // Cho các nút rộng ra
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
                    const SizedBox(height: 12), // Đổi từ SizedBox(width: 16)
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
              
              const SizedBox(height: 16), // Thêm khoảng cách

              // --- KHUNG HIỂN THỊ (CAMERA HOẶC ẢNH) ---
              if (_showCamera)
                SizedBox(
                  width: _processingWidth,
                  height: _processingHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      HtmlElementView(viewType: _viewId),
                       Center(
                        child: Container(
                          width: _processingWidth * 0.6,
                          height: _processingHeight * 0.8,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.yellow, width: 4),
                            borderRadius: BorderRadius.circular(150),
                          ),
                        ),
                      )
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
                ? Column(children: [const CircularProgressIndicator(), const SizedBox(height: 8), Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))])
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