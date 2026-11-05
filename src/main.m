// PhoneAgent v0.2
// 在 v0.1(点击/滑动)基础上增加:截屏、Vision OCR、本地 HTTP 接口(127.0.0.1:8200)、后台保活。
// 注意:截屏用的是私有接口,未经真机测试,失败时界面日志会写明原因。

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
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
static IOHIDEventSystemClientRef gClient;

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
    gClient = pClientCreate(kCFAllocatorDefault);
    if (!gClient) return @"IOHIDEventSystemClientCreate 返回空";
    return nil;
}

// phase: 0=按下 1=移动 2=抬起;nx/ny 是 0~1 的归一化坐标
static void sendFinger(double nx, double ny, int phase) {
    uint64_t t = mach_absolute_time();
    BOOL touching = (phase != 2);
    uint32_t mask = (phase == 1) ? 0x4 : 0x3;
    IOHIDEventRef hand = pCreateDigitizer(kCFAllocatorDefault, t, 3, 0, 0, mask, 0,
                                          nx, ny, 0, 0, 0, touching, touching, 0);
    pSetInt(hand, 0xb0019, 1);
    IOHIDEventRef finger = pCreateFinger(kCFAllocatorDefault, t, 1, 2, mask, nx, ny, 0,
                                         touching ? 1.0 : 0.0, 0, touching, touching, 0);
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
    if (steps < 2) steps = 2;
    sendFinger(x1 / s.width, y1 / s.height, 0);
    for (int i = 1; i <= steps; i++) {
        double k = (double)i / steps;
        usleep(ms * 1000 / steps);
        sendFinger((x1 + (x2 - x1) * k) / s.width, (y1 + (y2 - y1) * k) / s.height, 1);
    }
    sendFinger(x2 / s.width, y2 / s.height, 2);
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
    UIImage *img = [UIImage imageWithData:d];
    if (!img) { *note = @"广播帧解码失败"; return nil; }
    return img;
}

// 依次尝试 R→A→B→C→D;全部失败时 err 里列出每种方法的原因
static UIImage *takeScreenshot(NSString **err) {
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

#pragma mark - OCR (Vision)

// 返回 [{text,x,y,w,h}],坐标是屏幕点(pt),x/y 为中心点
// 说明:App 在后台时不能用 GPU,所以强制只用 CPU;并依次尝试 3 种设置。
static NSArray *ocrWithHandler(VNImageRequestHandler *h, NSString **err) {
    CGSize s = screenSize();
    NSMutableArray *notes = [NSMutableArray array];
    for (int attempt = 0; attempt < 3; attempt++) {
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.usesCPUOnly = YES;
        if (attempt == 0) {
            req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
            req.usesLanguageCorrection = YES;
        } else if (attempt == 1) {
            req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        } else {
            req.recognitionLevel = VNRequestTextRecognitionLevelFast;
            req.usesLanguageCorrection = NO;
        }
        NSError *e = nil;
        BOOL ok = NO;
        @try { ok = [h performRequests:@[req] error:&e]; }
        @catch (NSException *ex) {
            [notes addObject:[NSString stringWithFormat:@"第%d次异常:%@", attempt + 1, ex.reason]];
            continue;
        }
        if (!ok) {
            NSString *m = e ? e.localizedDescription : @"无错误信息";
            if (m.length > 80) m = [m substringToIndex:80];
            [notes addObject:[NSString stringWithFormat:@"第%d次失败:%@", attempt + 1, m]];
            continue;
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
    if (err) *err = [notes componentsJoinedByString:@";"];
    return nil;
}

// 用广播扩展送来的原始 NV12 数据建一个"不带 IOSurface"的 CVPixelBuffer 直接交给 Vision
// 注意:锁失败或平面地址为空时必须返回 nil(走图片路径),绝不能直接 memcpy,否则闪退。
static NSArray *ocrNV12(NSString **err) {
    // v0.4.2 加固后开广播仍闪退,说明崩点就在这条路(建缓冲/Vision 用它)。
    // 先整条停用,只走图片路径;IOSurface 现在能建了,图片路径的 Vision 应能自己建缓冲。
    if (err) *err = @"NV12 路径已停用";
    return nil;
    NSData *nv; uint32_t w, h, fmt;
    @synchronized (gLock) { nv = gNV12; w = gNW; h = gNH; fmt = gNFmt; }
    if (!nv.length || !w || !h) { if (err) *err = @"没有 NV12 数据"; return nil; }
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &pb);
    if (r != kCVReturnSuccess || !pb) {
        if (err) *err = [NSString stringWithFormat:@"建 CVPixelBuffer 失败(%d)", (int)r];
        return nil;
    }
    if (CVPixelBufferGetPlaneCount(pb) != 2) {
        CVPixelBufferRelease(pb);
        if (err) *err = [NSString stringWithFormat:@"NV12 缓冲区平面数不对(%lu)", (unsigned long)CVPixelBufferGetPlaneCount(pb)];
        return nil;
    }
    CVReturn lr = CVPixelBufferLockBaseAddress(pb, 0);
    if (lr != kCVReturnSuccess) {
        CVPixelBufferRelease(pb);
        if (err) *err = [NSString stringWithFormat:@"锁 CVPixelBuffer 失败(%d)", (int)lr];
        return nil;
    }
    size_t yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1);
    size_t yrb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    void *yd = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    void *cd = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (!yw || !yh || !cw || !ch || !yrb || !crb || !yd || !cd) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = [NSString stringWithFormat:@"NV12 平面无效 w=%u h=%u fmt=0x%x nv=%lu yw=%zu yh=%zu cw=%zu ch=%zu yrb=%zu crb=%zu yd=%p cd=%p",
                         w, h, fmt, (unsigned long)nv.length, yw, yh, cw, ch, yrb, crb, yd, cd];
        return nil;
    }
    if (nv.length != yw * yh + cw * 2 * ch) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = [NSString stringWithFormat:@"NV12 数据长度对不上(数据%lu,要%zu)", (unsigned long)nv.length, yw * yh + cw * 2 * ch];
        return nil;
    }
    const uint8_t *src = nv.bytes;
    for (size_t i = 0; i < yh; i++) memcpy((uint8_t *)yd + i * yrb, src + i * yw, yw);
    src += yw * yh;
    for (size_t i = 0; i < ch; i++) memcpy((uint8_t *)cd + i * crb, src + i * cw * 2, cw * 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    VNImageRequestHandler *h2 = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    NSArray *out = ocrWithHandler(h2, err);
    CVPixelBufferRelease(pb);
    return out;
}

