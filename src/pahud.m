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

// 文件名带端口号,正式版(8200)和实验版(8201)同时装着也不会互相干扰
#define HUD_DIR @"/var/mobile/Library/Caches/"
#define HUD_LOG [NSString stringWithFormat:HUD_DIR @"pa_hud_%d.log", PORT]
#define HUD_PID [NSString stringWithFormat:HUD_DIR @"pa_hud_%d.pid", PORT]
#define HUD_GEO [NSString stringWithFormat:HUD_DIR @"pa_hud_%d.geo", PORT]
#define HUD_PORT (PORT + 100)   // 悬浮层自己的本机接口:正式版 8300,实验版 8301

static NSString *gHudBid, *gHudPAKey;
static BOOL gHudServe = NO;     // v0.9.73:给 PhoneAgent 跑任务用(不是实验页的自测)
static pid_t gHudPAPid = 0;
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
    @synchronized (NSFileManager.class) {
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

// 请 PhoneAgent 本体(mobile 身份的正常 App)写剪贴板,返回说明
static NSString *hudClipViaPA(NSString *text) {
    NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%d/clip?key=%@", PORT, gHudPAKey ?: @""];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
    rq.HTTPMethod = @"POST"; rq.HTTPBody = [text dataUsingEncoding:NSUTF8StringEncoding]; rq.timeoutInterval = 4;
    __block NSString *res = @"没回应(PhoneAgent 可能被系统挂起)";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([j isKindOfClass:NSDictionary.class]) {
                long st = [j[@"state"] longValue];
                res = [NSString stringWithFormat:@"%@(PhoneAgent 状态:%@)", [j[@"ok"] boolValue] ? @"写入成功" : @"写入失败",
                       st == 0 ? @"前台" : st == 1 ? @"非活跃" : st == 2 ? @"后台" : @"未知"];
            } else res = [NSString stringWithFormat:@"回应看不懂 HTTP %ld", (long)((NSHTTPURLResponse *)r).statusCode];
        } else if (e) res = [NSString stringWithFormat:@"连不上:%@", e.localizedDescription];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    return res;
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
        // lab18:加了系统用的剪贴板后台权限(com.apple.Pasteboard.background-access)。①悬浮层自己写;②请 PhoneAgent 代写
        __block BOOL pbOK = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try { UIPasteboard.generalPasteboard.string = @"蓝牙"; pbOK = [UIPasteboard.generalPasteboard.string isEqualToString:@"蓝牙"]; } @catch (NSException *e) {}
        });
        hlog(@"m7a 悬浮层自己写「蓝牙」:读回%@,发 Cmd+V", pbOK ? @"一致" : @"不一致");
        doCmdKey(0x19);
        usleep(1800 * 1000);
        NSString *t3 = hTexts(hOCR(), 8);
        hlog(@"m8a 粘贴后:%@ —— %@", t3, [t3 containsString:@"蓝牙"] ? @"✓ ①能用" : @"✗ ①不行");
        NSString *r = hudClipViaPA(@"无线");
        hlog(@"m7b 请 PhoneAgent 写「无线」:%@,发 Cmd+V", r);
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
                winRefreshOrigin(); // 写一下“正在拖”,PhoneAgent 这时先不点
            } else gDragMode = 0;
        } else if (move && gDragMode) {
            CGSize sc = UIScreen.mainScreen.bounds.size;
            double dx = p.x - gDragP0.x, dy = p.y - gDragP0.y;
            if (gDragMode == 1) hudLayout(CGPointMake(gDragO0.x + dx, gDragO0.y + dy), gDragK0);
            else hudLayout(gDragO0, gDragK0 + (dx / sc.width + dy / sc.height) / 2);
        } else if (lift && gDragMode) {
            hlog(@"小窗%@:左上角 (%.0f,%.0f) 缩放 %.0f%%", gDragMode == 1 ? @"移动" : @"改大小", gHudWin.frame.origin.x, gHudWin.frame.origin.y, winScale() * 100);
            gDragMode = 0;
            winRefreshOrigin(); // 松手:写新位置,PhoneAgent 接着点
        }
    });
}


