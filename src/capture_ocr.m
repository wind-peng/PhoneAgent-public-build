// PhoneAgent:截屏、OCR、诊断
#import "pa_internal.h"
#import <objc/runtime.h>
#import <dlfcn.h>

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
// rect:这张图对应的屏幕区域(pt);整屏传 CGRectZero
// v0.9.7:精确模式闪退的原因(崩溃日志确认):iOS 16.1 里 Vision 销毁精确识别引擎(CREngineAccurate)时,
// 另一个线程正在用它识别,系统直接 SIGTRAP("Semaphore object deallocated while in use"),@try 拦不住。
// 对策:1) 所有 OCR 串行(一把递归锁);2) 用一个常驻的 VNSequenceRequestHandler + 每种模式一个常驻请求,
// 识别引擎创建后不再销毁;3) 精确模式下不做角落二次识别,避免两种配置来回切换;
// 4) 识别前后打标记,如果精确模式中途闪退,下次启动自动关掉精确模式。
static NSRecursiveLock *ocrLock(void) {
    static NSRecursiveLock *l; static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSRecursiveLock new]; });
    return l;
}
static VNSequenceRequestHandler *gOCRSeq;
static VNRecognizeTextRequest *gReqFast, *gReqAccurate;

BOOL gOCRGuardTripped;

// v0.9.8:第二份崩溃日志显示,系统在识别过程中自己替换精确识别引擎,
// 销毁旧模型(CRTextSequenceRecognizerModelEspresso)时 iOS 16.1 必崩。
// 对策:把这个私有类的 dealloc 换成"什么都不做"——旧模型直接泄漏,不销毁就不会崩。
// 每次泄漏几十 MB,所以计数,超过上限本次运行就退回快速模式,防止内存爆掉。
static volatile int gLeakedModels;
static BOOL gLeakPatchOK;
static void paLeakDealloc(__unsafe_unretained id self, SEL _cmd) { gLeakedModels++; }
static void installOCRLeakPatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/TextRecognition.framework/TextRecognition", RTLD_NOW);
        const char *names[] = {"CRTextSequenceRecognizerModelEspresso", NULL};
        for (int i = 0; names[i]; i++) {
            Class c = objc_getClass(names[i]);
            if (!c) continue;
            Method m = class_getInstanceMethod(c, sel_registerName("dealloc"));
            if (!m) continue;
            // 只替换该类自己实现的 dealloc(不动父类)
            if (!class_addMethod(c, sel_registerName("dealloc"), (IMP)paLeakDealloc, method_getTypeEncoding(m)))
                method_setImplementation(m, (IMP)paLeakDealloc);
            gLeakPatchOK = YES;
        }
    });
}
#define PA_MAX_LEAKED_MODELS 10

BOOL ocrAccurateOn(void) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"ocr_accurate"]) return NO;
    installOCRLeakPatch();
    if (!gLeakPatchOK) return NO;                       // 找不到私有类:不冒险,用快速模式
    if (gLeakedModels >= PA_MAX_LEAKED_MODELS) return NO; // 泄漏太多:本次运行退回快速模式
    return YES;
}

// 启动时调用:上次精确识别没结束就闪退了 → 自动关闭精确模式,返回 YES
BOOL ocrCrashGuardCheck(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (![ud boolForKey:@"ocr_accurate_inflight"]) return NO;
    [ud setBool:NO forKey:@"ocr_accurate_inflight"];
    if (![ud boolForKey:@"ocr_accurate"]) return NO;
    [ud setBool:NO forKey:@"ocr_accurate"];
    return YES;
}

