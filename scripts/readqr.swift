// Prints the QR codes in an image: checks the Mac's pairing window. Usage: swift scripts/readqr.swift shot.png
import CoreImage
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = CIImage(contentsOf: url),
      let d = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { exit(1) }
for f in d.features(in: image) { if let q = f as? CIQRCodeFeature { print(q.messageString ?? "") } }