static NSArray *ocrImage(UIImage *img, NSString **err) {
    NSMutableString *notes = [NSMutableString string];
    if ([gShotMethod isEqualToString:@"R"]) {
        NSString *e1 = nil;
        NSArray *r = ocrNV12(&e1);
        if (r) return r;
        [notes appendFormat:@"[NV12路径]%@ ", e1];
    }
    NSString *e2 = nil;
    if (!img.CGImage) {
        if (err) *err = [NSString stringWithFormat:@"OCR 全部失败 [NV12路径]%@ [图片路径]图片没有 CGImage", notes];
        return nil;
    }
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    NSArray *r = ocrWithHandler(h, &e2);
    if (r) return r;
    [notes appendFormat:@"[图片路径]%@", e2];
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

static NSString *setKeepAlive(BOOL on) {
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
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"version": @"0.4.1", @"broadcast": @(broadcastAlive())});
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
    NSString *exact = nil, *partial = nil;
    for (id a in apps) {
        NSString *n = nil, *bid = nil;
        @try { n = [a valueForKey:@"localizedName"]; bid = [a valueForKey:@"applicationIdentifier"]; }
        @catch (NSException *ex) { continue; }
        if (![n isKindOfClass:NSString.class] || ![bid isKindOfClass:NSString.class] || !n.length) continue;
        if ([n isEqualToString:name]) exact = bid;
        else if (!partial && [n localizedCaseInsensitiveContainsString:name]) partial = bid;
    }
    NSString *r = exact ?: partial;
    if (!r) *info = [NSString stringWithFormat:@"没找到名为「%@」的 App", name];
    return r;
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
    NSDictionary *body = @{@"model": model, @"messages": messages, @"temperature": @0.2,
                           @"max_tokens": @500, @"response_format": @{@"type": @"json_object"}};
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
    NSDictionary *act = [NSJSONSerialization JSONObjectWithData:[content dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:nil];
    if (![act isKindOfClass:NSDictionary.class]) {
        *err = [NSString stringWithFormat:@"模型没返回 JSON: %@", content.length > 120 ? [content substringToIndex:120] : content];
        return nil;
    }
    return act;
}