// cg 或 pb 二选一;rect:这张图对应的屏幕区域(pt),整屏传 CGRectZero
static NSArray *ocrRun(CGImageRef cg, CVPixelBufferRef pb, CGRect rect, NSString **err) {
    if (!cg && !pb) { if (err) *err = @"OCR 没有图片"; return nil; }
    CGSize s0 = screenSize();
    if (CGRectIsEmpty(rect)) rect = CGRectMake(0, 0, s0.width, s0.height);
    CGSize s = rect.size;
    BOOL accurate = ocrAccurateOn();
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableArray *out = [NSMutableArray array];
    NSRecursiveLock *lk = ocrLock();
    [lk lock];
    @try {
        if (!gOCRSeq) gOCRSeq = [VNSequenceRequestHandler new];
        VNRecognizeTextRequest *req;
        if (accurate) {
            if (!gReqAccurate) {
                gReqAccurate = [VNRecognizeTextRequest new];
                gReqAccurate.revision = VNRecognizeTextRequestRevision2;
                gReqAccurate.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
                gReqAccurate.usesLanguageCorrection = YES;
                gReqAccurate.recognitionLanguages = @[@"zh-Hans", @"en-US"];
                gReqAccurate.usesCPUOnly = YES;
            }
            req = gReqAccurate;
            [ud setBool:YES forKey:@"ocr_accurate_inflight"];
            [ud synchronize];
        } else {
            if (!gReqFast) {
                gReqFast = [VNRecognizeTextRequest new];
                gReqFast.revision = VNRecognizeTextRequestRevision1;
                gReqFast.recognitionLevel = VNRequestTextRecognitionLevelFast;
                gReqFast.usesLanguageCorrection = NO;
                gReqFast.recognitionLanguages = @[@"zh-Hans", @"en-US"];
                gReqFast.usesCPUOnly = YES;
            }
            req = gReqFast;
        }
        NSError *e = nil;
        BOOL ok = cg ? [gOCRSeq performRequests:@[req] onCGImage:cg error:&e]
                     : [gOCRSeq performRequests:@[req] onCVPixelBuffer:pb error:&e];
        if (accurate) [ud setBool:NO forKey:@"ocr_accurate_inflight"];
        if (!ok) {
            if (err) *err = e.localizedDescription ?: @"Vision 识别失败";
            out = nil;
        } else {
            for (VNRecognizedTextObservation *o in req.results) {
                VNRecognizedText *t = [[o topCandidates:1] firstObject];
                if (!t.string.length) continue;
                CGRect bb = o.boundingBox;
                [out addObject:@{
                    @"text": t.string,
                    @"x": @((int)round(rect.origin.x + (bb.origin.x + bb.size.width / 2) * s.width)),
                    @"y": @((int)round(rect.origin.y + (1 - bb.origin.y - bb.size.height / 2) * s.height)),
                    @"w": @((int)round(bb.size.width * s.width)),
                    @"h": @((int)round(bb.size.height * s.height))}];
            }
        }
    } @catch (NSException *ex) {
        if (accurate) [ud setBool:NO forKey:@"ocr_accurate_inflight"];
        if (err) *err = [NSString stringWithFormat:@"Vision 异常:%@", ex.reason ?: @"未知异常"];
        out = nil;
    } @finally {
        [lk unlock];
    }
    return out;
}

// v0.9.6:把同一行、水平紧挨着的碎片合并成一条(Vision 常把一个按钮/一句话切成几段)
static BOOL isLatinish(NSString *t) {
    if (!t.length) return NO;
    unichar c = [t characterAtIndex:t.length - 1];
    return c < 0x2E80;
}
static NSArray *mergeFragments(NSArray *items) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *it in items) [a addObject:[it mutableCopy]];
    BOOL changed = YES;
    int guard = 0;
    while (changed && guard++ < 6) {
        changed = NO;
        [a sortUsingComparator:^NSComparisonResult(NSDictionary *p, NSDictionary *q) {
            double xp = [p[@"x"] doubleValue] - [p[@"w"] doubleValue] / 2, xq = [q[@"x"] doubleValue] - [q[@"w"] doubleValue] / 2;
            return xp < xq ? NSOrderedAscending : (xp > xq ? NSOrderedDescending : NSOrderedSame);
        }];
        for (NSUInteger i = 0; i < a.count && !changed; i++) {
            NSMutableDictionary *p = a[i];
            double px = [p[@"x"] doubleValue], py = [p[@"y"] doubleValue], pw = [p[@"w"] doubleValue], ph = [p[@"h"] doubleValue];
            for (NSUInteger j = 0; j < a.count; j++) {
                if (j == i) continue;
                NSMutableDictionary *q = a[j];
                double qx = [q[@"x"] doubleValue], qy = [q[@"y"] doubleValue], qw = [q[@"w"] doubleValue], qh = [q[@"h"] doubleValue];
                double mh = MAX(ph, qh);
                if (mh <= 0 || fabs(py - qy) > mh * 0.35) continue;
                if (ph / MAX(1.0, qh) > 1.6 || qh / MAX(1.0, ph) > 1.6) continue;
                double gap = (qx - qw / 2) - (px + pw / 2);
                if (gap < -2 || gap > (ph + qh) / 2 * 0.6) continue;
                NSString *pt = p[@"text"], *qt = q[@"text"];
                NSString *joined = (isLatinish(pt) && qt.length && [qt characterAtIndex:0] < 0x2E80) ? [NSString stringWithFormat:@"%@ %@", pt, qt] : [pt stringByAppendingString:qt];
                double l = MIN(px - pw / 2, qx - qw / 2), r = MAX(px + pw / 2, qx + qw / 2);
                double t = MIN(py - ph / 2, qy - qh / 2), b = MAX(py + ph / 2, qy + qh / 2);
                p[@"text"] = joined;
                p[@"x"] = @((int)round((l + r) / 2)); p[@"y"] = @((int)round((t + b) / 2));
                p[@"w"] = @((int)round(r - l)); p[@"h"] = @((int)round(b - t));
                [a removeObjectAtIndex:j];
                changed = YES;
                break;
            }
        }
    }
    return a;
}

