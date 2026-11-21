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
#import <Speech/Speech.h>
#import <UserNotifications/UserNotifications.h>
#import <AudioToolbox/AudioToolbox.h>
#import <PhotosUI/PhotosUI.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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

// 硬件键盘快捷键:按住左 Command(0xE3)+ 一个字母键(键盘页 0x07):A=0x04,V=0x19
static BOOL doCmdKey(uint32_t usage) {
    if (!pCreateKeyboard || !gClient) return NO;
    uint32_t seq[4][2] = {{0xE3, 1}, {usage, 1}, {usage, 0}, {0xE3, 0}};
    for (int i = 0; i < 4; i++) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, seq[i][0], seq[i][1] ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(60 * 1000);
    }
    return YES;
}

// 发一个无害的 Shift 键事件:对系统来说算"用户活动",可以重置自动锁屏计时
static void doShiftKey(void) {
    if (!pCreateKeyboard || !gClient) return;
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, 0xE1, down ? true : false, 0);
        if (!e) return;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(40 * 1000);
    }
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
static volatile BOOL gBroadcastStopRequested; // 任务结束时请扩展关闭录屏
static RPSystemBroadcastPickerView *gPicker;   // 界面里的录屏选择按钮(自动开启录屏时要用)
static NSMutableArray *gRunLog;          // 本次任务的完整日志(结果窗口用)
static NSString *gTaskStatus, *gTaskResultText, *gLastResultText, *gTaskDisplay, *gLastSpeechText;
static NSArray *gRunImages;              // 本次任务附带的图片(JPEG 数据)
static NSMutableArray *gAttachImages, *gAttachNames; // 界面里已选的附件
static NSMutableString *gAttachText;     // 界面里已选文件的文字内容

// ---- 需要用户参与的请求(暂停 / 确认):界面弹窗、通知按钮、URL、HTTP 都可以回应 ----
enum { PAReqNone = 0, PAReqWaiting = 1, PAReqAllow = 2, PAReqAllowAll = 3, PAReqDeny = 4, PAReqStop = 5 };
static volatile int gReqState;
static NSString *gReqKind, *gReqText;
static volatile BOOL gConfirmSkipThisTask;   // 用户选了“本次任务不再问”
static void agentRespond(int st) { if (gReqState == PAReqWaiting) gReqState = st; }
// ---- 经验库 ----
static NSMutableArray *gExpSteps;            // 本次任务已执行的步骤(成功后存进经验库)
static NSString *gExpHint, *gExpReplayID;    // 给模型的参考提示 / 本次回放用到的经验 id
static BOOL gExpReplayAborted;               // 回放中途中止过

// 读已保存的设置(空字符串按没有处理)。模型名在界面里存的键是 llm_model。
static NSString *savedSetting(NSString *k, NSString *def) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:k];
    return v.length ? v : def;
}

// ---- 模型提供商:每个提供商各自保存 API Key / 接口地址 / 模型名 ----
static NSArray *defaultProviders(void) {
    return @[
        @{@"id": @"deepseek", @"name": @"DeepSeek", @"base": @"https://api.deepseek.com", @"model": @"deepseek-flash"},
        @{@"id": @"glm", @"name": @"智谱 GLM-5.3", @"base": @"https://open.bigmodel.cn/api/paas/v4", @"model": @"glm-5.3-flash"},
        @{@"id": @"autoglm", @"name": @"智谱 AutoGLM-Phone", @"base": @"https://open.bigmodel.cn/api/paas/v4", @"model": @"autoglm-phone"},
        @{@"id": @"custom", @"name": @"自定义(OpenAI 兼容接口)", @"base": @"", @"model": @""}];
}
// 模型列表保存在本机;没改过就用上面的默认列表。界面里可以添加、删除。
static NSArray *providerList(void) {
    NSData *d = [NSUserDefaults.standardUserDefaults dataForKey:@"providers_json"];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([o isKindOfClass:NSArray.class] && [o count]) return o;
    return defaultProviders();
}
static void saveProviders(NSArray *list) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    if (d) [NSUserDefaults.standardUserDefaults setObject:d forKey:@"providers_json"];
}
static NSString *selectedProviderID(void) {
    NSString *cur = savedSetting(@"provider", @"deepseek");
    NSArray *list = providerList();
    for (NSDictionary *p in list) if ([p[@"id"] isEqualToString:cur]) return cur;
    return [list.firstObject[@"id"] description] ?: @"deepseek";
}
static NSString *providerDefault(NSString *pid, NSString *field) {
    for (NSDictionary *p in providerList()) if ([p[@"id"] isEqualToString:pid]) return p[field] ?: @"";
    return @"";
}
static NSString *provValue(NSString *pid, NSString *field) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"p_%@_%@", pid, field]];
    if (v.length) return v;
    return [field isEqualToString:@"key"] ? @"" : providerDefault(pid, field);
}
static void loadLLMConfig(NSString **key, NSString **base, NSString **model) {
    NSString *pid = selectedProviderID();
    *key = provValue(pid, @"key"); *base = provValue(pid, @"base"); *model = provValue(pid, @"model");
}

// ---- 安全设置:敏感操作确认、禁止进入的 App ----
static NSString *defaultSensitiveWords(void) { return @"发送\n发布\n提交\n删除\n清空\n退出登录\n注销\n卸载\n授权\n拨打\n呼叫\n预订\n报名\n转发"; }
static NSString *defaultBlockedApps(void) { return @"银行\n支付宝\n云闪付\n数字人民币\n京东金融\n蚂蚁财富\n钱包\nWallet"; }
static NSArray *splitList(NSString *t) {
    NSMutableArray *out = [NSMutableArray array];
    NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@"\n,，、;；"];
    for (NSString *p in [t componentsSeparatedByCharactersInSet:seps]) {
        NSString *x = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (x.length) [out addObject:x];
    }
    return out;
}
static NSArray *sensitiveWords(void) { return splitList([NSUserDefaults.standardUserDefaults stringForKey:@"sens_words"] ?: defaultSensitiveWords()); }
static NSArray *blockedApps(void) { return splitList([NSUserDefaults.standardUserDefaults stringForKey:@"blocked_apps"] ?: defaultBlockedApps()); }
static BOOL confirmEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"confirm_on"] ? [d boolForKey:@"confirm_on"] : YES;
}
static BOOL isBlockedApp(NSString *name, NSString *bid) {
    for (NSString *e in blockedApps())
        if ([name localizedCaseInsensitiveContainsString:e] || [bid localizedCaseInsensitiveContainsString:e]) return YES;
    return NO;
}
// 涉及花钱的词:永远不自动点击,只能请用户本人完成(不受“敏感操作确认”开关影响)
static NSArray *moneyWords(void) {
    return @[@"支付", @"付款", @"结算", @"提交订单", @"立即购买", @"去支付", @"转账", @"汇款", @"充值", @"红包", @"免密支付", @"支付密码"];
}
// 点击位置附近(OCR 框外扩 25pt)的文字
static NSString *textNear(NSArray *items, double x, double y) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *it in items) {
        double dx = fabs([it[@"x"] doubleValue] - x), dy = fabs([it[@"y"] doubleValue] - y);
        double hw = [it[@"w"] doubleValue] / 2 + 25, hh = [it[@"h"] doubleValue] / 2 + 25;
        if (dx <= hw && dy <= hh) [parts addObject:it[@"text"] ?: @""];
    }
    return [parts componentsJoinedByString:@" "];
}
// 恰好落在某个 OCR 框里(外扩 12pt)的那段文字,没有就返回空
static NSString *nearestItemText(NSArray *items, double x, double y) {
    NSString *best = @""; double bd = 1e9;
    for (NSDictionary *it in items) {
        double dx = fabs(x - [it[@"x"] doubleValue]), dy = fabs(y - [it[@"y"] doubleValue]);
        double hw = [it[@"w"] doubleValue] / 2 + 12, hh = [it[@"h"] doubleValue] / 2 + 12;
        if (dx <= hw && dy <= hh && dx + dy < bd) { bd = dx + dy; best = it[@"text"] ?: @""; }
    }
    return best;
}
// category:2 = 涉及花钱(只能用户本人操作),1 = 需要先征得用户同意
static NSString *sensitiveMatch(NSString *text, int *category) {
    if (!text.length) return nil;
    for (NSString *w in moneyWords()) if ([text containsString:w]) { *category = 2; return w; }
    if (!confirmEnabled()) return nil;
    for (NSString *w in sensitiveWords()) if ([text localizedCaseInsensitiveContainsString:w]) { *category = 1; return w; }
    return nil;
}
// 综合“按钮名 + 点击位置附近的文字 + 模型写的风险说明”判断这一步是否敏感
static NSString *classifyAction(NSString *target, NSString *risk, NSArray *items, double x, double y, int *category) {
    NSString *near = items.count ? textNear(items, x, y) : @"";
    NSString *blob = [NSString stringWithFormat:@"%@ %@ %@", target ?: @"", near, risk ?: @""];
    int cat = 0;
    NSString *w = sensitiveMatch(blob, &cat);
    // 只有安全设置中的敏感词命中时才请求确认；模型的 risk 仅用于辅助判断和日志，
    // 不再因为模型自行填写 risk 就绕过用户的敏感词设置强制弹确认。
    *category = cat;
    return w;
}

