// PhoneAgent v0.2
// 在 v0.1(点击/滑动)基础上增加:截屏、Vision OCR、本地 HTTP 接口(127.0.0.1:8200)、后台保活。
// 注意:截屏用的是私有接口,未经真机测试,失败时界面日志会写明原因。

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <mach/mach.h>

#import <ReplayKit/ReplayKit.h>
#import "shared.h"

#pragma mark - 触摸注入 (IOHID)

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;

static IOHIDEventSystemClientRef (*pClientCreate)(CFAllocatorRef);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventRef (*pCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                         uint32_t, uint32_t, double, double, double, double, double,
                                         Boolean, Boolean, uint32_t);
static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                      double, double, double, double, double,
                                      Boolean, Boolean, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int64_t);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pSetFloat)(IOHIDEventRef, uint32_t, double);
static IOHIDEventRef (*pCreateKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
static IOHIDEventSystemClientRef gClient;
static int gSwipeMode = 0; // 0 基础;1 +触点半径;2 +半径且移动事件带 Touch;3 +半径、慢速并在起止停顿;4 = 3 + 移动事件带 Range|Touch

static NSString *loadHID(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return @"dlopen IOKit 失败";
#define LOAD(var, name) var = dlsym(h, name); if (!var) return @"缺少符号 " name;
    LOAD(pClientCreate, "IOHIDEventSystemClientCreate")
    LOAD(pDispatch, "IOHIDEventSystemClientDispatchEvent")
    LOAD(pCreateDigitizer, "IOHIDEventCreateDigitizerEvent")
    LOAD(pCreateFinger, "IOHIDEventCreateDigitizerFingerEvent")
    LOAD(pAppend, "IOHIDEventAppendEvent")
    LOAD(pSetInt, "IOHIDEventSetIntegerValue")
    LOAD(pSetSender, "IOHIDEventSetSenderID")
    pSetFloat = dlsym(h, "IOHIDEventSetFloatValue");           // 可选
    pCreateKeyboard = dlsym(h, "IOHIDEventCreateKeyboardEvent"); // 可选(Home 键用)
    gClient = pClientCreate(kCFAllocatorDefault);
    if (!gClient) return @"IOHIDEventSystemClientCreate 返回空";
    return nil;
}

// phase: 0=按下 1=移动 2=抬起;nx/ny 是 0~1 的归一化坐标
static void sendFinger(double nx, double ny, int phase) {
    uint64_t t = mach_absolute_time();
    BOOL touching = (phase != 2);
    uint32_t mask = (phase == 1) ? 0x4 : 0x3;
    if (phase == 1) { if (gSwipeMode == 2) mask = 0x6; else if (gSwipeMode == 4) mask = 0x7; }
    IOHIDEventRef hand = pCreateDigitizer(kCFAllocatorDefault, t, 3, 0, 0, mask, 0,
                                          nx, ny, 0, 0, 0, touching, touching, 0);
    pSetInt(hand, 0xb0019, 1);
    IOHIDEventRef finger = pCreateFinger(kCFAllocatorDefault, t, 1, 2, mask, nx, ny, 0,
                                         touching ? 1.0 : 0.0, 0, touching, touching, 0);
    if (gSwipeMode >= 1 && pSetFloat) { pSetFloat(finger, 0xb0014, 0.04); pSetFloat(finger, 0xb0015, 0.04); } // 触点半径
    pAppend(hand, finger, 0);
    CFRelease(finger);
    pSetSender(hand, 0x8000000817319372ULL);
    pDispatch(gClient, hand);
    CFRelease(hand);
}

static CGSize screenSize(void) { return UIScreen.mainScreen.bounds.size; } // pt

static void doTap(double x, double y) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(60 * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

static void doSwipe(double x1, double y1, double x2, double y2, int steps, int ms) {
    CGSize s = screenSize();
    if (gSwipeMode >= 3) { if (steps < 40) steps = 40; if (ms < 700) ms = 700; }
    if (steps < 2) steps = 2;
    sendFinger(x1 / s.width, y1 / s.height, 0);
    if (gSwipeMode >= 3) usleep(80 * 1000);
    for (int i = 1; i <= steps; i++) {
        double k = (double)i / steps;
        usleep(ms * 1000 / steps);
        sendFinger((x1 + (x2 - x1) * k) / s.width, (y1 + (y2 - y1) * k) / s.height, 1);
    }
    if (gSwipeMode >= 3) usleep(80 * 1000);
    sendFinger(x2 / s.width, y2 / s.height, 2);
}

// 用 HID 的"Home 键"(消费者页 Menu)回主屏幕;返回是否发出了事件
static BOOL doHomeKey(void) {
    if (!pCreateKeyboard || !gClient) return NO;
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x0C, 0x40, down ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(80 * 1000);
    }
    return YES;
}

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

static NSString *loadShot(void) {
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
static NSObject *gLock;
static NSData *gFrame, *gNV12;
static uint32_t gNW, gNH, gNFmt;
static int gExtIS = -2;
static CFAbsoluteTime gFrameT, gHbT;

static BOOL broadcastAlive(void) {
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
static UIImage *takeScreenshot(NSString **err) {
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

static UIImage *resizeToWidth(UIImage *img, CGFloat width) {
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

static NSArray *ocrImage(UIImage *img, NSString **err) {
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

static NSString *diagReport(void) {
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

#pragma mark - 打开 App

static BOOL openApp(NSString *bid) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace"));
    if (!ws) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"openApplicationWithBundleID:"), bid);
}

#pragma mark - 后台保活(静音循环)

static AVAudioPlayer *gPlayer;

static NSData *silentWav(void) {
    uint32_t rate = 8000, n = rate * 2, dataLen = n; // 1 秒 16bit 单声道
    NSMutableData *d = [NSMutableData data];
    void (^w32)(uint32_t) = ^(uint32_t v) { [d appendBytes:&v length:4]; };
    void (^w16)(uint16_t) = ^(uint16_t v) { [d appendBytes:&v length:2]; };
    [d appendBytes:"RIFF" length:4]; w32(36 + dataLen);
    [d appendBytes:"WAVEfmt " length:8]; w32(16); w16(1); w16(1); w32(rate); w32(rate * 2); w16(2); w16(16);
    [d appendBytes:"data" length:4]; w32(dataLen);
    [d increaseLengthBy:dataLen];
    return d;
}

static void resumeKeepAlive(void) {
    if (!gPlayer) return;
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    if (!gPlayer.isPlaying) [gPlayer play];
}

static NSString *setKeepAlive(BOOL on) {
    static BOOL observing;
    if (on && !observing) {
        observing = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if ([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) resumeKeepAlive();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (gPlayer) { gPlayer = nil; setKeepAlive(YES); }
        }];
        [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { resumeKeepAlive(); }];
    }
    if (!on) { [gPlayer stop]; gPlayer = nil; return @"后台保活已关"; }
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSError *e = nil;
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e];
    [s setActive:YES error:&e];
    gPlayer = [[AVAudioPlayer alloc] initWithData:silentWav() error:&e];
    if (!gPlayer) return [NSString stringWithFormat:@"保活失败: %@", e.localizedDescription];
    gPlayer.numberOfLoops = -1;
    gPlayer.volume = 0.01;
    [gPlayer play];
    return @"后台保活已开";
}

#pragma mark - 本地 HTTP 接口

// 智能体部分在后面定义,这里先声明
static volatile BOOL gAgentRunning;
static void agentSay(NSString *m);
static void agentRun(NSString *task, NSString *base, NSString *key, NSString *model);
static NSMutableArray *gAgentLog; // 最近的任务日志,给 /status 用

// 读已保存的设置(空字符串按没有处理)。模型名在界面里存的键是 llm_model。
static NSString *savedSetting(NSString *k, NSString *def) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:k];
    return v.length ? v : def;
}