// v0.9.6:右上角区域(跳过/关闭这类小字)放大 2 倍再识别一次,补上第一次漏掉的短文字
static NSArray *cornerPass(UIImage *src, NSArray *have) {
    if (!src.CGImage) return have;
    CGSize sc = screenSize();
    CGRect ptRect = CGRectMake(sc.width * 0.55, sc.height * 0.03, sc.width * 0.45, sc.height * 0.14);
    double k = src.size.width / sc.width;
    CGRect pxRect = CGRectMake(ptRect.origin.x * k, ptRect.origin.y * k, ptRect.size.width * k, ptRect.size.height * k);
    CGImageRef crop = CGImageCreateWithImageInRect(src.CGImage, pxRect);
    if (!crop) return have;
    UIImage *ci = [UIImage imageWithCGImage:crop scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(crop);
    CGSize big = CGSizeMake(ptRect.size.width * 6, ptRect.size.height * 6); // 约等于原始像素的 2 倍
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIImage *up = [[[UIGraphicsImageRenderer alloc] initWithSize:big format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [ci drawInRect:CGRectMake(0, 0, big.width, big.height)];
    }];
    if (!up.CGImage) return have;
    NSString *e = nil;
    NSArray *extra = ocrRun(up.CGImage, NULL, ptRect, &e);
    if (!extra.count) return have;
    NSMutableArray *out = [have mutableCopy];
    for (NSDictionary *x in extra) {
        NSString *t = x[@"text"];
        if (t.length > 8) continue;
        BOOL dup = NO;
        for (NSDictionary *o in have)
            if (fabs([o[@"x"] doubleValue] - [x[@"x"] doubleValue]) < 20 && fabs([o[@"y"] doubleValue] - [x[@"y"] doubleValue]) < 14) { dup = YES; break; }
        if (!dup) [out addObject:x];
    }
    return out;
}

static NSArray *postOCR(UIImage *src, NSArray *r) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL merge = [d objectForKey:@"ocr_merge"] ? [d boolForKey:@"ocr_merge"] : YES;
    BOOL corner = [d objectForKey:@"ocr_corner"] ? [d boolForKey:@"ocr_corner"] : YES;
    if (corner && !ocrAccurateOn()) { @try { r = cornerPass(src, r); } @catch (NSException *ex) {} }
    if (merge) r = mergeFragments(r);
    return r;
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
    NSArray *out = ocrRun(NULL, pb, CGRectZero, err);
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
    NSArray *r = ocrRun(ocrImg.CGImage, NULL, CGRectZero, &e2);
    if (r) return postOCR(img, r);
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

#pragma mark - v0.9.18 OCR 自检

// Swift 写的 Live Text(VisionKit ImageAnalyzer,iOS 16,就是相册"长按识别文字"的引擎),见 src/livetext.swift
@interface PALiveText : NSObject
+ (NSString *)transcript:(UIImage *)img timeout:(double)t;
@end

static NSString *paCacheDir(void) {
    return [@"/var/mobile/Library/Caches" stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier];
}

static UIImage *selfTestImage(void) {
    CGSize sz = CGSizeMake(700, 260);
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat]; f.scale = 1;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [UIColor.whiteColor setFill]; UIRectFill(CGRectMake(0, 0, sz.width, sz.height));
        NSDictionary *a = @{NSFontAttributeName: [UIFont systemFontOfSize:48 weight:UIFontWeightMedium], NSForegroundColorAttributeName: UIColor.blackColor};
        [@"淘宝 大风衣 搜索" drawAtPoint:CGPointMake(30, 40) withAttributes:a];
        [@"京东 价格 128.5元 Buy" drawAtPoint:CGPointMake(30, 140) withAttributes:a];
    }];
}