// ---------- v0.9.73:悬浮层的本机接口(只给 PhoneAgent 用,带钥匙) ----------
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
static void hSend(int c, int code, NSString *type, NSData *body) {
    NSString *h = [NSString stringWithFormat:@"HTTP/1.1 %d OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", code, type, (unsigned long)body.length];
    NSMutableData *d = [[h dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [d appendData:body];
    const uint8_t *p = d.bytes; size_t left = d.length;
    while (left > 0) { ssize_t n = write(c, p, left); if (n <= 0) break; p += n; left -= n; }
    close(c);
}
static void hJSON(int c, int code, NSDictionary *j) {
    hSend(c, code, @"application/json", [NSJSONSerialization dataWithJSONObject:j options:0 error:nil]);
}
static void hHandle(int c) {
    char buf[4096]; ssize_t n = read(c, buf, sizeof buf - 1);
    if (n <= 0) { close(c); return; }
    buf[n] = 0;
    NSString *head = [NSString stringWithUTF8String:buf] ?: @"";
    NSArray *parts = [[[head componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
    if (parts.count < 2) { close(c); return; }
    NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://h" stringByAppendingString:parts[1]]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
    if (!gHudPAKey.length || ![q[@"key"] isEqualToString:gHudPAKey]) { hJSON(c, 403, @{@"ok": @NO}); return; }
    NSString *path = uc.path ?: @"/";
    if ([path isEqualToString:@"/ping"]) { hJSON(c, 200, @{@"ok": @YES, @"active": @(winActive())}); return; }
    if ([path isEqualToString:@"/open"]) {
        NSString *note = nil;
        BOOL ok = winOpen(q[@"bid"] ?: @"", &note);
        hlog(@"打开 %@:%@", q[@"bid"], ok ? (note ?: @"成功") : (note ?: @"失败"));
        hJSON(c, 200, @{@"ok": @(ok), @"note": note ?: @""});
        return;
    }
    if ([path isEqualToString:@"/close"]) { winClose(); hJSON(c, 200, @{@"ok": @YES}); return; }
    if ([path isEqualToString:@"/snap"]) {
        NSString *e = nil;
        UIImage *u = winSnapshot(&e);
        NSData *d = u ? UIImageJPEGRepresentation(u, 0.85) : nil;
        if (d.length) hSend(c, 200, @"image/jpeg", d);
        else hJSON(c, 500, @{@"ok": @NO, @"error": e ?: @"快照失败"});
        return;
    }
    hJSON(c, 404, @{@"ok": @NO});
}
static void hudServeStart(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET; a.sin_port = htons(HUD_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock, (struct sockaddr *)&a, sizeof a) != 0 || listen(sock, 8) != 0) { hlog(@"✗ 接口端口 %d 打不开", HUD_PORT); exit(1); }
    hlog(@"接口已开 %d", HUD_PORT);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            int c = accept(sock, NULL, NULL);
            if (c < 0) continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { hHandle(c); } });
        }
    });
    // PhoneAgent 没了(闪退/被杀),悬浮层也跟着退,不留一个关不掉的窗
    if (gHudPAPid > 0) {
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{
            if (kill(gHudPAPid, 0) != 0 && errno == ESRCH) { hlog(@"PhoneAgent 已退出,悬浮层也退出"); winClose(); exit(0); }
        });
        dispatch_resume(t);
        static dispatch_source_t keep; keep = t;
    }
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
        if (gHudServe) hlog(@"悬浮层待命,等 PhoneAgent 打开 App");
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        Class HC = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        unsigned int cid = [win respondsToSelector:sel_registerName("_contextId")] ? ((unsigned int (*)(id, SEL))objc_msgSend)(win, sel_registerName("_contextId")) : 0;
        if (HC && cid) {
            self.hosting = [HC new];
            ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(self.hosting, sel_registerName("registerWindowWithContextID:atLevel:"), cid, win.windowLevel);
            hlog(@"悬浮窗已登记 context=%u", cid);
        } else hlog(@"✗ 登记悬浮窗失败 HC=%@ context=%u", HC, cid);
        if (gHudServe) self.window.hidden = YES; // 打开 App 时才显示
    } @catch (NSException *e) { hlog(@"✗ 建悬浮窗异常 %@", e.reason ?: e.name); }
    if (gHudServe) { hudServeStart(); return YES; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try { hudFlow(); } @catch (NSException *e) { hlog(@"✗ 流程异常 %@", e.reason ?: e.name); }
    });
    if (!gHudServe) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        gHudPAKey = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"";
        gHudServe = argc > 4 && strcmp(argv[4], "serve") == 0;
        gHudPAPid = argc > 5 ? (pid_t)atoi(argv[5]) : 0;
        [[NSString stringWithFormat:@"%d", getpid()] writeToFile:HUD_PID atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(HUD_PID.UTF8String, 0666);
        NSSetUncaughtExceptionHandler(&hudUncaught);
        hlog(gHudServe ? @"== 悬浮层启动(任务用)" : @"== lab14 悬浮层启动,目标 %@", gHudBid);
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
static NSString *hudSpawn5(const char *arg, const char *arg2, const char *arg3, const char *arg4, const char *arg5, BOOL wait) {
    uint32_t sz = 0; _NSGetExecutablePath(NULL, &sz);
    char *exe = calloc(1, sz + 1); _NSGetExecutablePath(exe, &sz);
    posix_spawnattr_t attr; posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (!wait) { posix_spawnattr_setpgroup(&attr, 0); posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP); }
    const char *args[] = { exe, arg, arg2, arg3, arg4, arg5, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    free(exe);
    if (rc != 0) return [NSString stringWithFormat:@"启动失败 %s", strerror(rc)];
    if (wait) { int st = 0; waitpid(pid, &st, 0); }
    else { int st = 0; waitpid(pid, &st, WNOHANG); }
    return [NSString stringWithFormat:@"已启动 pid=%d", pid];
}

static NSString *hudSpawn(const char *arg, const char *arg2, const char *arg3, BOOL wait) { return hudSpawn5(arg, arg2, arg3, NULL, NULL, wait); }

static NSString *gHudKey;
NSString *hudKey(void) { return gHudKey; }
NSString *hudStart(NSString *bid) {
    unlink(HUD_LOG.UTF8String);
    hudSpawn("-pahudexit", NULL, NULL, YES);
    gHudKey = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return hudSpawn("-pahud", bid.UTF8String ?: "com.apple.Preferences", gHudKey.UTF8String, NO);
}
NSString *hudStop(void) { return hudSpawn("-pahudexit", NULL, NULL, YES); }

// ---------- v0.9.73 PhoneAgent 这边:跑任务时启动悬浮层并给它发指令 ----------
void hudWriteGeo(double ox, double oy, double k) {
    NSString *g = [NSString stringWithFormat:@"%.2f %.2f %.4f %d", ox, oy, k, gDragMode ? 1 : 0];
    [g writeToFile:HUD_GEO atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(HUD_GEO.UTF8String, 0666);
}
// 读小窗位置和缩放(拖动后会变);0.3 秒内用缓存,滑动时每秒要读几十次。
// 你正在拖小窗时(第 4 个数为 1)先等,松手再点,最多等 8 秒
BOOL hudGeo(double *ox, double *oy, double *k) {
    static double cx, cy, ck; static CFAbsoluteTime ct; static BOOL have, drag;
    @synchronized (NSFileManager.class) {
        for (int i = 0; i < 80; i++) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (!have || drag || now - ct > 0.3) {
                NSString *g = [NSString stringWithContentsOfFile:HUD_GEO encoding:NSUTF8StringEncoding error:nil];
                NSArray *a = [g componentsSeparatedByString:@" "];
                if (a.count >= 3 && [a[2] doubleValue] > 0.05) {
                    cx = [a[0] doubleValue]; cy = [a[1] doubleValue]; ck = [a[2] doubleValue];
                    drag = a.count >= 4 && [a[3] intValue] == 1;
                    have = YES; ct = now;
                }
            }
            if (!have || !drag) break;
            usleep(100 * 1000);
        }
        if (!have) return NO;
        *ox = cx; *oy = cy; *k = ck;
        return YES;
    }
}
static NSData *hudReq(NSString *path, NSDictionary *q, double timeout, NSInteger *code) {
    NSURLComponents *uc = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d%@", HUD_PORT, path]];
    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"key" value:gHudKey ?: @""]];
    for (NSString *k in q) [items addObject:[NSURLQueryItem queryItemWithName:k value:q[k]]];
    uc.queryItems = items;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:uc.URL];
    rq.timeoutInterval = timeout;
    __block NSData *out = nil; __block NSInteger st = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        out = d; st = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1) * NSEC_PER_SEC)));
    if (code) *code = st;
    return out;
}
static BOOL hudAlive(void) {
    if (!gHudKey.length) return NO;
    NSInteger st = 0;
    hudReq(@"/ping", @{}, 1.0, &st);
    return st == 200;
}
// 确保悬浮层在待命;没有就启动一个(最多等 6 秒)
static BOOL hudEnsure(NSString **note) {
    if (hudAlive()) return YES;
    hudSpawn("-pahudexit", NULL, NULL, YES);
    unlink(HUD_LOG.UTF8String);
    gHudKey = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    char pid[16]; snprintf(pid, sizeof pid, "%d", getpid());
    NSString *r = hudSpawn5("-pahud", "-", gHudKey.UTF8String, "serve", pid, NO);
    for (int i = 0; i < 30; i++) { usleep(200 * 1000); if (hudAlive()) return YES; }
    if (note) *note = [NSString stringWithFormat:@"悬浮层没起来(%@)。最后日志:%@", r, [[hudReadLog() componentsSeparatedByString:@"\n"] lastObject] ?: @""];
    return NO;
}
BOOL hudRemoteOpen(NSString *bid, NSString **note) {
    if (!hudEnsure(note)) return NO;
    NSInteger st = 0;
    NSData *d = hudReq(@"/open", @{@"bid": bid ?: @""}, 15, &st);
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) { if (note) *note = [NSString stringWithFormat:@"悬浮层没回应(HTTP %ld)", (long)st]; return NO; }
    if (note) *note = j[@"note"];
    return [j[@"ok"] boolValue];
}
void hudRemoteClose(void) { if (gHudKey.length) hudReq(@"/close", @{}, 3, NULL); }
UIImage *hudRemoteSnapshot(NSString **err) {
    NSInteger st = 0;
    NSData *d = hudReq(@"/snap", @{}, 5, &st);
    UIImage *u = (st == 200 && d.length) ? [UIImage imageWithData:d] : nil;
    if (!u && err) *err = [NSString stringWithFormat:@"悬浮小窗快照失败(HTTP %ld)", (long)st];
    return u;
}

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
