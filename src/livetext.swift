// v0.9.18:用 iOS 16 的 VisionKit ImageAnalyzer(相册"识别文字"同一个引擎)识别图片文字,只给 OCR 自检用
import UIKit
import VisionKit

final class PALiveBox: @unchecked Sendable { var s = "超时(20 秒没返回)" }

@objc(PALiveText) public final class PALiveText: NSObject {
    @objc(transcript:timeout:) public static func transcript(_ img: UIImage, timeout: Double) -> String {
        guard #available(iOS 16.0, *) else { return "需要 iOS 16" }
        if !ImageAnalyzer.isSupported { return "本机不支持 ImageAnalyzer" }
        let box = PALiveBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let a = ImageAnalyzer()
                let r = try await a.analyze(img, configuration: ImageAnalyzer.Configuration([.text]))
                box.s = r.transcript.isEmpty ? "成功但没识别到文字" : "成功:" + r.transcript
            } catch {
                box.s = "失败:\(error)"
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return box.s
    }
}
