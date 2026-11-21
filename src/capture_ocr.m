// PhoneAgent:截屏、OCR、诊断
#import "pa_internal.h"

#pragma mark - 截屏(多种方法依次尝试,并记录每种的结果)

static void (*pCARender)(uint32_t, CFStringRef, void *, int, int);
static void *(*pSurfCreate)(CFDictionaryRef);
static int (*pSurfLock)(void *, uint32_t, uint32_t *);
static int (*pSurfUnlock)(void *, uint32_t, uint32_t *);
static void *(*pSurfBase)(void *);
static size_t (*pSurfRowBytes)(void *);
static size_t (*pSurfW)(void *);
static size_t (*pSurfH)(void *);
static CGImageRef (*pUIGetScreenImage)(void);
static NSString *gShotMethod = @"";

NSString *loadShot(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!qc || !is) return @"dlopen QuartzCore/IOSurface 失败";
#define LOADQ(var, h, name) var = dlsym(h, name); if (!var) return @"缺少符号 " name;
    LOADQ(pCARender, qc, "CARenderServerRenderDisplay")
    LOADQ(pSurfCreate, is, "IOSurfaceCreate")
    LOADQ(pSurfLock, is, "IOSurfaceLock")
    LOADQ(pSurfUnlock, is, "IOSurfaceUnlock")
    LOADQ(pSurfBase, is, "IOSurfaceGetBaseAddress")
    LOADQ(pSurfRowBytes, is, "IOSurfaceGetBytesPerRow")
    LOADQ(pSurfW, is, "IOSurfaceGetWidth")
    LOADQ(pSurfH, is, "IOSurfaceGetHeight")
    pUIGetScreenImage = dlsym(RTLD_DEFAULT, "UIGetScreenImage"); // 可能不存在,不算失败
    return nil;
}