static NSString *gToken;

static void sendResp(int c, int code, NSString *ctype, NSData *body) {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        code, ctype, (unsigned long)body.length];
    NSData *hd = [head dataUsingEncoding:NSUTF8StringEncoding];
    write(c, hd.bytes, hd.length);
    const uint8_t *p = body.bytes; size_t left = body.length;
    while (left > 0) {
        ssize_t n = write(c, p, left);
        if (n <= 0) break;
        p += n; left -= n;
    }
    close(c);
}

static void sendJSON(int c, int code, id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data];
    sendResp(c, code, @"application/json; charset=utf-8", d);
}

static void handleClient(int c) {
    NSMutableData *raw = [NSMutableData data];
    char buf[65536];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange he = NSMakeRange(NSNotFound, 0);
    while (he.location == NSNotFound && raw.length < 262144) {
        ssize_t n = read(c, buf, sizeof buf);
        if (n <= 0) break;
        [raw appendBytes:buf length:n];
        he = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
    }
    if (he.location == NSNotFound) { close(c); return; }
    NSString *head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, he.location)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    NSUInteger bodyStart = he.location + 4;
    long long clen = 0;
    for (NSString *ln in [head componentsSeparatedByString:@"\r\n"])
        if ([ln.lowercaseString hasPrefix:@"content-length:"]) clen = [[ln substringFromIndex:15] longLongValue];
    if (clen < 0 || clen > 8 * 1024 * 1024) { close(c); return; }
    while (raw.length < bodyStart + clen) {
        ssize_t n = read(c, buf, sizeof buf);
        if (n <= 0) break;
        [raw appendBytes:buf length:n];
    }
    NSData *body = (clen > 0 && raw.length >= bodyStart + clen)
        ? [raw subdataWithRange:NSMakeRange(bodyStart, (NSUInteger)clen)] : nil;
    NSArray *parts = [[[head componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
    if (parts.count < 2) { close(c); return; }
    NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://h" stringByAppendingString:parts[1]]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
    NSString *path = uc.path ?: @"/";
    CGSize s = screenSize();

    if ([path isEqualToString:@"/ping"]) {
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"version": @"0.5.3", @"broadcast": @(broadcastAlive())});
        return;
    }
    if ([path isEqualToString:@"/frame"] || [path isEqualToString:@"/hb"] || [path isEqualToString:@"/bye"]) {
        if (![q[@"key"] isEqualToString:[NSString stringWithUTF8String:FRAME_KEY]]) {
            sendJSON(c, 403, @{@"ok": @NO});
            return;
        }
        BOOL was = broadcastAlive();
        @synchronized (gLock) {
            if ([path isEqualToString:@"/bye"]) {
                gHbT = 0;
            } else {
                gHbT = CFAbsoluteTimeGetCurrent();
                if (q[@"is"]) gExtIS = [q[@"is"] intValue];
                if (body.length && [path isEqualToString:@"/frame"]) {
                    NSData *jpg = body, *nv = nil; uint32_t w = 0, h = 0, fmt = 0;
                    if (body.length >= 24 && memcmp(body.bytes, "PAF1", 4) == 0) {
                        uint32_t hd[6]; memcpy(hd, body.bytes, 24);
                        uint32_t jl = hd[3], nl = hd[4];
                        if (24 + (uint64_t)jl + nl <= body.length) {
                            w = hd[1]; h = hd[2]; fmt = hd[5];
                            jpg = [body subdataWithRange:NSMakeRange(24, jl)];
                            nv = nl ? [body subdataWithRange:NSMakeRange(24 + jl, nl)] : nil;
                        }
                    }
                    gFrame = jpg; gNV12 = nv; gNW = w; gNH = h; gNFmt = fmt; gFrameT = gHbT;
                }
            }
        }
        BOOL now = broadcastAlive();
        if (!was && now) [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"广播扩展已连接(扩展内创建 IOSurface:%@)", gExtIS == 1 ? @"成功" : gExtIS == 0 ? @"失败" : @"未知"]];
        if (was && !now) [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"广播已停止"];
        sendJSON(c, 200, @{@"ok": @YES});
        return;
    }
    if (![q[@"token"] isEqualToString:gToken]) {
        sendJSON(c, 403, @{@"ok": @NO, @"error": @"token 不对"});
        return;
    }
    if ([path isEqualToString:@"/tap"]) {
        doTap([q[@"x"] doubleValue], [q[@"y"] doubleValue]);
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/swipe"]) {
        int ms = q[@"ms"] ? [q[@"ms"] intValue] : 300;
        doSwipe([q[@"x1"] doubleValue], [q[@"y1"] doubleValue],
                [q[@"x2"] doubleValue], [q[@"y2"] doubleValue], 20, ms);
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/open"]) {
        BOOL ok = openApp(q[@"bundle"] ?: @"");
        sendJSON(c, 200, @{@"ok": @(ok)});
    } else if ([path isEqualToString:@"/screenshot"]) {
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { sendJSON(c, 500, @{@"ok": @NO, @"error": err ?: @"未知错误"}); return; }
        img = resizeToWidth(img, [q[@"w"] doubleValue]);
        sendResp(c, 200, @"image/jpeg", UIImageJPEGRepresentation(img, 0.6));
    } else if ([path isEqualToString:@"/task"]) {
        // 给快捷指令/Siri 用:GET /task?token=..&text=<URL 编码的任务>,或 POST 正文直接放任务文字
        NSString *task = q[@"text"];
        if (!task.length && body.length) task = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSString *key = savedSetting(@"llm_key", @""), *base = savedSetting(@"llm_base", @"https://api.deepseek.com"), *model = savedSetting(@"llm_model", savedSetting(@"llm_model2", @"deepseek-flash"));
        if (!task.length) { sendJSON(c, 400, @{@"ok": @NO, @"error": @"没有任务文字"}); return; }
        if (!key.length || !base.length || !model.length) {
            sendJSON(c, 400, @{@"ok": @NO, @"error": @"还没保存 API 设置:请先在 App 里点一次“开始任务”或“看图测试”"});
            return;
        }
        if (gAgentRunning) { sendJSON(c, 409, @{@"ok": @NO, @"error": @"已有任务在运行"}); return; }
        if (!broadcastAlive()) { sendJSON(c, 409, @{@"ok": @NO, @"error": @"屏幕广播没开,请先在 PhoneAgent 里开启"}); return; }
        agentSay([NSString stringWithFormat:@"收到语音任务:%@", task]);
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"收到语音任务:%@", task]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(task, base, key, model); });
        sendJSON(c, 200, @{@"ok": @YES, @"task": task});
    } else if ([path isEqualToString:@"/stop"]) {
        gAgentRunning = NO;
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/status"]) {
        NSArray *lines;
        @synchronized (gLock) { lines = [gAgentLog copy] ?: @[]; }
        NSUInteger n = lines.count > 15 ? lines.count - 15 : 0;
        sendJSON(c, 200, @{@"ok": @YES, @"running": @(gAgentRunning), @"broadcast": @(broadcastAlive()),
                           @"log": [lines subarrayWithRange:NSMakeRange(n, lines.count - n)]});
    } else if ([path isEqualToString:@"/ocr"]) {
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { sendJSON(c, 500, @{@"ok": @NO, @"error": err ?: @"未知错误"}); return; }
        NSArray *items = ocrImage(img, &err);
        if (!items) { sendJSON(c, 500, @{@"ok": @NO, @"error": err ?: @"未知错误"}); return; }
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"items": items});
    } else {
        sendJSON(c, 404, @{@"ok": @NO, @"error": @"未知接口"});
    }
}

