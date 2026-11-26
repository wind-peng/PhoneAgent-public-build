// lab1:嵌入实验(参考"巨魔分屏"的做法)
// 用 FrontBoard 私有接口把别的 App 的画面嵌进本 App 窗口,测试:
//   1) 能不能嵌进来  2) 不开录屏能不能截到它的画面并 OCR  3) 手点嵌入画面有没有反应
// 全部用运行时调用,每一步写日志;缺类/缺方法只报错不闪退。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <CoreImage/CoreImage.h>
#import "pa_internal.h"

static id lab_cls(NSString *n) { return NSClassFromString(n); }
#define MSG0(o, s)          ((id (*)(id, SEL))objc_msgSend)((o), sel_registerName(s))
#define MSG1(o, s, a)       ((id (*)(id, SEL, id))objc_msgSend)((o), sel_registerName(s), (a))
#define MSG2(o, s, a, b)    ((id (*)(id, SEL, id, id))objc_msgSend)((o), sel_registerName(s), (a), (b))
#define MSGB(o, s, v)       ((void (*)(id, SEL, BOOL))objc_msgSend)((o), sel_registerName(s), (v))
#define MSGL(o, s, v)       ((void (*)(id, SEL, long))objc_msgSend)((o), sel_registerName(s), (v))
#define MSGD(o, s, v)       ((void (*)(id, SEL, double))objc_msgSend)((o), sel_registerName(s), (v))
#define MSGR(o, s, v)       ((void (*)(id, SEL, CGRect))objc_msgSend)((o), sel_registerName(s), (v))

static BOOL lab_has(id o, const char *s) { return o && [o respondsToSelector:sel_registerName(s)]; }

@interface SceneLabVC : UIViewController
@property (nonatomic, strong) UITextField *bidField;
@property (nonatomic, strong) UITextView *logTV;
@property (nonatomic, strong) UIView *host;
@property (nonatomic, strong) id scene, presenter;
@property (nonatomic, strong) UIView *presView;
@property (nonatomic, assign) int shrinkStep;
@end