// 把 BGRA 的 IOSurface 拷出来做成 UIImage;note 写失败原因
static UIImage *imageFromSurface(void *surf, NSString **note) {
    pSurfLock(surf, 1, NULL);
    size_t w = pSurfW(surf), h = pSurfH(surf), rb = pSurfRowBytes(surf);
    uint8_t *base = pSurfBase(surf);
    if (!base || !w || !h || !rb) {
        pSurfUnlock(surf, 1, NULL);
        if (note) *note = [NSString stringWithFormat:@"surface 无效(%zux%zu rb=%zu)", w, h, rb];
        return nil;
    }
    NSData *data = [NSData dataWithBytes:base length:rb * h];
    pSurfUnlock(surf, 1, NULL);
    const uint8_t *bytes = data.bytes;
    BOOL allZero = YES;
    for (int i = 0; i < 600 && allZero; i++) {
        size_t off = (((size_t)i * 7919) % (w * h)) * 4;
        size_t row = off / (w * 4), col = (off % (w * 4));
        size_t o = row * rb + col;
        if (bytes[o] || bytes[o + 1] || bytes[o + 2]) allZero = NO;
    }
    if (allZero) { if (note) *note = @"画面全黑"; return nil; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef cg = CGImageCreate(w, h, 8, 32, rb, cs,
                                  kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                  dp, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    if (!cg) { if (note) *note = @"CGImageCreate 失败"; return nil; }
    UIImage *img = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

// 方法 A: +[UIWindow createScreenIOSurface]
static UIImage *shotA(NSString **note) {
    SEL sel = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:sel]) { *note = @"UIWindow 没有 createScreenIOSurface"; return nil; }
    void *surf = ((void *(*)(id, SEL))objc_msgSend)(UIWindow.class, sel);
    if (!surf) { *note = @"createScreenIOSurface 返回空"; return nil; }
    UIImage *img = imageFromSurface(surf, note);
    CFRelease(surf);
    return img;
}

// 方法 B: UIGetScreenImage()
static UIImage *shotB(NSString **note) {
    if (!pUIGetScreenImage) { *note = @"没有 UIGetScreenImage 符号"; return nil; }
    CGImageRef cg = pUIGetScreenImage();
    if (!cg) { *note = @"UIGetScreenImage 返回空"; return nil; }
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

// 方法 C: 自己 IOSurfaceCreate,再让 CARenderServer 渲染进去
static UIImage *shotC(NSString **note) {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    size_t w = (size_t)px.width, h = (size_t)px.height;
    size_t bpr = ((w * 4) + 63) & ~(size_t)63;
    NSDictionary *full = @{@"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
                           @"IOSurfaceBytesPerElement": @4, @"IOSurfaceBytesPerRow": @(bpr),
                           @"IOSurfacePixelFormat": @(0x42475241), @"IOSurfaceAllocSize": @(bpr * h)};
    void *surf = pSurfCreate((__bridge CFDictionaryRef)full);
    if (!surf) { *note = @"IOSurfaceCreate 失败"; return nil; }
    pCARender(0, CFSTR("LCD"), surf, 0, 0);
    UIImage *img = imageFromSurface(surf, note);
    CFRelease(surf);
    return img;
}

// 方法 D: 用 CVPixelBuffer 创建带 IOSurface 的缓冲,再让 CARenderServer 渲染进去
static UIImage *shotD(NSString **note) {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    size_t w = (size_t)px.width, h = (size_t)px.height;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess || !pb) { *note = [NSString stringWithFormat:@"CVPixelBufferCreate 失败(%d)", (int)r]; return nil; }
    void *surf = (void *)CVPixelBufferGetIOSurface(pb);
    if (!surf) { CVPixelBufferRelease(pb); *note = @"CVPixelBuffer 没有 IOSurface"; return nil; }
    pCARender(0, CFSTR("LCD"), surf, 0, 0);
    UIImage *img = imageFromSurface(surf, note);
    CVPixelBufferRelease(pb);
    return img;
}

// 广播帧缓存(由 ReplayKit 扩展经 /frame 推送)
NSObject *gLock;
NSData *gFrame, *gNV12;
uint32_t gNW, gNH, gNFmt;
int gExtIS = -2;
CFAbsoluteTime gFrameT, gHbT;

BOOL broadcastAlive(void) {
    @synchronized (gLock) { return gHbT > 0 && CFAbsoluteTimeGetCurrent() - gHbT < 6; }
}

// 方法 R: 用 ReplayKit 广播扩展送来的最新一帧
static UIImage *shotR(NSString **note) {
    NSData *d; CFAbsoluteTime hb;
    @synchronized (gLock) { d = gFrame; hb = gHbT; }
    if (!d) { *note = @"还没收到广播画面(广播没开?)"; return nil; }
    if (hb <= 0 || CFAbsoluteTimeGetCurrent() - hb > 6) { *note = @"广播已停止"; return nil; }
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
    if (!src) { *note = @"广播 JPEG 解码器创建失败"; return nil; }
    NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    NSNumber *w = props[(NSString *)kCGImagePropertyPixelWidth];
    NSNumber *h = props[(NSString *)kCGImagePropertyPixelHeight];
    if (!w || !h || w.unsignedIntegerValue == 0 || h.unsignedIntegerValue == 0 ||
        w.unsignedIntegerValue > 8192 || h.unsignedIntegerValue > 8192) {
        CFRelease(src);
        *note = @"广播 JPEG 尺寸无效";
        return nil;
    }
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) { *note = @"广播帧解码失败"; return nil; }
    UIImage *img = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

// 依次尝试 R→A→B→C→D;全部失败时 err 里列出每种方法的原因
UIImage *takeScreenshot(NSString **err) {
    // 广播开启时禁止调用 A-D 的私有 IOSurface 截图接口。
    // 这些接口与 ReplayKit 同时工作时可能触发系统进程级崩溃，必须只使用广播帧。
    if (broadcastAlive()) return shotR(err);
    typedef UIImage *(*ShotFn)(NSString **);
    ShotFn fns[5] = {shotR, shotA, shotB, shotC, shotD};
    NSString *names[5] = {@"R", @"A", @"B", @"C", @"D"};
    NSMutableString *report = [NSMutableString string];
    for (int i = 0; i < 5; i++) {
        NSString *note = nil;
        UIImage *img = fns[i](&note);
        if (img) { gShotMethod = names[i]; return img; }
        [report appendFormat:@"%@:%@; ", names[i], note ?: @"?"];
    }
    if (err) *err = report;
    return nil;
}

UIImage *resizeToWidth(UIImage *img, CGFloat width) {
    if (width <= 0 || width >= img.size.width) return img;
    CGFloat k = width / img.size.width;
    CGSize ns = CGSizeMake(width, img.size.height * k);
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ns format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
}

static UIImage *prepareOCRImage(UIImage *src) {
    UIImage *scaled = resizeToWidth(src, 1400);
    CIImage *input = [[CIImage alloc] initWithImage:scaled];
    if (!input) return scaled;
    CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
    [filter setValue:input forKey:kCIInputImageKey];
    [filter setValue:@0.0 forKey:kCIInputSaturationKey];
    [filter setValue:@1.18 forKey:kCIInputContrastKey];
    [filter setValue:@0.02 forKey:kCIInputBrightnessKey];
    CIContext *ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
    CGImageRef cg = [ctx createCGImage:filter.outputImage fromRect:filter.outputImage.extent];
    if (!cg) return scaled;
    UIImage *out = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return out;
}

#pragma mark - OCR (Vision)

// 返回 [{text,x,y,w,h}],坐标是屏幕点(pt),x/y 为中心点。
// iOS 16.1 的 Vision Revision 3 模型在本项目环境中会触发
// "Semaphore object deallocated while in use"，因此固定使用稳定的 Revision 1/Fast。
static NSArray *ocrWithHandler(VNImageRequestHandler *h, NSString **err) {
    if (!h) { if (err) *err = @"Vision 请求处理器为空"; return nil; }
    CGSize s = screenSize();
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.revision = VNRecognizeTextRequestRevision1;
    req.recognitionLevel = VNRequestTextRecognitionLevelFast;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;
    req.usesCPUOnly = YES;
    NSError *e = nil;
    BOOL ok = NO;
    @try { ok = [h performRequests:@[req] error:&e]; }
    @catch (NSException *ex) {
        if (err) *err = [NSString stringWithFormat:@"Vision 异常:%@", ex.reason ?: @"未知异常"];
        return nil;
    }
    if (!ok) {
        if (err) *err = e.localizedDescription ?: @"Vision 识别失败";
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (VNRecognizedTextObservation *o in req.results) {
        VNRecognizedText *t = [[o topCandidates:1] firstObject];
        if (!t.string.length) continue;
        CGRect bb = o.boundingBox;
        [out addObject:@{
            @"text": t.string,
            @"x": @((int)round((bb.origin.x + bb.size.width / 2) * s.width)),
            @"y": @((int)round((1 - bb.origin.y - bb.size.height / 2) * s.height)),
            @"w": @((int)round(bb.size.width * s.width)),
            @"h": @((int)round(bb.size.height * s.height))}];
    }
    return out;
}

// 用广播扩展送来的原始 NV12 数据建一个"不带 IOSurface"的 CVPixelBuffer 直接交给 Vision
static NSArray *ocrNV12(NSString **err) {
    NSData *nv; uint32_t w, h, fmt;
    @synchronized (gLock) { nv = gNV12; w = gNW; h = gNH; fmt = gNFmt; }
    if (!nv.length || !w || !h) { if (err) *err = @"没有 NV12 数据"; return nil; }
    if (w > 8192 || h > 8192 || (w & 1) || (h & 1)) {
        if (err) *err = [NSString stringWithFormat:@"NV12 尺寸无效(%ux%u)", w, h];
        return nil;
    }
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        if (err) *err = [NSString stringWithFormat:@"不支持的 NV12 格式(0x%x)", fmt];
        return nil;
    }
    size_t expected = (size_t)w * h + (size_t)w * h / 2;
    if (nv.length != expected) {
        if (err) *err = [NSString stringWithFormat:@"NV12 长度无效(%lu,应为%lu)",
                         (unsigned long)nv.length, (unsigned long)expected];
        return nil;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &pb);
    if (r != kCVReturnSuccess || !pb) {
        if (err) *err = [NSString stringWithFormat:@"建 CVPixelBuffer 失败(%d)", (int)r];
        return nil;
    }
    r = CVPixelBufferLockBaseAddress(pb, 0);
    if (r != kCVReturnSuccess) {
        CVPixelBufferRelease(pb);
        if (err) *err = [NSString stringWithFormat:@"锁定 NV12 缓冲失败(%d)", (int)r];
        return nil;
    }
    size_t yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1);
    uint8_t *yd = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *cd = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (!yw || !yh || !cw || !ch || !yd || !cd || nv.length != yw * yh + cw * 2 * ch) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = @"NV12 平面或数据长度无效";
        return nil;
    }
    const uint8_t *src = nv.bytes;
    size_t yrb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    if (yrb < yw) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = @"NV12 Y 平面行宽无效";
        return nil;
    }
    for (size_t i = 0; i < yh; i++) memcpy(yd + i * yrb, src + i * yw, yw);
    src += yw * yh;
    size_t crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    if (crb < cw * 2) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = @"NV12 UV 平面行宽无效";
        return nil;
    }
    for (size_t i = 0; i < ch; i++) memcpy(cd + i * crb, src + i * cw * 2, cw * 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    VNImageRequestHandler *h2 = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    NSArray *out = ocrWithHandler(h2, err);
    CVPixelBufferRelease(pb);
    return out;
}

