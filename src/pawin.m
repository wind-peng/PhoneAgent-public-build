// v0.9.67 小窗模式:任务里的 App 嵌进 PhoneAgent 右上角的小窗(屏幕的 30%)里跑。
// 画面用场景快照(App 原尺寸,和小窗大小无关),点击/滑动按小窗位置换算,不用屏幕录制、不用来回切 App。
// 做法来自 scene-lab 实验 lab1~lab13(先结束同名进程再嵌入;快照需要 QuartzCore 截屏权限)。
#import "pa_internal.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>

#define W0(o, s)        ((id (*)(id, SEL))objc_msgSend)((o), sel_registerName(s))
#define W1(o, s, a)     ((id (*)(id, SEL, id))objc_msgSend)((o), sel_registerName(s), (a))
#define W2(o, s, a, b)  ((id (*)(id, SEL, id, id))objc_msgSend)((o), sel_registerName(s), (a), (b))
#define WB(o, s, v)     ((void (*)(id, SEL, BOOL))objc_msgSend)((o), sel_registerName(s), (v))
#define WL(o, s, v)     ((void (*)(id, SEL, long))objc_msgSend)((o), sel_registerName(s), (v))
#define WD(o, s, v)     ((void (*)(id, SEL, double))objc_msgSend)((o), sel_registerName(s), (v))
#define WR(o, s, v)     ((void (*)(id, SEL, CGRect))objc_msgSend)((o), sel_registerName(s), (v))

static const double kWinK = 0.3;          // 小窗缩放
static id gWScene, gWPresenter;           // 只在主线程读写
static UIView *gWView;
static UIWindow *gWWin;
static NSString *gWBid;
static volatile BOOL gWActive = NO;
static volatile double gWOX = 0, gWOY = 0; // 小窗左上角(屏幕 pt)
static volatile BOOL gPAFront = YES;       // PhoneAgent 在前台(进后台后不再发触摸,免得点到别的 App)
static BOOL gWHud = NO;                    // lab14:在悬浮层进程里(小窗盖在所有界面上,不用管 PhoneAgent 在不在前台)

// lab14:悬浮层进程把自己的系统级窗口交给小窗用
void winSetHostWindow(UIWindow *w) { gWWin = w; gWHud = YES; gPAFront = YES; }

static Class wC(NSString *n) { return NSClassFromString(n); }
static BOOL wHas(id o, const char *s) { return o && [o respondsToSelector:sel_registerName(s)]; }
static void wMain(dispatch_block_t b) { if (NSThread.isMainThread) b(); else dispatch_sync(dispatch_get_main_queue(), b); }

BOOL winEnabled(void) { return paOn(@"win_mode", NO); }
BOOL winActive(void) { return gWActive; }
NSString *winBid(void) { return gWActive ? gWBid : nil; }
BOOL winTouchBlocked(void) { return gWActive && !gPAFront; }

// 触摸坐标(0~1,按整屏算)换到小窗里:屏幕点 = 小窗左上角 + App 坐标 × 0.3
void winMapNorm(double *nx, double *ny) {
    if (!gWActive) return;
    CGSize s = screenSize();
    *nx = (gWOX + *nx * s.width * kWinK) / s.width;
    *ny = (gWOY + *ny * s.height * kWinK) / s.height;
}

static void wWatchFront(void) {
    if (gWHud) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wMain(^{ gPAFront = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground; });
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) { gPAFront = NO; }];
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) { gPAFront = YES; }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { gPAFront = YES; }];
    });
}