// ---- 经验库:存取、相似度、提示 ----
static BOOL expEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"exp_on"] ? [d boolForKey:@"exp_on"] : YES;
}
static BOOL expReplayEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"exp_replay_on"] ? [d boolForKey:@"exp_replay_on"] : YES;
}
static NSMutableArray *expLoad(void) {
    NSData *d = [NSUserDefaults.standardUserDefaults dataForKey:@"exp_json"];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    return [o isKindOfClass:NSMutableArray.class] ? o : [NSMutableArray array];
}
static void expSave(NSArray *arr) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
    if (d) [NSUserDefaults.standardUserDefaults setObject:d forKey:@"exp_json"];
}
static NSSet *expBigrams(NSString *t) {
    NSMutableString *s = [NSMutableString string];
    NSCharacterSet *skip = [NSCharacterSet characterSetWithCharactersInString:@" \t\n,.。,!?;:、“”\"'()[]【】"];
    for (NSUInteger i = 0; i < t.length; i++) { unichar c = [t characterAtIndex:i]; if (![skip characterIsMember:c]) [s appendFormat:@"%C", c]; }
    NSString *n = s.lowercaseString;
    NSMutableSet *set = [NSMutableSet set];
    if (n.length < 2) { if (n.length) [set addObject:n]; return set; }
    for (NSUInteger i = 0; i + 1 < n.length; i++) [set addObject:[n substringWithRange:NSMakeRange(i, 2)]];
    return set;
}
// 两句任务的相似度(字对的重合比例,0~1)
static double expSim(NSString *a, NSString *b) {
    NSSet *A = expBigrams(a ?: @""), *B = expBigrams(b ?: @"");
    if (!A.count || !B.count) return 0;
    NSMutableSet *inter = [A mutableCopy]; [inter intersectSet:B];
    NSMutableSet *uni = [A mutableCopy]; [uni unionSet:B];
    return (double)inter.count / (double)uni.count;
}
static NSMutableDictionary *expFind(NSString *task, double *score) {
    NSMutableDictionary *best = nil; double bs = 0;
    for (NSMutableDictionary *e in expLoad()) { double sc = expSim(task, e[@"task"]); if (sc > bs) { bs = sc; best = e; } }
    *score = bs;
    return best;
}
static NSString *expStepDesc(NSDictionary *st) {
    NSString *a = st[@"a"] ?: @"", *t = st[@"t"] ?: @"";
    if ([a isEqualToString:@"open_app"]) return [NSString stringWithFormat:@"打开 App「%@」", st[@"name"] ?: @""];
    if ([a isEqualToString:@"tap"]) return t.length ? [NSString stringWithFormat:@"点击「%@」", t] : @"点击一个没有文字的图标";
    if ([a isEqualToString:@"double_tap"]) return t.length ? [NSString stringWithFormat:@"双击「%@」", t] : @"双击";
    if ([a isEqualToString:@"long_press"]) return t.length ? [NSString stringWithFormat:@"长按「%@」", t] : @"长按";
    if ([a isEqualToString:@"input_text"]) return [NSString stringWithFormat:@"在%@输入「%@」", t.length ? [NSString stringWithFormat:@"「%@」", t] : @"输入框", st[@"text"] ?: @""];
    if ([a isEqualToString:@"swipe"]) return @"滑动";
    if ([a isEqualToString:@"home"]) return @"回主屏幕";
    if ([a isEqualToString:@"back"]) return @"返回";
    if ([a isEqualToString:@"ask_user"]) return [NSString stringWithFormat:@"请用户处理:%@", st[@"text"] ?: @""];
    return a;
}
// 给模型的参考:最相似的两条成功经验(相似度 >= 0.3)
static NSString *expHintFor(NSString *task) {
    if (!expEnabled() || !task.length) return @"";
    NSMutableArray *scored = [NSMutableArray array];
    for (NSDictionary *e in expLoad()) {
        double sc = expSim(task, e[@"task"]);
        if (sc >= 0.3) [scored addObject:@{@"s": @(sc), @"e": e}];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"s"] compare:a[@"s"]]; }];
    if (!scored.count) return @"";
    NSMutableString *h = [NSMutableString stringWithString:@"过往成功经验(仅供参考,界面可能已经变化,一切以当前截图为准):"];
    for (NSUInteger i = 0; i < MIN((NSUInteger)2, scored.count); i++) {
        NSDictionary *e = scored[i][@"e"];
        NSArray *steps = e[@"steps"];
        NSMutableArray *ds = [NSMutableArray array];
        for (NSUInteger k = 0; k < MIN((NSUInteger)15, steps.count); k++) [ds addObject:[NSString stringWithFormat:@"%lu) %@", (unsigned long)k + 1, expStepDesc(steps[k])]];
        [h appendFormat:@"\n· 任务「%@」:%@", e[@"task"], [ds componentsJoinedByString:@" "]];
    }
    return h;
}
static void expRecord(NSDictionary *step) {
    if (!gExpSteps) gExpSteps = [NSMutableArray array];
    if (gExpSteps.count < 80) [gExpSteps addObject:step];
}
// 屏幕上有代表性的几段文字(用来在回放时核对“现在的屏幕和当时是不是同一个页面”)
static NSArray *expAnchors(NSArray *items) {
    NSArray *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int ya = [a[@"y"] intValue] / 12, yb = [b[@"y"] intValue] / 12;
        if (ya != yb) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
        return [(NSNumber *)a[@"x"] compare:(NSNumber *)b[@"x"]];
    }];
    NSCharacterSet *plain = [NSCharacterSet characterSetWithCharactersInString:@"0123456789:%. "];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in sorted) {
        NSString *t = [it[@"text"] description];
        if (t.length < 2 || t.length > 12 || [out containsObject:t]) continue;
        if ([t rangeOfCharacterFromSet:plain.invertedSet].location == NSNotFound) continue; // 纯数字/时间/电量
        [out addObject:t];
        if (out.count >= 6) break;
    }
    return out;
}
// 任务结束时存进经验库:成功完成才存;已有几乎相同的经验就合并(留步数更少的那条)
static void expFinish(NSString *task, NSString *status) {
    if (!expEnabled()) return;
    NSMutableArray *all = expLoad();
    BOOL ok = [status isEqualToString:@"已完成"];
    NSMutableDictionary *target = nil;
    if (gExpReplayID.length) for (NSMutableDictionary *e in all) if ([e[@"id"] isEqualToString:gExpReplayID]) target = e;
    if (!target && ok) {
        double sc = 0; NSMutableDictionary *best = nil;
        for (NSMutableDictionary *e in all) { double v = expSim(task, e[@"task"]); if (v > sc) { sc = v; best = e; } }
        if (best && sc >= 0.9) target = best;
    }
    if (target) {
        if (gExpReplayAborted) target[@"fail"] = @([target[@"fail"] intValue] + 1);
        else if (ok) target[@"ok"] = @([target[@"ok"] intValue] + 1);
        if (ok && gExpSteps.count >= 2 && gExpSteps.count < [target[@"steps"] count]) target[@"steps"] = [gExpSteps copy];
        if ([target[@"fail"] intValue] >= 3 && [target[@"fail"] intValue] > [target[@"ok"] intValue]) [all removeObject:target]; // 老是失效的经验自动淘汰
    } else if (ok && gExpSteps.count >= 2 && gExpSteps.count <= 60) {
        [all addObject:[@{@"id": [NSUUID UUID].UUIDString, @"task": task ?: @"", @"created": @([NSDate date].timeIntervalSince1970),
                          @"used": @0, @"ok": @1, @"fail": @0, @"steps": [gExpSteps copy]} mutableCopy]];
    }
    while (all.count > 100) [all removeObjectAtIndex:0];
    expSave(all);
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
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"version": @"0.9.1", @"broadcast": @(broadcastAlive())});
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
                gBroadcastStopRequested = NO;
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
        sendJSON(c, 200, @{@"ok": @YES, @"cmd": gBroadcastStopRequested ? @"stop" : @""});
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
        NSString *key = nil, *base = nil, *model = nil; loadLLMConfig(&key, &base, &model);
        if (!task.length) { sendJSON(c, 400, @{@"ok": @NO, @"error": @"没有任务文字"}); return; }
        if (!key.length || !base.length || !model.length) {
            sendJSON(c, 400, @{@"ok": @NO, @"error": @"还没保存 API 设置:请先在 App 里点一次“开始任务”或“看图测试”"});
            return;
        }
        if (gAgentRunning) { sendJSON(c, 409, @{@"ok": @NO, @"error": @"已有任务在运行"}); return; }
        {
            NSUserDefaults *u2 = NSUserDefaults.standardUserDefaults;
            BOOL autoCast = [u2 objectForKey:@"auto_cast"] ? [u2 boolForKey:@"auto_cast"] : YES;
            if (!autoCast && !broadcastAlive()) { sendJSON(c, 409, @{@"ok": @NO, @"error": @"屏幕广播没开,请先在 PhoneAgent 里开启,或打开“任务时自动开启/关闭屏幕录制”开关"}); return; }
        }
        agentSay([NSString stringWithFormat:@"收到语音任务:%@", task]);
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"收到语音任务:%@", task]];
        gRunImages = nil; gTaskDisplay = task;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(task, base, key, model); });
        sendJSON(c, 200, @{@"ok": @YES, @"task": task});
    } else if ([path isEqualToString:@"/respond"]) {
        // 回应“暂停/确认”请求:action = allow|resume(允许/继续) allowall(允许且本次不再问) deny(拒绝) stop(停止任务)
        NSString *a = q[@"action"] ?: @"";
        int st = ([a isEqualToString:@"allow"] || [a isEqualToString:@"resume"]) ? PAReqAllow : [a isEqualToString:@"allowall"] ? PAReqAllowAll :
                 [a isEqualToString:@"deny"] ? PAReqDeny : [a isEqualToString:@"stop"] ? PAReqStop : 0;
        if (!st) { sendJSON(c, 400, @{@"ok": @NO, @"error": @"action 应为 allow/resume/allowall/deny/stop"}); return; }
        agentRespond(st);
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/stop"]) {
        gAgentRunning = NO;
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/status"]) {
        NSArray *lines;
        @synchronized (gLock) { lines = [gAgentLog copy] ?: @[]; }
        NSUInteger n = lines.count > 15 ? lines.count - 15 : 0;
        sendJSON(c, 200, @{@"ok": @YES, @"running": @(gAgentRunning), @"waiting": @(gReqState == PAReqWaiting), @"broadcast": @(broadcastAlive()),
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
        if (gRunLog) { [gRunLog addObject:m ?: @""]; if (gRunLog.count > 500) [gRunLog removeObjectAtIndex:0]; }
        // 根据日志文字判断任务结果(完成 / 停止),结果窗口会用到
        if ([m hasPrefix:@"任务完成:"]) { gTaskStatus = @"已完成"; gTaskResultText = [m substringFromIndex:5]; }
        else if ([m hasPrefix:@"任务停止:"]) { gTaskStatus = @"已停止"; gTaskResultText = [m substringFromIndex:5]; }
        else if ([m isEqualToString:@"任务已被停止"]) { gTaskStatus = @"已被手动停止"; }
        else if ([m containsString:@"任务停止"] || [m hasPrefix:@"拦截:"] || [m hasPrefix:@"需要你来处理:"] ||
                 [m containsString:@"已停止,请"] || [m containsString:@"任务未执行"] || [m hasSuffix:@"已停止"]) {
            gTaskStatus = @"已停止"; gTaskResultText = m;
        }
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
        *info = [NSString stringWithFormat:@"没找到名为「%@」的 App。已安装的第三方 App:%@。请改用其中的准确名称重试 open_app;如果目标 App 不在列表里,可能没装,程序会自动回主屏幕并左滑到 App 资源库再找一次。",
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

static NSDictionary *callLLMOnce(NSString *base, NSString *key, NSString *model, NSArray *messages, NSString **err) {
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
    if (!url) { *err = @"接口地址格式不对"; return nil; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 90;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    // GLM-5.3 系列:思考模式始终开启,思考内容也占 max_tokens,所以要给得足够大;
    // 按智谱文档的推荐参数:temperature 1、top_p 0.95、reasoning_effort max、thinking.clear_thinking false
    BOOL glm = [model.lowercaseString hasPrefix:@"glm"];
    NSDictionary *body = glm
        ? @{@"model": model, @"messages": messages, @"temperature": @1.0, @"top_p": @0.95, @"max_tokens": @16384,
            @"thinking": @{@"type": @"enabled", @"clear_thinking": @NO}, @"reasoning_effort": @"max"}
        : @{@"model": model, @"messages": messages, @"temperature": @0.1,
            @"max_tokens": @700, @"response_format": @{@"type": @"json_object"}};
    if (glm) r.timeoutInterval = 300;
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    __block NSData *data = nil; __block NSError *e = nil; __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *er) {
        data = d; e = er; code = [(NSHTTPURLResponse *)resp statusCode];
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (!gAgentRunning) {
            [task cancel];
            if (err) *err = @"用户已停止任务";
            return nil;
        }
    }
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
    if (content.length == 0) {
        NSString *fr = nil;
        @try { fr = j[@"choices"][0][@"finish_reason"]; } @catch (NSException *ex) {}
        *err = [NSString stringWithFormat:@"模型没有输出答案(finish_reason=%@,可能思考占满了 max_tokens)", fr ?: @"?"];
        return nil;
    }
    content = [[content stringByReplacingOccurrencesOfString:@"```json" withString:@""]
               stringByReplacingOccurrencesOfString:@"```" withString:@""];
    NSDictionary *act = parseModelJSON(content);
    if (![act isKindOfClass:NSDictionary.class]) {
        *err = [NSString stringWithFormat:@"模型没返回 JSON: %@", content.length > 120 ? [content substringToIndex:120] : content];
        return nil;
    }
    return act;
}

// 临时性错误(网络、限流、服务端 5xx、模型没给答案/没给 JSON)才重试;密钥错误、参数错误等不重试
static BOOL llmErrRetryable(NSString *err) {
    if (!err.length) return NO;
    if ([err hasPrefix:@"网络错误"]) return YES;
    if ([err hasPrefix:@"接口返回 "]) {
        NSInteger code = [[err substringFromIndex:5] integerValue];
        return code == 408 || code == 409 || code == 425 || code == 429 || code >= 500;
    }
    return [err containsString:@"模型没有输出答案"] || [err containsString:@"模型没返回 JSON"] || [err containsString:@"接口返回格式不认识"];
}

// 请求失败最多试 5 次(间隔 1、2、3、4 秒)
static NSDictionary *callLLM(NSString *base, NSString *key, NSString *model, NSArray *messages, NSString **err) {
    NSString *last = nil;
    for (int attempt = 1; attempt <= 5; attempt++) {
        NSString *e = nil;
        NSDictionary *r = callLLMOnce(base, key, model, messages, &e);
        if (r) return r;
        last = e;
        if (!gAgentRunning || attempt == 5 || !llmErrRetryable(e)) break;
        agentSay([NSString stringWithFormat:@"请求失败(%@),%d 秒后重试(第 %d/5 次)", e.length > 80 ? [e substringToIndex:80] : e, attempt, attempt + 1]);
        sleep(attempt);
    }
    if (err) *err = last;
    return nil;
}

static NSString *const kAgentSystem =
@"你是一个控制 iPhone 的视觉智能体。每一步都会收到:任务、最近的动作历史、一张当前屏幕截图(780x1688 像素,图上叠加了红色网格线,每 100 像素一条,边缘标有像素数字),以及本地 OCR 识别出的带编号文字列表。\n"
@"所有坐标(x,y,x2,y2,以及 OCR 列表里的坐标)都是这张截图的像素坐标:左上角 (0,0),右下角 (780,1688),x 向右,y 向下。请对照网格线和边缘数字估计位置,点击要落在目标元素的中心。\n"
@"只输出一个 JSON 对象,不要输出其他内容。thought 不超过20个字；visible_text 只抄录关键文字且不超过120字；target 写这一步要点的按钮/文字名称(没有就留空);risk:如果这一步会对外产生影响或难以撤销(发送消息、发布内容、提交表单、删除、预订、退出登录、授权等),用一句话写明后果,例如“发送消息给张三:今晚吃饭吗”,否则留空；然后输出 action 和参数。\n"
@"action 可选值:\n"
@"- tap: 参数 id 或 x,y。点击。目标是 OCR 列表里的文字时,优先只给 id(程序会点该文字的中心,最准);没有文字的图标或空白输入框才给 x,y。\n"
@"- long_press: 参数 id 或 x,y。长按。\n"
@"- swipe: 参数 x,y,x2,y2,或只给 direction(up/down/left/right,表示手指滑动的方向)。往下看更多内容用 up。本设备上滑动可能不稳定,能用别的办法就别滑。\n"
@"- home: 回到主屏幕。需要回主屏幕时只用这个动作,不要用 swipe。\n"
@"- open_app: 参数 name(App 的中文名)。直接打开 App。\n"
@"- input_text: 参数 id 或 x,y,text,可选 app(当前所在 App 的名字)。程序会先临时切到 PhoneAgent 把 text 写入剪贴板(iOS 不允许后台 App 写剪贴板),再切回原来的 App,点击输入框并用键盘快捷键粘贴(会替换输入框里原有的文字;不行时自动改用长按菜单,并自动点掉“允许粘贴”);完成后请看截图确认输入框里出现了目标文字。这是输入文字的首选动作,text 必须是要输入的完整文字。\n"
@"- set_clipboard: 参数 text,可选 app。只把文字放进剪贴板(同样会临时切到 PhoneAgent 再切回),不点击。一般直接用 input_text。\n"
@"- wait: 等待 1.5 秒。\n"
@"- done: 参数 text。任务已完成;text 是写给用户看的完整结果(如果任务是查询、总结、比较信息,把得到的信息完整清楚地写在这里)。\n"
@"- stop: 参数 text。确实无法继续时才用。\n"
@"- ask_user: 参数 text。遇到必须由用户本人处理的情况(登录、输入验证码或密码、人机验证、人脸识别、付款、需要用户在多个选项里做选择等)时用:程序会提醒用户并暂停,用户处理完点“继续”后你会拿到新的屏幕再继续。text 写清楚需要用户做什么。\n"
@"规则:\n"
@"1. 有文字的目标一律用 id;只有没有文字的图标/输入框才给 x,y,并对照网格线估计。\n"
@"2. 付款、转账、输入支付密码这类花钱环节绝不自己点击,用 ask_user 请用户本人完成;发送、发布、提交、删除等有对外影响或难以撤销的操作,必须在 risk 里写明后果(程序会先征得用户同意);其余任务按要求完成。\n"
@"3. 每步只做一个动作。\n"
@"4. 屏幕连续没变化就换一种办法,仍不行就 stop。\n"
@"5. 看不到想要的内容时,先上滑或换搜索词,不要重复无效动作。\n"
@"6. visible_text 必须如实抄录截图中的关键文字;如果看到输入支付密码、确认付款等付款界面,action 用 ask_user 请用户本人完成。\n"
@"7. 找不到 App 时,先按 open_app 返回的已安装 App 列表换准确名称重试;仍找不到时程序会自动回主屏幕并左滑进入 App 资源库,这时点顶部搜索框,用 input_text 输入 App 名称搜索,再点搜索结果打开。\n"
@"8. input_text 由程序自己完成粘贴;如果下一张截图里输入框仍是空的,再次使用 input_text,并确认 id 或 x,y 指向的是输入框。\n"
@"9. 遇到登录、验证码、人机验证、人脸识别、需要用户在多个选项里做选择时,用 ask_user,不要 stop。";

static NSString *memoryText(void) { return [NSUserDefaults.standardUserDefaults stringForKey:@"memory_text"] ?: @""; }

// 把用户的"记忆/偏好"附在系统提示词后面
static NSString *systemPromptWithMemory(void) {
    NSMutableString *p = [kAgentSystem mutableCopy];
    NSString *m = [memoryText() stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (m.length) [p appendFormat:@"\n\n用户的偏好与记忆(执行任务时请参考;如果和本次任务的明确要求冲突,以本次任务为准):\n%@", m];
    NSArray *bl = blockedApps();
    if (bl.count) [p appendFormat:@"\n\n禁止进入的 App(绝对不要打开,也不要通过链接、搜索或分享进入;名称或包名里含有这些词的都算):%@", [bl componentsJoinedByString:@"、"]];
    if (!confirmEnabled()) [p appendString:@"\n\n用户已关闭“敏感操作确认”:发送、发布、提交、删除等操作直接执行,不要为此使用 ask_user 征求用户同意,risk 留空即可;付款、转账、输入支付密码仍然要用 ask_user 请用户本人完成。"];
    if (gExpHint.length) [p appendFormat:@"\n\n%@", gExpHint];
    return p;
}

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
static NSString *gCurrentModel;   // 当前任务用的模型名(决定请求参数的写法)
static NSData *gPrevModelJPEG;    // 上一步送给模型的截图(GLM 模式下作为对照图一起发)
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
    BOOL glm = [gCurrentModel.lowercaseString hasPrefix:@"glm"];
    NSMutableDictionary *imgURL = [@{ @"url": [@"data:image/jpeg;base64," stringByAppendingString:[jpg base64EncodedStringWithOptions:0]] } mutableCopy];
    if (!glm) imgURL[@"detail"] = @"original"; // 这个字段是 DeepSeek 的写法,GLM 不带
    NSDictionary *image = @{ @"type": @"image_url", @"image_url": imgURL };
    NSData *prev = gPrevModelJPEG;
    gPrevModelJPEG = jpg;
    NSMutableArray *content = [NSMutableArray arrayWithObject:@{ @"type": @"text", @"text": text }];
    NSArray *atts = gRunImages; // 用户随任务附带的图片(参考资料)
    for (NSUInteger ai = 0; ai < atts.count; ai++) {
        [content addObject:@{ @"type": @"text", @"text": [NSString stringWithFormat:@"任务附带图片 %lu/%lu(用户提供的参考资料,不是手机屏幕):", (unsigned long)ai + 1, (unsigned long)atts.count] }];
        [content addObject:@{ @"type": @"image_url", @"image_url": @{ @"url": [@"data:image/jpeg;base64," stringByAppendingString:[atts[ai] base64EncodedStringWithOptions:0]] } }];
    }
    if (glm && prev.length) { // 原生多模态模型可以同时看两张图:上一步之前的屏幕 + 当前屏幕,用来判断动作有没有生效
        [content addObject:@{ @"type": @"text", @"text": @"图1:上一步动作执行之前的屏幕(仅供对照):" }];
        [content addObject:@{ @"type": @"image_url", @"image_url": @{ @"url": [@"data:image/jpeg;base64," stringByAppendingString:[prev base64EncodedStringWithOptions:0]] } }];
        [content addObject:@{ @"type": @"text", @"text": @"图2:当前屏幕(据此决定下一步;先和图1对比,判断上一步有没有生效、页面有没有跳转):" }];
    }
    [content addObject:image];
    return @[ @{ @"role": @"system", @"content": systemPromptWithMemory() },
              @{ @"role": @"user", @"content": content } ];
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

static void waitForStableFrame(double maxWait); // 定义在下面

// 找不到 App 时的兜底:回主屏幕,向左滑到最后一页进入"App 资源库"(检测到"资源库"字样即成功)
static BOOL enterAppLibrary(NSString **note) {
    NSString *hn = nil;
    goHome(&hn);
    CGSize sc = screenSize();
    for (int i = 0; i < 9 && gAgentRunning; i++) {
        NSString *e = nil;
        waitForStableFrame(2.0);
        UIImage *img = takeScreenshot(&e);
        NSArray *items = img ? ocrImage(img, &e) : nil;
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            if ([t containsString:@"资源库"] || [t localizedCaseInsensitiveContainsString:@"App Library"]) {
                *note = @"已进入 App 资源库";
                return YES;
            }
        }
        doSwipe(sc.width * 0.88, sc.height * 0.5, sc.width * 0.12, sc.height * 0.5, 20, 320);
        sleep(1);
    }
    *note = @"左滑多次仍没有进入 App 资源库(滑动可能没生效)";
    return NO;
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

#pragma mark - AutoGLM-Phone 模式(模型名含 autoglm 时自动启用)

static NSString *const kAGPrompt =
@"你是一个智能体分析专家，可以根据操作历史和当前状态图执行一系列操作来完成任务。\n"
@"你必须严格按照要求输出以下格式：\n"
@"<think>{think}</think>\n"
@"<answer>{action}</answer>\n"
@"\n"
@"其中：\n"
@"- {think} 是对你为什么选择这个操作的简短推理说明。\n"
@"- {action} 是本次执行的具体操作指令，必须严格遵循下方定义的指令格式。\n"
@"\n"
@"操作指令及其作用如下：\n"
@"- do(action=\"Launch\", app=\"xxx\")\n"
@"    Launch是启动目标app的操作，这比通过主屏幕导航更快。此操作完成后，您将自动收到结果状态的截图。\n"
@"- do(action=\"Tap\", element=[x,y])\n"
@"    Tap是点击操作，点击屏幕上的特定点。可用此操作点击按钮、选择项目、从主屏幕打开应用程序，或与任何可点击的用户界面元素进行交互。坐标系统从左上角 (0,0) 开始到右下角（999,999）结束。此操作完成后，您将自动收到结果状态的截图。\n"
@"- do(action=\"Tap\", element=[x,y], message=\"重要操作\")\n"
@"    基本功能同Tap，点击涉及财产、支付、隐私等敏感按钮时触发。\n"
@"- do(action=\"Type\", text=\"xxx\")\n"
@"    Type是输入操作，在当前聚焦的输入框中输入文本。使用此操作前，请确保输入框已被聚焦（先点击它）。输入的文本将像使用键盘输入一样输入。自动清除文本：当你使用输入操作时，输入框中现有的任何文本（包括占位符文本和实际输入）都会在输入新文本前自动清除。你无需在输入前手动清除文本——直接使用输入操作输入所需文本即可。操作完成后，你将自动收到结果状态的截图。\n"
@"- do(action=\"Type_Name\", text=\"xxx\")\n"
@"    Type_Name是输入人名的操作，基本功能同Type。\n"
@"- do(action=\"Interact\")\n"
@"    Interact是当有多个满足条件的选项时而触发的交互操作，询问用户如何选择。\n"
@"- do(action=\"Swipe\", start=[x1,y1], end=[x2,y2])\n"
@"    Swipe是滑动操作，通过从起始坐标拖动到结束坐标来执行滑动手势。可用于滚动内容、在屏幕之间导航、下拉通知栏以及项目栏或进行基于手势的导航。坐标系统从左上角 (0,0) 开始到右下角（999,999）结束。滑动持续时间会自动调整以实现自然的移动。此操作完成后，您将自动收到结果状态的截图。\n"
@"- do(action=\"Note\", message=\"True\")\n"
@"    记录当前页面内容以便后续总结。\n"
@"- do(action=\"Call_API\", instruction=\"xxx\")\n"
@"    总结或评论当前页面或已记录的内容。\n"
@"- do(action=\"Long Press\", element=[x,y])\n"
@"    Long Pres是长按操作，在屏幕上的特定点长按指定时间。可用于触发上下文菜单、选择文本或激活长按交互。坐标系统从左上角 (0,0) 开始到右下角（999,999）结束。此操作完成后，您将自动收到结果状态的屏幕截图。\n"
@"- do(action=\"Double Tap\", element=[x,y])\n"
@"    Double Tap在屏幕上的特定点快速连续点按两次。使用此操作可以激活双击交互，如缩放、选择文本或打开项目。坐标系统从左上角 (0,0) 开始到右下角（999,999）结束。此操作完成后，您将自动收到结果状态的截图。\n"
@"- do(action=\"Take_over\", message=\"xxx\")\n"
@"    Take_over是接管操作，表示在登录和验证阶段需要用户协助。\n"
@"- do(action=\"Back\")\n"
@"    导航返回到上一个屏幕或关闭当前对话框。使用此操作可以从更深的屏幕返回、关闭弹出窗口或退出当前上下文。此操作完成后，您将自动收到结果状态的截图。\n"
@"- do(action=\"Home\")\n"
@"    Home是回到系统桌面的操作。使用此操作可退出当前应用并返回主屏幕，或从已知状态启动新任务。此操作完成后，您将自动收到结果状态的截图。\n"
@"- do(action=\"Wait\", duration=\"x seconds\")\n"
@"    等待页面加载，x为需要等待多少秒。\n"
@"- finish(message=\"xxx\")\n"
@"    finish是结束任务的操作，表示准确完整完成任务，message是终止信息。\n"
@"\n"
@"必须遵循的规则：\n"
@"1. 在执行任何操作前，先检查当前app是否是目标app，如果不是，先执行 Launch。\n"
@"2. 如果进入到了无关页面，先执行 Back。如果执行Back后页面没有变化，请点击页面左上角的返回键进行返回，或者右上角的X号关闭。\n"
@"3. 如果页面未加载出内容，最多连续 Wait 三次，否则执行 Back重新进入。\n"
@"4. 如果页面显示网络问题，需要重新加载，请点击重新加载。\n"
@"5. 如果当前页面找不到目标联系人、商品、店铺等信息，可以尝试 Swipe 滑动查找。\n"
@"6. 遇到价格区间、时间区间等筛选条件，如果没有完全符合的，可以放宽要求。\n"
@"7. 在做小红书总结类任务时一定要筛选图文笔记。\n"
@"8. 购物车全选后再点击全选可以把状态设为全不选，在做购物车任务时，如果购物车里已经有商品被选中时，你需要点击全选后再点击取消全选，再去找需要购买或者删除的商品。\n"
@"9. 在做外卖任务时，如果相应店铺购物车里已经有其他商品你需要先把购物车清空再去购买用户指定的外卖。\n"
@"10. 在做点外卖任务时，如果用户需要点多个外卖，请尽量在同一店铺进行购买，如果无法找到可以下单，并说明某个商品未找到。\n"
@"11. 请严格遵循用户意图执行任务，用户的特殊要求可以执行多次搜索，滑动查找。比如（i）用户要求点一杯咖啡，要咸的，你可以直接搜索咸咖啡，或者搜索咖啡后滑动查找咸的咖啡，比如海盐咖啡。（ii）用户要找到XX群，发一条消息，你可以先搜索XX群，找不到结果后，将\"群\"字去掉，搜索XX重试。（iii）用户要找到宠物友好的餐厅，你可以搜索餐厅，找到筛选，找到设施，选择可带宠物，或者直接搜索可带宠物，必要时可以使用AI搜索。\n"
@"12. 在选择日期时，如果原滑动方向与预期日期越来越远，请向反方向滑动查找。\n"
@"13. 执行任务过程中如果有多个可选择的项目栏，请逐个查找每个项目栏，直到完成任务，一定不要在同一项目栏多次查找，从而陷入死循环。\n"
@"14. 在执行下一步操作前请一定要检查上一步的操作是否生效，如果点击没生效，可能因为app反应较慢，请先稍微等待一下，如果还是不生效请调整一下点击位置重试，如果仍然不生效请跳过这一步继续任务，并在finish message说明点击不生效。\n"
@"15. 在执行任务中如果遇到滑动不生效的情况，请调整一下起始点位置，增大滑动距离重试，如果还是不生效，有可能是已经滑到底了，请继续向反方向滑动，直到顶部或底部，如果仍然没有符合要求的结果，请跳过这一步继续任务，并在finish message说明但没找到要求的项目。\n"
@"16. 在做游戏任务时如果在战斗页面如果有自动战斗一定要开启自动战斗，如果多轮历史状态相似要检查自动战斗是否开启。\n"
@"17. 如果没有合适的搜索结果，可能是因为搜索页面不对，请返回到搜索页面的上一级尝试重新搜索，如果尝试三次返回上一级搜索后仍然没有符合要求的结果，执行 finish(message=\"原因\")。\n"
@"18. 在结束任务前请一定要仔细检查任务是否完整准确的完成，如果出现错选、漏选、多选的情况，请返回之前的步骤进行纠正。\n"
@"\n"
@"补充说明（当前设备是 iPhone）：\n"
@"- iPhone 没有系统返回键，Back 会由程序点击左上角返回按钮来实现；Type 由程序通过剪贴板粘贴来实现，无需关心键盘。\n"
@"- 涉及支付、转账、输入支付密码等花钱环节，不要自己点击，用 do(action=\"Take_over\", message=\"需要你本人完成付款\") 请用户本人完成；其余任务正常完成。\n"
@"- finish 的 message 请写成给用户看的完整结果（如果任务是查询或总结信息，把信息完整写在 message 里）。";

// 已安装 App 的 bundle id -> 显示名(只查一次)
static NSString *agAppName(NSString *bid) {
    if (!bid.length) return @"Unknown";
    if ([bid isEqualToString:@"com.apple.springboard"]) return @"System Home";
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        id ws = c ? ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace")) : nil;
        SEL sel = NSSelectorFromString(@"allInstalledApplications");
        NSArray *apps = (ws && [ws respondsToSelector:sel]) ? ((id (*)(id, SEL))objc_msgSend)(ws, sel) : nil;
        for (id a in apps) {
            @try {
                NSString *n = [a valueForKey:@"localizedName"], *b = [a valueForKey:@"applicationIdentifier"];
                if ([n isKindOfClass:NSString.class] && [b isKindOfClass:NSString.class] && n.length) m[b] = n;
            } @catch (NSException *ex) {}
        }
        map = m;
    });
    return map[bid] ?: bid;
}

static NSString *agSystemPrompt(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    f.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    f.dateFormat = @"yyyy年MM月dd日 EEEE";
    NSString *mem = [memoryText() stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *memPart = mem.length ? [NSString stringWithFormat:@"\n\n用户的偏好与记忆（执行任务时请参考；与本次任务冲突时以本次任务为准）：\n%@", mem] : @"";
    NSArray *bl = blockedApps();
    NSString *blPart = bl.count ? [NSString stringWithFormat:@"\n\n禁止进入的 App（绝对不要打开）：%@", [bl componentsJoinedByString:@"、"]] : @"";
    NSString *hintPart = gExpHint.length ? [@"\n\n" stringByAppendingString:gExpHint] : @"";
    if (!confirmEnabled()) hintPart = [hintPart stringByAppendingString:@"\n\n用户已关闭“敏感操作确认”：发送、发布、提交、删除等操作直接执行，不要用 Take_over 或 Interact 征求同意，也不要给 Tap 加 message=\"重要操作\"；付款、转账、输入支付密码仍然要用 Take_over 请用户本人完成。"];
    return [NSString stringWithFormat:@"今天的日期是: %@\n%@%@%@%@", [f stringFromDate:[NSDate date]], kAGPrompt, memPart, blPart, hintPart];
}

// 从 do(action="Tap", text="xxx") 这样的文本里取字符串参数
static NSString *agArg(NSString *s, NSString *key) {
    NSString *pat = [NSString stringWithFormat:@"[(,\\s]%@\\s*=\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|'((?:[^'\\\\]|\\\\.)*)')", key];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    NSRange r = [m rangeAtIndex:1];
    if (r.location == NSNotFound) r = [m rangeAtIndex:2];
    if (r.location == NSNotFound) return nil;
    NSString *v = [s substringWithRange:r];
    v = [v stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
    v = [v stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
    v = [v stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
    return v;
}

// 取 element=[x,y] / start=[x,y] / end=[x,y]
static BOOL agPoint(NSString *s, NSString *key, double *x, double *y) {
    NSString *pat = [NSString stringWithFormat:@"[(,\\s]%@\\s*=\\s*\\[\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)\\s*\\]", key];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return NO;
    *x = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue];
    *y = [[s substringWithRange:[m rangeAtIndex:2]] doubleValue];
    return YES;
}

// 模型回复 -> 思考 + 动作。标准格式 <think>..</think><answer>..</answer>,也兼容缺标签的情况
static void agParse(NSString *content, NSString **think, NSString **action) {
    NSString *c = content ?: @"";
    NSRange a = [c rangeOfString:@"<answer>"];
    if (a.location != NSNotFound) {
        NSString *t = [c substringToIndex:a.location];
        NSUInteger from = a.location + a.length;
        NSRange e = [c rangeOfString:@"</answer>" options:0 range:NSMakeRange(from, c.length - from)];
        NSString *ans = e.location != NSNotFound ? [c substringWithRange:NSMakeRange(from, e.location - from)] : [c substringFromIndex:from];
        *think = [[t stringByReplacingOccurrencesOfString:@"<think>" withString:@""] stringByReplacingOccurrencesOfString:@"</think>" withString:@""];
        *action = [ans stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return;
    }
    NSRange f = [c rangeOfString:@"finish(message="], d = [c rangeOfString:@"do(action="];
    NSRange r = (f.location != NSNotFound && (d.location == NSNotFound || f.location < d.location)) ? f : d;
    if (r.location != NSNotFound) {
        *think = [c substringToIndex:r.location];
        *action = [[c substringFromIndex:r.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return;
    }
    *think = c; *action = @"";
}

// 最近一帧广播画面(原始 JPEG)
static NSData *agLatestJPEG(NSString **err) {
    if (!broadcastAlive()) { *err = @"屏幕广播没开(或已停止)"; return nil; }
    NSData *d;
    @synchronized (gLock) { d = gFrame; }
    if (!d.length) { *err = @"还没收到画面"; return nil; }
    return d;
}

static NSString *agFrameSig(NSData *d) {
    const uint8_t *p = d.bytes; uint64_t h = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < d.length; i += 211) { h ^= p[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%lu-%llx", (unsigned long)d.length, h];
}

// 直接把一个完整请求体发给 /chat/completions,返回第一条回复的文字
static NSString *agPostOnce(NSString *base, NSString *key, NSDictionary *body, BOOL honorStop, NSString **err) {
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
    if (!url) { *err = @"接口地址格式不对"; return nil; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 180;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    __block NSData *data = nil; __block NSError *e = nil; __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *er) {
        data = d; e = er; code = [(NSHTTPURLResponse *)resp statusCode];
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (honorStop && !gAgentRunning) {
            [task cancel];
            if (err) *err = @"用户已停止任务";
            return nil;
        }
    }
    if (e || !data) { *err = [NSString stringWithFormat:@"网络错误:%@", e.localizedDescription ?: @"无数据"]; return nil; }
    if (code != 200) {
        NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        *err = [NSString stringWithFormat:@"接口返回 %ld: %@", (long)code, t.length > 300 ? [t substringToIndex:300] : t];
        return nil;
    }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *content = nil;
    @try { content = j[@"choices"][0][@"message"][@"content"]; } @catch (NSException *ex) {}
    if (![content isKindOfClass:NSString.class]) { *err = @"接口返回格式不认识"; return nil; }
    return content;
}

// 请求失败最多试 5 次;honorStop=YES 时用户点了停止就不再重试
static NSString *agPostRetry(NSString *base, NSString *key, NSDictionary *body, BOOL honorStop, NSString **err) {
    NSString *last = nil;
    for (int attempt = 1; attempt <= 5; attempt++) {
        NSString *e = nil;
        NSString *r = agPostOnce(base, key, body, honorStop, &e);
        if (r.length) return r;
        if (r && !r.length) e = @"模型没有输出答案";
        last = e;
        if ((honorStop && !gAgentRunning) || attempt == 5 || !llmErrRetryable(e)) break;
        agentSay([NSString stringWithFormat:@"请求失败(%@),%d 秒后重试(第 %d/5 次)", e.length > 80 ? [e substringToIndex:80] : e, attempt, attempt + 1]);
        sleep(attempt);
    }
    if (err) *err = last;
    return nil;
}

// 截一次图并做本地 OCR,在其中找包含 words 之一、且不含 excludes 的文字
static NSDictionary *agFindOnScreen(NSArray *words, NSArray *excludes, NSString **err) {
    waitForStableFrame(2.0);
    UIImage *img = takeScreenshot(err);
    if (!img) return nil;
    NSArray *items = ocrImage(img, err);
    for (NSDictionary *it in items) {
        NSString *t = it[@"text"];
        BOOL hit = NO; for (NSString *w in words) if ([t containsString:w]) { hit = YES; break; }
        if (!hit) continue;
        BOOL bad = NO; for (NSString *x in excludes) if ([t containsString:x]) { bad = YES; break; }
        if (!bad) return it;
    }
    return nil;
}

// 在 (x,y) 的输入框里输入文字:写剪贴板(必须在前台) -> 回到原 App -> 点输入框聚焦
// 方法一:硬件键盘快捷键 Cmd+A(替换旧内容)+ Cmd+V,并自动点掉 iOS 的“允许粘贴”确认框。
//   判断有没有生效:出现过“允许粘贴”框 / Cmd+V 前后画面变了 / OCR 在屏幕上看到了粘贴的文字,任一成立就算成功。
// 方法二(方法一看不出效果时):长按输入框 -> (有“全选”就先全选) -> 点“粘贴” -> 点“允许粘贴”。
// 两种都无法确认时也返回 YES,但 note 里写明“没能确认”,让模型看下一张截图自己判断(输入其实经常是成功的)。
static BOOL agPasteText(NSString *text, double x, double y, NSString *backHint, NSString **note) {
    NSString *n = nil; BOOL stranded = NO;
    *note = nil;
    if (!writeClipboardInForeground(text, backHint, &n, &stranded)) { *note = n ?: @"剪贴板写入失败"; return NO; }
    if (stranded) { *note = @"剪贴板已写入,但没能自动回到原来的 App"; return NO; }
    usleep(800 * 1000);
    doTap(x, y);
    usleep(900 * 1000);
    NSString *e = nil;

    BOOL sent = doCmdKey(0x04);                 // Cmd+A:选中旧内容(没有旧内容就什么也不发生)
    usleep(500 * 1000);
    waitForStableFrame(2.0);
    NSData *f1 = agLatestJPEG(&e);
    NSString *sig1 = f1 ? agFrameSig(f1) : @"";
    sent = doCmdKey(0x19) && sent;              // Cmd+V
    usleep(900 * 1000);
    NSDictionary *allow1 = agFindOnScreen(@[@"允许粘贴"], @[@"不允许"], &e);
    if (allow1) { doTap([allow1[@"x"] doubleValue], [allow1[@"y"] doubleValue]); usleep(900 * 1000); }
    waitForStableFrame(2.0);
    NSData *f2 = agLatestJPEG(&e);
    NSString *sig2 = f2 ? agFrameSig(f2) : @"";
    if (sent) {
        if (allow1) return YES;
        if (sig1.length && sig2.length && ![sig1 isEqualToString:sig2]) return YES;
        NSString *flat = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
        NSString *snip = flat.length > 6 ? [flat substringToIndex:6] : flat;
        if (!snip.length) return YES;
        UIImage *img = takeScreenshot(&e);
        NSArray *items = img ? ocrImage(img, &e) : nil;
        for (NSDictionary *it in items) if ([it[@"text"] containsString:snip]) return YES;
    }

    doLongPress(x, y, 1100);
    NSDictionary *all = agFindOnScreen(@[@"全选"], @[], &e);
    if (all) { doTap([all[@"x"] doubleValue], [all[@"y"] doubleValue]); usleep(800 * 1000); }
    NSDictionary *paste = agFindOnScreen(@[@"粘贴"], @[@"允许", @"不允许", @"并"], &e);
    if (!paste) { *note = @"没能确认文字是否输入成功(键盘快捷键没有明显效果,也没找到“粘贴”菜单)"; return YES; }
    doTap([paste[@"x"] doubleValue], [paste[@"y"] doubleValue]);
    usleep(900 * 1000);
    NSDictionary *allow = agFindOnScreen(@[@"允许粘贴"], @[@"不允许"], &e);
    if (allow) { doTap([allow[@"x"] doubleValue], [allow[@"y"] doubleValue]); usleep(900 * 1000); }
    return YES;
}

// iPhone 没有返回键:优先点屏幕左上角的“返回/取消/关闭”文字,否则点左上角箭头的常见位置
static NSString *agGoBack(NSArray *items) {
    for (NSDictionary *it in items) {
        NSString *t = it[@"text"];
        double x = [it[@"x"] doubleValue], y = [it[@"y"] doubleValue];
        if (y < 150 && x < 200 && ([t containsString:@"返回"] || [t isEqualToString:@"取消"] || [t isEqualToString:@"关闭"])) {
            doTap(x, y);
            return [NSString stringWithFormat:@"点击了左上角的“%@”", t];
        }
    }
    doTap(28, 70);
    return @"点击了左上角返回箭头的常见位置";
}

#pragma mark - 需要用户参与(暂停 / 确认)、敏感操作与禁止 App、经验库回放

// ---- 系统级弹窗:通过 CFUserNotification 让 SpringBoard 在当前任何 App 上面弹出提醒(带按钮)。
// 需要 entitlement com.apple.springboard.show-alert;在你的系统上是否允许,我没法确认,不行时创建会失败、自动忽略(还有通知和 App 内弹窗)。
// 返回:被点的按钮序号(0/1/2);-1 = 被取消;-2 = 创建失败(*code 是错误码);-3 = 超时或被外部取消
static int systemAlertBlocking(NSString *title, NSString *msg, NSArray *buttons, double timeout, BOOL (^shouldCancel)(void), int *code) {
    static void *cf; static CFTypeRef (*pCreate)(CFAllocatorRef, CFTimeInterval, CFOptionFlags, SInt32 *, CFDictionaryRef);
    static SInt32 (*pReceive)(CFTypeRef, CFTimeInterval, CFOptionFlags *); static SInt32 (*pCancel)(CFTypeRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
        if (cf) { pCreate = dlsym(cf, "CFUserNotificationCreate"); pReceive = dlsym(cf, "CFUserNotificationReceiveResponse"); pCancel = dlsym(cf, "CFUserNotificationCancel"); }
    });
    if (!pCreate || !pReceive || !pCancel) { if (code) *code = -1; return -2; }
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"AlertHeader"] = title ?: @""; d[@"AlertMessage"] = msg ?: @"";
    if (buttons.count > 0) d[@"DefaultButtonTitle"] = buttons[0];
    if (buttons.count > 1) d[@"AlternateButtonTitle"] = buttons[1];
    if (buttons.count > 2) d[@"OtherButtonTitle"] = buttons[2];
    SInt32 err = 0;
    CFTypeRef n = pCreate(kCFAllocatorDefault, 0, 0, &err, (__bridge CFDictionaryRef)d);
    if (!n || err != 0) { if (n) CFRelease(n); if (code) *code = (int)err; return -2; }
    int result = -3;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < timeout) {
        if (shouldCancel && shouldCancel()) break;
        CFOptionFlags flags = 0;
        if (pReceive(n, 1.0, &flags) == 0) { int idx = (int)(flags & 0x3); result = idx == 3 ? -1 : idx; break; }
    }
    pCancel(n);
    CFRelease(n);
    return result;
}

// 请求(暂停/确认)用的系统弹窗:确认 = 允许 / 拒绝(跳过)/ 停止任务;暂停 = 继续 / 停止任务。“本次任务不再问”在通知和 App 内弹窗里选。
static void systemAlertForRequest(NSString *kind, NSString *text) {
    BOOL confirm = [kind isEqualToString:@"confirm"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *btn = confirm ? @[@"允许", @"拒绝(跳过这一步)", @"停止任务"] : @[@"继续", @"停止任务"];
        int code = 0;
        int r = systemAlertBlocking(confirm ? @"PhoneAgent 需要你确认" : @"PhoneAgent 任务已暂停",
                                    confirm ? text : [text stringByAppendingString:@"\n\n处理完点“继续”。"], btn, 1800,
                                    ^BOOL{ return gReqState != PAReqWaiting; }, &code);
        if (r < 0) return;
        if (confirm) agentRespond(r == 0 ? PAReqAllow : (r == 1 ? PAReqDeny : PAReqStop));
        else agentRespond(r == 0 ? PAReqAllow : PAReqStop);
    });
}

// 在“安全设置”里点“测试提醒”:5 秒后同时发通知和系统弹窗,方便你切到别的 App 看效果
static void testReminder(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
        UNMutableNotificationContent *n = [UNMutableNotificationContent new];
        n.title = @"PhoneAgent 测试提醒"; n.body = @"如果你在别的 App 里看到这条通知,说明通知可用"; n.sound = UNNotificationSound.defaultSound;
        [c addNotificationRequest:[UNNotificationRequest requestWithIdentifier:@"pa.test" content:n trigger:nil] withCompletionHandler:nil];
        [c getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *st) {
            NSString *t = st.authorizationStatus == UNAuthorizationStatusAuthorized ? @"已允许" :
                (st.authorizationStatus == UNAuthorizationStatusNotDetermined ? @"还没有选择" : @"未允许(请到 设置 → 通知 → PhoneAgent 打开)");
            [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"测试提醒:通知权限 %@", t]];
        }];
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        int code = 0;
        int r = systemAlertBlocking(@"PhoneAgent 测试提醒", @"如果你在别的 App 里看到这个弹窗,说明“系统弹窗”可用。点“好”关闭。", @[@"好"], 120, nil, &code);
        NSString *res = r == -2 ? [NSString stringWithFormat:@"系统弹窗创建失败(错误码 %d):这个系统不允许,只能靠通知和 App 内弹窗", code] :
                        r == -3 ? @"系统弹窗超时没有被点击" : @"系统弹窗可用,并且已被点击";
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[@"测试提醒:" stringByAppendingString:res]];
    });
}

static void postRequestNotification(NSString *kind, NSString *text) {
    BOOL confirm = [kind isEqualToString:@"confirm"];
    UNMutableNotificationContent *n = [UNMutableNotificationContent new];
    n.title = confirm ? @"PhoneAgent 需要你确认" : @"PhoneAgent 任务已暂停";
    n.body = text;
    n.sound = UNNotificationSound.defaultSound;
    n.categoryIdentifier = confirm ? @"PA_CONFIRM" : @"PA_PAUSE";
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:[UNNotificationRequest requestWithIdentifier:@"pa.req" content:n trigger:nil] withCompletionHandler:nil];
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *st) {
        if (st.authorizationStatus != UNAuthorizationStatusAuthorized && st.authorizationStatus != UNAuthorizationStatusProvisional)
            agentSay(@"提示:PhoneAgent 的通知权限没有开启,在别的 App 里收不到通知。请到 设置 → 通知 → PhoneAgent 允许通知");
    }];
}
static void clearRequestNotification(void) {
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    [c removeDeliveredNotificationsWithIdentifiers:@[@"pa.req"]];
    [c removePendingNotificationRequestsWithIdentifiers:@[@"pa.req"]];
}