static NSString *startServer(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return @"socket 失败";
    int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock, (struct sockaddr *)&a, sizeof a) != 0) { close(sock); return [NSString stringWithFormat:@"bind %d 失败(端口被占用?)", PORT]; }
    if (listen(sock, 8) != 0) { close(sock); return @"listen 失败"; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (1) {
            int c = accept(sock, NULL, NULL);
            if (c < 0) continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ handleClient(c); });
        }
    });
    return nil;
}

#pragma mark - 智能体循环

static volatile BOOL gAgentRunning = NO;

static void agentSay(NSString *m) {
    @synchronized (gLock) {
        if (gAgentLog) { [gAgentLog addObject:m ?: @""]; if (gAgentLog.count > 40) [gAgentLog removeObjectAtIndex:0]; }
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:m];
}

static void doLongPress(double x, double y, int ms) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(ms * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

// 按 App 名称找 bundle id(用系统私有接口列出已安装 App)
static NSString *bundleForAppName(NSString *name, NSString **info) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) { *info = @"没有 LSApplicationWorkspace"; return nil; }
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace"));
    SEL sel = NSSelectorFromString(@"allInstalledApplications");
    if (!ws || ![ws respondsToSelector:sel]) { *info = @"无法列出已安装 App"; return nil; }
    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, sel);
    NSMutableArray *names = [NSMutableArray array], *bids = [NSMutableArray array], *userNames = [NSMutableArray array];
    for (id a in apps) {
        NSString *n = nil, *bid = nil, *type = nil;
        @try { n = [a valueForKey:@"localizedName"]; bid = [a valueForKey:@"applicationIdentifier"]; type = [a valueForKey:@"applicationType"]; }
        @catch (NSException *ex) { continue; }
        if (![n isKindOfClass:NSString.class] || ![bid isKindOfClass:NSString.class] || !n.length) continue;
        [names addObject:n]; [bids addObject:bid];
        if ([type isKindOfClass:NSString.class] && [type isEqualToString:@"User"]) [userNames addObject:n];
    }
    NSString *q = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *exact = nil, *partial = nil;
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *n = names[i];
        if ([n caseInsensitiveCompare:q] == NSOrderedSame) { exact = bids[i]; break; }
        if (!partial && q.length >= 2 && ([n localizedCaseInsensitiveContainsString:q] || (n.length >= 2 && [q localizedCaseInsensitiveContainsString:n]))) partial = bids[i];
    }
    NSString *r = exact ?: partial;
    if (!r) { // 常见 App 别名(只有确实装了才会命中);长的关键词放前面
        NSArray *alias = @[@[@"网易云音乐", @"com.netease.cloudmusic"], @[@"哔哩哔哩", @"tv.danmaku.bilianime"],
            @[@"百度地图", @"com.baidu.map"], @[@"腾讯地图", @"com.tencent.sosomap"], @[@"小红书", @"com.xingin.discover"],
            @[@"拼多多", @"com.xunmeng.pinduoduo"], @[@"支付宝", @"com.alipay.iphoneclient"], @[@"高德", @"com.autonavi.amap"],
            @[@"微信", @"com.tencent.xin"], @[@"淘宝", @"com.taobao.taobao4iphone"], @[@"京东", @"com.360buy.jdmobile"],
            @[@"美团", @"com.meituan.imeituan"], @[@"抖音", @"com.ss.iphone.ugc.Aweme"], @[@"微博", @"com.sina.weibo"],
            @[@"钉钉", @"com.laiwang.DingTalk"], @[@"饿了么", @"me.ele.ios.eleme"], @[@"滴滴", @"com.xiaojukeji.didi"],
            @[@"备忘录", @"com.apple.mobilenotes"], @[@"设置", @"com.apple.Preferences"], @[@"相机", @"com.apple.camera"],
            @[@"照片", @"com.apple.mobileslideshow"], @[@"电话", @"com.apple.mobilephone"], @[@"信息", @"com.apple.MobileSMS"],
            @[@"Safari", @"com.apple.mobilesafari"], @[@"QQ", @"com.tencent.mqq"], @[@"地图", @"com.apple.Maps"]];
        for (NSArray *pair in alias)
            if ([q localizedCaseInsensitiveContainsString:pair[0]] && [bids containsObject:pair[1]]) { r = pair[1]; break; }
    }
    if (!r) {
        NSArray *shown = userNames.count > 60 ? [userNames subarrayWithRange:NSMakeRange(0, 60)] : userNames;
        *info = [NSString stringWithFormat:@"没找到名为「%@」的 App。已安装的第三方 App:%@。请改用其中的准确名称重试 open_app;如果目标 App 不在列表里,说明没装,请 stop 告诉用户。不要用滑动去主屏幕里找。",
                 name, [shown componentsJoinedByString:@"、"]];
    }
    return r;
}

