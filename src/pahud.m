// lab14 悬浮小窗:照巨魔分屏 / TrollSpeed 的做法,把小窗放进一个单独的“悬浮层进程”。
// PhoneAgent 用 root 身份再启动自己一份(参数 -pahud 包名),这份不走普通 App 流程,
// 只建一个系统级窗口并向 SpringBoard 登记(SBSAccessibilityWindowHostingController),所以能盖在主屏和其他 App 上。
// 悬浮层进程里复用 pawin.m 的嵌入/快照/换算点击,自己跑一遍测试流程,日志写到文件,PhoneAgent 的实验页读出来显示。
#import "pa_internal.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <mach-o/dyld.h>

extern char **environ;
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

#define HUD_LOG @"/var/mobile/Library/Caches/pa_hud.log"
#define HUD_PID @"/var/mobile/Library/Caches/pa_hud.pid"

static NSString *gHudBid;
static int hudClipChild(NSString *text);
static UIWindow *gHudWin;

// ---------- 悬浮层进程里写日志(PhoneAgent 那边读) ----------
static void hlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void hlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss"; });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:NSDate.date], s];
    @synchronized (HUD_LOG) {
        FILE *f = fopen(HUD_LOG.UTF8String, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
        chmod(HUD_LOG.UTF8String, 0666);
    }
}

// ---------- 悬浮窗口:系统级窗口,不归普通 App 场景管 ----------
@interface PAHudWindow : UIWindow @end
@implementation PAHudWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
@end