// 请用户参与:kind = "pause"(登录/验证码/付款等要用户本人处理)或 "confirm"(发送/发布/删除等敏感操作要先同意)。
// 同时用 界面弹窗 + 通知(带按钮,不用离开当前 App)+ 语音 提醒;一直等到用户回应(最多 30 分钟)。
// 返回:1 = 允许/继续,0 = 拒绝(跳过这一步),-1 = 停止任务
static int agentAsk(NSString *kind, NSString *text) {
    BOOL confirm = [kind isEqualToString:@"confirm"];
    NSString *selfID = NSBundle.mainBundle.bundleIdentifier;
    NSString *pausedApp = frontmostBundleID();
    gReqKind = kind; gReqText = text; gReqState = PAReqWaiting;
    agentSay([NSString stringWithFormat:@"%@:%@", confirm ? @"等待你确认" : @"任务已暂停,等你处理", text]);
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.request" object:@{@"kind": kind, @"text": text}];
    postRequestNotification(kind, text);
    systemAlertForRequest(kind, text); // 系统级弹窗:在当前任何 App 上面都能看到
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.speak"
        object:confirm ? [NSString stringWithFormat:@"需要你确认:%@", text] : [NSString stringWithFormat:@"需要你处理:%@。处理完点继续。", text]];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (gAgentRunning && gReqState == PAReqWaiting && CFAbsoluteTimeGetCurrent() - t0 < 1800) usleep(300 * 1000);
    int st = gReqState;
    gReqState = PAReqNone;
    clearRequestNotification();
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.requestDone" object:nil];
    if (!gAgentRunning) return -1;
    if (st == PAReqStop) { agentSay(@"任务已被停止"); return -1; }
    if (st == PAReqWaiting || st == PAReqNone) { agentSay(@"任务停止:等待你回应超过 30 分钟"); return -1; }
    if (st == PAReqAllowAll) gConfirmSkipThisTask = YES;
    // 用户可能为了点通知/弹窗切到了 PhoneAgent:回到原来的 App
    if (pausedApp.length && ![pausedApp isEqualToString:selfID]) {
        NSString *now = frontmostBundleID();
        if (now.length && ![now isEqualToString:pausedApp]) { openApp(pausedApp); sleep(2); }
    }
    return (st == PAReqAllow || st == PAReqAllowAll) ? 1 : 0;
}

