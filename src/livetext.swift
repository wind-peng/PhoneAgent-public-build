// v0.9.18:用 iOS 16 的 VisionKit ImageAnalyzer(相册"识别文字"同一个引擎)识别图片文字,只给 OCR 自检用
import UIKit
import VisionKit
import ObjectiveC

final class PALiveBox: @unchecked Sendable { var s = "超时(20 秒没返回)" }

// v0.9.19 探测:列出 ImageAnalysis 内部对象和方法,找每行文字的位置
func paMethods(_ o: AnyObject) -> String {
    var out: [String] = []
    var c: AnyClass? = object_getClass(o)
    var depth = 0
    while let cc = c, depth < 3 {
        let name = NSStringFromClass(cc)
        if name == "NSObject" { break }
        var n: UInt32 = 0
        var ms: [String] = []
        if let list = class_copyMethodList(cc, &n) {
            for i in 0..<Int(n) {
                let sel = NSStringFromSelector(method_getName(list[i]))
                let l = sel.lowercased()
                if ["line", "quad", "bound", "rect", "text", "word", "result", "element", "analysis", "item"].contains(where: { l.contains($0) }) && !sel.hasPrefix("_set") && !sel.hasPrefix("set") { ms.append(sel) }
            }
            free(list)
        }
        out.append("\(name){\(ms.prefix(40).joined(separator: " "))}")
        c = class_getSuperclass(cc); depth += 1
    }
    return out.joined(separator: " < ")
}
func paDump(_ v: Any, _ label: String, _ depth: Int, _ out: inout [String]) {
    if depth > 4 || out.count > 80 { return }
    let m = Mirror(reflecting: v)
    var line = String(repeating: "  ", count: depth) + label + ": " + String(describing: type(of: v))
    var ivarKids: [(String, Any)] = []
    if let o = v as? NSObject {
        line += " objc " + paMethods(o)
        var c: AnyClass? = object_getClass(o)
        while let cc = c, NSStringFromClass(cc) != "NSObject" {
            var n: UInt32 = 0
            if let list = class_copyIvarList(cc, &n) {
                for i in 0..<Int(n) {
                    let iv = list[i]
                    let nm = ivar_getName(iv).map { String(cString: $0) } ?? "?"
                    let ty = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
                    line += " [\(nm):\(ty)]"
                    if ty.hasPrefix("@"), let val = object_getIvar(o, iv) { ivarKids.append((nm, val)) }
                }
                free(list)
            }
            c = class_getSuperclass(cc)
        }
        if let arr = o as? NSArray, let f = arr.firstObject { line += " count=\(arr.count)"; ivarKids.append(("[0]", f)) }
    }
    out.append(line)
    for (nm, val) in ivarKids.prefix(12) { paDump(val, nm, depth + 1, &out) }
    for ch in m.children { paDump(ch.value, ch.label ?? "?", depth + 1, &out) }
}

@objc(PALiveText) public final class PALiveText: NSObject {
    @objc public static var probe = false
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
                if PALiveText.probe {
                    var lines: [String] = []
                    paDump(r, "analysis", 0, &lines)
                    box.s += "\n【探测】\n" + lines.joined(separator: "\n")
                }
            } catch {
                box.s = "失败:\(error)"
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return box.s
    }
}