static NSDictionary *hFind(NSArray *items, NSString *want, double maxY) {
    NSDictionary *best = nil; NSUInteger bestLen = NSUIntegerMax;
    for (NSDictionary *it in items) {
        NSString *s = [[it[@"text"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (maxY > 0 && [it[@"y"] doubleValue] > maxY) continue;
        if ([s rangeOfString:want].location == NSNotFound) continue;
        if (s.length > want.length + 4) continue;
        if (s.length < bestLen) { best = it; bestLen = s.length; }
    }
    return best;
}
static NSString *hTexts(NSArray *items, int n) {
    NSMutableArray *t = [NSMutableArray array];
    for (NSDictionary *it in items) { if ((int)t.count >= n) break; NSString *s = [it[@"text"] description]; if (s.length) [t addObject:s]; }
    return [t componentsJoinedByString:@" | "];
}
static NSArray *hOCR(void) {
    NSString *e = nil;
    UIImage *u = winSnapshot(&e);
    if (!u) { hlog(@"快照失败:%@", e ?: @""); return nil; }
    NSString *oe = nil;
    NSArray *r = ocrImage(u, &oe);
    if (!r) hlog(@"OCR 失败:%@", oe ?: @"");
    return r ?: @[];
}

// 测试流程(后台线程)。点击/滑动传 App 里的坐标,sendFinger 会按小窗位置换算
static void hudFlow(void) {
    NSString *note = nil;
    hlog(@"h1 在悬浮窗里打开 %@ …", gHudBid);
    if (!winOpen(gHudBid, &note)) { hlog(@"h1 ✗ 打开失败:%@", note ?: @""); return; }
    hlog(@"h1 ✓ %@", note ?: @"");
    NSString *he = loadHID();
    if (he.length) { hlog(@"HID 加载失败:%@", he); return; }
    for (int i = 20; i > 0; i -= 4) {
        hlog(@"h2 回主屏或开别的 App;按住橙条左边拖=移动,按住右边「⤡」拖=放大缩小(%d 秒后开始自动点)", i);
        sleep(4);
    }
    hlog(@"h3 开始自动点:小窗左上角 (%.0f,%.0f) 缩放 %.0f%%", gHudWin.frame.origin.x, gHudWin.frame.origin.y, winScale() * 100);
    NSArray *s0 = hOCR();
    hlog(@"m1 快照 OCR %lu 条:%@", (unsigned long)s0.count, hTexts(s0, 6));
    if (![gHudBid isEqualToString:@"com.apple.Preferences"]) {
        hlog(@"不是「设置」,只测显示和快照。下面每 5 秒拍一次,共 6 次");
        for (int i = 0; i < 6; i++) { sleep(5); NSArray *s = hOCR(); hlog(@"w%d %@", i + 1, hTexts(s, 6)); }
        hlog(@"== 完。告诉我:悬浮窗是不是一直盖在主屏/别的 App 上");
        return;
    }
    NSDictionary *g = nil;
    for (NSString *w in @[@"通用", @"诵用", @"显示与亮度", @"控制中心"]) { g = hFind(s0, w, 0); if (g) break; }
    if (!g) { hlog(@"m1 没找到「通用」。全部 OCR:%@", hTexts(s0, 40)); return; }
    hlog(@"m2 点「%@」App(%@,%@)", g[@"text"], g[@"x"], g[@"y"]);
    doTapRaw([g[@"x"] doubleValue], [g[@"y"] doubleValue]);
    usleep(1500 * 1000);
    NSArray *s1 = hOCR();
    BOOL moved = !hFind(s1, @"飞行模式", 0);
    hlog(@"m3 点后:%@ —— %@", hTexts(s1, 6), moved ? @"✓ 进了下一页" : @"✗ 页面没变");
    NSDictionary *back = hFind(s1, @"设置", 200);
    if (back) { hlog(@"m4 点「设置」返回"); doTapRaw([back[@"x"] doubleValue], [back[@"y"] doubleValue]); }
    else { hlog(@"m4 没找到返回,左边缘右滑"); doSwipeSmooth(2, 400, 300, 400, 300, 100); }
    usleep(1500 * 1000);
    hlog(@"m5 小窗里往下拉,露出搜索框");
    doSwipeSmooth(195, 250, 195, 600, 400, 150);
    usleep(1200 * 1000);
    NSArray *s2 = hOCR();
    NSDictionary *sf = hFind(s2, @"搜索", 0);
    if (!sf) { hlog(@"m6 没找到搜索框:%@", hTexts(s2, 6)); }
    else {
        hlog(@"m6 点搜索框 App(%@,%@)", sf[@"x"], sf[@"y"]);
        doTapRaw([sf[@"x"] doubleValue], [sf[@"y"] doubleValue]);
        usleep(1200 * 1000);
        // lab16:悬浮层是 root,直接写剪贴板写不进(lab15 实测)。试两种:①临时切成 mobile 身份写;②起一个 mobile 身份的子进程写
        __block BOOL pbOK = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            uid_t old = geteuid();
            int r = seteuid(501);
            @try { UIPasteboard.generalPasteboard.string = @"蓝牙"; pbOK = [UIPasteboard.generalPasteboard.string isEqualToString:@"蓝牙"]; } @catch (NSException *e) {}
            if (r == 0) seteuid(old);
        });
        hlog(@"m7a 切 mobile 身份写「蓝牙」:读回%@,发 Cmd+V", pbOK ? @"一致" : @"不一致");
        doCmdKey(0x19);
        usleep(1800 * 1000);
        NSString *t3 = hTexts(hOCR(), 8);
        BOOL a = [t3 containsString:@"蓝牙"];
        hlog(@"m8a 粘贴后:%@ —— %@", t3, a ? @"✓ ①能用" : @"✗ ①不行");
        int st = hudClipChild(@"无线");
        hlog(@"m7b 子进程(mobile)写「无线」:退出码 %d(0=读回一致),发 Cmd+V", st);
        doCmdKey(0x19);
        usleep(1800 * 1000);
        NSString *t4 = hTexts(hOCR(), 8);
        hlog(@"m8b 粘贴后:%@ —— %@", t4, [t4 containsString:@"无线"] ? @"✓ ②能用" : @"✗ ②不行");
    }
    hlog(@"== 全流程完。告诉我:测试时你在哪个界面、悬浮窗在不在、键盘弹在哪。悬浮窗 5 分钟后自动关,或在实验页点「14 关」");
}

// ---------- lab15:拖动 / 放大缩小 ----------
#define HUD_BAR 26.0
static UIView *gHudBar, *gHudContent;
static int gDragMode = 0;           // 0 没拖;1 移动;2 改大小
static CGPoint gDragP0, gDragO0;
static double gDragK0;

// 主线程:按左上角和缩放重新摆小窗
static void hudLayout(CGPoint o, double k) {
    CGSize sc = UIScreen.mainScreen.bounds.size;
    k = MAX(0.2, MIN(0.85, k));
    CGFloat w = round(sc.width * k), h = round(sc.height * k);
    o.x = MAX(0, MIN(sc.width - w, o.x));
    o.y = MAX(0, MIN(sc.height - h - HUD_BAR, o.y));
    gHudWin.frame = CGRectMake(o.x, o.y, w, h + HUD_BAR);
    gHudWin.rootViewController.view.frame = gHudWin.bounds;
    gHudBar.frame = CGRectMake(0, 0, w, HUD_BAR);
    [gHudBar viewWithTag:1].frame = CGRectMake(0, 0, w * 0.6, HUD_BAR);
    [gHudBar viewWithTag:2].frame = CGRectMake(w * 0.6, 0, w * 0.4, HUD_BAR);
    gHudContent.frame = CGRectMake(0, HUD_BAR, w, h);
    winSetScale(k);
    winRefreshOrigin();
}

static Class gAXRep;
// 悬浮层收到的触摸(只有落在我们自己窗口上的才会送来,小窗里 App 画面上的触摸直接给那个 App)
static void hudHIDCallback(void *target, void *refcon, void *service, void *event) {
    if (!event || !gAXRep) return;
    id rep = ((id (*)(id, SEL, void *, id))objc_msgSend)(gAXRep, sel_registerName("representationWithHIDEvent:hidStreamIdentifier:"), event, @"UIApplicationEvents");
    if (!rep) return;
    CGPoint p = ((CGPoint (*)(id, SEL))objc_msgSend)(rep, sel_registerName("location"));
    BOOL down = ((BOOL (*)(id, SEL))objc_msgSend)(rep, sel_registerName("isTouchDown"));
    BOOL move = ((BOOL (*)(id, SEL))objc_msgSend)(rep, sel_registerName("isMove"));
    BOOL lift = ((BOOL (*)(id, SEL))objc_msgSend)(rep, sel_registerName("isLift")) || ((BOOL (*)(id, SEL))objc_msgSend)(rep, sel_registerName("isCancel"));
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gHudWin) return;
        CGRect f = gHudWin.frame;
        if (down) {
            CGRect bar = CGRectMake(f.origin.x, f.origin.y, f.size.width, HUD_BAR + 6);
            if (CGRectContainsPoint(bar, p)) {
                gDragMode = (p.x > f.origin.x + f.size.width * 0.55) ? 2 : 1;
                gDragP0 = p; gDragO0 = f.origin; gDragK0 = winScale();
            } else gDragMode = 0;
        } else if (move && gDragMode) {
            CGSize sc = UIScreen.mainScreen.bounds.size;
            double dx = p.x - gDragP0.x, dy = p.y - gDragP0.y;
            if (gDragMode == 1) hudLayout(CGPointMake(gDragO0.x + dx, gDragO0.y + dy), gDragK0);
            else hudLayout(gDragO0, gDragK0 + (dx / sc.width + dy / sc.height) / 2);
        } else if (lift && gDragMode) {
            hlog(@"小窗%@:左上角 (%.0f,%.0f) 缩放 %.0f%%", gDragMode == 1 ? @"移动" : @"改大小", gHudWin.frame.origin.x, gHudWin.frame.origin.y, winScale() * 100);
            gDragMode = 0;
        }
    });
}

