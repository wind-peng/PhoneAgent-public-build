// lab1:嵌入实验(参考"巨魔分屏"的做法)
// 用 FrontBoard 私有接口把别的 App 的画面嵌进本 App 窗口,测试:
//   1) 能不能嵌进来  2) 不开录屏能不能截到它的画面并 OCR  3) 手点嵌入画面有没有反应
// 全部用运行时调用,每一步写日志;缺类/缺方法只报错不闪退。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
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

- (void)onShot {
    if (!self.presView) { [self log:@"还没嵌入"]; return; }
    CGRect full = UIScreen.mainScreen.bounds;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 2;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:full.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGAffineTransform t = self.presView.transform;
        self.presView.transform = CGAffineTransformIdentity;
        BOOL ok = [self.presView drawViewHierarchyInRect:CGRectMake(0, 0, full.size.width, full.size.height) afterScreenUpdates:YES];
        self.presView.transform = t;
        [self log:[NSString stringWithFormat:@"h drawViewHierarchy 返回 %@", ok ? @"成功" : @"失败"]];
    }];
    // 粗看是不是全空白
    CGImageRef cg = img.CGImage;
    size_t w = 40, h = 80; unsigned char px[40 * 80 * 4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg); CGContextRelease(ctx);
    int minV = 255, maxV = 0;
    for (size_t i = 0; i < w * h; i++) { int v = (px[i*4] + px[i*4+1] + px[i*4+2]) / 3; minV = MIN(minV, v); maxV = MAX(maxV, v); }
    [self log:[NSString stringWithFormat:@"h 截图 %.0fx%.0f,亮度范围 %d~%d(范围很小 = 可能是空白)", img.size.width * img.scale, img.size.height * img.scale, minV, maxV]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        NSArray *items = ocrImage(img, &err);
        NSMutableArray *ts = [NSMutableArray array];
        for (NSDictionary *it in items) { if (ts.count >= 8) break; NSString *t = [it[@"text"] description]; if (t.length) [ts addObject:t]; }
        [self log:[NSString stringWithFormat:@"i OCR 识别到 %lu 条%@:%@", (unsigned long)items.count, err.length ? [@" 错误 " stringByAppendingString:err] : @"", [ts componentsJoinedByString:@" | "]]];
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