static NSDictionary *parseModelJSON(NSString *raw) {
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *s = [raw stringByReplacingOccurrencesOfString:@"```json" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"```" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"：" withString:@":"];
    s = [s stringByReplacingOccurrencesOfString:@"，" withString:@","];
    s = [s stringByReplacingOccurrencesOfString:@"“" withString:@"\""];
    s = [s stringByReplacingOccurrencesOfString:@"”" withString:@"\""];
    s = [s stringByReplacingOccurrencesOfString:@"mvisible_text\"\"" withString:@"\"visible_text\":\""];
    NSRange begin = [s rangeOfString:@"{"];
    NSRange end = [s rangeOfString:@"}" options:NSBackwardsSearch];
    if (begin.location == NSNotFound || end.location == NSNotFound || end.location < begin.location) return nil;
    s = [s substringWithRange:NSMakeRange(begin.location, end.location - begin.location + 1)];
    id obj = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSDictionary *callLLM(NSString *base, NSString *key, NSString *model, NSArray *messages, NSString **err) {
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
    if (!url) { *err = @"接口地址格式不对"; return nil; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 90;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    NSDictionary *body = @{@"model": model, @"messages": messages, @"temperature": @0.1,
                           @"max_tokens": @700, @"response_format": @{@"type": @"json_object"}};
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    __block NSData *data = nil; __block NSError *e = nil; __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *er) {
        data = d; e = er; code = [(NSHTTPURLResponse *)resp statusCode];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (e || !data) { *err = [NSString stringWithFormat:@"网络错误:%@", e.localizedDescription ?: @"无数据"]; return nil; }
    if (code != 200) {
        NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        *err = [NSString stringWithFormat:@"接口返回 %ld: %@", (long)code, t.length > 200 ? [t substringToIndex:200] : t];
        return nil;
    }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *content = nil;
    @try { content = j[@"choices"][0][@"message"][@"content"]; } @catch (NSException *ex) {}
    if (![content isKindOfClass:NSString.class]) { *err = @"接口返回格式不认识"; return nil; }
    content = [[content stringByReplacingOccurrencesOfString:@"```json" withString:@""]
               stringByReplacingOccurrencesOfString:@"```" withString:@""];
    NSDictionary *act = parseModelJSON(content);
    if (![act isKindOfClass:NSDictionary.class]) {
        *err = [NSString stringWithFormat:@"模型没返回 JSON: %@", content.length > 120 ? [content substringToIndex:120] : content];
        return nil;
    }
    return act;
}

static NSString *const kAgentSystem =
@"你是一个控制 iPhone 的视觉智能体。每一步都会收到:任务、最近的动作历史、一张当前屏幕截图(780x1688 像素,图上叠加了红色网格线,每 100 像素一条,边缘标有像素数字),以及本地 OCR 识别出的带编号文字列表。\n"
@"所有坐标(x,y,x2,y2,以及 OCR 列表里的坐标)都是这张截图的像素坐标:左上角 (0,0),右下角 (780,1688),x 向右,y 向下。请对照网格线和边缘数字估计位置,点击要落在目标元素的中心。\n"
@"只输出一个 JSON 对象,不要输出其他内容。thought 不超过20个字；visible_text 只抄录关键文字且不超过120字；然后输出 action 和参数。\n"
@"action 可选值:\n"
@"- tap: 参数 id 或 x,y。点击。目标是 OCR 列表里的文字时,优先只给 id(程序会点该文字的中心,最准);没有文字的图标或空白输入框才给 x,y。\n"
@"- long_press: 参数 id 或 x,y。长按。\n"
@"- swipe: 参数 x,y,x2,y2,或只给 direction(up/down/left/right,表示手指滑动的方向)。往下看更多内容用 up。本设备上滑动可能不稳定,能用别的办法就别滑。\n"
@"- home: 回到主屏幕。需要回主屏幕时只用这个动作,不要用 swipe。\n"
@"- open_app: 参数 name(App 的中文名)。直接打开 App。\n"
@"- input_text: 参数 id 或 x,y,text,可选 app(当前所在 App 的名字)。程序会先临时切到 PhoneAgent 把 text 写入剪贴板(iOS 不允许后台 App 写剪贴板),再切回原来的 App,点击并长按输入框呼出菜单;下一步必须观察并点击“粘贴”或“允许粘贴”,再确认输入框出现目标文字。这是输入文字的首选动作,text 必须是要输入的完整文字。\n"
@"- set_clipboard: 参数 text,可选 app。只把文字放进剪贴板(同样会临时切到 PhoneAgent 再切回),不点击。一般直接用 input_text。\n"
@"- wait: 等待 1.5 秒。\n"
@"- done: 参数 text。任务已完成。\n"
@"- stop: 参数 text。无法继续或需要人工处理。\n"
@"规则:\n"
@"1. 有文字的目标一律用 id;只有没有文字的图标/输入框才给 x,y,并对照网格线估计。\n"
@"2. 只做到\"加入购物车\"为止。绝不点击结算、支付、提交订单、立即购买、确认付款;遇到这些步骤立即 stop。\n"
@"3. 每步只做一个动作。\n"
@"4. 屏幕连续没变化就换一种办法,仍不行就 stop。\n"
@"5. 看不到想要的内容时,先上滑或换搜索词,不要重复无效动作。\n"
@"6. visible_text 必须如实抄录截图中的关键文字,如果看到支付密码、付款、结算、提交订单等内容,action 必须为 stop。\n"
@"7. 找不到 App 时,按 open_app 返回的已安装 App 列表换准确名称重试;列表里没有就 stop。不要靠滑动去主屏幕里翻找 App。\n"
@"8. input_text 后如果看到“粘贴”或“允许粘贴”，必须点击对应菜单；如果输入框仍为空，重新使用 input_text，不要只重复 tap。";

static NSArray *visionMessages(NSString *task, NSString *history, UIImage *img, NSString **err) {
    UIImage *scaled = resizeToWidth(img, 1400);
    NSData *jpg = UIImageJPEGRepresentation(scaled, 0.85);
    if (!jpg.length) { if (err) *err = @"截图 JPEG 编码失败"; return nil; }
    NSString *b64 = [jpg base64EncodedStringWithOptions:0];
    if (!b64.length) { if (err) *err = @"截图 Base64 编码失败"; return nil; }
    NSString *text = [NSString stringWithFormat:
                      @"任务:%@\n\n最近的动作:\n%@\n请观察下面这张当前屏幕截图并返回一个 JSON 动作。",
                      task, history.length ? history : @"(还没有)"];
    NSDictionary *image = @{ @"type": @"image_url",
                             @"image_url": @{ @"url": [@"data:image/jpeg;base64," stringByAppendingString:b64],
                                               @"detail": @"original" }};
    NSDictionary *user = @{ @"role": @"user", @"content": @[
        @{ @"type": @"text", @"text": text }, image ] };
    return @[ @{ @"role": @"system", @"content": kAgentSystem }, user ];
}

static NSArray *textMessages(NSString *task, NSString *history, NSArray *items) {
    NSMutableString *screen = [NSMutableString string];
    int n = 0;
    for (NSDictionary *it in items) {
        if (n++ >= 120) break;
        NSString *t = it[@"text"];
        if (t.length > 60) t = [t substringToIndex:60];
        [screen appendFormat:@"(%@,%@) %@\n", it[@"x"], it[@"y"], t];
    }
    if (!screen.length) [screen appendString:@"(本地 OCR 没有识别到文字)\n"];
    NSString *user = [NSString stringWithFormat:
                      @"任务:%@\n\n最近的动作:\n%@\n当前屏幕文字(x,y 文字):\n%@",
                      task, history.length ? history : @"(还没有)\n", screen];
    return @[ @{ @"role": @"system", @"content": kAgentSystem },
              @{ @"role": @"user", @"content": user } ];
}

#define MODEL_W 780
#define MODEL_H 1688

// 把截图缩放到固定的 780x1688(正好是屏幕 pt 尺寸的 2 倍),并叠加每 100 像素一条的红色网格和边缘数字,
// 帮助视觉模型把"看到的位置"换算成坐标。
static UIImage *renderForModel(UIImage *src) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(MODEL_W, MODEL_H) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:CGRectMake(0, 0, MODEL_W, MODEL_H)];
        CGContextRef c = ctx.CGContext;
        CGContextSetLineWidth(c, 1);
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:1 green:0 blue:0 alpha:0.35].CGColor);
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
                                NSForegroundColorAttributeName: UIColor.redColor,
                                NSBackgroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75]};
        for (int x = 100; x < MODEL_W; x += 100) {
            CGContextMoveToPoint(c, x, 0); CGContextAddLineToPoint(c, x, MODEL_H); CGContextStrokePath(c);
            NSString *t = [NSString stringWithFormat:@"%d", x];
            [t drawAtPoint:CGPointMake(x + 2, 2) withAttributes:attrs];
            [t drawAtPoint:CGPointMake(x + 2, MODEL_H - 22) withAttributes:attrs];
        }
        for (int y = 100; y < MODEL_H; y += 100) {
            CGContextMoveToPoint(c, 0, y); CGContextAddLineToPoint(c, MODEL_W, y); CGContextStrokePath(c);
            NSString *t = [NSString stringWithFormat:@"%d", y];
            [t drawAtPoint:CGPointMake(2, y + 2) withAttributes:attrs];
            [t drawAtPoint:CGPointMake(MODEL_W - 46, y + 2) withAttributes:attrs];
        }
    }];
}

static NSArray *hybridMessages(NSString *task, NSString *history, UIImage *img, NSArray *items, NSString **err) {
    UIImage *scaled = renderForModel(img);
    NSData *jpg = UIImageJPEGRepresentation(scaled, 0.8);
    if (!jpg.length) { if (err) *err = @"截图 JPEG 编码失败"; return nil; }
    CGSize sc = screenSize();
    double k = MODEL_W / sc.width;
    NSMutableString *ocr = [NSMutableString string];
    int n = 0;
    for (NSDictionary *it in items) {
        if (n >= 80) break;
        n++;
        NSString *t = it[@"text"];
        if (t.length > 40) t = [t substringToIndex:40];
        [ocr appendFormat:@"[%d] (%d,%d) %@\n", n, (int)round([it[@"x"] doubleValue] * k), (int)round([it[@"y"] doubleValue] * k), t];
    }
    if (!ocr.length) [ocr appendString:@"(本地 OCR 没有识别到文字)\n"];
    NSString *text = [NSString stringWithFormat:
                      @"任务:%@\n\n最近的动作:\n%@\n本地 OCR 文字列表(格式 [编号] (中心x,中心y) 文字,坐标是截图像素):\n%@\n请观察截图,决定一个 JSON 动作。",
                      task, history.length ? history : @"(还没有)", ocr];
    NSDictionary *image = @{ @"type": @"image_url",
                             @"image_url": @{ @"url": [@"data:image/jpeg;base64," stringByAppendingString:[jpg base64EncodedStringWithOptions:0]],
                                               @"detail": @"original" }};
    return @[ @{ @"role": @"system", @"content": kAgentSystem },
              @{ @"role": @"user", @"content": @[ @{ @"type": @"text", @"text": text }, image ] } ];
}