@implementation SceneLabVC
static NSMutableString *gLabLog;
static void labUncaught(NSException *e) {
    NSString *t = [NSString stringWithFormat:@"!! 未捕获异常:%@ %@\n%@", e.name, e.reason,
                   [[e.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, e.callStackSymbols.count))] componentsJoinedByString:@"\n"]];
    [gLabLog appendFormat:@"%@\n", t];
    [NSUserDefaults.standardUserDefaults setObject:gLabLog forKey:@"scenelab_last"];
    [NSUserDefaults.standardUserDefaults synchronize];
}
- (void)log:(NSString *)s {
    // lab2:先同步写盘再刷界面,闪退前最后一行也能留下
    @synchronized (SceneLabVC.class) {
        if (!gLabLog) gLabLog = [NSMutableString string];
        [gLabLog appendFormat:@"%@\n", s];
        [NSUserDefaults.standardUserDefaults setObject:gLabLog forKey:@"scenelab_last"];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logTV.text = [self.logTV.text stringByAppendingFormat:@"%@\n", s];
        [self.logTV scrollRangeToVisible:NSMakeRange(self.logTV.text.length, 0)];
    });
}
- (UIButton *)btn:(NSString *)t sel:(SEL)s {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    b.titleLabel.adjustsFontSizeToFitWidth = YES; b.titleLabel.minimumScaleFactor = 0.6;
    [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"嵌入实验";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制日志" style:UIBarButtonItemStylePlain target:self action:@selector(onCopy)];
    self.bidField = [UITextField new];
    self.bidField.borderStyle = UITextBorderStyleRoundedRect;
    self.bidField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.bidField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.bidField.text = [NSUserDefaults.standardUserDefaults stringForKey:@"scenelab_bid"] ?: @"com.apple.Preferences";
    self.bidField.placeholder = @"App 包名,如 com.apple.Preferences";
    UIStackView *btns = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self btn:@"1 嵌入" sel:@selector(onEmbed)],
        [self btn:@"1b 直接启动" sel:@selector(onEmbedDirect)],
        [self btn:@"2 截图+OCR" sel:@selector(onShot)],
        [self btn:@"3 程序点" sel:@selector(onAutoTap)],
        [self btn:@"5 快照2" sel:@selector(onSnap2)],
        [self btn:@"6 变小/藏" sel:@selector(onShrink)],
        [self btn:@"7 全流程" sel:@selector(onFlow)],
        [self btn:@"关闭" sel:@selector(onClose)]]];
    btns.axis = UILayoutConstraintAxisHorizontal; btns.distribution = UIStackViewDistributionFillEqually;
    self.host = [UIView new];
    self.host.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.host.layer.borderWidth = 1; self.host.layer.borderColor = UIColor.separatorColor.CGColor;
    self.host.clipsToBounds = YES;
    self.logTV = [UITextView new];
    self.logTV.editable = NO;
    self.logTV.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:@"scenelab_last"];
    self.logTV.text = last.length ? [NSString stringWithFormat:@"(上次日志,若中途闪退看最后一行)\n%@\n----\n", last] : @"";
    gLabLog = [NSMutableString string];
    NSSetUncaughtExceptionHandler(&labUncaught);
    for (UIView *v in @[self.bidField, btns, self.host, self.logTV]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.bidField.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.bidField.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.bidField.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [btns.topAnchor constraintEqualToAnchor:self.bidField.bottomAnchor constant:6],
        [btns.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [btns.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.host.topAnchor constraintEqualToAnchor:btns.bottomAnchor constant:6],
        [self.host.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [self.host.widthAnchor constraintEqualToAnchor:g.widthAnchor multiplier:0.62],
        [self.host.heightAnchor constraintEqualToAnchor:self.host.widthAnchor multiplier:UIScreen.mainScreen.bounds.size.height / UIScreen.mainScreen.bounds.size.width],
        [self.logTV.topAnchor constraintEqualToAnchor:self.host.bottomAnchor constant:6],
        [self.logTV.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.logTV.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.logTV.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
}
- (void)onCopy { UIPasteboard.generalPasteboard.string = self.logTV.text; self.navigationItem.rightBarButtonItem.title = @"已复制"; }

- (void)onEmbed {
    [self.view endEditing:YES];
    if (self.presView) { [self log:@"已经嵌入了,先点关闭"]; return; }
    NSString *bid = [self.bidField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!bid.length) return;
    [NSUserDefaults.standardUserDefaults setObject:bid forKey:@"scenelab_bid"];
    [self log:[NSString stringWithFormat:@"== 嵌入 %@ (iOS %@)", bid, UIDevice.currentDevice.systemVersion]];
    @try {
        NSArray *need = @[@"RBSProcessIdentity", @"RBSProcessPredicate", @"RBSProcessHandle", @"FBProcessManager",
                          @"FBMutableProcessExecutionContext", @"FBApplicationProcessLaunchTransaction", @"FBSceneManager",
                          @"FBSMutableSceneDefinition", @"FBSSceneIdentity", @"FBSSceneClientIdentity",
                          @"UIApplicationSceneSpecification", @"FBSMutableSceneParameters",
                          @"UIMutableApplicationSceneSettings", @"UIMutableApplicationSceneClientSettings"];
        for (NSString *n in need) if (!lab_cls(n)) { [self log:[@"缺少类:" stringByAppendingString:n]]; return; }
        [self log:@"a 私有类都在"];

        id identity = MSG1(lab_cls(@"RBSProcessIdentity"), "identityForEmbeddedApplicationIdentifier:", bid);
        id predicate = MSG1(lab_cls(@"RBSProcessPredicate"), "predicateMatchingIdentity:", identity);
        id manager = MSG0(lab_cls(@"FBProcessManager"), "sharedInstance");
        [self log:[NSString stringWithFormat:@"b identity=%@ manager=%@", identity ? @"有" : @"无", manager ? @"有" : @"无"]];
        if (!identity || !manager) return;

        id (^provider)(void) = ^id(void) {
            @try {
                [self log:@"c1 provider 被调用"];
                id ctx = [lab_cls(@"FBMutableProcessExecutionContext") new];
                MSG1(ctx, "setIdentity:", identity);
                MSG1(ctx, "setEnvironment:", @{});
                MSGL(ctx, "setLaunchIntent:", 4);
                [self log:@"c2 调 launchProcessWithContext"];
                id proc = MSG1(manager, "launchProcessWithContext:", ctx);
                [self log:[NSString stringWithFormat:@"c3 进程=%@", proc ? @"有" : @"无"]];
                return proc;
            } @catch (NSException *e) { [self log:[@"启动进程异常:" stringByAppendingString:e.reason ?: e.name]]; return nil; }
        };
        id tx = MSG2([lab_cls(@"FBApplicationProcessLaunchTransaction") alloc], "initWithProcessIdentity:executionContextProvider:", identity, provider);
        if (!tx) { [self log:@"c 启动事务创建失败"]; return; }
        __weak SceneLabVC *ws = self;
        [self log:@"c0 事务已建,设完成回调"];
        MSG1(tx, "setCompletionBlock:", (id)^{
            [ws log:@"c4 事务完成回调"];
            dispatch_async(dispatch_get_main_queue(), ^{ [ws afterLaunch:bid identity:identity predicate:predicate manager:manager]; });
        });
        [self log:@"c 开始启动进程(begin)…"];
        MSG0(tx, "begin");
        [self log:@"c5 begin 已返回"];
        objc_setAssociatedObject(self, "tx", tx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"异常:%@ %@", e.name, e.reason]];
    }
}

// lab2:不走启动事务,直接让 FBProcessManager 启动,再建场景
- (void)onEmbedDirect {
    [self.view endEditing:YES];
    if (self.presView) { [self log:@"已经嵌入了,先点关闭"]; return; }
    NSString *bid = [self.bidField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!bid.length) return;
    [self log:[NSString stringWithFormat:@"== 直接启动 %@", bid]];
    @try {
        id identity = MSG1(lab_cls(@"RBSProcessIdentity"), "identityForEmbeddedApplicationIdentifier:", bid);
        id predicate = MSG1(lab_cls(@"RBSProcessPredicate"), "predicateMatchingIdentity:", identity);
        id manager = MSG0(lab_cls(@"FBProcessManager"), "sharedInstance");
        [self log:@"d0 建执行上下文"];
        id ctx = [lab_cls(@"FBMutableProcessExecutionContext") new];
        MSG1(ctx, "setIdentity:", identity);
        MSG1(ctx, "setEnvironment:", @{});
        MSGL(ctx, "setLaunchIntent:", 4);
        [self log:@"d1 调 launchProcessWithContext"];
        id proc = MSG1(manager, "launchProcessWithContext:", ctx);
        [self log:[NSString stringWithFormat:@"d2 进程=%@", proc ? @"有" : @"无"]];
        __weak SceneLabVC *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws afterLaunch:bid identity:identity predicate:predicate manager:manager];
        });
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"异常:%@ %@", e.name, e.reason]];
    }
}