static NSString *const kAgentSystem =
@"你是一个控制 iPhone 的智能体,屏幕大小 390x844 pt。每一步你会收到:任务、最近的动作历史、当前屏幕上识别到的文字及其中心坐标(x,y,单位 pt)。\n"
@"只输出一个 JSON 对象,不要输出其他内容。字段:thought(一句话说明意图)、action、以及该动作需要的参数。\n"
@"action 可选值:\n"
@"- tap: 参数 x,y。点击。\n"
@"- long_press: 参数 x,y。长按。\n"
@"- swipe: 参数 x,y,x2,y2。从(x,y)滑到(x2,y2)。往下看更多内容用从下往上滑(y 大,y2 小)。\n"
@"- open_app: 参数 name(App 的中文名)。直接打开 App。\n"
@"- set_clipboard: 参数 text。把文字放进剪贴板。输入文字的办法:set_clipboard,然后 tap 输入框,再 long_press 输入框,再 tap 弹出的\"粘贴\",若出现\"允许粘贴\"就点它。\n"
@"- wait: 等待 1.5 秒。\n"
@"- done: 参数 text。任务已完成。\n"
@"- stop: 参数 text。无法继续或需要人工处理。\n"
@"规则:\n"
@"1. 坐标只能取自屏幕文字列表,或根据版面(如底部标签栏、右上角图标)合理推断。\n"
@"2. 只做到\"加入购物车\"为止。绝不点击结算、支付、提交订单、立即购买、确认付款;遇到这些步骤立即 stop。\n"
@"3. 每步只做一个动作。\n"
@"4. 屏幕连续没变化就换一种办法,仍不行就 stop。\n"
@"5. 看不到想要的内容时,先上滑或换搜索词,不要重复无效动作。";

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