static NSArray *kDangerWords(void) {
    return @[@"立即支付", @"确认支付", @"去支付", @"付款", @"提交订单", @"立即购买", @"去结算", @"结算",
             @"确认付款", @"支付密码", @"免密支付"];
}

// 点击位置附近的文字含有支付类词语时返回该文字
static NSString *dangerNear(NSArray *items, double x, double y) {
    for (NSDictionary *it in items) {
        double dx = fabs([it[@"x"] doubleValue] - x), dy = fabs([it[@"y"] doubleValue] - y);
        double hw = [it[@"w"] doubleValue] / 2 + 25, hh = [it[@"h"] doubleValue] / 2 + 25;
        if (dx <= hw && dy <= hh)
            for (NSString *k in kDangerWords()) if ([it[@"text"] containsString:k]) return it[@"text"];
    }
    return nil;
}

static BOOL paySheetVisible(NSArray *items) {
    for (NSDictionary *it in items) {
        NSString *t = it[@"text"];
        if ([t containsString:@"输入支付密码"] || [t containsString:@"请输入密码"] || [t containsString:@"确认付款"]) return YES;
    }
    return NO;
}

static NSString *gLastApp; // 最近一次 open_app 成功打开的 bundle id

// 当前最前台 App 的 bundle id(SpringBoardServices 私有接口,失败返回 nil)。
// 先在 NSUserDefaults 里打个"可能崩溃"的标记,万一这个接口在本系统上签名不对导致崩溃,下次启动就自动停用。
static NSString *frontmostBundleID(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:@"sbfront_crashed"]) return nil;
    static void *h; static mach_port_t (*getPort)(void); static void (*getFront)(mach_port_t, char *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        if (h) {
            getPort = dlsym(h, "SBSSpringBoardServerPort");
            getFront = dlsym(h, "SBFrontmostApplicationDisplayIdentifier");
        }
    });
    if (!getPort || !getFront) return nil;
    [d setBool:YES forKey:@"sbfront_crashed"]; [d synchronize];
    mach_port_t port = getPort();
    char buf[512]; memset(buf, 0, sizeof buf);
    if (port) getFront(port, buf);
    [d setBool:NO forKey:@"sbfront_crashed"]; [d synchronize];
    return buf[0] ? [NSString stringWithUTF8String:buf] : nil;
}

static UIApplicationState appStateNow(void) {
    __block UIApplicationState st = UIApplicationStateBackground;
    dispatch_sync(dispatch_get_main_queue(), ^{ st = UIApplication.sharedApplication.applicationState; });
    return st;
}

static BOOL waitAppActive(double timeout) {
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + timeout;
    while (CFAbsoluteTimeGetCurrent() < end) {
        if (appStateNow() == UIApplicationStateActive) return YES;
        usleep(200 * 1000);
    }
    return NO;
}

// 写剪贴板。iOS 9 起不允许后台 App 访问剪贴板(写入也会被忽略),而 PhoneAgent 平时都在后台操作别的 App,
// 所以这里先把 PhoneAgent 切到前台、写入并读回校验,再切回原来的 App。
// 返回 YES 表示写入并校验成功;stranded 为 YES 表示切走后没能自动回去(需要模型用 open_app 回到目标 App)。
static BOOL writeClipboardInForeground(NSString *text, NSString *backHint, NSString **note, BOOL *stranded) {
    *stranded = NO;
    NSString *selfID = NSBundle.mainBundle.bundleIdentifier;
    BOOL switched = NO;
    NSString *back = nil;
    if (appStateNow() != UIApplicationStateActive) {
        back = frontmostBundleID();
        if (!back.length || [back isEqualToString:selfID] || [back isEqualToString:@"com.apple.springboard"])
            back = backHint.length ? backHint : gLastApp;
        if (!openApp(selfID) || !waitAppActive(5)) { *note = @"没能把 PhoneAgent 切到前台,无法写剪贴板"; return NO; }
        switched = YES;
        usleep(500 * 1000);
    }
    __block NSString *check = nil; __block NSInteger cc0 = 0, cc1 = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIPasteboard *pb = UIPasteboard.generalPasteboard;
        cc0 = pb.changeCount;
        pb.string = text;
        cc1 = pb.changeCount;
        check = pb.string;
    });
    BOOL ok = [check isEqualToString:text];
    if (!ok) *note = [NSString stringWithFormat:@"剪贴板写入后读回不一致(changeCount %ld→%ld)", (long)cc0, (long)cc1];
    if (switched) {
        if (back.length && ![back isEqualToString:selfID] && ![back isEqualToString:@"com.apple.springboard"]) {
            openApp(back);
            sleep(2);
        } else {
            *stranded = YES;
        }
    }
    return ok;
}

// 回主屏幕:先发 Home 键事件;如果还能查到最前台 App 并且不是主屏,再尝试从底部上滑
static BOOL goHome(NSString **note) {
    BOOL sent = doHomeKey();
    sleep(1);
    NSString *f = frontmostBundleID();
    if ([f isEqualToString:@"com.apple.springboard"]) { *note = @"Home 键事件有效"; return YES; }
    if (!f.length) { *note = sent ? @"已发送 Home 键事件(无法确认结果)" : @"没有 Home 键接口,也无法确认结果"; return sent; }
    CGSize sc = screenSize();
    doSwipe(sc.width / 2, sc.height - 2, sc.width / 2, sc.height * 0.55, 12, 180);
    sleep(1);
    f = frontmostBundleID();
    BOOL ok = [f isEqualToString:@"com.apple.springboard"];
    *note = ok ? @"底部上滑有效" : [NSString stringWithFormat:@"Home 键和上滑都没能回到主屏(当前 %@)", f ?: @"未知"];
    return ok;
}

// 等广播画面静止:最近 0.8 秒内没有新帧,说明动画/转场结束了(最多等 maxWait 秒)
static void waitForStableFrame(double maxWait) {
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + maxWait;
    while (CFAbsoluteTimeGetCurrent() < end) {
        CFAbsoluteTime ft;
        @synchronized (gLock) { ft = gFrameT; }
        if (ft > 0 && CFAbsoluteTimeGetCurrent() - ft >= 0.8) return;
        usleep(150 * 1000);
    }
}

