import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InPlaceTranslatorApp());
}

@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: BubbleOverlayScreen(),
  ));
}

class InPlaceTranslatorApp extends StatefulWidget {
  const InPlaceTranslatorApp({super.key});

  @override
  State<InPlaceTranslatorApp> createState() => _InPlaceTranslatorAppState();
}

class _InPlaceTranslatorAppState extends State<InPlaceTranslatorApp> {
  static const platform = MethodChannel('com.example.livetranslator/screen');
  final TextEditingController _apiKeyController = TextEditingController();

  // اختر اللغة الأصلية للمانهوا (latin للإنجليزية، korean للكورية)
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  bool _isRunning = false;
  bool _isBusy = false;
  Timer? _loopTimer;
  String _lastExtractedSignature = "";
  GenerativeModel? _model;

  Future<void> _startOrStopLive() async {
    if (_apiKeyController.text.trim().isEmpty) return;

    if (_isRunning) {
      _loopTimer?.cancel();
      await platform.invokeMethod('stopScreenStream');
      await FlutterOverlayWindow.closeOverlay();
      setState(() => _isRunning = false);
      return;
    }

    if (!(await FlutterOverlayWindow.isPermissionGranted())) {
      final granted = await FlutterOverlayWindow.requestPermission() ?? false;
      if (!granted) return;
    }

    final bool started = await platform.invokeMethod('startScreenStream');
    if (!started) return;

    _model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: _apiKeyController.text.trim(),
      generationConfig: GenerationConfig(responseMimeType: 'application/json'),
      systemInstruction: Content.system(
        'أنت مترجم مانهوا محترف. ستستلم قائمة نصوص مرقمة مستخرجة من فقاعات حوار. '
        'أعد JSON فقط يحتوي على مصفوفة باسم "translations" بنفس الترتيب والعدد، '
        'بحيث تكون الترجمة العربية طبيعية ومختصرة لتناسب حجم الفقاعة.'
      ),
    );

    // فتح نافذة شفافة بحجم الشاشة بالكامل وتسمح بمرور اللمس (clickThrough) للتمرير
    await FlutterOverlayWindow.showOverlay(
      enableDrag: false,
      flag: OverlayFlag.clickThrough, // مهم جداً: يسمح لك بعمل Scroll في المانهوا تحت الترجمة!
      alignment: OverlayAlignment.center,
      width: WindowSize.fullCover,
      height: WindowSize.fullCover,
    );

    setState(() => _isRunning = true);

    // فحص الشاشة كل 1.2 ثانية
    _loopTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _processScreen());
  }

  Future<void> _processScreen() async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      final Map<dynamic, dynamic>? frameData = await platform.invokeMethod('getLatestFrame');
      if (frameData == null) return;

      final String imagePath = frameData['path'];
      final int imgWidth = frameData['width'];
      final int imgHeight = frameData['height'];

      // 1. استخراج الفقاعات محلياً بواسطة ML Kit (بدون استهلاك API)
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      // فلترة الكتل النصية الصغيرة جداً (أرقام الصفحات أو الضوضاء)
      final validBlocks = recognizedText.blocks.where((b) => b.text.trim().length > 2).toList();

      if (validBlocks.isEmpty) {
        await FlutterOverlayWindow.shareData(jsonEncode({"bubbles": []}));
        return;
      }

      // 2. فحص هل تغير الكلام على الشاشة أم أن المستخدم لم يحرك الصفحة؟
      final currentSignature = validBlocks.map((b) => b.text).join("|");
      if (currentSignature == _lastExtractedSignature) {
        return; // نفس الفقاعات معروضة حالياً، لا ترسل لـ Gemini!
      }
      _lastExtractedSignature = currentSignature;

      // 3. تجهيز النصوص لإرسالها دفعة واحدة لـ Gemini كـ Text خفيف
      final List<String> indexedTexts = [];
      for (int i = 0; i < validBlocks.length; i++) {
        indexedTexts.add('[$i] ${validBlocks[i].text.replaceAll('\n', ' ')}');
      }

      final response = await _model!.generateContent([
        Content.text(indexedTexts.join('\n'))
      ]);

      final Map<String, dynamic> jsonResp = jsonDecode(response.text ?? '{"translations":[]}');
      final List<dynamic> translatedList = jsonResp['translations'] ?? [];

      // 4. ربط كل ترجمة بإحداثيات الفقاعة الأصلية كنسبة مئوية من الشاشة
      final List bubblesPayload = [];
      for (int i = 0; i < validBlocks.length; i++) {
        if (i >= translatedList.length) break;
        final rect = validBlocks[i].boundingBox;
        bubblesPayload.add({
          "text": translatedList[i].toString(),
          "leftRatio": rect.left / imgWidth,
          "topRatio": rect.top / imgHeight,
          "widthRatio": rect.width / imgWidth,
          "heightRatio": rect.height / imgHeight,
        });
      }

      // 5. إرسال الفقاعات المترجمة للنافذة الشفافة لترسمها فوق الفقاعات الأصلية
      await FlutterOverlayWindow.shareData(jsonEncode({"bubbles": bubblesPayload}));

    } catch (e) {
      debugPrint("Translation loop error: $e");
    } finally {
      _isBusy = false;
    }
  }

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('مترجم الفقاعات المباشر (ML Kit + Gemini)')),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextField(
                  controller: _apiKeyController,
                  decoration: const InputDecoration(
                    labelText: 'أدخل Gemini API Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 55),
                    backgroundColor: _isRunning ? Colors.red : Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _startOrStopLive,
                  child: Text(_isRunning ? 'إيقاف الترجمة' : 'تشغيل تغطية الفقاعات التلقائية'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// شاشة الـ Overlay الشفافة التي ترسم المربعات البيضاء فوق فقاعات المانهوا
class BubbleOverlayScreen extends StatefulWidget {
  const BubbleOverlayScreen({super.key});

  @override
  State<BubbleOverlayScreen> createState() => _BubbleOverlayScreenState();
}

class _BubbleOverlayScreenState extends State<BubbleOverlayScreen> {
  List<dynamic> _bubbles = [];

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((raw) {
      try {
        final decoded = jsonDecode(raw.toString());
        if (mounted) {
          setState(() => _bubbles = decoded['bubbles'] ?? []);
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: _bubbles.map((b) {
            final double left = (b['leftRatio'] as num) * screenSize.width;
            final double top = (b['topRatio'] as num) * screenSize.height;
            final double width = (b['widthRatio'] as num) * screenSize.width;
            final double height = (b['heightRatio'] as num) * screenSize.height;

            return Positioned(
              left: left,
              top: top,
              width: width < 60 ? 60 : width,
              height: height < 35 ? 35 : height,
              child: Container(
                padding: const EdgeInsets.all(4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95), // يغطي الكلام الأجنبي باللون الأبيض
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width),
                    child: Text(
                      b['text'],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