// 结束已在跑的同名 App(微信等已在后台时不结束就嵌不出画面,lab13 验证)
void winKill(NSString *bid) {
    if (!bid.length) return;
    @try {
        Class PC = wC(@"RBSProcessPredicate");
        id pred = [PC respondsToSelector:sel_registerName("predicateMatchingBundleIdentifier:")] ? W1(PC, "predicateMatchingBundleIdentifier:", bid) : nil;
        if (!pred) pred = W1(PC, "predicateMatchingIdentity:", W1(wC(@"RBSProcessIdentity"), "identityForEmbeddedApplicationIdentifier:", bid));
        NSError *err = nil;
        id h = pred ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)(wC(@"RBSProcessHandle"), sel_registerName("handleForPredicate:error:"), pred, &err) : nil;
        int pid = (h && wHas(h, "pid")) ? ((int (*)(id, SEL))objc_msgSend)(h, sel_registerName("pid")) : 0;
        if (pid > 0) { kill(pid, SIGKILL); usleep(800 * 1000); }
    } @catch (NSException *e) {}
}

void winClose(void) {
    wMain(^{
        gWActive = NO;
        @try {
            if (gWPresenter && wHas(gWPresenter, "invalidate")) W0(gWPresenter, "invalidate");
            [gWView removeFromSuperview];
            if (gWScene) {
                id sm = W0(wC(@"FBSceneManager"), "sharedInstance");
                if (wHas(sm, "destroyScene:withTransitionContext:")) W2(sm, "destroyScene:withTransitionContext:", W0(gWScene, "identifier"), nil);
            }
        } @catch (NSException *e) {}
        gWView = nil; gWPresenter = nil; gWScene = nil; gWBid = nil;
        gWWin.hidden = YES;
    });
}

static UIWindow *wWindow(void) { // 主线程
    if (gWWin) return gWWin;
    UIWindowScene *ws = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { ws = (UIWindowScene *)s; if (s.activationState == UISceneActivationStateForegroundActive) break; }
    if (!ws) return nil;
    CGSize sc = UIScreen.mainScreen.bounds.size;
    CGFloat w = round(sc.width * kWinK), h = round(sc.height * kWinK);
    UIWindow *win = [[UIWindow alloc] initWithWindowScene:ws];
    win.frame = CGRectMake(sc.width - w - 8, 54, w, h);
    win.windowLevel = UIWindowLevelAlert + 5;
    win.rootViewController = [UIViewController new];
    win.rootViewController.view.backgroundColor = UIColor.blackColor;
    win.rootViewController.view.clipsToBounds = YES;
    win.layer.borderWidth = 1; win.layer.borderColor = UIColor.systemBlueColor.CGColor;
    win.clipsToBounds = YES;
    gWWin = win;
    return win;
}