// 点击前的敏感检查:0 = 可以执行,1 = 用户拒绝/已由用户本人处理(跳过这一步,原因在 skipNote),-1 = 停止任务
static int guardSensitiveTap(NSString *target, NSString *risk, NSArray *items, double x, double y, NSString **skipNote) {
    int cat = 0;
    NSString *hit = classifyAction(target, risk, items, x, y, &cat);
    if (!hit) return 0;
    NSString *tgt = target.length ? target : @"屏幕上的这个位置";
    agentSay([NSString stringWithFormat:@"敏感操作判定:%@(依据:%@)", cat == 2 ? @"涉及付款,需要你本人处理" : @"需要你确认", hit]);
    if (cat == 2) {
        int r = agentAsk(@"pause", [NSString stringWithFormat:@"要点击「%@」,涉及付款或转账。为了安全我不会自动操作,请你本人完成;处理完点“继续”。", tgt]);
        if (r < 0) return -1;
        *skipNote = [NSString stringWithFormat:@"这一步涉及付款(「%@」),已由用户本人处理,没有点击;请根据新的屏幕继续", tgt];
        return 1;
    }
    if (cat == 1 && !gConfirmSkipThisTask) {
        NSString *app = agAppName(frontmostBundleID());
        int r = agentAsk(@"confirm", [NSString stringWithFormat:@"在「%@」里要点击「%@」%@%@", app, tgt, risk.length ? @"。后果:" : @"", risk ?: @""]);
        if (r < 0) return -1;
        if (r == 0) { *skipNote = [NSString stringWithFormat:@"用户拒绝了点击「%@」,没有执行;请换一种方式或结束任务", tgt]; return 1; }
        // 用户刚点击“允许”后，等待确认弹窗完全消失并把触摸焦点交还给目标 App，
        // 避免紧接着发送的 HID 点击被系统弹窗的关闭动画吞掉。
        usleep(1000 * 1000);
    }
    return 0;
}