NSArray *ocrImage(UIImage *img, NSString **err) {
    if (!img.CGImage) { if (err) *err = @"截图没有有效图像"; return nil; }
    // 先放大、灰度化并提高对比度，再交给稳定的 Revision 1/Fast，改善小字识别。
    UIImage *ocrImg = prepareOCRImage(img);
    NSMutableString *notes = [NSMutableString string];
    // 广播帧的 NV12 缓冲由 ReplayKit 提供，格式和 IOSurface 能力随系统版本变化。
    // 直接把它交给 Vision 在部分设备上会触发 CoreVideo/Vision 原生崩溃；
    // 已经校验并解码的 JPEG 是稳定路径，先用它完成 OCR。
    NSString *e2 = nil;
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:ocrImg.CGImage options:@{}];
    NSArray *r = ocrWithHandler(h, &e2);
    if (r) return r;
    [notes appendFormat:@"[图片路径]%@", e2];
    // JPEG OCR 失败时，才尝试经过完整校验的 NV12；失败只作为普通错误返回。
    if ([gShotMethod isEqualToString:@"R"]) {
        NSString *e1 = nil;
        NSArray *nv = ocrNV12(&e1);
        if (nv) return nv;
        [notes appendFormat:@" [NV12路径]%@", e1 ?: @"失败"];
    }
    if (err) *err = [NSString stringWithFormat:@"OCR 全部失败 %@", notes];
    return nil;
}