@interface PAHudDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) id hosting;
@end
@implementation PAHudDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    hlog(@"悬浮层进程启动 pid=%d uid=%d", getpid(), getuid());
    @try {
        CGSize sc = UIScreen.mainScreen.bounds.size;
        PAHudWindow *win = [[PAHudWindow alloc] initWithFrame:CGRectMake(sc.width - round(sc.width * 0.3) - 8, 54, 10, 10)];
        win.rootViewController = [UIViewController new];
        win.rootViewController.view.backgroundColor = UIColor.blackColor;
        win.layer.borderWidth = 1.5; win.layer.borderColor = UIColor.systemOrangeColor.CGColor;
        win.layer.cornerRadius = 6;
        win.clipsToBounds = YES;
        // 顶上的拖动条:左边按住拖=移动,右边「⤡」按住拖=放大缩小
        UIView *bar = [UIView new];
        bar.backgroundColor = UIColor.systemOrangeColor;
        UILabel *l1 = [UILabel new]; l1.text = @" ≡ 拖动"; l1.font = [UIFont boldSystemFontOfSize:12]; l1.textColor = UIColor.whiteColor;
        UILabel *l2 = [UILabel new]; l2.text = @"⤡ "; l2.font = [UIFont boldSystemFontOfSize:16]; l2.textColor = UIColor.whiteColor; l2.textAlignment = NSTextAlignmentRight;
        l1.tag = 1; l2.tag = 2;
        [bar addSubview:l1]; [bar addSubview:l2];
        UIView *content = [UIView new];
        content.backgroundColor = UIColor.blackColor;
        content.clipsToBounds = YES;
        [win.rootViewController.view addSubview:content];
        [win.rootViewController.view addSubview:bar];
        gHudBar = bar; gHudContent = content;
        win.windowLevel = 10000010.0;
        win.hidden = NO;
        [win makeKeyAndVisible];
        self.window = win;
        gHudWin = win;
        winSetHostWindow(win, content);
        hudLayout(win.frame.origin, 0.3);
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        Class HC = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        unsigned int cid = [win respondsToSelector:sel_registerName("_contextId")] ? ((unsigned int (*)(id, SEL))objc_msgSend)(win, sel_registerName("_contextId")) : 0;
        if (HC && cid) {
            self.hosting = [HC new];
            ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(self.hosting, sel_registerName("registerWindowWithContextID:atLevel:"), cid, win.windowLevel);
            hlog(@"悬浮窗已登记 context=%u", cid);
        } else hlog(@"✗ 登记悬浮窗失败 HC=%@ context=%u", HC, cid);
    } @catch (NSException *e) { hlog(@"✗ 建悬浮窗异常 %@", e.reason ?: e.name); }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try { hudFlow(); } @catch (NSException *e) { hlog(@"✗ 流程异常 %@", e.reason ?: e.name); }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hlog(@"5 分钟到,悬浮层退出");
        winClose();
        exit(0);
    });
    return YES;
}
@end