// 最前台是禁止进入的 App:退回主屏幕,返回那个 App 的名字;不是就返回 nil
static NSString *enforceBlockedFront(void) {
    NSString *fbid = frontmostBundleID();
    if (!fbid.length || [fbid isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return nil;
    NSString *fname = agAppName(fbid);
    if (!isBlockedApp(fname, fbid)) return nil;
    NSString *hn = nil;
    goHome(&hn);
    return fname;
}

static NSArray *agScreenItems(NSString **err) {
    waitForStableFrame(2.0);
    UIImage *img = takeScreenshot(err);
    return img ? ocrImage(img, err) : nil;
}

// ---- 经验库回放 ----
static NSDictionary *expFindItem(NSArray *items, NSString *t, double rx, double ry) {
    if (!t.length) return nil;
    NSDictionary *best = nil; double bd = 1e9; int bestRank = 9;
    for (NSDictionary *it in items) {
        NSString *x = it[@"text"];
        if (!x.length) continue;
        int rank = [x isEqualToString:t] ? 0 : ([x containsString:t] ? 1 : ((x.length >= 2 && [t containsString:x]) ? 2 : 9));
        if (rank == 9) continue;
        double d = fabs([it[@"x"] doubleValue] - rx) + fabs([it[@"y"] doubleValue] - ry);
        if (rank < bestRank || (rank == bestRank && d < bd)) { best = it; bestRank = rank; bd = d; }
    }
    return best;
}
static int expAnchorHits(NSArray *items, NSArray *anchors) {
    int hits = 0;
    for (NSString *a in anchors)
        for (NSDictionary *it in items) {
            NSString *x = it[@"text"];
            if ([x containsString:a] || (x.length >= 2 && [a containsString:x])) { hits++; break; }
        }
    return hits;
}

// 按记录的步骤快速回放;每一步先核对屏幕、用屏幕上的文字重新定位按钮,对不上就中止交给模型。
// 返回:0 = 全部回放完,1 = 中途中止(原因在 *why),-1 = 用户停止了任务
static int expReplay(NSDictionary *entry, NSMutableArray *history, int *done, NSString **why) {
    NSArray *steps = entry[@"steps"];
    CGSize sc = screenSize();
    *done = 0;
    for (NSUInteger i = 0; i < steps.count && gAgentRunning; i++) {
        NSDictionary *st = steps[i];
        NSString *a = st[@"a"] ?: @"";
        NSString *blocked = enforceBlockedFront();
        if (blocked) { *why = [NSString stringWithFormat:@"进入了禁止进入的 App「%@」,已退回主屏幕", blocked]; return 1; }
        if ([a isEqualToString:@"open_app"]) {
            NSString *name = st[@"name"] ?: @"", *info = nil;
            NSString *bid = bundleForAppName(name, &info);
            if (!bid) { *why = [NSString stringWithFormat:@"找不到 App「%@」", name]; return 1; }
            if (isBlockedApp(name, nil) || isBlockedApp(agAppName(bid), bid)) { *why = [NSString stringWithFormat:@"「%@」是禁止进入的 App", name]; return 1; }
            if (!openApp(bid)) { *why = [NSString stringWithFormat:@"打开「%@」失败", name]; return 1; }
            gLastApp = bid;
            sleep(3);
        } else if ([a isEqualToString:@"tap"] || [a isEqualToString:@"long_press"] || [a isEqualToString:@"double_tap"] || [a isEqualToString:@"input_text"]) {
            NSString *e = nil;
            NSArray *items = agScreenItems(&e);
            NSArray *anchors = st[@"anchors"] ?: @[];
            if (!items.count) { *why = @"屏幕上识别不到文字,无法核对"; return 1; }
            if (paySheetVisible(items)) {
                int r = agentAsk(@"pause", @"看到支付/密码界面。为了安全我不会自动付款,请你本人完成;处理完点“继续”。");
                if (r < 0) return -1;
                *why = @"出现了支付界面,已由用户本人处理";
                return 1;
            }
            if (anchors.count >= 2) {
                int hits = expAnchorHits(items, anchors);
                if (hits * 2 < (int)anchors.count) { *why = [NSString stringWithFormat:@"屏幕和记录时对不上(核对 %d/%lu)", hits, (unsigned long)anchors.count]; return 1; }
            }
            NSString *t = st[@"t"] ?: @"";
            double rx = [st[@"x"] doubleValue], ry = [st[@"y"] doubleValue], x = rx, y = ry;
            if (t.length) {
                NSDictionary *it = expFindItem(items, t, rx, ry);
                if (!it) { *why = [NSString stringWithFormat:@"屏幕上没找到「%@」", t]; return 1; }
                x = [it[@"x"] doubleValue]; y = [it[@"y"] doubleValue];
            } else {
                int hits = expAnchorHits(items, anchors);
                if (anchors.count < 3 || hits * 10 < (int)anchors.count * 7) { *why = @"这一步点的是没有文字的图标,屏幕核对不够确定"; return 1; }
            }
            x = MAX(0, MIN(sc.width - 1, x)); y = MAX(0, MIN(sc.height - 1, y));
            if ([a isEqualToString:@"input_text"]) {
                NSString *note = nil;
                if (!agPasteText(st[@"text"] ?: @"", x, y, nil, &note)) { *why = [@"输入失败:" stringByAppendingString:note ?: @""]; return 1; }
            } else {
                NSString *skip = nil;
                int g = guardSensitiveTap(t, @"", items, x, y, &skip);
                if (g < 0) return -1;
                if (g > 0) { *why = skip ?: @"这一步被用户拒绝或由用户本人处理"; return 1; }
                if ([a isEqualToString:@"tap"]) doTap(x, y);
                else if ([a isEqualToString:@"long_press"]) doLongPress(x, y, 1100);
                else { doTap(x, y); usleep(120 * 1000); doTap(x, y); }
                sleep(2);
            }
        } else if ([a isEqualToString:@"swipe"]) {
            doSwipe([st[@"x1"] doubleValue], [st[@"y1"] doubleValue], [st[@"x2"] doubleValue], [st[@"y2"] doubleValue], 20, 350);
            sleep(2);
        } else if ([a isEqualToString:@"home"]) {
            NSString *hn = nil; goHome(&hn); sleep(1);
        } else if ([a isEqualToString:@"back"]) {
            NSString *e = nil; NSArray *items = agScreenItems(&e);
            agGoBack(items); sleep(2);
        } else if ([a isEqualToString:@"ask_user"]) {
            int r = agentAsk(@"pause", st[@"text"] ?: @"需要你处理");
            if (r < 0) return -1;
        }
        (*done)++;
        [history addObject:[NSString stringWithFormat:@"[经验回放] %lu. %@", (unsigned long)i + 1, expStepDesc(st)]];
        expRecord(st); // 已回放的步骤也算进本次轨迹,成功后一起存
    }
    return gAgentRunning ? 0 : -1;
}

// 在模型开始之前调用:任务和某条经验几乎相同(相似度 >= 0.85)就先快速回放,再交给模型接手核对、读取最终内容。
// 返回给模型看的一句说明;没有可用经验返回 nil;用户停止了任务时 *stopped = YES
static NSString *expTryReplay(NSString *task, NSMutableArray *history, BOOL *stopped) {
    *stopped = NO;
    if (!expEnabled() || !expReplayEnabled()) return nil;
    double score = 0;
    NSMutableDictionary *e = expFind(task, &score);
    if (!e || score < 0.85 || [e[@"steps"] count] < 2) return nil;
    NSMutableArray *all = expLoad();
    for (NSMutableDictionary *x in all) if ([x[@"id"] isEqualToString:e[@"id"]]) x[@"used"] = @([x[@"used"] intValue] + 1);
    expSave(all);
    gExpReplayID = e[@"id"];
    agentSay([NSString stringWithFormat:@"经验库:找到几乎相同的成功经验(相似度 %.0f%%,%lu 步),先快速回放,再由模型接手核对", score * 100, (unsigned long)[e[@"steps"] count]]);
    int done = 0; NSString *why = nil;
    int r = expReplay(e, history, &done, &why);
    if (r < 0) { *stopped = YES; return nil; }
    NSString *summary;
    if (r == 0) summary = [NSString stringWithFormat:@"经验库已回放 %d 步(全部完成)。", done];
    else { gExpReplayAborted = YES; summary = [NSString stringWithFormat:@"经验库回放了 %d 步后中止:%@。", done, why ?: @"屏幕对不上"]; }
    agentSay(summary);
    return summary;
}

static void agentRunAutoGLM(NSString *task, NSString *base, NSString *key, NSString *model) {
    gAgentRunning = YES;
    if (!base.length || [base.lowercaseString containsString:@"deepseek"]) {
        base = @"https://open.bigmodel.cn/api/paas/v4";
        agentSay(@"提示:AutoGLM-Phone 模型用智谱 BigModel 接口,已自动改用 https://open.bigmodel.cn/api/paas/v4(API Key 要填智谱的)");
    }
    CGSize sc = screenSize();
    if (gRunImages.count) agentSay(@"提示:AutoGLM 模式暂不支持任务附带图片,图片已忽略(文件里的文字仍然有效)");
    NSMutableArray *ctx = [NSMutableArray arrayWithObject:@{@"role": @"system", @"content": agSystemPrompt()}];
    NSString *pendingNote = nil, *lastSig = @"";
    int same = 0, parseFails = 0;
    double lastX = -1, lastY = -1;
    agentSay([NSString stringWithFormat:@"任务开始[AutoGLM %@]:%@", model, task]);
    int blockedHits = 0;
    {   // 经验库:几乎相同的任务先快速回放,再交给模型
        BOOL replayStopped = NO;
        NSString *replaySummary = expTryReplay(gTaskDisplay.length ? gTaskDisplay : task, [NSMutableArray array], &replayStopped);
        if (replayStopped) { agentSay(@"任务已被停止"); gAgentRunning = NO; return; }
        if (replaySummary.length) pendingNote = [NSString stringWithFormat:@"(系统提示:%@请根据当前截图核对任务是否已经完成:没完成就继续做,完成了就 finish 并写出结果。)", replaySummary];
    }
    for (int step = 1; gAgentRunning; step++) { // 不限步数,靠"停止任务"和卡死检测结束
        waitForStableFrame(3.0);
        NSString *err = nil;
        NSData *jpg = agLatestJPEG(&err);
        if (!jpg) { agentSay([@"拿不到屏幕画面,任务停止:" stringByAppendingString:err ?: @"?"]); break; }
        // 本地 OCR 不发给模型,只用来做支付拦截和辅助动作
        UIImage *img = takeScreenshot(&err);
        NSArray *items = img ? ocrImage(img, &err) : nil;
        NSString *blockedName = enforceBlockedFront();
        if (blockedName) {
            agentSay([NSString stringWithFormat:@"安全:当前在禁止进入的 App「%@」,已自动退回主屏幕", blockedName]);
            pendingNote = [NSString stringWithFormat:@"(系统提示:程序发现进入了禁止进入的 App「%@」,已退回主屏幕;不要再打开它。)", blockedName];
            if (++blockedHits >= 4) { agentSay(@"任务停止:多次进入禁止进入的 App,已停止"); break; }
            lastSig = @""; same = 0;
            continue;
        }
        if (items.count && paySheetVisible(items)) {
            int r = agentAsk(@"pause", @"看到支付/密码界面。为了安全我不会自动付款,请你本人完成;处理完点“继续”(或点“停止任务”)。");
            if (r < 0) break;
            pendingNote = @"(系统提示:出现过支付界面,用户已本人处理后点了继续,请根据当前截图继续。)";
            lastSig = @""; same = 0;
            continue;
        }
        NSString *sig = agFrameSig(jpg);
        if ([sig isEqualToString:lastSig]) same++; else same = 0;
        lastSig = sig;
        if (same >= 5) { agentSay(@"屏幕连续多步没变化,已停止"); break; }

        NSString *appName = agAppName(frontmostBundleID());
        NSData *infoJSON = [NSJSONSerialization dataWithJSONObject:@{@"current_app": appName} options:0 error:nil];
        NSString *info = [[NSString alloc] initWithData:infoJSON encoding:NSUTF8StringEncoding] ?: @"{}";
        NSMutableString *text = [NSMutableString stringWithFormat:@"%@** Screen Info **\n\n%@", step == 1 ? [task stringByAppendingString:@"\n\n"] : @"", info];
        if (pendingNote.length) { [text appendFormat:@"\n\n%@", pendingNote]; pendingNote = nil; }
        if (same >= 2) [text appendString:@"\n\n(系统提示:上一步操作后屏幕没有变化,请换一种方式,例如调整点击位置、先 Wait、或 Back 后重进。)"];

        NSString *b64 = [jpg base64EncodedStringWithOptions:0];
        NSDictionary *userMsg = @{@"role": @"user", @"content": @[
            @{@"type": @"image_url", @"image_url": @{@"url": [@"data:image/jpeg;base64," stringByAppendingString:b64]}},
            @{@"type": @"text", @"text": text}]};
        NSMutableArray *msgs = [ctx mutableCopy];
        [msgs addObject:userMsg];
        NSDictionary *body = @{@"model": model, @"messages": msgs, @"max_tokens": @3000,
                               @"temperature": @0.0, @"top_p": @0.85, @"frequency_penalty": @0.2};
        NSString *content = agPostRetry(base, key, body, YES, &err);
        if (!gAgentRunning) break;
        if (!content) { agentSay([@"调用模型失败,任务停止:" stringByAppendingString:err ?: @"?"]); break; }
        NSString *think = nil, *action = nil;
        agParse(content, &think, &action);
        think = [think stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        if (!action.length) {
            agentSay([NSString stringWithFormat:@"模型回复里没找到动作,重试(%d):%@", parseFails + 1, content.length > 100 ? [content substringToIndex:100] : content]);
            if (++parseFails >= 3) { agentSay(@"连续 3 次没有解析出动作,任务停止"); break; }
            pendingNote = @"(系统提示:请严格按格式输出 <think>思考</think><answer>do(...) 或 finish(message=\"...\")</answer>。)";
            step--;
            continue;
        }
        parseFails = 0;
        // 和 Open-AutoGLM 一样:历史里的用户消息去掉图片,只保留文字;再接上模型这一步的回复
        [ctx addObject:@{@"role": @"user", @"content": [text copy]}];
        [ctx addObject:@{@"role": @"assistant", @"content": [NSString stringWithFormat:@"<think>%@</think><answer>%@</answer>", think, action]}];
        // 步数不限,所以上下文要控制长度:始终保留 系统提示 + 第一轮(里面有任务原文) + 最近 40 轮
        while (ctx.count > 3 + 80) [ctx removeObjectsInRange:NSMakeRange(3, 2)];
        agentSay([NSString stringWithFormat:@"第%d步[%@]:%@ → %@", step, appName, think.length > 120 ? [think substringToIndex:120] : think, action]);

        if ([action hasPrefix:@"finish"]) {
            agentSay([NSString stringWithFormat:@"任务完成:%@", agArg(action, @"message") ?: @""]);
            break;
        }
        NSString *act = [agArg(action, @"action") ?: @"" lowercaseString];
        double ax = 0, ay = 0, bx = 0, by = 0;
        BOOL hasEl = agPoint(action, @"element", &ax, &ay);
        double x = ax / 1000.0 * sc.width, y = ay / 1000.0 * sc.height;
        x = MAX(0, MIN(sc.width - 1, x)); y = MAX(0, MIN(sc.height - 1, y));

        if ([act isEqualToString:@"tap"] || [act isEqualToString:@"long press"] || [act isEqualToString:@"double tap"]) {
            if (!hasEl) { pendingNote = @"(系统提示:动作缺少 element=[x,y] 坐标。)"; continue; }
            NSString *near = nearestItemText(items, x, y);
            NSString *risk = agArg(action, @"message").length ? @"模型标注为重要操作" : @"";
            NSString *skip = nil;
            int g = guardSensitiveTap(near, risk, items.count ? items : nil, x, y, &skip);
            if (g < 0) break;
            if (g > 0) { agentSay([@"提示:" stringByAppendingString:skip ?: @"这一步被跳过"]); pendingNote = [NSString stringWithFormat:@"(系统提示:%@)", skip ?: @"这一步被跳过"]; continue; }
            if ([act isEqualToString:@"tap"]) doTap(x, y);
            else if ([act isEqualToString:@"long press"]) doLongPress(x, y, 1100);
            else { doTap(x, y); usleep(120 * 1000); doTap(x, y); }
            lastX = x; lastY = y;
            expRecord(@{@"a": [act isEqualToString:@"tap"] ? @"tap" : ([act isEqualToString:@"long press"] ? @"long_press" : @"double_tap"),
                        @"t": near, @"x": @(x), @"y": @(y), @"anchors": items.count ? expAnchors(items) : @[]});
            sleep(2);
        } else if ([act isEqualToString:@"swipe"]) {
            double sx = 0, sy = 0;
            if (!agPoint(action, @"start", &sx, &sy) || !agPoint(action, @"end", &bx, &by)) { pendingNote = @"(系统提示:Swipe 缺少 start/end 坐标。)"; continue; }
            doSwipe(sx / 1000.0 * sc.width, sy / 1000.0 * sc.height, bx / 1000.0 * sc.width, by / 1000.0 * sc.height, 20, 350);
            expRecord(@{@"a": @"swipe", @"x1": @(sx / 1000.0 * sc.width), @"y1": @(sy / 1000.0 * sc.height), @"x2": @(bx / 1000.0 * sc.width), @"y2": @(by / 1000.0 * sc.height), @"anchors": items.count ? expAnchors(items) : @[]});
            sleep(2);
        } else if ([act isEqualToString:@"type"] || [act isEqualToString:@"type_name"]) {
            NSString *t = agArg(action, @"text") ?: @"";
            if (lastX < 0) { pendingNote = @"(系统提示:输入文字前需要先点击输入框。)"; continue; }
            NSString *note = nil;
            if (!agPasteText(t, lastX, lastY, nil, &note)) {
                agentSay([@"提示:输入失败:" stringByAppendingString:note ?: @"?"]);
                pendingNote = [NSString stringWithFormat:@"(系统提示:Type 失败:%@。请重新点击输入框后再试。)", note ?: @""];
            } else {
                expRecord(@{@"a": @"input_text", @"text": t, @"t": nearestItemText(items, lastX, lastY), @"x": @(lastX), @"y": @(lastY), @"anchors": items.count ? expAnchors(items) : @[]});
                if (note.length) pendingNote = [NSString stringWithFormat:@"(系统提示:已执行输入,但%@。请看当前截图;输入框是空的就重新点击输入框后再 Type。)", note];
            }
        } else if ([act isEqualToString:@"launch"]) {
            NSString *name = agArg(action, @"app") ?: @"";
            NSString *i2 = nil;
            NSString *bid = bundleForAppName(name, &i2);
            if (isBlockedApp(name, nil) || (bid && isBlockedApp(agAppName(bid), bid))) {
                agentSay([NSString stringWithFormat:@"安全:「%@」是禁止进入的 App,已拒绝打开", name]);
                pendingNote = [NSString stringWithFormat:@"(系统提示:「%@」在用户设置的禁止进入的 App 列表里,不能打开。请换别的方式完成任务,或用 Take_over 说明。)", name];
            } else if (bid && openApp(bid)) { gLastApp = bid; lastX = lastY = -1; expRecord(@{@"a": @"open_app", @"name": name}); }
            else {
                agentSay([@"提示:" stringByAppendingString:i2 ?: @"打开失败"]);
                NSString *ln = nil;
                BOOL inLib = enterAppLibrary(&ln);
                pendingNote = [NSString stringWithFormat:@"(系统提示:%@ 程序已自动尝试进入 App 资源库:%@。%@)", i2 ?: @"打开失败", ln ?: @"", inLib ? @"请点击顶部搜索框,用 Type 输入 App 名称搜索,再点搜索结果打开。" : @"如果仍不在资源库界面,请先 Home 再试,或 finish 说明。"];
            }
            sleep(3);
        } else if ([act isEqualToString:@"back"]) {
            agentSay([@"返回:" stringByAppendingString:agGoBack(items)]);
            expRecord(@{@"a": @"back"});
            sleep(2);
        } else if ([act isEqualToString:@"home"]) {
            NSString *hn = nil;
            goHome(&hn);
            lastX = lastY = -1;
            expRecord(@{@"a": @"home"});
            sleep(1);
        } else if ([act isEqualToString:@"wait"]) {
            NSString *d = agArg(action, @"duration") ?: @"2";
            int secs = MAX(1, MIN(10, [d intValue]));
            sleep(secs);
        } else if ([act isEqualToString:@"take_over"] || [act isEqualToString:@"interact"]) {
            NSString *msg = agArg(action, @"message") ?: ([act isEqualToString:@"interact"] ? @"有多个选项需要你选择" : @"需要你协助(登录、验证等)");
            int r = agentAsk(@"pause", msg);
            if (r < 0) break;
            expRecord(@{@"a": @"ask_user", @"text": msg});
            pendingNote = @"(系统提示:用户已手动处理完毕并点了继续,请根据当前截图继续任务。)";
            lastSig = @""; same = 0;
        } else if ([act isEqualToString:@"note"] || [act isEqualToString:@"call_api"]) {
            // 记录/总结类动作:这里不需要额外操作
        } else {
            pendingNote = [NSString stringWithFormat:@"(系统提示:无法识别的动作「%@」,请使用规定的指令。)", act];
        }
    }
    if (gAgentRunning) agentSay(@"任务结束");
    else agentSay(@"任务已被停止");
    gAgentRunning = NO;
}

#pragma mark - 任务收尾:防锁屏、结果、记忆

static uint32_t gPMA;
static dispatch_source_t gAwakeTimer;

// 任务期间保持亮屏:idleTimerDisabled(只在前台有效)+ IOPM 断言(私有,可能无效)+ 每 8 秒一个无害的 Shift 键事件重置锁屏计时
static void taskAwakeStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ UIApplication.sharedApplication.idleTimerDisabled = YES; });
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    int (*create)(CFStringRef, uint32_t, CFStringRef, uint32_t *) = h ? dlsym(h, "IOPMAssertionCreateWithName") : NULL;
    if (create && !gPMA) create(CFSTR("PreventUserIdleDisplaySleep"), 255, CFSTR("PhoneAgent task"), &gPMA);
    if (!gAwakeTimer) {
        gAwakeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(gAwakeTimer, DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(gAwakeTimer, ^{ doShiftKey(); });
        dispatch_resume(gAwakeTimer);
    }
}

static void taskAwakeStop(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ UIApplication.sharedApplication.idleTimerDisabled = NO; });
    if (gAwakeTimer) { dispatch_source_cancel(gAwakeTimer); gAwakeTimer = nil; }
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    int (*rel)(uint32_t) = h ? dlsym(h, "IOPMAssertionRelease") : NULL;
    if (rel && gPMA) { rel(gPMA); gPMA = 0; }
}

// 任务结束后让当前模型从任务和结果里提炼值得长期记住的偏好,追加进"记忆"(可以在记忆窗口里改)
static void memoryLearn(NSString *task, NSString *result) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"memory_auto"] && ![d boolForKey:@"memory_auto"]) return;
    NSString *key = nil, *base = nil, *model = nil;
    loadLLMConfig(&key, &base, &model);
    if (!key.length || !base.length || !model.length) return;
    NSString *lm = model.lowercaseString;
    if ([lm containsString:@"autoglm"]) return; // 手机专用模型不适合做文字提炼
    NSString *mem = memoryText();
    NSString *prompt = [NSString stringWithFormat:
        @"你是用户个人助手的记忆模块。下面是已有记忆、用户刚刚下达的手机任务和执行结果。请只提取值得长期记住的用户偏好或稳定事实(例如常用的 App、喜欢的品牌/口味/尺码、常去的地点、说话习惯、对结果格式的要求)。"
        @"不要记录一次性的事情;不要记录密码、验证码、银行卡号、身份证号、手机号、支付信息等敏感内容;不要重复已有记忆。"
        @"每条一行,以“- ”开头,每条不超过 40 个字;没有新内容就只输出“无”。\n\n已有记忆:\n%@\n\n任务:%@\n\n结果:%@",
        mem.length ? mem : @"(空)", task ?: @"", result ?: @""];
    BOOL glm = [lm hasPrefix:@"glm"];
    NSDictionary *body = @{@"model": model, @"messages": @[@{@"role": @"user", @"content": prompt}],
                           @"temperature": glm ? @1.0 : @0.2, @"max_tokens": glm ? @4096 : @300};
    NSString *err = nil;
    NSString *c = agPostRetry(base, key, body, NO, &err);
    if (!c.length) return;
    NSMutableArray *add = [NSMutableArray array];
    for (NSString *ln in [c componentsSeparatedByString:@"\n"]) {
        NSString *t = [ln stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!([t hasPrefix:@"-"] || [t hasPrefix:@"•"])) continue;
        if (t.length < 3 || t.length > 90 || [mem containsString:t]) continue;
        [add addObject:t];
        if (add.count >= 5) break;
    }
    if (!add.count) return;
    NSString *joined = [add componentsJoinedByString:@"\n"];
    NSString *newMem = mem.length ? [mem stringByAppendingFormat:@"\n%@", joined] : joined;
    if (newMem.length > 3000) newMem = [newMem substringFromIndex:newMem.length - 3000];
    [d setObject:newMem forKey:@"memory_text"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"已记住新偏好:\n%@", joined]];
}

// 自动开启屏幕录制:先把 PhoneAgent 切到前台,触发系统的“屏幕直播”面板,再用 HID 点面板里的“开始直播”。
// 难点:此时还没有录屏就没有截图,看不到按钮在哪,所以只能"盲点"——按屏幕高度的若干个比例位置依次试,
// 哪个位置能让广播真的连上,就把这个比例记下来,以后直接用。
static void castGuard(BOOL on) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.guard" object:@(on)];
}

static void triggerPicker(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *v in gPicker.subviews)
            if ([v isKindOfClass:UIButton.class]) { [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside]; break; }
    });
}

static BOOL ensureBroadcast(NSString **note) {
    if (broadcastAlive()) return YES;
    // 冷启动或刚回到前台时,扩展的心跳最多要 2 秒才到;先等一等,免得录屏明明开着却又去触发“开始直播”(那样会点到“停止直播”)
    for (int i = 0; i < 18 && !broadcastAlive(); i++) usleep(200 * 1000);
    if (broadcastAlive()) return YES;
    if (!gPicker) { *note = @"找不到录屏按钮"; return NO; }
    if (appStateNow() != UIApplicationStateActive) {
        openApp(NSBundle.mainBundle.bundleIdentifier);
        if (!waitAppActive(6)) { *note = @"PhoneAgent 没能回到前台"; return NO; }
        usleep(700 * 1000);
    }
    castGuard(YES); // 盲点期间在 PhoneAgent 自己的界面上盖一层透明的"吞点击"层:系统面板在它上面,点面板不受影响;面板不在时,盲点只会落在这层上
    CGSize sc = screenSize();
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    double saved = [d doubleForKey:@"bcast_btn_y"];
    NSMutableArray *cands = [NSMutableArray array];
    if (saved > 0) [cands addObject:@(saved)];
    for (NSNumber *r in @[@0.589, @0.575, @0.603, @0.56, @0.62]) // 0.589 来自你发的截图:“开始直播”按钮中心在屏幕高度的 58.9% 处
        if (fabs(r.doubleValue - saved) > 0.005) [cands addObject:r];
    for (NSNumber *r in cands) {
        triggerPicker();
        usleep(1600 * 1000); // 等系统的“屏幕直播”面板弹出
        doTap(sc.width / 2, sc.height * r.doubleValue);
        for (int i = 0; i < 40 && !broadcastAlive(); i++) usleep(200 * 1000); // 3 秒倒计时 + 扩展连接
        if (broadcastAlive()) {
            [d setDouble:r.doubleValue forKey:@"bcast_btn_y"];
            usleep(900 * 1000);
            doTap(sc.width / 2, sc.height * 0.81); // 倒计时结束后系统面板还停在屏幕上:点面板下面空白区域的中心(按截图:面板下缘 61.8%,下面空白区中心约 81%)把它收起来
            usleep(900 * 1000);
            castGuard(NO);
            return YES;
        }
        doTap(sc.width / 2, sc.height * 0.81); // 没点中:点面板下面的空白处把它收起来,再试下一个位置
        usleep(900 * 1000);
    }
    castGuard(NO);
    *note = @"盲点“开始直播”的几个位置都没有成功";
    return NO;
}

