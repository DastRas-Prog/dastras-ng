import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'lang.dart';
import 'pal.dart';

/// Camera screen: returns the text of the first QR code it sees.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _c = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            MobileScanner(
              controller: _c,
              onDetect: (cap) {
                if (_done) return;
                for (final b in cap.barcodes) {
                  final v = b.rawValue;
                  if (v != null && v.trim().isNotEmpty) {
                    _done = true;
                    Navigator.pop(context, v.trim());
                    break;
                  }
                }
              },
            ),
            Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Pal.green, width: 3),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.flashlight_on_rounded),
                    onPressed: () => _c.toggleTorch(),
                  ),
                ]),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 60,
              child: Text(tr('scan_hint'),
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ]),
        ));
  }
}

/// Shows [data] as a QR code anyone can scan.
void showQrDialog(BuildContext context, String title, String data) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 260,
        height: 260,
        child: Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: QrImageView(data: data, version: QrVersions.auto, size: 240, backgroundColor: Colors.white),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ok')))],
    ),
  );
}
