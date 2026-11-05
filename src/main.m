// PhoneAgent v0.2.6
// v0.2.6: 回退 0.2.5 的方法 E(_UICreateScreenUIImage),恢复 0.2.4 的截图逻辑,用于定位 0.2.5 启动后无反应的问题。
// v0.2.4: 截图改为 B→C→D→A，并增加纯色图片检测，避免空白图被误判成功。
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

#ifndef PORT
#define PORT 8200
#endif

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

// 检查 UIImage 是否真的包含屏幕内容。
// 私有截图 API 有时会返回尺寸正确、但像素是单一纯色的“假成功”图片。
// 当前 iPhone UI 通常同时包含背景、文字和图标；低色彩变化的图片视为无效并继续尝试下一种方法。
static BOOL imageLooksLikeScreen(UIImage *img, NSString **note) {
    CGImageRef source = img.CGImage;
    if (!source) {
        if (note) *note = @"图片没有 CGImage";
        return NO;
    }

    const size_t side = 32;
    uint8_t pixels[side * side * 4];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, side, side, 8, side * 4, cs,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        if (note) *note = @"创建截图检测位图失败";
        return NO;
    }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), source);
    CGContextRelease(ctx);

    int minL = 255, maxL = 0;
    int distinct = 0;
    uint32_t seen[side * side];
    size_t seenCount = 0;

    for (size_t i = 0; i < side * side; i++) {
        int r = pixels[i * 4 + 0];
        int g = pixels[i * 4 + 1];
        int b = pixels[i * 4 + 2];
        int lum = (299 * r + 587 * g + 114 * b) / 1000;
        if (lum < minL) minL = lum;
        if (lum > maxL) maxL = lum;

        // 量化颜色，避免抗锯齿造成大量无意义的“不同颜色”
        uint32_t key = ((uint32_t)(r >> 4) << 8) |
                       ((uint32_t)(g >> 4) << 4) |
                       (uint32_t)(b >> 4);
        BOOL found = NO;
        for (size_t j = 0; j < seenCount; j++) {
            if (seen[j] == key) { found = YES; break; }
        }
        if (!found) {
            seen[seenCount++] = key;
            distinct++;
        }
    }

    // 对当前测试界面而言，纯色/近似纯色不是有效的屏幕截图。
    BOOL valid = (distinct >= 5 && (maxL - minL) >= 12);
    if (!valid && note) {
        *note = [NSString stringWithFormat:@"图片像素近似纯色(颜色种类=%d,亮度范围=%d..%d)", distinct, minL, maxL];
    }
    return valid;
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

// 优先尝试 B→C→D，最后才尝试 A。
// 每种方法返回图片后都检查真实像素；尺寸正常但整张纯色的图片不算截图成功。
static UIImage *takeScreenshot(NSString **err) {
    if (!pCARender) { if (err) *err = @"截屏模块未初始化"; return nil; }
    typedef UIImage *(*ShotFn)(NSString **);
    ShotFn fns[4] = {shotB, shotC, shotD, shotA};
    NSString *names[4] = {@"B", @"C", @"D", @"A"};
    NSMutableString *report = [NSMutableString string];
    for (int i = 0; i < 4; i++) {
        NSString *note = nil;
        UIImage *img = fns[i](&note);
        if (img) {
            NSString *qualityNote = nil;
            if (imageLooksLikeScreen(img, &qualityNote)) {
                gShotMethod = names[i];
                return img;
            }
            note = qualityNote ?: @"像素内容检测未通过";
        }
        [report appendFormat:@"%@:%@; ", names[i], note ?: @"未知失败"];
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
static NSArray *ocrImage(UIImage *img, NSString **err) {
    CGSize s = screenSize();
    NSMutableArray *out = [NSMutableArray array];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = YES;
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    NSError *e = nil;
    if (![h performRequests:@[req] error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"OCR 失败: %@", e.localizedDescription];
        return nil;
    }
    for (VNRecognizedTextObservation *o in req.results) {
        VNRecognizedText *t = [[o topCandidates:1] firstObject];
        if (!t.string.length) continue;
        CGRect b = o.boundingBox; // 归一化,原点在左下
        [out addObject:@{
            @"text": t.string,
            @"x": @((int)round((b.origin.x + b.size.width / 2) * s.width)),
            @"y": @((int)round((1 - b.origin.y - b.size.height / 2) * s.height)),
            @"w": @((int)round(b.size.width * s.width)),
            @"h": @((int)round(b.size.height * s.height))}];
    }
    return out;
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
    char buf[8192];
    ssize_t n = read(c, buf, sizeof buf - 1);
    if (n <= 0) { close(c); return; }
    buf[n] = 0;
    NSString *req = [NSString stringWithUTF8String:buf] ?: @"";
    NSArray *parts = [[[req componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
    if (parts.count < 2) { close(c); return; }
    NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://h" stringByAppendingString:parts[1]]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
    NSString *path = uc.path ?: @"/";
    CGSize s = screenSize();

    if ([path isEqualToString:@"/ping"]) {
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"version": @"0.2.6"});
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

#pragma mark - 界面

@interface VC : UIViewController
@property (nonatomic, strong) UITextField *xf, *yf;
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
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        tip, self.xf, self.yf,
        [self btn:@"3 秒后点击 (x,y)" action:@selector(onTap)],
        [self btn:@"3 秒后上滑一次" action:@selector(onSwipe)],
        [self btn:@"3 秒后 截屏 + OCR" action:@selector(onOCR)],
        [self btn:@"后台保活 开/关" action:@selector(onKeep)],
        [self btn:@"诊断 IOSurface" action:@selector(onDiag)],
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
        self.log.text = [NSString stringWithFormat:@"%@\n%@", m, self.log.text ?: @""];
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