// 主线程:进程已启动,建场景并放进小窗
static NSString *wBuildScene(NSString *bid, id identity, id predicate, id manager) {
    @try {
        NSError *err = nil;
        id handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(wC(@"RBSProcessHandle"), sel_registerName("handleForPredicate:error:"), predicate, &err);
        if (!handle) return [NSString stringWithFormat:@"拿不到进程:%@", err.localizedDescription ?: @""];
        if (wHas(handle, "auditToken") && wHas(manager, "registerProcessForAuditToken:")) {
            typedef struct { unsigned int v[8]; } pa_tok_t; // 32 字节结构体,不能当对象取
            pa_tok_t tok = ((pa_tok_t (*)(id, SEL))objc_msgSend)(handle, sel_registerName("auditToken"));
            ((id (*)(id, SEL, pa_tok_t))objc_msgSend)(manager, sel_registerName("registerProcessForAuditToken:"), tok);
        }
        NSString *sceneID = [NSString stringWithFormat:@"sceneID:%@-pawin", bid];
        id def = W0(wC(@"FBSMutableSceneDefinition"), "definition");
        W1(def, "setIdentity:", W1(wC(@"FBSSceneIdentity"), "identityForIdentifier:", sceneID));
        W1(def, "setClientIdentity:", W1(wC(@"FBSSceneClientIdentity"), "identityForProcessIdentity:", identity));
        id spec = W0(wC(@"UIApplicationSceneSpecification"), "specification");
        W1(def, "setSpecification:", spec);
        id params = W1(wC(@"FBSMutableSceneParameters"), "parametersForSpecification:", spec);
        CGRect full = UIScreen.mainScreen.bounds; // App 按整屏布局,显示时缩小
        id settings = [wC(@"UIMutableApplicationSceneSettings") new];
        if (wHas(settings, "setCanShowAlerts:")) WB(settings, "setCanShowAlerts:", YES);
        if (wHas(UIScreen.mainScreen, "displayConfiguration")) W1(settings, "setDisplayConfiguration:", W0(UIScreen.mainScreen, "displayConfiguration"));
        WB(settings, "setForeground:", YES);
        WR(settings, "setFrame:", full);
        WL(settings, "setInterfaceOrientation:", UIInterfaceOrientationPortrait);
        WD(settings, "setLevel:", 1);
        W1(settings, "setPersistenceIdentifier:", NSUUID.UUID.UUIDString);
        if (wHas(settings, "setStatusBarDisabled:")) WB(settings, "setStatusBarDisabled:", YES);
        W1(params, "setSettings:", settings);
        id cs = [wC(@"UIMutableApplicationSceneClientSettings") new];
        WL(cs, "setInterfaceOrientation:", UIInterfaceOrientationPortrait);
        W1(params, "setClientSettings:", cs);
        id sm = W0(wC(@"FBSceneManager"), "sharedInstance");
        if (!wHas(sm, "createSceneWithDefinition:initialParameters:")) return @"系统没有建场景的接口";
        id scene = W2(sm, "createSceneWithDefinition:initialParameters:", def, params);
        if (!scene) return @"场景创建失败";
        id pm = wHas(scene, "uiPresentationManager") ? W0(scene, "uiPresentationManager") : nil;
        id presenter = pm ? W1(pm, "createPresenterWithIdentifier:", sceneID) : nil;
        if (!presenter) return @"拿不到 presenter";
        W0(presenter, "activate");
        UIView *pv = W0(presenter, "presentationView");
        if (![pv isKindOfClass:UIView.class]) return @"presentationView 不是视图";
        UIWindow *win = wWindow();
        if (!win) return @"找不到 PhoneAgent 的窗口场景";
        pv.frame = full;
        pv.layer.anchorPoint = CGPointZero; pv.layer.position = CGPointZero;
        pv.transform = CGAffineTransformMakeScale(kWinK, kWinK);
        [win.rootViewController.view addSubview:pv];
        win.hidden = NO;
        gWOX = win.frame.origin.x; gWOY = win.frame.origin.y;
        gWScene = scene; gWPresenter = presenter; gWView = pv; gWBid = [bid copy];
        gWActive = YES;
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"异常 %@", e.reason ?: e.name];
    }
}

static long wContentState(void) {
    __block long st = -1;
    wMain(^{ if (gWScene && wHas(gWScene, "contentState")) st = ((long (*)(id, SEL))objc_msgSend)(gWScene, sel_registerName("contentState")); });
    return st;
}