static void hudUncaught(NSException *e) {
    hlog(@"!! 未捕获异常 %@ %@\n%@", e.name, e.reason, [[e.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, e.callStackSymbols.count))] componentsJoinedByString:@"\n"]);
}

// 悬浮层进程入口(main.m 看到 -pahud 时调用)
int paHudMain(int argc, char *argv[]) {
    @autoreleasepool {
        gHudBid = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"com.apple.Preferences";
        [[NSString stringWithFormat:@"%d", getpid()] writeToFile:HUD_PID atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(HUD_PID.UTF8String, 0666);
        NSSetUncaughtExceptionHandler(&hudUncaught);
        hlog(@"== lab14 悬浮层启动,目标 %@", gHudBid);
        void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW);
        void *bk = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        void (*GSInit)(void) = gs ? dlsym(gs, "GSInitialize") : NULL;
        void (*GSEvInit)(Boolean) = gs ? dlsym(gs, "GSEventInitialize") : NULL;
        void (*GSPush)(CFStringRef) = gs ? dlsym(gs, "GSEventPushRunLoopMode") : NULL;
        void (*BKStart)(void) = bk ? dlsym(bk, "BKSDisplayServicesStart") : NULL;
        void (*UIInit)(void) = dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
        void (*UISingleton)(Class) = dlsym(RTLD_DEFAULT, "UIApplicationInstantiateSingleton");
        if (!GSInit || !BKStart || !UIInit || !UISingleton) {
            hlog(@"✗ 缺少系统函数 GS=%p BK=%p UIInit=%p UISingleton=%p", GSInit, BKStart, UIInit, UISingleton);
            return 1;
        }
        [UIScreen initialize];
        CFRunLoopGetCurrent();
        GSInit();
        BKStart();
        UIInit();
        UISingleton(UIApplication.class);
        static PAHudDelegate *del; del = [PAHudDelegate new];
        UIApplication.sharedApplication.delegate = del;
        if ([UIApplication.sharedApplication respondsToSelector:sel_registerName("_accessibilityInit")])
            ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, sel_registerName("_accessibilityInit"));
        [NSRunLoop currentRunLoop];
        if (GSEvInit) GSEvInit(0);
        if (GSPush) GSPush(kCFRunLoopDefaultMode);
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
        gAXRep = NSClassFromString(@"AXEventRepresentation");
        void *(*BKSReg)(void *) = bk ? dlsym(bk, "BKSHIDEventRegisterEventCallback") : NULL;
        if (BKSReg && gAXRep) { BKSReg((void *)hudHIDCallback); hlog(@"触摸回调已接上(可拖动/改大小)"); }
        else hlog(@"✗ 触摸回调没接上 BKSReg=%p AX=%@", BKSReg, gAXRep);
        hlog(@"UIKit 初始化完成,进入运行");
        ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, sel_registerName("__completeAndRunAsPlugin"));
        CFRunLoopRun();
        return 0;
    }
}