- (void)afterLaunch:(NSString *)bid identity:(id)identity predicate:(id)predicate manager:(id)manager {
    @try {
        NSError *err = nil;
        id handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(lab_cls(@"RBSProcessHandle"), sel_registerName("handleForPredicate:error:"), predicate, &err);
        [self log:[NSString stringWithFormat:@"d 进程 handle=%@ %@", handle ? @"有" : @"无", err.localizedDescription ?: @""]];
        // lab3:auditToken 返回的是 32 字节结构体,不能当对象取(lab2 就崩在这)
        if (handle && lab_has(handle, "auditToken") && lab_has(manager, "registerProcessForAuditToken:")) {
            typedef struct { unsigned int v[8]; } pa_tok_t;
            pa_tok_t tok = ((pa_tok_t (*)(id, SEL))objc_msgSend)(handle, sel_registerName("auditToken"));
            [self log:@"d1 拿到 auditToken,注册进程"];
            ((id (*)(id, SEL, pa_tok_t))objc_msgSend)(manager, sel_registerName("registerProcessForAuditToken:"), tok);
            [self log:@"d2 注册完成"];
        } else [self log:@"d1 跳过注册"];

        NSString *sceneID = [NSString stringWithFormat:@"sceneID:%@-palab", bid];
        id def = MSG0(lab_cls(@"FBSMutableSceneDefinition"), "definition");
        MSG1(def, "setIdentity:", MSG1(lab_cls(@"FBSSceneIdentity"), "identityForIdentifier:", sceneID));
        MSG1(def, "setClientIdentity:", MSG1(lab_cls(@"FBSSceneClientIdentity"), "identityForProcessIdentity:", identity));
        [self log:@"d3 场景定义已建"];
        id spec = MSG0(lab_cls(@"UIApplicationSceneSpecification"), "specification");
        MSG1(def, "setSpecification:", spec);
        id params = MSG1(lab_cls(@"FBSMutableSceneParameters"), "parametersForSpecification:", spec);

        [self log:@"d4 参数对象已建"];
        CGRect full = UIScreen.mainScreen.bounds; // 让 App 按整屏尺寸布局,显示时再缩小
        id settings = [lab_cls(@"UIMutableApplicationSceneSettings") new];
        if (lab_has(settings, "setCanShowAlerts:")) MSGB(settings, "setCanShowAlerts:", YES);
        if (lab_has(UIScreen.mainScreen, "displayConfiguration")) MSG1(settings, "setDisplayConfiguration:", MSG0(UIScreen.mainScreen, "displayConfiguration"));
        MSGB(settings, "setForeground:", YES);
        MSGR(settings, "setFrame:", full);
        MSGL(settings, "setInterfaceOrientation:", UIInterfaceOrientationPortrait);
        MSGD(settings, "setLevel:", 1);
        MSG1(settings, "setPersistenceIdentifier:", NSUUID.UUID.UUIDString);
        if (lab_has(settings, "setStatusBarDisabled:")) MSGB(settings, "setStatusBarDisabled:", YES);
        MSG1(params, "setSettings:", settings);
        id cs = [lab_cls(@"UIMutableApplicationSceneClientSettings") new];
        MSGL(cs, "setInterfaceOrientation:", UIInterfaceOrientationPortrait);
        MSG1(params, "setClientSettings:", cs);
        [self log:@"e 场景参数已设好"];

        id sm = MSG0(lab_cls(@"FBSceneManager"), "sharedInstance");
        if (!lab_has(sm, "createSceneWithDefinition:initialParameters:")) { [self log:@"f FBSceneManager 没有 createScene 方法"]; return; }
        id scene = MSG2(sm, "createSceneWithDefinition:initialParameters:", def, params);
        [self log:[NSString stringWithFormat:@"f 场景=%@", scene ? @"已创建" : @"失败"]];
        if (!scene) return;
        [self log:@"f1 取 presenter"];
        id pm = lab_has(scene, "uiPresentationManager") ? MSG0(scene, "uiPresentationManager") : nil;
        id presenter = pm ? MSG1(pm, "createPresenterWithIdentifier:", sceneID) : nil;
        if (!presenter) { [self log:@"g 拿不到 presenter"]; return; }
        MSG0(presenter, "activate");
        [self log:@"f2 presenter 已激活"];
        UIView *pv = MSG0(presenter, "presentationView");
        if (![pv isKindOfClass:UIView.class]) { [self log:@"g presentationView 不是 UIView"]; return; }
        self.scene = scene; self.presenter = presenter; self.presView = pv;
        CGFloat k = self.host.bounds.size.width / full.size.width;
        pv.frame = full;
        pv.layer.anchorPoint = CGPointZero; pv.layer.position = CGPointZero;
        pv.transform = CGAffineTransformMakeScale(k, k);
        [self.host addSubview:pv];
        [self log:[NSString stringWithFormat:@"g 已嵌入,缩放 %.2f。看框里有没有画面;用手点框里试试有没有反应。然后点「2 截图+OCR」", k]];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"异常:%@ %@", e.name, e.reason]];
    }
}