// 任务结束后关闭录屏:让广播扩展自己结束(扩展调用 finishBroadcastWithError),最多等 10 秒
static void requestBroadcastStop(void) {
    if (!broadcastAlive()) return;
    gBroadcastStopRequested = YES;
    for (int i = 0; i < 50 && broadcastAlive(); i++) usleep(200 * 1000);
    BOOL still = broadcastAlive();
    gBroadcastStopRequested = NO;
    agentSay(still ? @"提示:屏幕录制没能自动关闭,请手动关闭" : @"屏幕录制已自动关闭");
}

static void taskRunBegin(NSString *task) {
    @synchronized (gLock) { [gRunLog removeAllObjects]; gTaskStatus = @""; gTaskResultText = @""; }
    gAgentRunning = YES; // 从这里开始就算"任务进行中"(包括自动开启录屏的阶段)
    gExpSteps = [NSMutableArray array]; gExpReplayID = nil; gExpReplayAborted = NO;
    gConfirmSkipThisTask = NO; gReqState = PAReqNone;
    gExpHint = expHintFor(gTaskDisplay.length ? gTaskDisplay : task); // 相似的过往经验,作为参考提示给模型
    taskAwakeStart();
}

// 任务结束:停止防锁屏 -> 回到 PhoneAgent -> 弹出结果窗口 -> 后台提炼记忆
static void taskRunEnd(NSString *task, BOOL stopCast) {
    gAgentRunning = NO;
    taskAwakeStop();
    NSString *status, *result; NSArray *lines;
    @synchronized (gLock) { status = gTaskStatus; result = gTaskResultText; lines = [gRunLog copy]; }
    if (!status.length) status = @"已结束";
    if (!result.length) result = @"(模型没有给出结果文字,详见下面的执行记录)";
    NSString *shown = gTaskDisplay.length ? gTaskDisplay : task;
    expFinish(shown, status); // 成功完成的任务存进经验库
    NSString *text = [NSString stringWithFormat:@"【任务】\n%@\n\n【状态】%@\n\n【结果】\n%@\n\n【执行记录】\n%@",
                      shown, status, result, [lines componentsJoinedByString:@"\n"]];
    gLastResultText = text;
    gLastSpeechText = [NSString stringWithFormat:@"任务%@。%@", status, result];
    if (appStateNow() != UIApplicationStateActive) {
        openApp(NSBundle.mainBundle.bundleIdentifier);
        waitAppActive(6);
        usleep(500 * 1000);
    }
    if (stopCast && broadcastAlive()) {
        // 先关录屏,并自动点掉系统弹出的“直播已停止”提示里的“好”,然后才显示结果窗口。
        // 期间盖一层“正在关闭屏幕录制”的遮罩:万一没点中提示框,点击也只会落在遮罩上,不会误点别的。
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.closing" object:@YES];
        requestBroadcastStop();
        usleep(1700 * 1000); // 等系统弹出提示
        CGSize sc = screenSize();
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        double okx = [ud doubleForKey:@"stop_ok_x"], oky = [ud doubleForKey:@"stop_ok_y"];
        if (okx <= 0) okx = 0.327; // 来自你发的截图:“好”按钮中心在屏幕宽的 32.7%、高的 56.6%
        if (oky <= 0) oky = 0.566;
        doTap(sc.width * okx, sc.height * oky);
        usleep(1000 * 1000);
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.closing" object:@NO];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.showResult" object:text];
    NSString *shownCopy = [shown copy], *resultCopy = [result copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ memoryLearn(shownCopy, resultCopy); });
}

static void agentRunCore(NSString *task, NSString *base, NSString *key, NSString *model) {
    if ([model.lowercaseString containsString:@"autoglm"]) { agentRunAutoGLM(task, base, key, model); return; }
    gCurrentModel = model;
    gPrevModelJPEG = nil;
    if ([model.lowercaseString hasPrefix:@"glm"] && (!base.length || [base.lowercaseString containsString:@"deepseek"])) {
        base = @"https://open.bigmodel.cn/api/paas/v4";
        agentSay(@"提示:GLM 模型用智谱 BigModel 接口,已自动改用 https://open.bigmodel.cn/api/paas/v4(API Key 要填智谱的)");
    }
    if ([model isEqualToString:@"deepseek-chat"] || !model.length) model = @"deepseek-flash";
    gAgentRunning = YES;
    NSMutableArray *history = [NSMutableArray array];
    NSString *lastSig = @""; int same = 0;
    CGSize sc = screenSize();
    agentSay([NSString stringWithFormat:@"任务开始:%@", task]);
    int blockedHits = 0;
    {   // 经验库:任务和某条成功经验几乎相同时,先快速回放,再由模型接手核对
        BOOL replayStopped = NO;
        NSString *replaySummary = expTryReplay(gTaskDisplay.length ? gTaskDisplay : task, history, &replayStopped);
        if (replayStopped) { agentSay(@"任务已被停止"); gAgentRunning = NO; return; }
        if (replaySummary.length) [history addObject:[NSString stringWithFormat:@"(%@请根据当前屏幕核对任务是否已经完成:没完成就继续做,完成了就用 done 给出结果。)", replaySummary]];
    }
    for (int step = 1; gAgentRunning; step++) { // 不限步数,靠"停止任务"和卡死检测结束
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
        NSString *blockedName = enforceBlockedFront();
        if (blockedName) {
            agentSay([NSString stringWithFormat:@"安全:当前在禁止进入的 App「%@」,已自动退回主屏幕", blockedName]);
            [history addObject:[NSString stringWithFormat:@"%d. (程序发现进入了禁止进入的 App「%@」,已退回主屏幕;不要再打开它)", step, blockedName]];
            if (++blockedHits >= 4) { agentSay(@"任务停止:多次进入禁止进入的 App,已停止"); break; }
            continue;
        }
        if (localOK && paySheetVisible(items)) {
            int r = agentAsk(@"pause", @"看到支付/密码界面。为了安全我不会自动付款,请你本人完成;处理完点“继续”(或点“停止任务”)。");
            if (r < 0) break;
            [history addObject:[NSString stringWithFormat:@"%d. (出现支付界面,已由用户本人处理后继续)", step]];
            lastSig = @""; same = 0;
            continue;
        }

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
        BOOL payPage = NO;
        for (NSString *word in @[@"输入支付密码", @"请输入支付密码", @"确认付款", @"立即支付", @"确认支付", @"免密支付"]) if ([visible containsString:word]) { payPage = YES; break; }
        if (payPage) {
            int r = agentAsk(@"pause", @"模型识别到付款界面。为了安全我不会自动付款,请你本人完成;处理完点“继续”(或点“停止任务”)。");
            if (r < 0) break;
            [history addObject:[NSString stringWithFormat:@"%d. (出现付款界面,已由用户本人处理后继续)", step]];
            lastSig = @""; same = 0;
            continue;
        }

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
        if ([action isEqualToString:@"ask_user"]) { // 需要用户本人处理(登录/验证码/付款/选择…):提醒并暂停,处理完点“继续”
            NSString *why = [act[@"text"] description] ?: @"需要你处理";
            int r = agentAsk(@"pause", why);
            if (r < 0) break;
            expRecord(@{@"a": @"ask_user", @"text": why});
            [history addObject:[NSString stringWithFormat:@"%d. ask_user(%@) → 用户已处理并点了继续,请根据新的屏幕继续", step, why]];
            lastSig = @""; same = 0;
            continue;
        }
        NSString *result = @"已执行";
        if ([action isEqualToString:@"tap"] || [action isEqualToString:@"long_press"]) {
            NSString *tgt = usedID ? idText : ([act[@"target"] description] ?: @"");
            NSString *risk = [act[@"risk"] description] ?: @"";
            NSString *skip = nil;
            int g = guardSensitiveTap(tgt, risk, localOK ? items : nil, x, y, &skip);
            if (g < 0) break;
            if (g > 0) {
                [history addObject:[NSString stringWithFormat:@"%d. %@", step, skip ?: @"这一步被跳过"]];
                agentSay([@"提示:" stringByAppendingString:skip ?: @"这一步被跳过"]);
                continue;
            }
            if ([action isEqualToString:@"tap"]) doTap(x, y); else doLongPress(x, y, 900);
            [history addObject:usedID ? [NSString stringWithFormat:@"%d. %@ id=%ld「%@」", step, action, (long)oid, idText] : [NSString stringWithFormat:@"%d. %@(%.0f,%.0f)", step, action, xpx, ypx]];
            expRecord(@{@"a": action, @"t": tgt, @"x": @(x), @"y": @(y), @"anchors": localOK ? expAnchors(items) : @[]});
            sleep(2);
        } else if ([action isEqualToString:@"swipe"]) {
            doSwipe(x, y, x2, y2, 20, 350);
            expRecord(@{@"a": @"swipe", @"x1": @(x), @"y1": @(y), @"x2": @(x2), @"y2": @(y2), @"anchors": localOK ? expAnchors(items) : @[]});
            [history addObject:[NSString stringWithFormat:@"%d. swipe(%.0f,%.0f → %.0f,%.0f)", step, xpx, ypx, x2 / kx, y2 / ky]];
            sleep(2);
        } else if ([action isEqualToString:@"open_app"]) {
            NSString *name = [act[@"name"] description] ?: @"";
            NSString *info = nil;
            NSString *bid = bundleForAppName(name, &info);
            if (isBlockedApp(name, nil) || (bid && isBlockedApp(agAppName(bid), bid))) {
                result = [NSString stringWithFormat:@"「%@」在用户设置的禁止进入的 App 列表里,不能打开。请换别的方式完成,或用 ask_user/stop 说明。", name];
            } else if (bid && openApp(bid)) { result = @"已打开"; gLastApp = bid; expRecord(@{@"a": @"open_app", @"name": name}); }
            else {
                result = info ?: @"打开失败";
                NSString *ln = nil;
                BOOL inLib = enterAppLibrary(&ln);
                result = [result stringByAppendingFormat:@"\n程序已自动尝试进入 App 资源库:%@。%@", ln ?: @"", inLib ? @"请点击顶部搜索框,用 input_text 输入 App 名称搜索,再点搜索结果打开。" : @"如果仍不在资源库界面,请用 home 动作回主屏幕后再试,或 stop。"];
            }
            [history addObject:[NSString stringWithFormat:@"%d. open_app(%@) → %@", step, name, result]];
            sleep(3);
        } else if ([action isEqualToString:@"input_text"] || [action isEqualToString:@"set_clipboard"]) {
            BOOL typing = [action isEqualToString:@"input_text"];
            NSString *text = [act[@"text"] description] ?: @"";
            NSString *hintBid = nil;
            NSString *appHint = [act[@"app"] description];
            if (appHint.length) { NSString *i2 = nil; hintBid = bundleForAppName(appHint, &i2); }
            NSString *note = nil;
            if (typing) {
                BOOL ok = agPasteText(text, x, y, hintBid, &note);
                if (!ok) {
                    [history addObject:[NSString stringWithFormat:@"%d. input_text 失败:%@", step, note]];
                    agentSay([@"提示:输入失败:" stringByAppendingString:note ?: @"?"]);
                    sleep(1);
                    continue;
                }
                result = note.length ? [NSString stringWithFormat:@"已尝试粘贴,但%@;请看下一张截图确认输入框里有没有文字,没有就再用 input_text", note]
                                     : @"已把文字粘贴进输入框(键盘快捷键或粘贴菜单),请看下一张截图确认";
                [history addObject:[NSString stringWithFormat:@"%d. input_text(%@,%@)", step, usedID ? [NSString stringWithFormat:@"id=%ld", (long)oid] : [NSString stringWithFormat:@"%.0f,%.0f", xpx, ypx], text]];
                expRecord(@{@"a": @"input_text", @"text": text, @"t": usedID ? idText : ([act[@"target"] description] ?: @""), @"x": @(x), @"y": @(y), @"anchors": localOK ? expAnchors(items) : @[]});
                sleep(1);
            } else {
                BOOL stranded = NO;
                BOOL ok = writeClipboardInForeground(text, hintBid, &note, &stranded);
                if (!ok) {
                    [history addObject:[NSString stringWithFormat:@"%d. set_clipboard 失败:%@", step, note]];
                    agentSay([@"提示:" stringByAppendingString:note ?: @"剪贴板写入失败"]);
                    sleep(1);
                    continue;
                }
                if (stranded) {
                    [history addObject:[NSString stringWithFormat:@"%d. set_clipboard 已写入剪贴板,但没能回到原来的 App", step]];
                    agentSay(@"提示:剪贴板已写入,但没能自动回到原来的 App,请用 open_app 回到目标 App");
                    continue;
                }
                [history addObject:[NSString stringWithFormat:@"%d. set_clipboard(%@) 已确认", step, text]];
            }
        } else if ([action isEqualToString:@"home"]) {
            NSString *hn = nil;
            BOOL hok = goHome(&hn);
            result = hok ? @"已回到主屏幕" : [@"回主屏幕可能失败:" stringByAppendingString:hn ?: @""];
            [history addObject:[NSString stringWithFormat:@"%d. home → %@", step, result]];
            expRecord(@{@"a": @"home"});
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

// 对外的入口:开始/收尾都在这里处理,中间走原来的逻辑
static void agentRun(NSString *task, NSString *base, NSString *key, NSString *model) {
    taskRunBegin(task);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL autoCast = [ud objectForKey:@"auto_cast"] ? [ud boolForKey:@"auto_cast"] : YES;
    BOOL proceed = YES;
    if (autoCast && !broadcastAlive()) {
        agentSay(@"屏幕录制没开,正在自动开启……");
        NSString *n = nil;
        if (ensureBroadcast(&n)) agentSay(@"屏幕录制已自动开启");
        else { agentSay([NSString stringWithFormat:@"任务停止:自动开启屏幕录制失败(%@),请手动开启屏幕广播后再开始", n ?: @""]); proceed = NO; }
    }
    if (proceed && gAgentRunning) agentRunCore(task, base, key, model);
    taskRunEnd(task, autoCast);
}

#pragma mark - 界面

// ---- 语音朗读(系统自带的语音合成,中文) ----
@interface PATTS : NSObject <AVSpeechSynthesizerDelegate>
+ (instancetype)shared;
- (void)speak:(NSString *)text;
- (void)stop;
@property (nonatomic, readonly) BOOL speaking;
@end

@implementation PATTS {
    AVSpeechSynthesizer *_syn;
}
+ (instancetype)shared {
    static PATTS *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PATTS new]; s->_syn = [AVSpeechSynthesizer new]; s->_syn.delegate = s; });
    return s;
}
- (BOOL)speaking { return _syn.isSpeaking; }
- (void)speak:(NSString *)text {
    [self stop];
    NSString *t = text.length > 1500 ? [text substringToIndex:1500] : text;
    if (!t.length) return;
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:t];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    [_syn speakUtterance:u];
}
- (void)stop { if (_syn.isSpeaking) [_syn stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.ttsDone" object:nil];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u {
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.ttsDone" object:nil];
}
@end

// ---- 语音输入(在 App 里按麦克风按钮;识别由系统的语音识别完成) ----
@interface PAVoice : NSObject
@property (nonatomic, copy) void (^onText)(NSString *text);
@property (nonatomic, copy) void (^onState)(BOOL listening, NSString *msg);
@property (nonatomic, readonly) BOOL listening;
- (void)toggle;
- (void)stop;
@end

@implementation PAVoice {
    AVAudioEngine *_engine;
    SFSpeechRecognizer *_rec;
    SFSpeechAudioBufferRecognitionRequest *_req;
    SFSpeechRecognitionTask *_task;
    BOOL _listening;
}
- (BOOL)listening { return _listening; }
- (void)notify:(BOOL)on msg:(NSString *)m { if (self.onState) self.onState(on, m); }
- (void)toggle { if (_listening) [self stop]; else [self requestAndStart]; }
- (void)requestAndStart {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [self notify:NO msg:@"没有语音识别权限:请在 设置 → PhoneAgent 里打开“语音识别”"];
                return;
            }
            [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { [self notify:NO msg:@"没有麦克风权限:请在 设置 → PhoneAgent 里打开“麦克风”"]; return; }
                    [self begin];
                });
            }];
        });
    }];
}
- (void)begin {
    _rec = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
    if (!_rec || !_rec.isAvailable) { [self notify:NO msg:@"语音识别暂时不可用(需要联网)"]; return; }
    NSError *e = nil;
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
           options:(AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionAllowBluetooth)
             error:&e];
    [s setActive:YES error:&e];
    _engine = [AVAudioEngine new];
    _req = [SFSpeechAudioBufferRecognitionRequest new];
    _req.shouldReportPartialResults = YES;
    SFSpeechAudioBufferRecognitionRequest *req = _req;
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) { [req appendAudioPCMBuffer:buf]; }];
    [_engine prepare];
    if (![_engine startAndReturnError:&e]) {
        [self notify:NO msg:[NSString stringWithFormat:@"无法启动录音:%@", e.localizedDescription]];
        [self teardown];
        return;
    }
    _listening = YES;
    [self notify:YES msg:@"正在听……说完再点一次结束"];
    __weak PAVoice *w = self;
    _task = [_rec recognitionTaskWithRequest:_req resultHandler:^(SFSpeechRecognitionResult *r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PAVoice *me = w;
            if (!me) return;
            if (r && me.onText) me.onText(r.bestTranscription.formattedString);
            if (err || r.isFinal) { [me stop]; [me finishTask]; }
        });
    }];
}
- (void)teardown {
    if (_engine.isRunning) [_engine stop];
    [_engine.inputNode removeTapOnBus:0];
    _engine = nil;
}
- (void)stop {
    if (!_listening) return;
    _listening = NO;
    [_req endAudio];
    [self teardown];
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [s setActive:YES error:nil];
    resumeKeepAlive();
    [self notify:NO msg:@"语音输入结束"];
}
- (void)finishTask { [_task cancel]; _task = nil; _req = nil; }
@end