static void agentRun(NSString *task, NSString *base, NSString *key, NSString *model) {
    gAgentRunning = YES;
    NSMutableArray *history = [NSMutableArray array];
    NSString *lastSig = @""; int same = 0;
    CGSize sc = screenSize();
    agentSay([NSString stringWithFormat:@"任务开始:%@", task]);
    for (int step = 1; step <= 25 && gAgentRunning; step++) {
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { agentSay([@"截屏失败,任务停止:" stringByAppendingString:err ?: @"?"]); break; }
        NSArray *items = ocrImage(img, &err);
        if (!items) { agentSay([@"OCR 失败,任务停止:" stringByAppendingString:err ?: @"?"]); break; }
        if (paySheetVisible(items)) { agentSay(@"看到支付/密码界面,已停止,请手动处理"); break; }
        items = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            int ya = [a[@"y"] intValue] / 12, yb = [b[@"y"] intValue] / 12;
            if (ya != yb) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
            return [(NSNumber *)a[@"x"] compare:(NSNumber *)b[@"x"]];
        }];
        NSMutableString *screen = [NSMutableString string];
        int n = 0;
        for (NSDictionary *it in items) {
            if (n++ >= 120) break;
            NSString *t = it[@"text"];
            if (t.length > 40) t = [t substringToIndex:40];
            [screen appendFormat:@"(%@,%@) %@\n", it[@"x"], it[@"y"], t];
        }
        if (!screen.length) [screen appendString:@"(没识别到文字)\n"];
        if ([screen isEqualToString:lastSig]) same++; else same = 0;
        lastSig = [screen copy];
        if (same >= 4) { agentSay(@"屏幕连续多步没变化,已停止"); break; }

        NSMutableString *hist = [NSMutableString string];
        NSUInteger from = history.count > 8 ? history.count - 8 : 0;
        for (NSUInteger i = from; i < history.count; i++) [hist appendFormat:@"%@\n", history[i]];
        NSString *user = [NSString stringWithFormat:@"任务:%@\n\n最近的动作:\n%@\n%@当前屏幕文字(x,y 文字):\n%@",
                          task, hist.length ? hist : @"(还没有)\n",
                          same > 0 ? [NSString stringWithFormat:@"注意:屏幕和上一步相比没有变化(已连续 %d 次)。\n", same] : @"",
                          screen];
        NSArray *msgs = @[@{@"role": @"system", @"content": kAgentSystem},
                          @{@"role": @"user", @"content": user}];
        NSDictionary *act = callLLM(base, key, model, msgs, &err);
        if (!gAgentRunning) break;
        if (!act) { agentSay([@"调用模型失败,任务停止:" stringByAppendingString:err ?: @"?"]); break; }

        NSString *action = [[act[@"action"] description] lowercaseString] ?: @"";
        NSString *thought = [act[@"thought"] description] ?: @"";
        double x = [act[@"x"] doubleValue], y = [act[@"y"] doubleValue];
        double x2 = [act[@"x2"] doubleValue], y2 = [act[@"y2"] doubleValue];
        x = MAX(0, MIN(sc.width - 1, x)); y = MAX(0, MIN(sc.height - 1, y));
        x2 = MAX(0, MIN(sc.width - 1, x2)); y2 = MAX(0, MIN(sc.height - 1, y2));
        agentSay([NSString stringWithFormat:@"第%d步:%@ → %@", step, thought, action]);

        if ([action isEqualToString:@"done"] || [action isEqualToString:@"stop"]) {
            agentSay([NSString stringWithFormat:@"%@:%@", [action isEqualToString:@"done"] ? @"任务完成" : @"任务停止", [act[@"text"] description] ?: @""]);
            break;
        }
        NSString *result = @"已执行";
        if ([action isEqualToString:@"tap"] || [action isEqualToString:@"long_press"]) {
            NSString *danger = dangerNear(items, x, y);
            if (danger) { agentSay([NSString stringWithFormat:@"拦截:要点击的位置是「%@」,属于支付/结算,已停止,请手动操作", danger]); break; }
            if ([action isEqualToString:@"tap"]) doTap(x, y); else doLongPress(x, y, 900);
            [history addObject:[NSString stringWithFormat:@"%d. %@(%.0f,%.0f)", step, action, x, y]];
            sleep(2);
        } else if ([action isEqualToString:@"swipe"]) {
            doSwipe(x, y, x2, y2, 20, 350);
            [history addObject:[NSString stringWithFormat:@"%d. swipe(%.0f,%.0f → %.0f,%.0f)", step, x, y, x2, y2]];
            sleep(2);
        } else if ([action isEqualToString:@"open_app"]) {
            NSString *name = [act[@"name"] description] ?: @"";
            NSString *info = nil;
            NSString *bid = bundleForAppName(name, &info);
            if (bid && openApp(bid)) result = @"已打开";
            else result = info ?: @"打开失败";
            [history addObject:[NSString stringWithFormat:@"%d. open_app(%@) → %@", step, name, result]];
            sleep(3);
        } else if ([action isEqualToString:@"set_clipboard"]) {
            NSString *text = [act[@"text"] description] ?: @"";
            dispatch_sync(dispatch_get_main_queue(), ^{ UIPasteboard.generalPasteboard.string = text; });
            [history addObject:[NSString stringWithFormat:@"%d. set_clipboard(%@)", step, text]];
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
    self.modelF = [self tfield:@"模型名" key:@"llm_model" secure:NO def:@"deepseek-chat"];
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
        [self btn:@"3 秒后 截屏 + OCR" action:@selector(onOCR)],
        [self btn:@"后台保活 开/关" action:@selector(onKeep)],
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
- (void)onSwipe {
    if (!gClient) { [self say:@"触摸没初始化"]; return; }
    CGSize s = screenSize();
    [self runLater:^{ doSwipe(s.width / 2, s.height * 0.75, s.width / 2, s.height * 0.3, 20, 300); [self say:@"上滑已发送"]; } name:@"上滑"];
}
- (void)onOCR {
    [self runLater:^{
        NSString *err = nil;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        UIImage *img = takeScreenshot(&err);
        if (!img) { [self say:[@"截屏失败: " stringByAppendingString:err ?: @"?"]]; return; }
        double t1 = CFAbsoluteTimeGetCurrent() - t0;
        NSArray *items = ocrImage(img, &err);
        if (!items) { [self say:[NSString stringWithFormat:@"截屏成功(%.0fx%.0f, %.2fs),但 %@", img.size.width, img.size.height, t1, err]]; return; }
        NSMutableString *m = [NSMutableString stringWithFormat:@"截屏(方法%@) %.0fx%.0f %.2fs;OCR %lu 条 %.2fs", gShotMethod, img.size.width, img.size.height, t1,
                              (unsigned long)items.count, CFAbsoluteTimeGetCurrent() - t0 - t1];
        for (NSDictionary *it in [items subarrayWithRange:NSMakeRange(0, MIN(items.count, 10))])
            [m appendFormat:@"\n  (%@,%@) %@", it[@"x"], it[@"y"], it[@"text"]];
        [self say:m];
    } name:@"截屏+OCR"];
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
- (void)onKeep {
    [self say:setKeepAlive(gPlayer == nil)];
}
@end

@interface AD : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    signal(SIGPIPE, SIG_IGN);
    gLock = [NSObject new];
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