// lab4:三种截图方法逐个试,每种都裁出嵌入框那一块,看亮度并 OCR
static void lab_range(CGImageRef cg, int *mn, int *mx) {
    size_t w = 40, h = 80; unsigned char px[40 * 80 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { *mn = *mx = -1; return; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg); CGContextRelease(ctx);
    int a = 255, b = 0;
    for (size_t i = 0; i < w * h; i++) { int v = (px[i*4] + px[i*4+1] + px[i*4+2]) / 3; a = MIN(a, v); b = MAX(b, v); }
    *mn = a; *mx = b;
}

// 整屏截图 → 裁出嵌入框(按屏幕点坐标换算到像素)
- (UIImage *)cropBox:(CGImageRef)full {
    if (!full) return nil;
    CGRect box = [self.host convertRect:self.host.bounds toView:nil];   // 窗口坐标 = 屏幕坐标(竖屏)
    CGFloat sx = CGImageGetWidth(full) / UIScreen.mainScreen.bounds.size.width;
    CGFloat sy = CGImageGetHeight(full) / UIScreen.mainScreen.bounds.size.height;
    CGRect px = CGRectIntegral(CGRectMake(box.origin.x * sx, box.origin.y * sy, box.size.width * sx, box.size.height * sy));
    CGImageRef c = CGImageCreateWithImageInRect(full, px);
    if (!c) return nil;
    UIImage *img = [UIImage imageWithCGImage:c]; CGImageRelease(c);
    return img;
}

- (void)report:(NSString *)tag image:(UIImage *)img {
    if (!img.CGImage) { [self log:[NSString stringWithFormat:@"%@ 没拿到图", tag]]; return; }
    int mn = 0, mx = 0; lab_range(img.CGImage, &mn, &mx);
    [self log:[NSString stringWithFormat:@"%@ 图 %zux%zu,亮度 %d~%d", tag, CGImageGetWidth(img.CGImage), CGImageGetHeight(img.CGImage), mn, mx]];
    if (mx - mn < 10) return;
    NSString *err = nil;
    NSArray *items = ocrImage(img, &err);
    NSMutableArray *ts = [NSMutableArray array];
    for (NSDictionary *it in items) { if (ts.count >= 8) break; NSString *t = [it[@"text"] description]; if (t.length) [ts addObject:t]; }
    [self log:[NSString stringWithFormat:@"%@ OCR %lu 条%@:%@", tag, (unsigned long)items.count, err.length ? [@" 错误 " stringByAppendingString:err] : @"", [ts componentsJoinedByString:@" | "]]];
}

// 方法 C:直接从显示服务读整块屏幕像素(CARenderServerRenderDisplay → IOSurface)
- (UIImage *)shotRenderServer {
    dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    typedef void *(*fCreate)(CFDictionaryRef);
    typedef int (*fLock)(void *, uint32_t, uint32_t *);
    typedef void *(*fBase)(void *);
    typedef size_t (*fBPR)(void *);
    typedef void (*fRender)(int, CFStringRef, void *, int, int);
    fCreate sCreate = (fCreate)dlsym(RTLD_DEFAULT, "IOSurfaceCreate");
    fLock sLock = (fLock)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    fLock sUnlock = (fLock)dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");
    fBase sBase = (fBase)dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
    fBPR sBPR = (fBPR)dlsym(RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
    fRender sRender = (fRender)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    if (!sCreate || !sLock || !sUnlock || !sBase || !sBPR || !sRender) {
        [self log:[NSString stringWithFormat:@"C 缺函数 create=%d lock=%d base=%d render=%d", !!sCreate, !!sLock, !!sBase, !!sRender]];
        return nil;
    }
    int W = (int)UIScreen.mainScreen.nativeBounds.size.width, H = (int)UIScreen.mainScreen.nativeBounds.size.height;
    int bpr = W * 4;
    NSDictionary *props = @{ @"IOSurfaceWidth": @(W), @"IOSurfaceHeight": @(H), @"IOSurfaceBytesPerElement": @4,
                             @"IOSurfaceBytesPerRow": @(bpr), @"IOSurfaceAllocSize": @(bpr * H),
                             @"IOSurfacePixelFormat": @(0x42475241u) };
    void *surf = sCreate((__bridge CFDictionaryRef)props);
    if (!surf) { [self log:@"C IOSurface 建不了"]; return nil; }
    [self log:[NSString stringWithFormat:@"C 调渲染服务 %dx%d", W, H]];
    sRender(0, CFSTR("LCD"), surf, 0, 0);
    sLock(surf, 1, NULL);   // 1 = 只读
    void *base = sBase(surf); size_t realBPR = sBPR(surf);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, W, H, 8, realBPR, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;   // 这里会复制一份像素
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    sUnlock(surf, 1, NULL);
    CFRelease((CFTypeRef)surf);
    if (!cg) { [self log:@"C 转图失败"]; return nil; }
    { int m1=0,m2=0; lab_range(cg,&m1,&m2); [self log:[NSString stringWithFormat:@"C 整屏亮度 %d~%d(整屏也是 0 = 没权限读屏)", m1, m2]]; }
    UIImage *box = [self cropBox:cg]; CGImageRelease(cg);
    return box;
}

- (void)onShot {
    if (!self.presView) { [self log:@"还没嵌入"]; return; }
    [self log:@"== 截图对比(A 视图绘制 / B UIKit 整屏 / C 渲染服务)"];
    CGRect full = UIScreen.mainScreen.bounds;

    // A:原来的方法(对远程画面通常是黑的)
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 2;
    UIImage *imgA = [[[UIGraphicsImageRenderer alloc] initWithSize:full.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGAffineTransform t = self.presView.transform;
        self.presView.transform = CGAffineTransformIdentity;
        [self.presView drawViewHierarchyInRect:CGRectMake(0, 0, full.size.width, full.size.height) afterScreenUpdates:YES];
        self.presView.transform = t;
    }];

    // B:UIKit 私有整屏截图
    UIImage *imgB = nil;
    typedef CGImageRef (*fScreen)(void);
    fScreen sB = (fScreen)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    typedef id (*fScreenUI)(void);
    fScreenUI sB2 = (fScreenUI)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    @try {
        if (sB2) { UIImage *u = sB2(); if (u.CGImage) { int m1=0,m2=0; lab_range(u.CGImage,&m1,&m2); [self log:[NSString stringWithFormat:@"B 整屏亮度 %d~%d", m1, m2]]; imgB = [self cropBox:u.CGImage]; } [self log:[NSString stringWithFormat:@"B 用 _UICreateScreenUIImage:%@", u ? @"有图" : @"空"]]; }
        else if (sB) { CGImageRef c = sB(); if (c) { imgB = [self cropBox:c]; CGImageRelease(c); } [self log:[NSString stringWithFormat:@"B 用 UIGetScreenImage:%@", c ? @"有图" : @"空"]]; }
        else [self log:@"B 两个函数都没有"];
    } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"B 异常 %@", e.reason]]; }

    // C:渲染服务
    UIImage *imgC = nil;
    @try { imgC = [self shotRenderServer]; } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"C 异常 %@", e.reason]]; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self report:@"A" image:imgA];
        [self report:@"B" image:imgB];
        [self report:@"C" image:imgC];
        [self log:@"== 完(亮度范围大且 OCR 有字 = 这种方法能用)"];
    });
}