static NSString *selfTestOCR(CGImageRef cg, NSInteger rev, BOOL accurate, BOOL cpu) {
    if (!cg) return @"没有图片";
    installOCRLeakPatch();
    VNRecognizeTextRequest *r = [VNRecognizeTextRequest new];
    r.revision = rev;
    r.recognitionLevel = accurate ? VNRequestTextRecognitionLevelAccurate : VNRequestTextRecognitionLevelFast;
    r.usesLanguageCorrection = accurate;
    r.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    r.usesCPUOnly = cpu;
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSError *e = nil; BOOL ok = NO; NSString *exc = nil;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [ocrLock() lock];
    if (accurate) { [ud setBool:YES forKey:@"ocr_accurate_inflight"]; [ud synchronize]; }
    @try { ok = [h performRequests:@[r] error:&e]; }
    @catch (NSException *ex) { exc = ex.reason ?: ex.name; }
    if (accurate) [ud setBool:NO forKey:@"ocr_accurate_inflight"];
    [ocrLock() unlock];
    int ms = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000);
    if (exc) return [NSString stringWithFormat:@"异常 %@ (%dms)", exc, ms];
    if (!ok) return [NSString stringWithFormat:@"失败 %@ code=%ld %@ (%dms)", e.domain, (long)e.code, e.localizedDescription, ms];
    NSMutableArray *ts = [NSMutableArray array];
    for (VNRecognizedTextObservation *o in r.results) { NSString *s = [[o topCandidates:1] firstObject].string; if (s.length) [ts addObject:s]; }
    NSString *j = [ts componentsJoinedByString:@" | "];
    if (j.length > 120) j = [[j substringToIndex:120] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"成功 %lu 段 (%dms):%@", (unsigned long)ts.count, ms, j];
}

static NSString *selfTestLive(UIImage *img) {
    Class c = NSClassFromString(@"PALiveText");
    if (!c) return @"LiveText 模块没编进来";
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSString *s = [c transcript:img timeout:20] ?: @"(空)";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
    if (s.length > 120) s = [[s substringToIndex:120] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"(%dms) %@", (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000), s];
}

static NSString *cacheListing(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableString *m = [NSMutableString string];
    NSString *sysCaches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    [m appendFormat:@"系统给的缓存目录:%@\n临时目录:%@\n", sysCaches, NSTemporaryDirectory()];
    NSString *dir = paCacheDir();
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir]) { [m appendFormat:@"%@ 不存在\n", dir]; }
    else {
        unsigned long long total = 0; int n = 0;
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        NSMutableString *lines = [NSMutableString string];
        for (NSString *p in en) {
            NSDictionary *at = en.fileAttributes;
            unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
            BOOL d = [at[NSFileType] isEqualToString:NSFileTypeDirectory];
            if (!d) total += sz;
            if (n < 40 && (d ? en.level <= 3 : sz > 100 * 1024)) { [lines appendFormat:@"  %@%@ %@\n", p, d ? @"/" : @"", d ? @"" : [NSString stringWithFormat:@"%.1fMB", sz / 1048576.0]]; n++; }
        }
        [m appendFormat:@"%@ 共 %.1fMB:\n%@", dir, total / 1048576.0, lines];
    }
    NSArray *all = [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/Caches" error:nil];
    NSMutableArray *rel = [NSMutableArray array];
    for (NSString *x in all) { NSString *l = x.lowercaseString; if ([l containsString:@"phoneagent"] || [l containsString:@"vision"] || [l containsString:@"e5rt"] || [l containsString:@"espresso"] || [l containsString:@"textrecognition"]) [rel addObject:x]; }
    [m appendFormat:@"Caches 下相关目录:%@\n", rel.count ? [rel componentsJoinedByString:@", "] : @"无"];
    return m;
}