// ---- 结果窗口:可以选中文字、一键复制 ----
@interface ResultVC : UIViewController
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIBarButtonItem *speakItem;
@end
@implementation ResultVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"任务结果";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO; tv.selectable = YES; tv.alwaysBounceVertical = YES;
    tv.font = [UIFont systemFontOfSize:16];
    tv.textContainerInset = UIEdgeInsetsMake(14, 12, 14, 12);
    tv.text = self.text;
    [self.view addSubview:tv];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithTitle:@"复制全部" style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)];
    self.speakItem = [[UIBarButtonItem alloc] initWithTitle:[PATTS shared].speaking ? @"停止" : @"朗读" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSpeak)];
    self.navigationItem.rightBarButtonItems = @[copyItem, self.speakItem];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ttsDone) name:@"pa.ttsDone" object:nil];
}
- (void)toggleSpeak {
    if ([PATTS shared].speaking) { [[PATTS shared] stop]; self.speakItem.title = @"朗读"; }
    else { [[PATTS shared] speak:gLastSpeechText.length ? gLastSpeechText : self.text]; self.speakItem.title = @"停止"; }
}
- (void)ttsDone { dispatch_async(dispatch_get_main_queue(), ^{ self.speakItem.title = @"朗读"; }); }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)close { [[PATTS shared] stop]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyAll {
    UIPasteboard.generalPasteboard.string = self.text;
    self.navigationItem.rightBarButtonItem.title = @"已复制";
}
@end

// ---- 记忆窗口:可以自己增删改,也可以让它任务后自动记 ----
@interface MemoryVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UISwitch *sw;
@end
@implementation MemoryVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记忆";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *hint = [UILabel new];
    hint.numberOfLines = 0; hint.font = [UIFont systemFontOfSize:13]; hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"每行一条,可以手动增删改。执行任务时会作为偏好提供给模型,例如:“买东西优先选京东”“我的收货地址默认用公司”“回答请简短”。请不要写密码、银行卡号等敏感信息。";
    UILabel *swl = [UILabel new]; swl.text = @"任务结束后自动记住新的偏好";
    swl.font = [UIFont systemFontOfSize:15];
    self.sw = [UISwitch new];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.sw.on = [d objectForKey:@"memory_auto"] ? [d boolForKey:@"memory_auto"] : YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[swl, self.sw]];
    row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionEqualSpacing;
    self.tv = [UITextView new];
    self.tv.font = [UIFont systemFontOfSize:16];
    self.tv.layer.borderWidth = 1; self.tv.layer.borderColor = UIColor.separatorColor.CGColor; self.tv.layer.cornerRadius = 8;
    self.tv.text = memoryText();
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[hint, row, self.tv]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [st.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [st.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12]]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:self.tv.text ?: @"" forKey:@"memory_text"];
    [d setBool:self.sw.on forKey:@"memory_auto"];
}
- (void)done { [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clearAll { self.tv.text = @""; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self save]; }
@end

// ---- 安全设置:敏感操作确认、禁止进入的 App ----
@interface SafetyVC : UIViewController
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UITextView *wordsTV, *appsTV;
@end
@implementation SafetyVC
- (UILabel *)lab:(NSString *)t small:(BOOL)small {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0; l.text = t;
    l.font = [UIFont systemFontOfSize:small ? 13 : 15 weight:small ? UIFontWeightRegular : UIFontWeightSemibold];
    l.textColor = small ? UIColor.secondaryLabelColor : UIColor.labelColor;
    return l;
}
- (UITextView *)box:(NSString *)text {
    UITextView *tv = [UITextView new];
    tv.font = [UIFont systemFontOfSize:16]; tv.text = text;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone; tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.layer.borderWidth = 1; tv.layer.borderColor = UIColor.separatorColor.CGColor; tv.layer.cornerRadius = 8;
    [tv.heightAnchor constraintEqualToConstant:140].active = YES;
    return tv;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"安全设置";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *swl = [self lab:@"敏感操作前先问我" small:NO];
    self.sw = [UISwitch new]; self.sw.on = confirmEnabled();
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[swl, self.sw]];
    row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionEqualSpacing; row.alignment = UIStackViewAlignmentCenter;
    UILabel *h1 = [self lab:@"开启后,点击“发送/发布/提交/删除”等按钮前会先弹出确认,同时发通知(可以直接在通知里点“允许/拒绝”,不用离开当前 App)并语音提醒。付款、转账、输入支付密码永远不会自动执行,只会请你本人完成,不受这个开关影响。" small:YES];
    self.wordsTV = [self box:[NSUserDefaults.standardUserDefaults stringForKey:@"sens_words"] ?: defaultSensitiveWords()];
    UILabel *h2 = [self lab:@"禁止进入的 App 名称或包名里含有下面任一词,就不会被打开;如果误入了会自动退回主屏幕。" small:YES];
    self.appsTV = [self box:[NSUserDefaults.standardUserDefaults stringForKey:@"blocked_apps"] ?: defaultBlockedApps()];
    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    [rb setTitle:@"恢复默认列表" forState:UIControlStateNormal];
    [rb addTarget:self action:@selector(restore) forControlEvents:UIControlEventTouchUpInside];
    UIButton *tb = [UIButton buttonWithType:UIButtonTypeSystem];
    [tb setTitle:@"测试提醒(点后 5 秒内切到别的 App 看看)" forState:UIControlStateNormal];
    [tb addTarget:self action:@selector(onTest) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[row, h1,
        [self lab:@"敏感词(每行一个;要点击的按钮名或它附近的文字含有这些词,就先确认)" small:NO], self.wordsTV,
        [self lab:@"禁止进入的 App(每行一个)" small:NO], h2, self.appsTV, rb, tb]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:sv]; [sv addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:g.topAnchor], [sv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-16]]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:self.sw.on forKey:@"confirm_on"];
    [d setObject:self.wordsTV.text ?: @"" forKey:@"sens_words"];
    [d setObject:self.appsTV.text ?: @"" forKey:@"blocked_apps"];
}
- (void)done { [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)restore { self.wordsTV.text = defaultSensitiveWords(); self.appsTV.text = defaultBlockedApps(); }
- (void)onTest {
    testReminder();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"测试提醒" message:@"5 秒后会同时发出通知和系统弹窗。请现在回到主屏幕或切到别的 App(比如微信)等着;结果会写在 PhoneAgent 的日志里。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self save]; }
@end

// ---- 经验库:查看、删除、开关 ----
@interface ExpVC : UITableViewController
@property (nonatomic, strong) NSMutableArray *items;
@end
@implementation ExpVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"经验库";
    self.items = expLoad();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clearAll {
    if (!self.items.count) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空经验库" message:@"确定删除所有已保存的经验?" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.items removeAllObjects]; expSave(self.items); [self.tableView reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : MAX((NSInteger)self.items.count, 1); }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"设置" : [NSString stringWithFormat:@"已保存的经验(%lu)", (unsigned long)self.items.count];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 0 ? @"任务成功完成后自动记录步骤。相似的任务会把过往经验作为参考提示给模型;几乎相同的任务会先快速回放(每一步都核对屏幕、用屏幕上的文字重新定位按钮,对不上就中止并交给模型)。多次回放失败的经验会自动淘汰。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = ip.row == 0 ? @"记录并参考经验" : @"相同任务先快速回放";
        UISwitch *sw = [UISwitch new];
        sw.tag = ip.row;
        sw.on = ip.row == 0 ? expEnabled() : expReplayEnabled();
        [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"exp"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"exp"];
    if (!self.items.count) {
        c.textLabel.text = @"还没有经验。任务成功完成后会自动记录。";
        c.textLabel.textColor = UIColor.secondaryLabelColor; c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    NSDictionary *e = self.items[self.items.count - 1 - ip.row]; // 新的在前
    c.textLabel.text = e[@"task"]; c.textLabel.numberOfLines = 2; c.textLabel.textColor = UIColor.labelColor;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%lu 步 · 成功 %d 次 · 失败 %d 次 · 回放 %d 次",
                              (unsigned long)[e[@"steps"] count], [e[@"ok"] intValue], [e[@"fail"] intValue], [e[@"used"] intValue]];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)onSwitch:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:sw.tag == 0 ? @"exp_on" : @"exp_replay_on"]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1 || !self.items.count) return;
    NSUInteger idx = self.items.count - 1 - ip.row;
    NSDictionary *e = self.items[idx];
    NSMutableString *m = [NSMutableString string];
    NSArray *steps = e[@"steps"];
    for (NSUInteger i = 0; i < steps.count; i++) [m appendFormat:@"%lu. %@\n", (unsigned long)i + 1, expStepDesc(steps[i])];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:e[@"task"] message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除这条" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.items removeObjectAtIndex:idx]; expSave(self.items); [self.tableView reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1 && self.items.count > 0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || !self.items.count) return;
    [self.items removeObjectAtIndex:self.items.count - 1 - ip.row];
    expSave(self.items);
    [tv reloadData];
}
@end

// ---- 主界面 ----
static NSData *attachJPEG(UIImage *img) {
    CGSize sz = img.size;
    CGFloat k = MIN(1.0, 1600.0 / MAX(sz.width, sz.height));
    CGSize ns = CGSizeMake(floor(sz.width * k), floor(sz.height * k));
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIImage *out = [[[UIGraphicsImageRenderer alloc] initWithSize:ns format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
    return UIImageJPEGRepresentation(out, 0.85);
}

@interface VC : UIViewController <UITextViewDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIButton *provBtn, *micBtn;
@property (nonatomic, strong) UITextField *keyF, *baseF, *modelF;
@property (nonatomic, strong) UITextView *taskTV;
@property (nonatomic, strong) UILabel *phLabel, *attLabel, *log;
@property (nonatomic, strong) PAVoice *voice;
@property (nonatomic, copy) NSString *voiceBase;
@property (nonatomic, strong) UIView *closingView, *guardView;
@property (nonatomic, strong) UIAlertController *reqAlert;
@end

@implementation VC
- (UIButton *)btn:(NSString *)title action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UITextField *)tf:(NSString *)ph secure:(BOOL)sec {
    UITextField *f = [UITextField new];
    f.placeholder = ph;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.secureTextEntry = sec;
    return f;
}
- (UIStackView *)row:(NSArray *)views {
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:views];
    r.axis = UILayoutConstraintAxisHorizontal; r.distribution = UIStackViewDistributionFillEqually; r.spacing = 8;
    return r;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    __weak VC *wself = self;

    // 模型选择 + 各自的 API 设置
    self.provBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.provBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.provBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    UIButton *addBtn = [self btn:@"＋添加" action:@selector(onAddProvider)];
    UIButton *delBtn = [self btn:@"删除" action:@selector(onDeleteProvider)];
    [delBtn setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [addBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [delBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.provBtn setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *provRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.provBtn, addBtn, delBtn]];
    provRow.axis = UILayoutConstraintAxisHorizontal; provRow.spacing = 16; provRow.alignment = UIStackViewAlignmentCenter;
    self.keyF = [self tf:@"API Key" secure:YES];
    self.baseF = [self tf:@"接口地址" secure:NO];
    self.modelF = [self tf:@"模型名" secure:NO];

    // 任务输入:多行文字 + 语音 + 附件
    self.taskTV = [UITextView new];
    self.taskTV.font = [UIFont systemFontOfSize:16];
    self.taskTV.layer.borderWidth = 1; self.taskTV.layer.borderColor = UIColor.separatorColor.CGColor; self.taskTV.layer.cornerRadius = 8;
    self.taskTV.delegate = self;
    self.taskTV.text = @"";
    self.phLabel = [UILabel new];
    self.phLabel.text = @"输入任务,例如:打开淘宝,搜索保温杯,加入购物车。也可以点下面的麦克风说,或附上图片/文件让模型处理。";
    self.phLabel.numberOfLines = 0; self.phLabel.font = [UIFont systemFontOfSize:15]; self.phLabel.textColor = UIColor.placeholderTextColor;
    self.phLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.taskTV addSubview:self.phLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.phLabel.topAnchor constraintEqualToAnchor:self.taskTV.topAnchor constant:8],
        [self.phLabel.leadingAnchor constraintEqualToAnchor:self.taskTV.leadingAnchor constant:8],
        [self.phLabel.widthAnchor constraintEqualToAnchor:self.taskTV.widthAnchor constant:-16],
        [self.taskTV.heightAnchor constraintEqualToConstant:120]]];
    self.micBtn = [self btn:@"🎤 语音输入" action:@selector(onMic)];
    UIButton *attBtn = [self btn:@"📎 图片/文件" action:@selector(onAttach)];
    self.attLabel = [UILabel new];
    self.attLabel.numberOfLines = 0; self.attLabel.font = [UIFont systemFontOfSize:13]; self.attLabel.textColor = UIColor.secondaryLabelColor;
    self.attLabel.hidden = YES;

    UIButton *startBtn = [self btn:@"开始任务" action:@selector(onStart)];
    UIButton *stopBtn = [self btn:@"停止任务" action:@selector(onStop)];
    UIButton *memBtn = [self btn:@"记忆" action:@selector(onMemory)];
    UIButton *resBtn = [self btn:@"上次结果" action:@selector(onLastResult)];
    UIButton *safeBtn = [self btn:@"安全设置" action:@selector(onSafety)];
    UIButton *expBtn = [self btn:@"经验库" action:@selector(onExp)];
    UIButton *keepBtn = [self btn:@"后台保活 开/关" action:@selector(onKeep)];
    UIButton *diagBtn = [self btn:@"诊断" action:@selector(onDiag)];

    // 屏幕广播(截屏必需)
    UILabel *bl = [UILabel new];
    bl.numberOfLines = 0; bl.font = [UIFont systemFontOfSize:14];
    bl.text = @"屏幕广播(截屏必需):点右边按钮 → 选 PhoneAgent → 开始直播";
    RPSystemBroadcastPickerView *pv = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    pv.preferredExtension = @"com.example.phoneagent.broadcast";
    pv.showsMicrophoneButton = NO;
    [pv.widthAnchor constraintEqualToConstant:56].active = YES;
    [pv.heightAnchor constraintEqualToConstant:56].active = YES;
    gPicker = pv;
    UILabel *acl = [UILabel new];
    acl.text = @"任务时自动开启/关闭屏幕录制"; acl.font = [UIFont systemFontOfSize:15]; acl.numberOfLines = 0;
    UISwitch *acs = [UISwitch new];
    NSUserDefaults *ud0 = NSUserDefaults.standardUserDefaults;
    acs.on = [ud0 objectForKey:@"auto_cast"] ? [ud0 boolForKey:@"auto_cast"] : YES;
    [acs addTarget:self action:@selector(onAutoCast:) forControlEvents:UIControlEventValueChanged];
    UIStackView *acrow = [[UIStackView alloc] initWithArrangedSubviews:@[acl, acs]];
    acrow.axis = UILayoutConstraintAxisHorizontal; acrow.alignment = UIStackViewAlignmentCenter;
    acrow.distribution = UIStackViewDistributionEqualSpacing;
    UILabel *ttl = [UILabel new];
    ttl.text = @"任务结果自动语音朗读"; ttl.font = [UIFont systemFontOfSize:15]; ttl.numberOfLines = 0;
    UISwitch *tts = [UISwitch new];
    tts.on = [ud0 objectForKey:@"tts_on"] ? [ud0 boolForKey:@"tts_on"] : YES;
    [tts addTarget:self action:@selector(onTTS:) forControlEvents:UIControlEventValueChanged];
    UIStackView *ttsrow = [[UIStackView alloc] initWithArrangedSubviews:@[ttl, tts]];
    ttsrow.axis = UILayoutConstraintAxisHorizontal; ttsrow.alignment = UIStackViewAlignmentCenter;
    ttsrow.distribution = UIStackViewDistributionEqualSpacing;
    UIStackView *brow = [[UIStackView alloc] initWithArrangedSubviews:@[bl, pv]];
    brow.axis = UILayoutConstraintAxisHorizontal; brow.spacing = 10; brow.alignment = UIStackViewAlignmentCenter;

    UILabel *tokenL = [UILabel new];
    tokenL.font = [UIFont systemFontOfSize:12]; tokenL.textColor = UIColor.tertiaryLabelColor;
    tokenL.text = [NSString stringWithFormat:@"快捷指令 token:%@", gToken];
    self.log = [UILabel new];
    self.log.numberOfLines = 0;
    self.log.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        provRow, self.keyF, self.baseF, self.modelF,
        self.taskTV, [self row:@[self.micBtn, attBtn]], self.attLabel,
        [self row:@[startBtn, stopBtn]], [self row:@[memBtn, safeBtn]], [self row:@[expBtn, resBtn]],
        acrow, ttsrow, brow, [self row:@[keepBtn, diagBtn]], tokenL, self.log]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
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

    // 通知:日志、结果窗口
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.say" object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { [wself say:[n.object description]]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.request" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself presentPendingRequest]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.requestDone" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself dismissRequestAlert]; [[PATTS shared] stop]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself presentPendingRequest]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.speak" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
        if (!([u objectForKey:@"tts_on"] && ![u boolForKey:@"tts_on"])) [[PATTS shared] speak:[n.object description]];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.guard" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself setGuardOverlay:[n.object boolValue]]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.closing" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself setClosingOverlay:[n.object boolValue]]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.showResult" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        [wself showResult:[n.object description]];
        NSUserDefaults *ud1 = NSUserDefaults.standardUserDefaults;
        if (!([ud1 objectForKey:@"tts_on"] && ![ud1 boolForKey:@"tts_on"])) [[PATTS shared] speak:gLastSpeechText];
    }];

    // 语音输入
    self.voice = [PAVoice new];
    self.voice.onText = ^(NSString *text) {
        wself.taskTV.text = [(wself.voiceBase ?: @"") stringByAppendingString:text ?: @""];
        wself.phLabel.hidden = wself.taskTV.text.length > 0;
    };
    self.voice.onState = ^(BOOL listening, NSString *msg) {
        [wself.micBtn setTitle:listening ? @"⏹ 点击结束" : @"🎤 语音输入" forState:UIControlStateNormal];
        if (msg.length && !listening) [wself say:msg];
    };

    [self loadFields];
    [self buildProviderMenu];
    [self refreshAttachLabel];

    NSString *e1 = loadHID();
    if (e1) [self say:[@"触摸初始化失败: " stringByAppendingString:e1]];
    NSString *e2 = loadShot();
    if (e2) [self say:[@"截屏初始化失败: " stringByAppendingString:e2]];
    NSString *e3 = startServer();
    if (e3) [self say:[@"本地服务启动失败: " stringByAppendingString:e3]];
    setKeepAlive(YES);
}