// lab5:程序发 HID 触摸到小窗里,看嵌入的 App 有没有反应
// 先点小窗里"App 坐标"(195,250)附近(设置首页偏上的一行),2 秒后在小窗里往上滑一下
- (void)onAutoTap {
    if (!self.presView) { [self log:@"还没嵌入"]; return; }
    NSString *e = loadHID();
    if (e.length) { [self log:[NSString stringWithFormat:@"j HID 加载失败:%@", e]]; return; }
    CGRect box = [self.host convertRect:self.host.bounds toView:nil];
    CGFloat k = box.size.width / UIScreen.mainScreen.bounds.size.width;
    double tx = box.origin.x + 195 * k, ty = box.origin.y + 250 * k;
    double sx = box.origin.x + 195 * k, sy1 = box.origin.y + 650 * k, sy2 = box.origin.y + 300 * k;
    [self log:[NSString stringWithFormat:@"j 小窗在屏幕 (%.0f,%.0f) %.0fx%.0f,缩放 %.2f", box.origin.x, box.origin.y, box.size.width, box.size.height, k]];
    [self log:[NSString stringWithFormat:@"j 1 秒后程序点屏幕 (%.0f,%.0f) = App 里 (195,250)", tx, ty]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        sleep(1);
        doTapRaw(tx, ty);
        [self log:@"j 已点。看小窗有没有进到某个设置页"];
        sleep(3);
        [self log:[NSString stringWithFormat:@"j 现在在小窗里往上滑 (%.0f,%.0f)→(%.0f,%.0f)", sx, sy1, sx, sy2]];
        doSwipeSmooth(sx, sy1, sx, sy2, 400, 150);
        [self log:@"j 已滑。看小窗内容有没有滚动。告诉我:点了有没有反应、滑了有没有滚"];
    });
}

// lab6:找"场景快照"接口 —— 按 App 原尺寸出图,和小窗大小无关
// 先列出 FrontBoard 里名字带 Snapshot 的类和场景对象上的快照方法,再逐个试无参数、返回对象的快照方法。
// 每试一个先记下名字;如果闪退,下次自动跳过它。
static NSArray *lab_snapSels(id o) {
    NSMutableArray *r = [NSMutableArray array];
    for (Class c = object_getClass(o); c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned n = 0; Method *ms = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *nm = NSStringFromSelector(method_getName(ms[i]));
            if ([nm rangeOfString:@"napshot" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            const char *t = method_getTypeEncoding(ms[i]);
            [r addObject:@[NSStringFromClass(c), nm, t ? @(t) : @""]];
        }
        free(ms);
    }
    return r;
}

- (UIImage *)imageFrom:(id)o depth:(int)d {
    if (!o || d > 2) return nil;
    if ([o isKindOfClass:UIImage.class]) return o;
    if (CFGetTypeID((__bridge CFTypeRef)o) == CGImageGetTypeID()) return [UIImage imageWithCGImage:(__bridge CGImageRef)o];
    NSArray *cands = @[@"CGImage", @"cgImage", @"image", @"IOSurface", @"ioSurface", @"fallbackIOSurface", @"surface", @"snapshot"];
    for (NSString *n in cands) {
        SEL sel = NSSelectorFromString(n);
        if (![o respondsToSelector:sel]) continue;
        Method m = class_getInstanceMethod(object_getClass(o), sel);
        char rt[64] = {0}; if (m) method_getReturnType(m, rt, sizeof rt);
        [self log:[NSString stringWithFormat:@"  · %@ 有 -%@ (返回 %s)", NSStringFromClass(object_getClass(o)), n, rt]];
        @try {
            if (rt[0] == '^') {
                void *p = ((void *(*)(id, SEL))objc_msgSend)(o, sel);
                if (!p) continue;
                if ([n rangeOfString:@"urface" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    CIImage *ci = [CIImage imageWithIOSurface:(IOSurfaceRef)p];
                    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
                    if (cg) { UIImage *u = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); return u; }
                } else {
                    return [UIImage imageWithCGImage:(CGImageRef)p];
                }
            } else if (rt[0] == '@') {
                id r = ((id (*)(id, SEL))objc_msgSend)(o, sel);
                if (r && r != o) { UIImage *u = [self imageFrom:r depth:d + 1]; if (u) return u; }
            }
        } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"  · 异常 %@", e.reason]]; }
    }
    return nil;
}