NSString *ocrSelfTest(void (^progress)(NSString *soFar)) {
    NSMutableString *m = [NSMutableString string];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    void (^add)(NSString *) = ^(NSString *s) {
        [m appendString:s]; [m appendString:@"\n"];
        [ud setObject:m forKey:@"ocr_selftest_last"]; [ud synchronize]; // 中途闪退也能看到做到哪一步
        if (progress) progress(m);
    };
    UIDevice *dv = UIDevice.currentDevice;
    add([NSString stringWithFormat:@"PhoneAgent %@ / iOS %@ / 防闪退补丁 %@ / 已泄漏模型 %d",
         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], dv.systemVersion,
         (installOCRLeakPatch(), gLeakPatchOK) ? @"已装" : @"没装上", gLeakedModels]);
    add(cacheListing());
    {
        VNRecognizeTextRequest *r = [VNRecognizeTextRequest new];
        r.revision = VNRecognizeTextRequestRevision2; r.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        NSError *e = nil; NSArray *langs = [r supportedRecognitionLanguagesAndReturnError:&e];
        add([NSString stringWithFormat:@"精确 Rev2 支持的语言:%@", langs ? [langs componentsJoinedByString:@","] : [NSString stringWithFormat:@"出错 %@", e]]);
    }
    UIImage *ti = selfTestImage();
    add(@"【内置中文图:淘宝 大风衣 搜索 / 京东 价格 128.5元 Buy】");
    add([@"1 快速 Rev1:" stringByAppendingString:selfTestOCR(ti.CGImage, VNRecognizeTextRequestRevision1, NO, YES)]);
    add([@"2 精确 Rev2 CPU:" stringByAppendingString:selfTestOCR(ti.CGImage, VNRecognizeTextRequestRevision2, YES, YES)]);
    add([@"3 精确 Rev2 非CPU:" stringByAppendingString:selfTestOCR(ti.CGImage, VNRecognizeTextRequestRevision2, YES, NO)]);
    add([@"4 Live Text:" stringByAppendingString:selfTestLive(ti)]);
    NSString *se = nil;
    UIImage *shot = takeScreenshot(&se);
    if (shot.CGImage) {
        add(@"【当前屏幕截图】");
        add([@"5 精确 Rev2 CPU:" stringByAppendingString:selfTestOCR(shot.CGImage, VNRecognizeTextRequestRevision2, YES, YES)]);
        add([@"6 Live Text:" stringByAppendingString:selfTestLive(shot)]);
    } else add([NSString stringWithFormat:@"【截图】拿不到(录屏没开?):%@", se ?: @""]);
    if (@available(iOS 16.0, *)) {
        add([@"7 精确 Rev3 非CPU(内置图,最后测,曾闪退):" stringByAppendingString:selfTestOCR(ti.CGImage, VNRecognizeTextRequestRevision3, YES, NO)]);
    }
    add(@"自检结束");
    return m;
}

// 把 PhoneAgent 自己的缓存目录改名备份(不删除,可恢复),下次识别时系统会重新生成
NSString *ocrClearCache(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = paCacheDir(), *bak = [dir stringByAppendingString:@".bak"];
    if (![fm fileExistsAtPath:dir]) return [NSString stringWithFormat:@"%@ 不存在,没有可清的", dir];
    [fm removeItemAtPath:bak error:nil];
    NSError *e = nil;
    if (![fm moveItemAtPath:dir toPath:bak error:&e]) return [NSString stringWithFormat:@"改名失败:%@", e.localizedDescription];
    return [NSString stringWithFormat:@"已把 %@ 改名为 .bak。请从后台划掉 PhoneAgent 再打开,然后再做一次自检。", dir];
}