// ---- 提供商 / 设置 ----
- (void)saveFields {
    NSString *pid = selectedProviderID();
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    [d setObject:[self.keyF.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:[NSString stringWithFormat:@"p_%@_key", pid]];
    [d setObject:[self.baseF.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:[NSString stringWithFormat:@"p_%@_base", pid]];
    [d setObject:[self.modelF.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:[NSString stringWithFormat:@"p_%@_model", pid]];
}
- (void)loadFields {
    NSString *pid = selectedProviderID();
    self.keyF.text = provValue(pid, @"key");
    self.baseF.text = provValue(pid, @"base");
    self.modelF.text = provValue(pid, @"model");
    self.baseF.placeholder = [providerDefault(pid, @"base") length] ? providerDefault(pid, @"base") : @"接口地址(OpenAI 兼容,例如 https://xxx/v1)";
    self.modelF.placeholder = [providerDefault(pid, @"model") length] ? providerDefault(pid, @"model") : @"模型名";
}
- (void)buildProviderMenu {
    NSString *cur = selectedProviderID();
    NSMutableArray *acts = [NSMutableArray array];
    NSString *curName = @"DeepSeek";
    __weak VC *wself = self;
    for (NSDictionary *p in providerList()) {
        NSString *pid = p[@"id"];
        UIAction *a = [UIAction actionWithTitle:p[@"name"] image:nil identifier:nil handler:^(UIAction *act) { [wself switchProvider:pid]; }];
        if ([pid isEqualToString:cur]) { a.state = UIMenuElementStateOn; curName = p[@"name"]; }
        [acts addObject:a];
    }
    self.provBtn.menu = [UIMenu menuWithTitle:@"选择模型" children:acts];
    self.provBtn.showsMenuAsPrimaryAction = YES;
    [self.provBtn setTitle:[NSString stringWithFormat:@"模型:%@  ▾", curName] forState:UIControlStateNormal];
}
- (void)onAddProvider {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"添加自定义模型"
        message:@"接口需要兼容 OpenAI 的 /chat/completions。接口地址和模型名以后可以在界面里再改。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"名称,例如:通义千问"; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"接口地址,例如 https://xxx/v1";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone; tf.autocorrectionType = UITextAutocorrectionTypeNo; tf.keyboardType = UIKeyboardTypeURL;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"模型名";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone; tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *wac = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        NSString *name = [wac.textFields[0].text stringByTrimmingCharactersInSet:ws];
        NSString *base = [wac.textFields[1].text stringByTrimmingCharactersInSet:ws];
        NSString *model = [wac.textFields[2].text stringByTrimmingCharactersInSet:ws];
        if (!name.length) name = @"自定义模型";
        [self saveFields];
        NSMutableArray *list = [providerList() mutableCopy];
        NSString *pid = [NSString stringWithFormat:@"c%.0f", [NSDate date].timeIntervalSince1970 * 1000];
        [list addObject:@{@"id": pid, @"name": name, @"base": base ?: @"", @"model": model ?: @""}];
        saveProviders(list);
        [NSUserDefaults.standardUserDefaults setObject:pid forKey:@"provider"];
        [self loadFields];
        [self buildProviderMenu];
        [self say:[NSString stringWithFormat:@"已添加模型“%@”,请填写它的 API Key", name]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)onDeleteProvider {
    NSMutableArray *list = [providerList() mutableCopy];
    if (list.count <= 1) { [self say:@"至少要保留一个模型"]; return; }
    NSString *pid = selectedProviderID(), *name = pid;
    for (NSDictionary *p in list) if ([p[@"id"] isEqualToString:pid]) name = p[@"name"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除模型"
        message:[NSString stringWithFormat:@"删除“%@”?它保存的 API Key、接口地址和模型名也会一起删除。", name] preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSMutableArray *rest = [NSMutableArray array];
        for (NSDictionary *p in list) if (![p[@"id"] isEqualToString:pid]) [rest addObject:p];
        saveProviders(rest);
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        for (NSString *f in @[@"key", @"base", @"model"]) [d removeObjectForKey:[NSString stringWithFormat:@"p_%@_%@", pid, f]];
        [d setObject:rest.firstObject[@"id"] forKey:@"provider"];
        [self loadFields];
        [self buildProviderMenu];
        [self say:[NSString stringWithFormat:@"已删除模型“%@”", name]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)switchProvider:(NSString *)pid {
    [self saveFields];
    [NSUserDefaults.standardUserDefaults setObject:pid forKey:@"provider"];
    [self loadFields];
    [self buildProviderMenu];
}

// ---- 日志 / 结果 ----
- (void)say:(NSString *)m {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *t = [NSString stringWithFormat:@"%@\n%@", m, self.log.text ?: @""];
        if (t.length > 6000) t = [t substringToIndex:6000];
        self.log.text = t;
    });
}
// 任务结束、自动关闭录屏的几秒里盖一层遮罩,吞掉点击
// ---- 暂停 / 确认 请求的弹窗(App 在前台时);App 在后台时靠通知,用户点开通知或回到 App 时再弹 ----
- (void)presentPendingRequest {
    if (gReqState != PAReqWaiting || self.reqAlert) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    BOOL confirm = [gReqKind isEqualToString:@"confirm"];
    __weak VC *wself = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:confirm ? @"需要你确认" : @"任务已暂停"
        message:confirm ? gReqText : [gReqText stringByAppendingString:@"\n\n请先去处理(必要时回到对应的 App),处理完点“继续”。"]
        preferredStyle:UIAlertControllerStyleAlert];
    if (confirm) {
        [ac addAction:[UIAlertAction actionWithTitle:@"允许" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqAllow); wself.reqAlert = nil; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"允许,本次任务不再问" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqAllowAll); wself.reqAlert = nil; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"拒绝(跳过这一步)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqDeny); wself.reqAlert = nil; }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqAllow); wself.reqAlert = nil; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"停止任务" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { agentRespond(PAReqStop); wself.reqAlert = nil; }]];
    self.reqAlert = ac;
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}
- (void)dismissRequestAlert {
    if (self.reqAlert) { [self.reqAlert dismissViewControllerAnimated:YES completion:nil]; self.reqAlert = nil; }
}
- (void)onSafety {
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:[SafetyVC new]] animated:YES completion:nil];
}
- (void)onExp {
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:[ExpVC new]] animated:YES completion:nil];
}

// 自动开启录屏的盲点期间:透明的吞点击层(盖在 PhoneAgent 自己的界面上,系统面板在它上面)
- (void)setGuardOverlay:(BOOL)on {
    if (!on) { [self.guardView removeFromSuperview]; self.guardView = nil; return; }
    if (self.guardView) return;
    UIView *v = [[UIView alloc] initWithFrame:self.view.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.backgroundColor = UIColor.clearColor;
    v.userInteractionEnabled = YES;
    [self.view addSubview:v];
    self.guardView = v;
}
- (void)setClosingOverlay:(BOOL)on {
    if (!on) { [self.closingView removeFromSuperview]; self.closingView = nil; return; }
    if (self.closingView) return;
    UIWindow *w = self.view.window ?: UIApplication.sharedApplication.windows.firstObject;
    if (!w) return;
    UIView *v = [[UIView alloc] initWithFrame:w.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    v.userInteractionEnabled = YES;
    UILabel *l = [UILabel new];
    l.text = @"任务已结束,正在关闭屏幕录制……"; l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium]; l.textAlignment = NSTextAlignmentCenter;
    l.frame = CGRectMake(0, w.bounds.size.height * 0.3, w.bounds.size.width, 30);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    [w addSubview:v];
    self.closingView = v;
}
- (void)showResult:(NSString *)text {
    gLastResultText = text;
    void (^present)(void) = ^{
        ResultVC *r = [ResultVC new];
        r.text = text;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:r];
        [self presentViewController:nav animated:YES completion:nil];
    };
    if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:present];
    else present();
}
- (void)onLastResult {
    if (!gLastResultText.length) { [self say:@"还没有任务结果"]; return; }
    [self showResult:gLastResultText];
}
- (void)onMemory {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[MemoryVC new]];
    [self presentViewController:nav animated:YES completion:nil];
}

// ---- 开始 / 停止 ----
- (void)onStart {
    [self.view endEditing:YES];
    [self saveFields];
    if (self.voice.listening) [self.voice stop];
    [[PATTS shared] stop];
    if (gAgentRunning) { [self say:@"已有任务在运行"]; return; }
    NSString *key = nil, *base = nil, *model = nil;
    loadLLMConfig(&key, &base, &model);
    NSString *task = [self.taskTV.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!task.length) { [self say:@"请先输入任务(可以用麦克风说)"]; return; }
    if (!key.length) { [self say:@"请先填写当前所选模型的 API Key"]; return; }
    if (!base.length || !model.length) { [self say:@"接口地址和模型名都要填"]; return; }
    NSString *full = gAttachText.length ? [task stringByAppendingFormat:@"\n\n【用户附带的文件内容】\n%@", gAttachText] : task;
    gTaskDisplay = task;
    gRunImages = [gAttachImages copy];
    if (!gPlayer) setKeepAlive(YES);
    if (!broadcastAlive()) [self say:@"提醒:屏幕广播还没开,没有广播会截屏失败"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(full, base, key, model); });
}
- (void)onTTS:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"tts_on"]; if (!sw.on) [[PATTS shared] stop]; }
- (void)onAutoCast:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"auto_cast"]; }
- (void)onStop { gAgentRunning = NO; agentRespond(PAReqStop); [self say:@"正在停止任务……"]; }
- (void)onKeep { [self say:setKeepAlive(gPlayer == nil)]; }
- (void)onDiag { [self say:diagReport()]; }

// ---- 语音 ----
- (void)onMic {
    if (!self.voice.listening) self.voiceBase = self.taskTV.text.length ? [self.taskTV.text stringByAppendingString:@" "] : @"";
    [self.voice toggle];
}
- (void)textViewDidChange:(UITextView *)tv { self.phLabel.hidden = tv.text.length > 0; }

// ---- 附件(图片 / 文件) ----
- (void)refreshAttachLabel {
    NSUInteger ni = gAttachImages.count;
    BOOL hasText = gAttachText.length > 0;
    if (!ni && !hasText) { self.attLabel.hidden = YES; return; }
    self.attLabel.hidden = NO;
    self.attLabel.text = [NSString stringWithFormat:@"已附带:%@%@%@(随任务一起发给模型;点“图片/文件”可清除)",
                          ni ? [NSString stringWithFormat:@"%lu 张图片", (unsigned long)ni] : @"",
                          (ni && hasText) ? @"、" : @"",
                          hasText ? [NSString stringWithFormat:@"文件文字 %lu 字", (unsigned long)gAttachText.length] : @""];
}
- (void)onAttach {
    [self.view endEditing:YES];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"附件" message:@"图片会随任务发给模型(需要所选模型支持看图);文件会把文字内容放进任务里(支持 txt/md/csv/json/pdf 等文本类文件,也可以选图片文件)" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从相册选图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = 5;
        cfg.filter = [PHPickerFilter imagesFilter];
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pk.delegate = self;
        [self presentViewController:pk animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"选择文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
        dp.delegate = self;
        dp.allowsMultipleSelection = YES;
        [self presentViewController:dp animated:YES completion:nil];
    }]];
    if (gAttachImages.count || gAttachText.length) {
        [ac addAction:[UIAlertAction actionWithTitle:@"清除所有附件" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [gAttachImages removeAllObjects]; [gAttachNames removeAllObjects]; [gAttachText setString:@""];
            [self refreshAttachLabel];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *r in results) {
        if (![r.itemProvider canLoadObjectOfClass:UIImage.class]) continue;
        [r.itemProvider loadObjectOfClass:UIImage.class completionHandler:^(id obj, NSError *err) {
            if (![obj isKindOfClass:UIImage.class]) return;
            NSData *jpg = attachJPEG((UIImage *)obj);
            if (!jpg.length) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [gAttachImages addObject:jpg];
                [gAttachNames addObject:@"相册图片"];
                [self refreshAttachLabel];
            });
        }];
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSArray *imgExt = @[@"jpg", @"jpeg", @"png", @"heic", @"gif", @"bmp", @"tiff"];
    for (NSURL *url in urls) {
        NSString *ext = url.pathExtension.lowercaseString, *name = url.lastPathComponent;
        if ([imgExt containsObject:ext]) {
            UIImage *im = [UIImage imageWithContentsOfFile:url.path];
            NSData *jpg = im ? attachJPEG(im) : nil;
            if (jpg.length) { [gAttachImages addObject:jpg]; [gAttachNames addObject:name]; }
            else [self say:[NSString stringWithFormat:@"无法读取图片:%@", name]];
            continue;
        }
        NSString *text = nil;
        if ([ext isEqualToString:@"pdf"]) {
            PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
            text = doc.string;
            if (!text.length) { [self say:[NSString stringWithFormat:@"PDF 里没有可提取的文字(可能是扫描件,请改成图片附上):%@", name]]; continue; }
        } else {
            text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
            if (!text) {
                NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
                text = [NSString stringWithContentsOfURL:url encoding:gb error:nil];
            }
            if (!text) { [self say:[NSString stringWithFormat:@"暂不支持这种文件(docx、xlsx 等请先转成 txt 或 pdf):%@", name]]; continue; }
        }
        if (text.length > 30000) text = [[text substringToIndex:30000] stringByAppendingString:@"\n……(内容过长,已截断)"];
        [gAttachText appendFormat:@"--- 文件:%@ ---\n%@\n\n", name, text];
        [gAttachNames addObject:name];
    }
    if (gAttachText.length > 80000) [gAttachText setString:[gAttachText substringToIndex:80000]];
    [self refreshAttachLabel];
}
@end

@interface AD : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
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
    if ([cmd isEqualToString:@"resume"] || [cmd isEqualToString:@"allow"]) { agentRespond(PAReqAllow); return YES; }
    if ([cmd isEqualToString:@"allowall"]) { agentRespond(PAReqAllowAll); return YES; }
    if ([cmd isEqualToString:@"deny"]) { agentRespond(PAReqDeny); return YES; }
    if ([cmd isEqualToString:@"stop"]) { gAgentRunning = NO; agentRespond(PAReqStop); return YES; }
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
    NSString *key = nil, *base = nil, *model = nil; loadLLMConfig(&key, &base, &model);
    NSString *say = nil;
    if (!task.length) say = @"收到语音任务,但文字是空的(听写可能没识别到内容,或快捷指令里的变量没接对,看上面“收到 URL”那行)";
    else if (!key.length || !base.length || !model.length) say = @"收到语音任务,但还没保存 API 设置:请先在 App 里点一次“开始任务”或“看图测试”";
    else if (gAgentRunning) say = @"收到语音任务,但已有任务在运行";
    if (say) { [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:say]; return YES; }
    agentSay([NSString stringWithFormat:@"收到语音任务:%@", task]);
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"收到语音任务:%@", task]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUserDefaults *u2 = NSUserDefaults.standardUserDefaults;
        BOOL autoCast = [u2 objectForKey:@"auto_cast"] ? [u2 boolForKey:@"auto_cast"] : YES;
        if (!autoCast) { // 没打开“自动开启录屏”才需要现成的广播;冷启动后扩展要重新连上,最多等 6 秒
            for (int i = 0; i < 30 && !broadcastAlive(); i++) usleep(200 * 1000);
            if (!broadcastAlive()) {
                [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"屏幕广播没开,任务未执行:请先开启屏幕广播,或打开界面里“任务时自动开启/关闭屏幕录制”的开关"];
                return;
            }
        }
        if (gAgentRunning) return;
        gRunImages = nil; gTaskDisplay = task;
        agentRun(task, base, key, model); // 开关打开时,agentRun 会自己检查录屏并自动开启
    });
    return YES;
}

// 通知(带按钮):暂停/确认请求时发出,用户可以不离开当前 App,直接在通知里点“继续/允许/拒绝/停止”
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *a = response.actionIdentifier;
    if ([a isEqualToString:@"allow"] || [a isEqualToString:@"resume"]) agentRespond(PAReqAllow);
    else if ([a isEqualToString:@"allowall"]) agentRespond(PAReqAllowAll);
    else if ([a isEqualToString:@"deny"]) agentRespond(PAReqDeny);
    else if ([a isEqualToString:@"stop"]) agentRespond(PAReqStop);
    completionHandler(); // 点通知本身只是打开 App,界面里会弹出对应的确认框
}

- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    signal(SIGPIPE, SIG_IGN);
    gLock = [NSObject new];
    gAgentLog = [NSMutableArray array];
    gRunLog = [NSMutableArray array];
    gAttachImages = [NSMutableArray array];
    gAttachNames = [NSMutableArray array];
    gAttachText = [NSMutableString string];
    gExpSteps = [NSMutableArray array];
    {   // 通知:注册带按钮的类别并请求权限
        UNUserNotificationCenter *nc = UNUserNotificationCenter.currentNotificationCenter;
        nc.delegate = self;
        UNNotificationAction *aOK = [UNNotificationAction actionWithIdentifier:@"allow" title:@"允许" options:UNNotificationActionOptionNone];
        UNNotificationAction *aAll = [UNNotificationAction actionWithIdentifier:@"allowall" title:@"允许,本次任务不再问" options:UNNotificationActionOptionNone];
        UNNotificationAction *aNo = [UNNotificationAction actionWithIdentifier:@"deny" title:@"拒绝(跳过这一步)" options:UNNotificationActionOptionDestructive];
        UNNotificationAction *aStop = [UNNotificationAction actionWithIdentifier:@"stop" title:@"停止任务" options:UNNotificationActionOptionDestructive];
        UNNotificationAction *aCont = [UNNotificationAction actionWithIdentifier:@"resume" title:@"继续" options:UNNotificationActionOptionNone];
        UNNotificationCategory *cConfirm = [UNNotificationCategory categoryWithIdentifier:@"PA_CONFIRM" actions:@[aOK, aAll, aNo, aStop] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
        UNNotificationCategory *cPause = [UNNotificationCategory categoryWithIdentifier:@"PA_PAUSE" actions:@[aCont, aStop] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
        [nc setNotificationCategories:[NSSet setWithObjects:cConfirm, cPause, nil]];
        [nc requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *err) {}];
    }
    {   // 旧版本只有一套 API 设置:迁移到对应的提供商名下
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if (![d boolForKey:@"migrated_v7"]) {
            NSString *k = [d stringForKey:@"llm_key"], *b = [d stringForKey:@"llm_base"], *m = [d stringForKey:@"llm_model"] ?: [d stringForKey:@"llm_model2"];
            if (k.length) {
                NSString *lm = m.lowercaseString, *pid = @"deepseek";
                if ([lm containsString:@"autoglm"]) pid = @"autoglm";
                else if ([lm hasPrefix:@"glm"]) pid = @"glm";
                else if (b.length && ![b.lowercaseString containsString:@"deepseek"]) pid = @"custom";
                [d setObject:k forKey:[NSString stringWithFormat:@"p_%@_key", pid]];
                if (b.length) [d setObject:b forKey:[NSString stringWithFormat:@"p_%@_base", pid]];
                if (m.length) [d setObject:m forKey:[NSString stringWithFormat:@"p_%@_model", pid]];
                [d setObject:pid forKey:@"provider"];
            }
            [d setBool:YES forKey:@"migrated_v7"];
        }
    }
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