static void agentRun(NSString *task, NSString *base, NSString *key, NSString *model) {
    if ([model isEqualToString:@"deepseek-chat"] || !model.length) model = @"deepseek-flash";
    gAgentRunning = YES;
    NSMutableArray *history = [NSMutableArray array];
    NSString *lastSig = @""; int same = 0;
    CGSize sc = screenSize();
    agentSay([NSString stringWithFormat:@"任务开始:%@", task]);
    for (int step = 1; step <= 25 && gAgentRunning; step++) {
        waitForStableFrame(3.0);
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { agentSay([@"截屏失败,任务停止:" stringByAppendingString:err ?: @"?"]); break; }
        NSArray *items = ocrImage(img, &err);
        if (items.count) items = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            int ya = [a[@"y"] intValue] / 12, yb = [b[@"y"] intValue] / 12;
            if (ya != yb) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
            return [(NSNumber *)a[@"x"] compare:(NSNumber *)b[@"x"]];
        }];
        NSString *localText = @"";
        for (NSDictionary *it in items) localText = [localText stringByAppendingFormat:@"%@", it[@"text"] ?: @""];
        BOOL localOK = items.count >= 2 && localText.length >= 6;
        NSString *screen = localOK ? localText : [NSString stringWithFormat:@"截图(%lu bytes)",
                            (unsigned long)UIImageJPEGRepresentation(img, 0.15).length];
        if ([screen isEqualToString:lastSig]) same++; else same = 0;
        lastSig = [screen copy];
        if (same >= 4) { agentSay(@"屏幕连续多步没变化,已停止"); break; }
        if (localOK && paySheetVisible(items)) { agentSay(@"本地 OCR 看到支付/密码界面,已停止,请手动处理"); break; }

        NSMutableString *hist = [NSMutableString string];
        NSUInteger from = history.count > 8 ? history.count - 8 : 0;
        for (NSUInteger i = from; i < history.count; i++) [hist appendFormat:@"%@\n", history[i]];
        NSArray *msgs = hybridMessages(task, hist, img, items, &err);
        if (!msgs) { agentSay([@"截图视觉请求失败:" stringByAppendingString:err ?: @"?"]); break; }
        NSDictionary *act = callLLM(base, key, model, msgs, &err);
        if (!act && localOK) agentSay(@"OCR+截图请求失败,稍后自动重试");
        if (!act) {
            agentSay(@"模型返回异常,1秒后重试");
            sleep(1);
            act = callLLM(base, key, model, msgs, &err);
        }
        if (!gAgentRunning) break;
        if (!act) { agentSay([@"调用模型失败,任务停止:" stringByAppendingString:err ?: @"?"]); break; }

        NSString *visible = [act[@"visible_text"] description] ?: @"";
        BOOL dangerous = NO;
        for (NSString *word in kDangerWords()) if ([visible containsString:word]) { dangerous = YES; break; }
        if (dangerous) { agentSay(@"视觉模型识别到支付/付款相关内容,任务已停止"); break; }

        NSString *action = [[act[@"action"] description] lowercaseString] ?: @"";
        NSString *thought = [act[@"thought"] description] ?: @"";
        // 模型给的是 780x1688 截图的像素坐标,换算成屏幕 pt;有 id 就直接用 OCR 文字的中心(已经是 pt)
        double kx = sc.width / MODEL_W, ky = sc.height / MODEL_H;
        double rx = [act[@"x"] doubleValue], ry = [act[@"y"] doubleValue];
        double x = rx * kx, y = ry * ky;
        double x2 = [act[@"x2"] doubleValue] * kx, y2 = [act[@"y2"] doubleValue] * ky;
        NSInteger oid = 0; id idv = act[@"id"];
        if ([idv respondsToSelector:@selector(integerValue)]) oid = [idv integerValue];
        BOOL usedID = NO; NSString *idText = @"";
        if (oid >= 1 && oid <= (NSInteger)MIN(items.count, 80)) {
            NSDictionary *it = items[oid - 1];
            x = [it[@"x"] doubleValue]; y = [it[@"y"] doubleValue];
            usedID = YES; idText = [it[@"text"] description] ?: @"";
        }
        if ([action isEqualToString:@"swipe"] && !(act[@"x"] && act[@"y"] && act[@"x2"] && act[@"y2"])) {
            NSString *dir = [[act[@"direction"] description] lowercaseString] ?: @"";
            double sx = 390, sy = 900, ex = 390, ey = 900; BOOL okDir = YES;
            if ([dir isEqualToString:@"up"]) { sy = 1250; ey = 500; }
            else if ([dir isEqualToString:@"down"]) { sy = 500; ey = 1250; }
            else if ([dir isEqualToString:@"left"]) { sx = 650; ex = 130; }
            else if ([dir isEqualToString:@"right"]) { sx = 130; ex = 650; }
            else okDir = NO;
            if (!okDir) {
                agentSay(@"提示:swipe 缺少坐标或方向,已忽略这一步");
                [history addObject:[NSString stringWithFormat:@"%d. swipe 缺少坐标/direction,未执行", step]];
                continue;
            }
            rx = sx; ry = sy; x = sx * kx; y = sy * ky; x2 = ex * kx; y2 = ey * ky;
        }
        BOOL outOfRange = (!usedID && (rx > MODEL_W + 20 || ry > MODEL_H + 20 || [act[@"x2"] doubleValue] > MODEL_W + 20 || [act[@"y2"] doubleValue] > MODEL_H + 20));
        x = MAX(0, MIN(sc.width - 1, x)); y = MAX(0, MIN(sc.height - 1, y));
        x2 = MAX(0, MIN(sc.width - 1, x2)); y2 = MAX(0, MIN(sc.height - 1, y2));
        double xpx = x / kx, ypx = y / ky;
        agentSay([NSString stringWithFormat:@"第%d步:%@ → %@ %@(%.0f,%.0f)pt", step, thought, action,
                  usedID ? [NSString stringWithFormat:@"id=%ld「%@」 ", (long)oid, idText] : @"", x, y]);
        BOOL needsXY = [action isEqualToString:@"tap"] || [action isEqualToString:@"long_press"] ||
                       [action isEqualToString:@"swipe"] || [action isEqualToString:@"input_text"];
        if (needsXY && outOfRange) {
            agentSay(@"提示:模型给的坐标超出截图范围(应为 0~780 x 0~1688),已忽略这一步");
            [history addObject:[NSString stringWithFormat:@"%d. %@ 的坐标超出范围,未执行;坐标必须是 780x1688 截图的像素坐标", step, action]];
            continue;
        }

        if ([action isEqualToString:@"done"] || [action isEqualToString:@"stop"]) {
            agentSay([NSString stringWithFormat:@"%@:%@", [action isEqualToString:@"done"] ? @"任务完成" : @"任务停止", [act[@"text"] description] ?: @""]);
            break;
        }
        NSString *result = @"已执行";
        if ([action isEqualToString:@"tap"] || [action isEqualToString:@"long_press"]) {
            NSString *danger = localOK ? dangerNear(items, x, y) : nil;
            if (danger) { agentSay([NSString stringWithFormat:@"拦截:要点击的位置是「%@」,属于支付/结算,已停止,请手动操作", danger]); break; }
            if ([action isEqualToString:@"tap"]) doTap(x, y); else doLongPress(x, y, 900);
            [history addObject:usedID ? [NSString stringWithFormat:@"%d. %@ id=%ld「%@」", step, action, (long)oid, idText] : [NSString stringWithFormat:@"%d. %@(%.0f,%.0f)", step, action, xpx, ypx]];
            sleep(2);
        } else if ([action isEqualToString:@"swipe"]) {
            doSwipe(x, y, x2, y2, 20, 350);
            [history addObject:[NSString stringWithFormat:@"%d. swipe(%.0f,%.0f → %.0f,%.0f)", step, xpx, ypx, x2 / kx, y2 / ky]];
            sleep(2);
        } else if ([action isEqualToString:@"open_app"]) {
            NSString *name = [act[@"name"] description] ?: @"";
            NSString *info = nil;
            NSString *bid = bundleForAppName(name, &info);
            if (bid && openApp(bid)) { result = @"已打开"; gLastApp = bid; }
            else result = info ?: @"打开失败";
            [history addObject:[NSString stringWithFormat:@"%d. open_app(%@) → %@", step, name, result]];
            sleep(3);
        } else if ([action isEqualToString:@"input_text"] || [action isEqualToString:@"set_clipboard"]) {
            BOOL typing = [action isEqualToString:@"input_text"];
            NSString *text = [act[@"text"] description] ?: @"";
            NSString *hintBid = nil;
            NSString *appHint = [act[@"app"] description];
            if (appHint.length) { NSString *i2 = nil; hintBid = bundleForAppName(appHint, &i2); }
            NSString *note = nil; BOOL stranded = NO;
            BOOL ok = writeClipboardInForeground(text, hintBid, &note, &stranded);
            if (!ok) {
                [history addObject:[NSString stringWithFormat:@"%d. %@ 失败:%@", step, action, note]];
                agentSay([@"提示:" stringByAppendingString:note ?: @"剪贴板写入失败"]);
                sleep(1);
                continue;
            }
            if (stranded) {
                [history addObject:[NSString stringWithFormat:@"%d. %@ 已写入剪贴板,但没能回到原来的 App", step, action]];
                agentSay(@"提示:剪贴板已写入,但没能自动回到原来的 App,请用 open_app 回到目标 App");
                continue;
            }
            if (typing) {
                doTap(x, y);
                usleep(800 * 1000);
                doLongPress(x, y, 1100);
                result = @"剪贴板已确认,已回到目标 App、聚焦输入框并呼出粘贴菜单;下一步请点击粘贴或允许粘贴";
                [history addObject:[NSString stringWithFormat:@"%d. input_text(%@,%@)", step, usedID ? [NSString stringWithFormat:@"id=%ld", (long)oid] : [NSString stringWithFormat:@"%.0f,%.0f", xpx, ypx], text]];
                sleep(2);
            } else {
                [history addObject:[NSString stringWithFormat:@"%d. set_clipboard(%@) 已确认", step, text]];
            }
        } else if ([action isEqualToString:@"home"]) {
            NSString *hn = nil;
            BOOL hok = goHome(&hn);
            result = hok ? @"已回到主屏幕" : [@"回主屏幕可能失败:" stringByAppendingString:hn ?: @""];
            [history addObject:[NSString stringWithFormat:@"%d. home → %@", step, result]];
            sleep(1);
        } else if ([action isEqualToString:@"wait"]) {
            [history addObject:[NSString stringWithFormat:@"%d. wait", step]];
            usleep(1500 * 1000);
        } else {
            [history addObject:[NSString stringWithFormat:@"%d. (无效动作 %@)", step, action]];
        }
        if (![result isEqualToString:@"已执行"] && ![result isEqualToString:@"已打开"]) agentSay([@"提示:" stringByAppendingString:result]);
    }
    if (gAgentRunning) agentSay(@"任务结束");
    else agentSay(@"任务已被停止");
    gAgentRunning = NO;
}