#pragma mark - 诊断:为什么创建不了 IOSurface

NSString *diagReport(void) {
    NSMutableString *r = [NSMutableString stringWithString:@"[诊断]\n"];
    [r appendFormat:@"uid=%d home=%@\n", getuid(), NSHomeDirectory()];
    [r appendFormat:@"可写 /var/mobile/Library: %@\n", access("/var/mobile/Library", W_OK) == 0 ? @"是" : @"否"];
    // 1) 实际生效的 entitlement
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    void *(*fTask)(CFAllocatorRef) = sec ? dlsym(sec, "SecTaskCreateFromSelf") : NULL;
    CFTypeRef (*fVal)(void *, CFStringRef, CFErrorRef *) = sec ? dlsym(sec, "SecTaskCopyValueForEntitlement") : NULL;
    if (fTask && fVal) {
        void *task = fTask(kCFAllocatorDefault);
        NSArray *keys = @[@"platform-application", @"com.apple.private.security.no-sandbox",
                          @"com.apple.private.security.no-container",
                          @"com.apple.private.hid.client.event-dispatch",
                          @"com.apple.backboard.client"];
        for (NSString *k in keys) {
            CFTypeRef v = task ? fVal(task, (__bridge CFStringRef)k, NULL) : NULL;
            [r appendFormat:@"  %@ = %@\n", [k stringByReplacingOccurrencesOfString:@"com.apple.private." withString:@""], v ? (__bridge id)v : @"无"];
            if (v) CFRelease(v);
        }
    } else {
        [r appendString:@"  读取 entitlement 失败(缺少 Security 符号)\n"];
    }
    // 2) 能不能打开 IOSurfaceRoot
    void *k = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    CFMutableDictionaryRef (*fMatch)(const char *) = k ? dlsym(k, "IOServiceMatching") : NULL;
    uint32_t (*fGet)(uint32_t, CFDictionaryRef) = k ? dlsym(k, "IOServiceGetMatchingService") : NULL;
    int (*fOpen)(uint32_t, uint32_t, uint32_t, uint32_t *) = k ? dlsym(k, "IOServiceOpen") : NULL;
    int (*fClose)(uint32_t) = k ? dlsym(k, "IOServiceClose") : NULL;
    if (fMatch && fGet && fOpen) {
        uint32_t svc = fGet(0, fMatch("IOSurfaceRoot"));
        [r appendFormat:@"IOSurfaceRoot 服务: %@\n", svc ? @"找到" : @"没找到"];
        if (svc) {
            uint32_t conn = 0;
            int kr = fOpen(svc, mach_task_self(), 0, &conn);
            [r appendFormat:@"IOServiceOpen(IOSurfaceRoot) = 0x%x %@\n", (unsigned)kr, kr == 0 ? @"(成功)" : @"(失败)"];
            if (kr == 0 && fClose) fClose(conn);
        }
    }
    // 3) 小尺寸 IOSurface
    if (pSurfCreate) {
        NSDictionary *d = @{@"IOSurfaceWidth": @64, @"IOSurfaceHeight": @64,
                            @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @(0x42475241)};
        void *sf = pSurfCreate((__bridge CFDictionaryRef)d);
        [r appendFormat:@"64x64 IOSurfaceCreate: %@", sf ? @"成功" : @"失败"];
        if (sf) CFRelease(sf);
    }
    return r;
}