- (void)onSnap {
    if (!self.presView) { [self log:@"还没嵌入"]; return; }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableArray *skip = [([ud arrayForKey:@"scenelab_skip"] ?: @[]) mutableCopy];
    NSString *trying = [ud stringForKey:@"scenelab_trying"];
    if (trying.length) { [skip addObject:trying]; [ud setObject:skip forKey:@"scenelab_skip"]; [ud removeObjectForKey:@"scenelab_trying"]; [self log:[NSString stringWithFormat:@"k 上次试 %@ 时闪退,这次跳过", trying]]; }

    // 1) FrontBoard / FrontBoardServices 里名字带 Snapshot 的类
    NSMutableSet *imgs = [NSMutableSet set];
    for (NSString *cn in @[@"FBScene", @"FBSScene", @"FBSSceneSettings", @"_UIScenePresenter"]) {
        Class c = NSClassFromString(cn); const char *im = c ? class_getImageName(c) : NULL;
        if (im) [imgs addObject:@(im)];
    }
    for (NSString *im in imgs) {
        unsigned n = 0; const char **names = objc_copyClassNamesForImage(im.UTF8String, &n);
        NSMutableArray *hit = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) { NSString *cn = @(names[i]); if ([cn rangeOfString:@"napshot" options:NSCaseInsensitiveSearch].location != NSNotFound) [hit addObject:cn]; }
        free(names);
        [self log:[NSString stringWithFormat:@"k %@ 快照类 %lu 个:%@", im.lastPathComponent, (unsigned long)hit.count, [[hit subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)30, hit.count))] componentsJoinedByString:@" "]]];
    }

    // 2) 场景 / presenter / 视图上带 snapshot 的方法
    NSDictionary *objs = @{ @"scene": self.scene ?: NSNull.null, @"presenter": self.presenter ?: NSNull.null, @"view": self.presView ?: NSNull.null };
    NSMutableArray *tries = [NSMutableArray array];
    for (NSString *k in @[@"scene", @"presenter", @"view"]) {
        id o = objs[k]; if (o == NSNull.null) continue;
        NSArray *sels = lab_snapSels(o);
        [self log:[NSString stringWithFormat:@"k %@(%@) 快照方法 %lu 个", k, NSStringFromClass(object_getClass(o)), (unsigned long)sels.count]];
        for (NSArray *x in sels) {
            [self log:[NSString stringWithFormat:@"  %@ -%@ %@", x[0], x[1], x[2]]];
            NSString *nm = x[1], *t = x[2];
            BOOL zeroArg = [nm rangeOfString:@":"].location == NSNotFound;
            BOOL retObj = [t hasPrefix:@"@"];
            NSString *low = nm.lowercaseString;
            BOOL bad = NO;
            for (NSString *w in @[@"invalidate", @"remove", @"delete", @"discard", @"set", @"clear", @"purge", @"destroy", @"cancel", @"_"])
                if ([low hasPrefix:w]) bad = YES;
            NSString *key = [NSString stringWithFormat:@"%@.%@", k, nm];
            if (zeroArg && retObj && !bad && ![skip containsObject:key]) [tries addObject:@[k, nm, key]];
        }
    }

    // 3) 逐个试
    UIImage *got = nil; NSString *how = nil;
    for (NSArray *x in tries) {
        id o = objs[x[0]];
        [ud setObject:x[2] forKey:@"scenelab_trying"]; [ud synchronize];
        [self log:[NSString stringWithFormat:@"k 试 %@", x[2]]];
        @try {
            id r = ((id (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(x[1]));
            [self log:[NSString stringWithFormat:@"  → %@", r ? NSStringFromClass(object_getClass(r)) : @"nil"]];
            UIImage *u = [self imageFrom:r depth:0];
            if (u && !got) { got = u; how = x[2]; }
        } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"  → 异常 %@", e.reason]]; }
        [ud removeObjectForKey:@"scenelab_trying"]; [ud synchronize];
    }
    if (!got) { [self log:@"k 没拿到快照图。把这段日志发我,我按上面列出的方法写下一步"]; return; }
    [self log:[NSString stringWithFormat:@"k 用 %@ 拿到图", how]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self report:@"S" image:got]; [self log:@"== 快照完"]; });
}

// lab7:lab6 找到 FBScene -createSnapshot,能出 1170x2532 原尺寸图但是黑的 —— 多半是没先调 -capture 真正渲染。
// 这版:列出快照对象的全部方法;调 capture 后再取 CGImage / IOSurface;也试带 context 的版本。
static NSString *lab_allSels(Class c) {
    NSMutableArray *r = [NSMutableArray array];
    for (; c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned n = 0; Method *ms = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *t = method_getTypeEncoding(ms[i]);
            [r addObject:[NSString stringWithFormat:@"%@ %s", NSStringFromSelector(method_getName(ms[i])), t ?: ""]];
        }
        free(ms);
    }
    return [r componentsJoinedByString:@"\n   "];
}

- (UIImage *)grab:(id)snap tag:(NSString *)tag {
    if (!snap) { [self log:[NSString stringWithFormat:@"%@ 快照对象=nil", tag]]; return nil; }
    if ([snap respondsToSelector:NSSelectorFromString(@"capture")]) {
        Method m = class_getInstanceMethod(object_getClass(snap), NSSelectorFromString(@"capture"));
        char rt[16] = {0}; if (m) method_getReturnType(m, rt, sizeof rt);
        [self log:[NSString stringWithFormat:@"%@ 调 capture(返回类型 %s)", tag, rt]];
        if (rt[0] == 'B' || rt[0] == 'c') {
            BOOL ok = ((BOOL (*)(id, SEL))objc_msgSend)(snap, NSSelectorFromString(@"capture"));
            [self log:[NSString stringWithFormat:@"%@ capture 返回 %@", tag, ok ? @"YES" : @"NO"]];
        } else {
            ((void (*)(id, SEL))objc_msgSend)(snap, NSSelectorFromString(@"capture"));
            [self log:[NSString stringWithFormat:@"%@ capture 已调", tag]];
        }
    } else [self log:[NSString stringWithFormat:@"%@ 没有 capture 方法", tag]];
    UIImage *best = nil; int bestSpan = -1;
    for (NSString *n in @[@"CGImage", @"IOSurface", @"fallbackIOSurface"]) {
        SEL sel = NSSelectorFromString(n);
        if (![snap respondsToSelector:sel]) continue;
        void *p = ((void *(*)(id, SEL))objc_msgSend)(snap, sel);
        if (!p) { [self log:[NSString stringWithFormat:@"%@ %@=空", tag, n]]; continue; }
        UIImage *u = nil;
        if ([n isEqualToString:@"CGImage"]) u = [UIImage imageWithCGImage:(CGImageRef)p];
        else {
            CIImage *ci = [CIImage imageWithIOSurface:(IOSurfaceRef)p];
            CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
            if (cg) { u = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
        }
        if (!u.CGImage) { [self log:[NSString stringWithFormat:@"%@ %@ 转图失败", tag, n]]; continue; }
        int mn = 0, mx = 0; lab_range(u.CGImage, &mn, &mx);
        [self log:[NSString stringWithFormat:@"%@ %@ %zux%zu 亮度 %d~%d", tag, n, CGImageGetWidth(u.CGImage), CGImageGetHeight(u.CGImage), mn, mx]];
        if (mx - mn > bestSpan) { bestSpan = mx - mn; best = u; }
    }
    return bestSpan >= 10 ? best : nil;
}

- (void)onSnap2 {
    if (!self.scene) { [self log:@"还没嵌入"]; return; }
    [self log:@"== 快照2"];
    @try {
        [self log:[NSString stringWithFormat:@"FBSceneSnapshot 方法:\n   %@", lab_allSels(NSClassFromString(@"FBSceneSnapshot"))]];
        [self log:[NSString stringWithFormat:@"FBSceneSnapshotContext 方法:\n   %@", lab_allSels(NSClassFromString(@"FBSceneSnapshotContext"))]];
    } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"列方法异常 %@", e.reason]]; }

    UIImage *got = nil;
    @try { got = [self grab:MSG0(self.scene, "createSnapshot") tag:@"P1 scene.createSnapshot"]; }
    @catch (NSException *e) { [self log:[NSString stringWithFormat:@"P1 异常 %@", e.reason]]; }
    if (!got) { @try {
        id ctx = MSG0(self.scene, "snapshotContext");
        [self log:[NSString stringWithFormat:@"P2 context=%@", ctx ? @"有" : @"无"]];
        if (ctx && lab_has(ctx, "setScale:")) { MSGD(ctx, "setScale:", UIScreen.mainScreen.scale); [self log:@"P2 已设 scale"]; }
        if (ctx) got = [self grab:MSG1(self.scene, "createSnapshotWithContext:", ctx) tag:@"P2 带 context"];
    } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"P2 异常 %@", e.reason]]; } }
    if (!got) { @try { got = [self grab:MSG0(self.presenter, "newSnapshot") tag:@"P3 presenter.newSnapshot"]; }
    @catch (NSException *e) { [self log:[NSString stringWithFormat:@"P3 异常 %@", e.reason]]; } }

    if (!got) { [self log:@"== 三种都没出有内容的图。整段发我"]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self report:@"S" image:got]; [self log:@"== 快照2 完"]; });
}