// 在小窗里打开 App(后台线程调用;会等到 App 画出第一帧,最多约 10 秒)
BOOL winOpen(NSString *bid, NSString **note) {
    if (!bid.length) { if (note) *note = @"包名为空"; return NO; }
    if (NSThread.isMainThread) { if (note) *note = @"不能在主线程打开小窗"; return NO; }
    wWatchFront();
    if (!gPAFront) { if (note) *note = @"PhoneAgent 不在前台,小窗看不到"; return NO; }
    NSArray *need = @[@"RBSProcessIdentity", @"RBSProcessPredicate", @"RBSProcessHandle", @"FBProcessManager",
                      @"FBMutableProcessExecutionContext", @"FBApplicationProcessLaunchTransaction", @"FBSceneManager",
                      @"FBSMutableSceneDefinition", @"FBSSceneIdentity", @"FBSSceneClientIdentity",
                      @"UIApplicationSceneSpecification", @"FBSMutableSceneParameters",
                      @"UIMutableApplicationSceneSettings", @"UIMutableApplicationSceneClientSettings"];
    for (NSString *n in need) if (!wC(n)) { if (note) *note = [@"系统缺少 " stringByAppendingString:n]; return NO; }
    winClose();
    winKill(bid);
    __block NSString *fail = @"启动超时";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id keepTx = nil;
    wMain(^{
        @try {
            id identity = W1(wC(@"RBSProcessIdentity"), "identityForEmbeddedApplicationIdentifier:", bid);
            id predicate = W1(wC(@"RBSProcessPredicate"), "predicateMatchingIdentity:", identity);
            id manager = W0(wC(@"FBProcessManager"), "sharedInstance");
            if (!identity || !manager) { fail = @"拿不到进程身份"; dispatch_semaphore_signal(sem); return; }
            id (^provider)(void) = ^id(void) {
                @try {
                    id ctx = [wC(@"FBMutableProcessExecutionContext") new];
                    W1(ctx, "setIdentity:", identity);
                    W1(ctx, "setEnvironment:", @{});
                    WL(ctx, "setLaunchIntent:", 4);
                    return W1(manager, "launchProcessWithContext:", ctx);
                } @catch (NSException *e) { return nil; }
            };
            id tx = W2([wC(@"FBApplicationProcessLaunchTransaction") alloc], "initWithProcessIdentity:executionContextProvider:", identity, provider);
            if (!tx) { fail = @"启动事务创建失败"; dispatch_semaphore_signal(sem); return; }
            W1(tx, "setCompletionBlock:", (id)^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    fail = wBuildScene(bid, identity, predicate, manager);
                    dispatch_semaphore_signal(sem);
                });
            });
            keepTx = tx;
            W0(tx, "begin");
        } @catch (NSException *e) {
            fail = [NSString stringWithFormat:@"异常 %@", e.reason ?: e.name];
            dispatch_semaphore_signal(sem);
        }
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))) != 0) {
        keepTx = nil;
        winClose();
        if (note) *note = @"启动超时(10 秒)";
        return NO;
    }
    keepTx = nil;
    if (fail) { winClose(); if (note) *note = fail; return NO; }
    for (int i = 0; i < 40 && wContentState() != 2; i++) usleep(200 * 1000); // 等 App 画出第一帧(微信约 2~4 秒)
    usleep(500 * 1000);
    if (note) *note = wContentState() == 2 ? @"已在小窗打开" : @"已在小窗打开(画面可能还在加载)";
    return YES;
}

// 小窗 App 的整屏快照(像素尺寸,如 1170×2532);深拷贝一份,免得快照对象释放后图被回收
UIImage *winSnapshot(NSString **err) {
    if (!gWActive) { if (err) *err = @"小窗没开"; return nil; }
    __block UIImage *out = nil; __block NSString *e = nil;
    wMain(^{
        @try {
            id snap = gWScene ? W0(gWScene, "createSnapshot") : nil;
            BOOL ok = snap && wHas(snap, "capture") ? ((BOOL (*)(id, SEL))objc_msgSend)(snap, sel_registerName("capture")) : NO;
            CGImageRef cg = ok ? ((CGImageRef (*)(id, SEL))objc_msgSend)(snap, sel_registerName("CGImage")) : NULL;
            if (!cg) { e = @"小窗快照失败"; return; }
            size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipLast);
            CGColorSpaceRelease(cs);
            if (!ctx) { e = @"快照拷贝失败"; return; }
            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
            CGImageRef copy = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
            if (copy) { out = [UIImage imageWithCGImage:copy scale:1 orientation:UIImageOrientationUp]; CGImageRelease(copy); }
            else e = @"快照拷贝失败";
        } @catch (NSException *x) { e = [NSString stringWithFormat:@"快照异常 %@", x.reason ?: x.name]; }
    });
    if (!out && err) *err = e;
    return out;
}