// 结束悬浮层(root 身份启动,PhoneAgent 自己是 mobile,杀不了 root 进程)
int paHudExitMain(void) {
    NSString *p = [NSString stringWithContentsOfFile:HUD_PID encoding:NSUTF8StringEncoding error:nil];
    if (p.intValue > 0) kill(p.intValue, SIGKILL);
    unlink(HUD_PID.UTF8String);
    return 0;
}

// ---------- PhoneAgent 这边:用 root 身份再启动自己一份 ----------
static NSString *hudSpawn(const char *arg, const char *arg2, BOOL wait) {
    uint32_t sz = 0; _NSGetExecutablePath(NULL, &sz);
    char *exe = calloc(1, sz + 1); _NSGetExecutablePath(exe, &sz);
    posix_spawnattr_t attr; posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (!wait) { posix_spawnattr_setpgroup(&attr, 0); posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP); }
    const char *args[] = { exe, arg, arg2, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    free(exe);
    if (rc != 0) return [NSString stringWithFormat:@"启动失败 %s", strerror(rc)];
    if (wait) { int st = 0; waitpid(pid, &st, 0); }
    else { int st = 0; waitpid(pid, &st, WNOHANG); }
    return [NSString stringWithFormat:@"已启动 pid=%d", pid];
}

NSString *hudStart(NSString *bid) {
    unlink(HUD_LOG.UTF8String);
    hudSpawn("-pahudexit", NULL, YES);
    return hudSpawn("-pahud", bid.UTF8String ?: "com.apple.Preferences", NO);
}
NSString *hudStop(void) { return hudSpawn("-pahudexit", NULL, YES); }
NSString *hudReadLog(void) { return [NSString stringWithContentsOfFile:HUD_LOG encoding:NSUTF8StringEncoding error:nil] ?: @""; }

// lab16:以 mobile(uid 501)身份起一个子进程写剪贴板,返回子进程退出码
static int hudClipChild(NSString *text) {
    uint32_t sz = 0; _NSGetExecutablePath(NULL, &sz);
    char *exe = calloc(1, sz + 1); _NSGetExecutablePath(exe, &sz);
    posix_spawnattr_t attr; posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 501);
    posix_spawnattr_set_persona_gid_np(&attr, 501);
    const char *args[] = { exe, "-paclip", text.UTF8String, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr); free(exe);
    if (rc != 0) { hlog(@"子进程启动失败 %s", strerror(rc)); return -1; }
    int stt = 0, i = 0;
    for (; i < 50 && waitpid(pid, &stt, WNOHANG) == 0; i++) usleep(100 * 1000); // 最多等 5 秒
    if (i >= 50) { kill(pid, SIGKILL); waitpid(pid, &stt, 0); hlog(@"子进程 5 秒没结束,已结束它"); return -2; }
    return WIFEXITED(stt) ? WEXITSTATUS(stt) : 100 + (WIFSIGNALED(stt) ? WTERMSIG(stt) : 0);
}
// 子进程入口:写剪贴板,读回一致返回 0
int paClipMain(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 3) return 2;
        NSString *t = [NSString stringWithUTF8String:argv[2]];
        UIPasteboard.generalPasteboard.string = t;
        return [UIPasteboard.generalPasteboard.string isEqualToString:t] ? 0 : 1;
    }
}