// lab9:快照按 App 原尺寸出图(lab8 已成功)。这版测:小窗缩到 30%、完全隐藏、移出屏幕时,快照还能不能拿到内容。
// 每按一次换一种状态并自动拍一张快照:1=缩到30%  2=隐藏(hidden)  3=透明度0  4=移到屏幕外  5=恢复
- (void)quickSnap:(NSString *)tag {
    @try {
        id snap = MSG0(self.scene, "createSnapshot");
        BOOL ok = snap ? ((BOOL (*)(id, SEL))objc_msgSend)(snap, sel_registerName("capture")) : NO;
        CGImageRef cg = (snap && ok) ? ((CGImageRef (*)(id, SEL))objc_msgSend)(snap, sel_registerName("CGImage")) : NULL;
        if (!cg) { [self log:[NSString stringWithFormat:@"%@ 快照失败 capture=%@", tag, ok ? @"YES" : @"NO"]]; return; }
        UIImage *u = [UIImage imageWithCGImage:cg];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self report:tag image:u]; });
    } @catch (NSException *e) { [self log:[NSString stringWithFormat:@"%@ 异常 %@", tag, e.reason]]; }
}

- (void)onShrink {
    if (!self.presView) { [self log:@"还没嵌入"]; return; }
    UIView *pv = self.presView;
    CGFloat k0 = self.host.bounds.size.width / UIScreen.mainScreen.bounds.size.width;
    self.shrinkStep = self.shrinkStep % 5 + 1;
    pv.hidden = NO; pv.alpha = 1; pv.layer.position = CGPointZero;
    NSString *tag = @"";
    switch (self.shrinkStep) {
        case 1: pv.transform = CGAffineTransformMakeScale(0.3, 0.3); tag = @"L1 缩到30%"; break;
        case 2: pv.transform = CGAffineTransformMakeScale(0.3, 0.3); pv.hidden = YES; tag = @"L2 隐藏"; break;
        case 3: pv.transform = CGAffineTransformMakeScale(0.3, 0.3); pv.alpha = 0; tag = @"L3 透明"; break;
        case 4: pv.transform = CGAffineTransformMakeScale(0.3, 0.3); pv.layer.position = CGPointMake(3000, 0); tag = @"L4 移出屏幕"; break;
        default: pv.transform = CGAffineTransformMakeScale(k0, k0); tag = @"L5 恢复"; break;
    }
    [self log:[NSString stringWithFormat:@"%@ —— 1 秒后拍快照", tag]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self quickSnap:tag]; });
}