#pragma mark - 界面

@interface VC : UIViewController
@property (nonatomic, strong) UITextField *xf, *yf, *keyF, *baseF, *modelF, *taskF;
@property (nonatomic, strong) UILabel *log;
@end

@implementation VC
- (UITextField *)field:(NSString *)ph text:(NSString *)t {
    UITextField *f = [UITextField new];
    f.placeholder = ph; f.text = t;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.keyboardType = UIKeyboardTypeDecimalPad;
    return f;
}
- (UITextField *)tfield:(NSString *)ph key:(NSString *)k secure:(BOOL)sec def:(NSString *)def {
    UITextField *f = [UITextField new];
    f.placeholder = ph;
    f.text = [NSUserDefaults.standardUserDefaults stringForKey:k] ?: def;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.secureTextEntry = sec;
    return f;
}
- (UIButton *)btn:(NSString *)title action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    CGSize s = screenSize();
    self.xf = [self field:@"x (pt)" text:[NSString stringWithFormat:@"%d", (int)(s.width / 2)]];
    self.yf = [self field:@"y (pt)" text:[NSString stringWithFormat:@"%d", (int)(s.height / 2)]];
    self.log = [UILabel new];
    self.log.numberOfLines = 0;
    self.log.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    UILabel *tip = [UILabel new];
    tip.numberOfLines = 0;
    tip.text = [NSString stringWithFormat:@"屏幕 %.0f x %.0f pt。按按钮后 3 秒内切到别的 App,等它自己执行。", s.width, s.height];
    self.keyF = [self tfield:@"API Key" key:@"llm_key" secure:YES def:@""];
    self.baseF = [self tfield:@"接口地址" key:@"llm_base" secure:NO def:@"https://api.deepseek.com"];
    self.modelF = [self tfield:@"视觉模型名" key:@"llm_model" secure:NO def:@"deepseek-flash"];
    self.taskF = [self tfield:@"任务,例如:打开淘宝,搜索 保温杯,加入购物车" key:@"llm_task" secure:NO def:@""];
    UILabel *bl = [UILabel new];
    bl.numberOfLines = 0;
    bl.text = @"屏幕广播(截屏用):点右边按钮 → 选 PhoneAgent → 开始直播";
    RPSystemBroadcastPickerView *pv = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    pv.preferredExtension = @"com.example.phoneagent.broadcast";
    pv.showsMicrophoneButton = NO;
    [pv.widthAnchor constraintEqualToConstant:56].active = YES;
    [pv.heightAnchor constraintEqualToConstant:56].active = YES;
    UIStackView *brow = [[UIStackView alloc] initWithArrangedSubviews:@[bl, pv]];
    brow.axis = UILayoutConstraintAxisHorizontal;
    brow.spacing = 10;
    brow.alignment = UIStackViewAlignmentCenter;
    __weak VC *wself = self;
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.say" object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { [wself say:[n.object description]]; }];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        tip, self.xf, self.yf,
        [self btn:@"3 秒后点击 (x,y)" action:@selector(onTap)],
        [self btn:@"3 秒后上滑一次" action:@selector(onSwipe)],
        [self btn:@"切换滑动模式(0~4)" action:@selector(onSwipeMode)],
        [self btn:@"3 秒后 回主屏(Home键)" action:@selector(onHome)],
        [self btn:@"3 秒后 截屏 + OCR" action:@selector(onOCR)],
        [self btn:@"后台保活 开/关" action:@selector(onKeep)],
        [self btn:@"3 秒后 测试写入剪贴板" action:@selector(onClip)],
        [self btn:@"诊断 IOSurface" action:@selector(onDiag)],
        brow,
        self.keyF, self.baseF, self.modelF, self.taskF,
        [self btn:@"开始任务" action:@selector(onStartAgent)],
        [self btn:@"停止任务" action:@selector(onStopAgent)],
        self.log]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];
    [sv addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:g.topAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:20],
        [st.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-20]]];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)]];

    NSString *e1 = loadHID();
    [self say:e1 ? [@"触摸初始化失败: " stringByAppendingString:e1] : @"触摸: 初始化成功"];
    NSString *e2 = loadShot();
    [self say:e2 ? [@"截屏初始化失败: " stringByAppendingString:e2] : @"截屏: 符号加载成功"];
    NSString *e3 = startServer();
    [self say:e3 ? [@"HTTP 服务失败: " stringByAppendingString:e3]
                 : [NSString stringWithFormat:@"HTTP 服务: 127.0.0.1:%d\ntoken: %@\n在 Safari 打开:\nhttp://127.0.0.1:%d/ping", PORT, gToken, PORT]];
    [self say:setKeepAlive(YES)];
    [self say:diagReport()];
}
- (void)say:(NSString *)m {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *t = [NSString stringWithFormat:@"%@\n%@", m, self.log.text ?: @""];
        if (t.length > 8000) t = [t substringToIndex:8000];
        self.log.text = t;
    });
}
- (void)runLater:(void (^)(void))block name:(NSString *)name {
    [self.view endEditing:YES];
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication
        beginBackgroundTaskWithExpirationHandler:^{ [UIApplication.sharedApplication endBackgroundTask:bg]; }];
    [self say:[name stringByAppendingString:@": 3 秒后执行"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        block();
        dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication endBackgroundTask:bg]; });
    });
}
- (void)onTap {
    if (!gClient) { [self say:@"触摸没初始化"]; return; }
    double x = self.xf.text.doubleValue, y = self.yf.text.doubleValue;
    [self runLater:^{ doTap(x, y); [self say:@"点击已发送"]; } name:[NSString stringWithFormat:@"点击(%.0f,%.0f)", x, y]];
}
- (void)onSwipeMode {
    gSwipeMode = (gSwipeMode + 1) % 5;
    [NSUserDefaults.standardUserDefaults setInteger:gSwipeMode forKey:@"swipe_mode"];
    NSArray *d = @[@"基础", @"+触点半径", @"+半径,移动事件带 Touch", @"+半径,慢速,起止停顿", @"+半径,慢速,移动事件带 Range|Touch"];
    [self say:[NSString stringWithFormat:@"滑动模式 %d(%@)已保存。点“3 秒后上滑一次”在设置等可滚动页面测试", gSwipeMode, d[gSwipeMode]]];
}
- (void)onHome {
    [self runLater:^{
        NSString *hn = nil;
        BOOL ok = goHome(&hn);
        [self say:[NSString stringWithFormat:@"回主屏:%@(%@)", ok ? @"成功" : @"可能失败", hn ?: @""]];
    } name:@"回主屏"];
}
- (void)onSwipe {
    if (!gClient) { [self say:@"触摸没初始化"]; return; }
    CGSize s = screenSize();
    [self runLater:^{ doSwipe(s.width / 2, s.height * 0.75, s.width / 2, s.height * 0.3, 20, 300); [self say:@"上滑已发送"]; } name:@"上滑"];
}
- (void)onOCR {
    [self runLater:^{
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { [self say:[@"截屏失败: " stringByAppendingString:err ?: @"?"]]; return; }
        NSString *key = [self.keyF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *base = [self.baseF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *model = [self.modelF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([model isEqualToString:@"deepseek-chat"] || !model.length) model = @"deepseek-flash";
        if (!key.length || !base.length) { [self say:@"请先填写 API Key 和接口地址"]; return; }
        NSArray *msgs = visionMessages(@"识别当前屏幕中的文字和主要按钮，只返回 JSON，visible_text 写出识别到的关键原文，action 返回 done。", @"", img, &err);
        NSDictionary *result = msgs ? callLLM(base, key, model, msgs, &err) : nil;
        if (!result) { [self say:[@"视觉模型失败: " stringByAppendingString:err ?: @"?"]]; return; }
        [self say:[NSString stringWithFormat:@"视觉识别(方法%@) %.0fx%.0f\n%@",
                   gShotMethod, img.size.width, img.size.height,
                   [result[@"visible_text"] description] ?: @"(模型未返回文字)"]];
    } name:@"截图+视觉识别"];
}
- (void)onStartAgent {
    [self.view endEditing:YES];
    if (gAgentRunning) { [self say:@"任务正在运行"]; return; }
    NSString *key = [self.keyF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *base = [self.baseF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *model = [self.modelF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *task = [self.taskF.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!key.length || !base.length || !model.length || !task.length) { [self say:@"API Key、接口地址、模型名、任务都要填"]; return; }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:key forKey:@"llm_key"]; [d setObject:base forKey:@"llm_base"];
    [d setObject:model forKey:@"llm_model"]; [d setObject:task forKey:@"llm_task"];
    if (!gPlayer) [self say:setKeepAlive(YES)];
    if (!broadcastAlive()) [self say:@"提醒:屏幕广播还没开,没有广播会截屏失败"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(task, base, key, model); });
}
- (void)onStopAgent { gAgentRunning = NO; [self say:@"正在停止任务..."]; }
- (void)onDiag { [self say:diagReport()]; }
- (void)onClip {
    [self runLater:^{
        NSString *note = nil; BOOL stranded = NO;
        NSString *front = frontmostBundleID();
        BOOL ok = writeClipboardInForeground(@"PhoneAgent剪贴板测试123", nil, &note, &stranded);
        [self say:[NSString stringWithFormat:@"剪贴板测试:%@(切换前最前台 App:%@%@)\n请到任意输入框长按粘贴,看是不是“PhoneAgent剪贴板测试123”",
                   ok ? @"写入并校验成功" : [@"失败:" stringByAppendingString:note ?: @"?"],
                   front ?: @"未知", stranded ? @",没能自动切回" : @""]];
    } name:@"剪贴板测试"];
}
- (void)onKeep {
    [self say:setKeepAlive(gPlayer == nil)];
}
@end

@interface AD : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AD
// phoneagent://task?token=XXXXXX&text=任务文字   或   phoneagent://stop?token=XXXXXX
// 给快捷指令用:打开 URL 会把 PhoneAgent 唤醒到前台,避免它在后台被挂起。token 不对一律忽略。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    NSURLComponents *uc = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
    NSString *cmd = uc.host ?: @"";
    if (![q[@"token"] isEqualToString:gToken]) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"收到 phoneagent:// 请求,但 token 不对,已忽略"];
        return YES;
    }
    if ([cmd isEqualToString:@"stop"]) { gAgentRunning = NO; return YES; }
    if (![cmd isEqualToString:@"task"]) return YES;
    // 把收到的 URL 原样记到日志里(token 打码),方便排查快捷指令到底传了什么
    NSString *raw = url.absoluteString ?: @"";
    NSString *tok = q[@"token"];
    if (tok.length) raw = [raw stringByReplacingOccurrencesOfString:tok withString:@"***"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say"
        object:[NSString stringWithFormat:@"收到 URL:%@\n参数名:%@", raw.length > 300 ? [raw substringToIndex:300] : raw, [q.allKeys componentsJoinedByString:@","]]];
    // 兼容几种参数名;都没有时取除 token 外最长的那个参数值
    NSString *task = q[@"text"] ?: q[@"t"] ?: q[@"task"] ?: q[@"q"] ?: @"";
    if (!task.length) {
        for (NSString *k in q) {
            if ([k isEqualToString:@"token"]) continue;
            if ([q[k] length] > task.length) task = q[k];
        }
    }
    // 快捷指令有时会把已经编码过的文字再编码一次,这里再解一层
    if ([task containsString:@"%"]) { NSString *d2 = [task stringByRemovingPercentEncoding]; if (d2.length) task = d2; }
    task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = savedSetting(@"llm_key", @""), *base = savedSetting(@"llm_base", @"https://api.deepseek.com"), *model = savedSetting(@"llm_model", savedSetting(@"llm_model2", @"deepseek-flash"));
    NSString *say = nil;
    if (!task.length) say = @"收到语音任务,但文字是空的(听写可能没识别到内容,或快捷指令里的变量没接对,看上面“收到 URL”那行)";
    else if (!key.length || !base.length || !model.length) say = @"收到语音任务,但还没保存 API 设置:请先在 App 里点一次“开始任务”或“看图测试”";
    else if (gAgentRunning) say = @"收到语音任务,但已有任务在运行";
    if (say) { [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:say]; return YES; }
    agentSay([NSString stringWithFormat:@"收到语音任务:%@", task]);
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"收到语音任务:%@", task]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 30 && !broadcastAlive(); i++) usleep(200 * 1000); // 冷启动后扩展要重新连上
        if (!broadcastAlive()) {
            [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"屏幕广播没开,任务未执行:请先开启屏幕广播"];
            return;
        }
        if (gAgentRunning) return;
        agentRun(task, base, key, model);
    });
    return YES;
}

- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    signal(SIGPIPE, SIG_IGN);
    gLock = [NSObject new];
    gAgentLog = [NSMutableArray array];
    gSwipeMode = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"swipe_mode"];
    gToken = [NSUserDefaults.standardUserDefaults stringForKey:@"token"];
    if (!gToken) {
        gToken = [NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)];
        [NSUserDefaults.standardUserDefaults setObject:gToken forKey:@"token"];
    }
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AD class])); }
}