// lab10:30% 小窗下走一遍完整流程:快照找字 → 换算坐标程序点 → 快照看页面变没变 → 返回 → 下拉出搜索框 → 剪贴板+Cmd+V 打字 → 快照看字进没进去
// OCR 给的 x/y 就是 App 里的坐标(快照是整屏原尺寸),屏幕坐标 = 小窗左上角 + App 坐标 × 缩放
- (NSArray *)snapOCR {
    __block UIImage *u = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            id snap = MSG0(self.scene, "createSnapshot");
            BOOL ok = snap ? ((BOOL (*)(id, SEL))objc_msgSend)(snap, sel_registerName("capture")) : NO;
            CGImageRef cg = ok ? ((CGImageRef (*)(id, SEL))objc_msgSend)(snap, sel_registerName("CGImage")) : NULL;
            if (cg) u = [UIImage imageWithCGImage:cg];
        } @catch (NSException *e) {}
    });
    if (!u) return nil;
    NSString *err = nil;
    return ocrImage(u, &err) ?: @[];
}
static NSString *lab_texts(NSArray *items, int n) {
    NSMutableArray *t = [NSMutableArray array];
    for (NSDictionary *it in items) { if ((int)t.count >= n) break; NSString *s = [it[@"text"] description]; if (s.length) [t addObject:s]; }
    return [t componentsJoinedByString:@" | "];
}
// lab11:OCR 常把图标认成杂字粘在前面(如「©通用」「Q搜索」「<设置」),所以按"包含"匹配,并优先选最短的那条
static NSDictionary *lab_find(NSArray *items, NSString *want, double maxY) {
    NSDictionary *best = nil; NSUInteger bestLen = NSUIntegerMax;
    for (NSDictionary *it in items) {
        NSString *s = [[it[@"text"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (maxY > 0 && [it[@"y"] doubleValue] > maxY) continue;
        if ([s rangeOfString:want].location == NSNotFound) continue;
        if (s.length > want.length + 4) continue;   // 太长的(比如一整句)不算
        if (s.length < bestLen) { best = it; bestLen = s.length; }
    }
    return best;
}

- (void)onFlow {
    if (!self.presView) { [self log:@"还没嵌入"]; return; }
    NSString *he = loadHID(); if (he.length) { [self log:[@"HID 加载失败:" stringByAppendingString:he]]; return; }
    const CGFloat K = 0.3;
    self.presView.hidden = NO; self.presView.alpha = 1; self.presView.layer.position = CGPointZero;
    self.presView.transform = CGAffineTransformMakeScale(K, K);
    CGRect box = [self.host convertRect:self.host.bounds toView:nil];
    CGPoint o = box.origin;
    [self log:[NSString stringWithFormat:@"== 全流程(小窗 30%%,左上角 %.0f,%.0f)", o.x, o.y]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^tapApp)(double, double) = ^(double x, double y) { doTapRaw(o.x + x * K, o.y + y * K); };
        usleep(800 * 1000);
        NSArray *s0 = [self snapOCR];
        [self log:[NSString stringWithFormat:@"m1 快照 OCR %lu 条:%@", (unsigned long)s0.count, lab_texts(s0, 6)]];
        NSDictionary *g = lab_find(s0, @"通用", 0);
        if (!g) { [self log:[NSString stringWithFormat:@"m1 没找到「通用」。全部 OCR:%@", lab_texts(s0, 40)]]; return; }
        [self log:[NSString stringWithFormat:@"m2 「通用」在 App 里 (%@,%@) → 屏幕 (%.0f,%.0f),程序点", g[@"x"], g[@"y"], o.x + [g[@"x"] doubleValue] * K, o.y + [g[@"y"] doubleValue] * K]];
        tapApp([g[@"x"] doubleValue], [g[@"y"] doubleValue]);
        usleep(1500 * 1000);
        NSArray *s1 = [self snapOCR];
        BOOL inGeneral = lab_find(s1, @"关于本机", 0) || lab_find(s1, @"软件更新", 0) || lab_find(s1, @"关于", 0);
        [self log:[NSString stringWithFormat:@"m3 点后快照:%@ —— %@", lab_texts(s1, 6), inGeneral ? @"✓ 进了「通用」,快照跟着变" : @"✗ 页面好像没变"]];
        // 返回:点左上角「设置」返回按钮
        NSDictionary *back = lab_find(s1, @"设置", 200);
        if (back) { [self log:@"m4 点左上角「设置」返回"]; tapApp([back[@"x"] doubleValue], [back[@"y"] doubleValue]); }
        else { [self log:@"m4 没找到返回按钮,从左边缘右滑返回"]; doSwipeSmooth(o.x + 2, o.y + 400 * K, o.x + 300 * K, o.y + 400 * K, 300, 100); }
        usleep(1500 * 1000);
        // 下拉出搜索框
        [self log:@"m5 在小窗里往下拉,露出搜索框"];
        doSwipeSmooth(o.x + 195 * K, o.y + 250 * K, o.x + 195 * K, o.y + 600 * K, 400, 150);
        usleep(1200 * 1000);
        NSArray *s2 = [self snapOCR];
        NSDictionary *sf = lab_find(s2, @"搜索", 0);
        if (!sf) { [self log:[NSString stringWithFormat:@"m6 没找到搜索框。快照:%@", lab_texts(s2, 6)]]; return; }
        [self log:[NSString stringWithFormat:@"m6 点搜索框 App(%@,%@)", sf[@"x"], sf[@"y"]]];
        tapApp([sf[@"x"] doubleValue], [sf[@"y"] doubleValue]);
        usleep(1200 * 1000);
        dispatch_sync(dispatch_get_main_queue(), ^{ UIPasteboard.generalPasteboard.string = @"蓝牙"; });
        [self log:@"m7 剪贴板写「蓝牙」,发 Cmd+V(注意看键盘弹在哪、有没有弹「允许粘贴」)"];
        doCmdKey(0x19);
        usleep(1800 * 1000);
        NSArray *s3 = [self snapOCR];
        NSString *t3 = lab_texts(s3, 8);
        BOOL typed = [t3 containsString:@"蓝牙"];
        [self log:[NSString stringWithFormat:@"m8 打字后快照:%@ —— %@", t3, typed ? @"✓ 看到「蓝牙」" : @"✗ 没看到「蓝牙」"]];
        [self log:@"== 全流程完。告诉我:键盘弹在哪、有没有「允许粘贴」框"];
    });
}

- (void)onClose {
    @try {
        if (self.presenter && lab_has(self.presenter, "invalidate")) MSG0(self.presenter, "invalidate");
        [self.presView removeFromSuperview];
        if (self.scene) {
            id sm = MSG0(lab_cls(@"FBSceneManager"), "sharedInstance");
            if (lab_has(sm, "destroyScene:withTransitionContext:")) MSG2(sm, "destroyScene:withTransitionContext:", MSG0(self.scene, "identifier"), nil);
        }
    } @catch (NSException *e) { [self log:[@"关闭异常:" stringByAppendingString:e.reason ?: e.name]]; }
    self.presView = nil; self.presenter = nil; self.scene = nil;
    [self log:@"已关闭"];
}
@end

UIViewController *sceneLabVC(void) { return [SceneLabVC new]; }
