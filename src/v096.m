// PhoneAgent v0.9.6:屏幕静止检测、广告倒计时、弹窗规则、图标候选、断点续跑、健康检查、保活、网络等待
#import "pa_internal.h"

BOOL paOn(NSString *key, BOOL def) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:key] ? [d boolForKey:key] : def;
}

#pragma mark - 画面缩略图对比

#define TH_W 96
#define TH_H 208
#define TH_SKIP_ROWS 12   // 顶部状态栏(时间、电量会变)不参与比较

// 广播 JPEG -> 96x208 灰度缩略图(用 ImageIO 的缩略图解码,很便宜)
NSData *frameThumb(NSData *jpeg) {
    if (!jpeg.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!src) return nil;
    NSDictionary *opt = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                          (id)kCGImageSourceThumbnailMaxPixelSize: @(TH_H * 2),
                          (id)kCGImageSourceShouldCacheImmediately: @YES};
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
    CFRelease(src);
    if (!cg) return nil;
    NSMutableData *buf = [NSMutableData dataWithLength:TH_W * TH_H];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, TH_W, TH_H, 8, TH_W, cs, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(cg); return nil; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, TH_W, TH_H), cg);
    CGContextRelease(ctx);
    CGImageRelease(cg);
    return buf;
}

// 两张缩略图里明显变化(灰度差 > 24)的格子数;任一为空返回 -1
int thumbChangedCells(NSData *a, NSData *b) {
    if (a.length != TH_W * TH_H || b.length != TH_W * TH_H) return -1;
    const uint8_t *pa = a.bytes, *pb = b.bytes;
    int n = 0;
    // CGBitmapContext 的第 0 行是图片顶部
    for (int y = TH_SKIP_ROWS; y < TH_H; y++)
        for (int x = 0; x < TH_W; x++) {
            int d = (int)pa[y * TH_W + x] - (int)pb[y * TH_W + x];
            if (d > 24 || d < -24) n++;
        }
    return n;
}

int thumbTotalCells(void) { return TH_W * (TH_H - TH_SKIP_ROWS); }

NSData *currentFrame(CFAbsoluteTime *t) {
    NSData *d; CFAbsoluteTime ft;
    @synchronized (gLock) { d = gFrame; ft = gFrameT; }
    if (t) *t = ft;
    return d;
}

// 动作后等画面稳定:先等 minWait 秒;之后满足任一条件就返回:
//  ① 最新两帧几乎一样(变化格子 <= 6,允许光标闪烁/小转圈);
//  ② 动作 0.6 秒后仍然 0.45 秒没有新帧(扩展只在画面变化时发帧,没新帧 = 画面没动)。
// 最多等 cap 秒。广播没开时退化为固定等待。
void waitScreenSettle(double minWait, double cap) {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    if (!broadcastAlive()) { usleep((useconds_t)(MAX(minWait, MIN(cap, 1.5)) * 1e6)); return; }
    if (minWait > 0) usleep((useconds_t)(minWait * 1e6));
    CFAbsoluteTime lastT = 0;
    NSData *lastThumb = frameThumb(currentFrame(&lastT));
    while (CFAbsoluteTimeGetCurrent() - t0 < cap) {
        usleep(150 * 1000);
        CFAbsoluteTime ft = 0;
        NSData *f = currentFrame(&ft);
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (ft != lastT) {
            NSData *th = frameThumb(f);
            int c = thumbChangedCells(lastThumb, th);
            lastT = ft; lastThumb = th;
            if (c >= 0 && c <= 6 && now - t0 >= 0.6) return;
            continue;
        }
        if (now - MAX(t0 + 0.6, lastT) >= 0.45) return;
    }
}

#pragma mark - 广告倒计时 / 弹窗规则

static NSArray *kCloseWords(void) { return @[@"跳过", @"关闭", @"关闭广告", @"×", @"X", @"x", @"✕", @"领取成功", @"已领取", @"我知道了"]; }

// 屏幕上有广告倒计时(“5秒”“5s后”“15 秒后可领奖”等)且没有可点的关闭/跳过按钮:返回秒数,否则 0
int adCountdownSeconds(NSArray *items) {
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,2})\\s*(?:秒|[sS](?![a-zA-Z]))" options:0 error:nil]; });
    BOOL adCtx = NO;
    for (NSDictionary *it in items) {
        NSString *t = [it[@"text"] description];
        for (NSString *w in @[@"广告", @"奖励", @"领取", @"后可", @"可领", @"试玩"]) if ([t containsString:w]) { adCtx = YES; break; }
        if (adCtx) break;
    }
    int found = 0;
    for (NSDictionary *it in items) {
        NSString *t = [[it[@"text"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!t.length || t.length > 20) continue;
        if ([it[@"icon"] boolValue]) continue;
        NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
        if (!m) continue;
        int n = [[t substringWithRange:[m rangeAtIndex:1]] intValue];
        if (n < 1 || n > 60) continue;
        BOOL ctx = NO;
        for (NSString *w in @[@"后", @"跳过", @"领", @"奖励", @"广告", @"关闭"]) if ([t containsString:w]) { ctx = YES; break; }
        if (!ctx && !(t.length <= 4 && adCtx)) continue;
        if ([t containsString:@"前"]) continue; // “5秒前”是时间戳
        found = MAX(found, n);
    }
    if (!found) return 0;
    // 已经有不带数字的关闭/跳过按钮:交给模型(或弹窗规则)去点
    for (NSDictionary *it in items) {
        NSString *t = [[it[@"text"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([t rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound) continue;
        for (NSString *w in kCloseWords()) if ([t isEqualToString:w]) return 0;
    }
    return found;
}

NSString *defaultPopupWords(void) { return @"跳过\n我知道了\n暂不\n以后再说\n关闭广告"; }

NSArray *popupWords(void) {
    NSString *t = [NSUserDefaults.standardUserDefaults stringForKey:@"popup_words"] ?: defaultPopupWords();
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in [t componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n,，、;；"]]) {
        NSString *x = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (x.length) [out addObject:x];
    }
    return out;
}

// OCR 文字和弹窗规则里的某个词完全相同,而且是一个独立的小按钮(不和同一行的其他文字挨着):返回要点的项
NSDictionary *popupTarget(NSArray *items) {
    NSArray *words = popupWords();
    if (!words.count) return nil;
    for (NSDictionary *it in items) {
        if ([it[@"icon"] boolValue]) continue;
        NSString *t = [[it[@"text"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![words containsObject:t]) continue;
        double x = [it[@"x"] doubleValue], y = [it[@"y"] doubleValue], w = [it[@"w"] doubleValue], h = [it[@"h"] doubleValue];
        if (w > 160 || h > 60 || y < 40) continue;
        BOOL alone = YES;
        for (NSDictionary *o in items) {
            if (o == it || [o[@"icon"] boolValue]) continue;
            double ox = [o[@"x"] doubleValue], oy = [o[@"y"] doubleValue], ow = [o[@"w"] doubleValue], oh = [o[@"h"] doubleValue];
            if (fabs(oy - y) > MAX(h, oh) * 0.6) continue; // 不同行
            double gap = fabs(ox - x) - (ow + w) / 2;
            if (gap < 14) { alone = NO; break; }
        }
        if (alone) return it;
    }
    return nil;
}

#pragma mark - 无文字图标候选(边缘 + 连通域,便宜版)

NSArray *detectIcons(UIImage *img, NSArray *textItems) {
    if (!img.CGImage) return @[];
    CGSize sc = screenSize();
    const int W = 260;
    int H = (int)lround(W * img.size.height / MAX(1.0, img.size.width));
    if (H < 100 || H > 1200) return @[];
    NSMutableData *gray = [NSMutableData dataWithLength:(NSUInteger)W * H];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(gray.mutableBytes, W, H, 8, W, cs, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return @[];
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img.CGImage);
    CGContextRelease(ctx);
    const uint8_t *g = gray.bytes;
    // Sobel 边缘 -> 二值,再膨胀 1 像素把一个图标的几笔连起来
    uint8_t *edge = calloc((size_t)W * H, 1), *dil = calloc((size_t)W * H, 1);
    int *lab = calloc((size_t)W * H, sizeof(int));
    int *stack = malloc(sizeof(int) * (size_t)W * H);
    if (!edge || !dil || !lab || !stack) { free(edge); free(dil); free(lab); free(stack); return @[]; }
    for (int y = 1; y < H - 1; y++)
        for (int x = 1; x < W - 1; x++) {
            const uint8_t *p = g + y * W + x;
            int gx = -p[-W - 1] - 2 * p[-1] - p[W - 1] + p[-W + 1] + 2 * p[1] + p[W + 1];
            int gy = -p[-W - 1] - 2 * p[-W] - p[-W + 1] + p[W - 1] + 2 * p[W] + p[W + 1];
            if (abs(gx) + abs(gy) > 140) edge[y * W + x] = 1;
        }
    for (int y = 1; y < H - 1; y++)
        for (int x = 1; x < W - 1; x++) {
            int i = y * W + x;
            if (edge[i] || edge[i - 1] || edge[i + 1] || edge[i - W] || edge[i + W]) dil[i] = 1;
        }
    double k = sc.width / W; // 像素 -> pt
    NSMutableArray *cands = [NSMutableArray array];
    int nlab = 0;
    for (int start = 0; start < W * H; start++) {
        if (!dil[start] || lab[start]) continue;
        nlab++;
        int sp = 0, cnt = 0, minx = W, miny = H, maxx = 0, maxy = 0;
        stack[sp++] = start; lab[start] = nlab;
        BOOL big = NO;
        while (sp) {
            int i = stack[--sp];
            int x = i % W, y = i / W;
            cnt++;
            if (x < minx) minx = x; if (x > maxx) maxx = x; if (y < miny) miny = y; if (y > maxy) maxy = y;
            if (maxx - minx > 40 || maxy - miny > 40) big = YES; // 太大不是小图标,但仍要标记完整个连通域
            int nb[4] = {i - 1, i + 1, i - W, i + W};
            for (int q = 0; q < 4; q++) {
                int j = nb[q];
                if (j < 0 || j >= W * H || !dil[j] || lab[j]) continue;
                if ((q == 0 && x == 0) || (q == 1 && x == W - 1)) continue;
                lab[j] = nlab; stack[sp++] = j;
            }
        }
        if (big) continue;
        double bw = (maxx - minx + 1) * k, bh = (maxy - miny + 1) * k;
        if (bw < 10 || bh < 10 || bw > 44 || bh > 44) continue;
        double asp = bw / bh;
        if (asp < 0.5 || asp > 2.0) continue;
        double fill = (double)cnt / ((maxx - minx + 1) * (maxy - miny + 1));
        if (fill < 0.12 || fill > 0.85) continue;
        double cx = (minx + maxx + 1) / 2.0 * k, cy = (miny + maxy + 1) / 2.0 * k;
        if (cy < 50) continue; // 状态栏
        // 周围一圈(外扩 5 像素)要比较干净:否则多半是图片里的细节
        int ring = 0, ringN = 0;
        for (int y = MAX(0, miny - 5); y <= MIN(H - 1, maxy + 5); y++)
            for (int x = MAX(0, minx - 5); x <= MIN(W - 1, maxx + 5); x++) {
                if (x >= minx && x <= maxx && y >= miny && y <= maxy) continue;
                ringN++; if (edge[y * W + x]) ring++;
            }
        if (ringN && (double)ring / ringN > 0.04) continue;
        // 和 OCR 文字框重叠的跳过
        BOOL overlap = NO;
        for (NSDictionary *it in textItems) {
            double tx = [it[@"x"] doubleValue], ty = [it[@"y"] doubleValue], tw = [it[@"w"] doubleValue], th = [it[@"h"] doubleValue];
            if (fabs(tx - cx) < (tw + bw) / 2 + 6 && fabs(ty - cy) < (th + bh) / 2 + 6) { overlap = YES; break; }
        }
        if (overlap) continue;
        double score = 0;
        if (cy < 170 || cy > sc.height - 120) score += 2;
        if (cx < 70 || cx > sc.width - 70) score += 1;
        score -= fabs(asp - 1.0);
        [cands addObject:@{@"text": @"[图标]", @"x": @((int)round(cx)), @"y": @((int)round(cy)),
                           @"w": @((int)round(bw)), @"h": @((int)round(bh)), @"icon": @YES, @"s": @(score)}];
        if (cands.count > 200) break;
    }
    free(edge); free(dil); free(lab); free(stack);
    [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"s"] compare:a[@"s"]]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *c in cands) {
        NSMutableDictionary *m = [c mutableCopy]; [m removeObjectForKey:@"s"];
        [out addObject:m];
        if (out.count >= 15) break;
    }
    return out;
}

#pragma mark - 断点续跑

NSDictionary *gResumeCP;

static NSString *cpPath(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [doc stringByAppendingPathComponent:@"pa_checkpoint.json"];
}
void cpSave(NSDictionary *d) {
    if (!paOn(@"checkpoint_on", YES) || !d) return;
    NSMutableDictionary *m = [d mutableCopy];
    m[@"t"] = @([NSDate date].timeIntervalSince1970);
    NSData *data = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
    if (data) [data writeToFile:cpPath() atomically:YES];
}
NSDictionary *cpLoad(void) {
    NSData *d = [NSData dataWithContentsOfFile:cpPath()];
    if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![o isKindOfClass:NSDictionary.class]) return nil;
    double t = [o[@"t"] doubleValue];
    if ([NSDate date].timeIntervalSince1970 - t > 2 * 3600) { [NSFileManager.defaultManager removeItemAtPath:cpPath() error:nil]; return nil; }
    if (![o[@"task"] isKindOfClass:NSString.class] || ![o[@"task"] length]) return nil;
    return o;
}
void cpClear(void) { [NSFileManager.defaultManager removeItemAtPath:cpPath() error:nil]; }

#pragma mark - 健康:发热 / 低电量

static int gHealthLevel = 0;
double healthCheckDelay(void) {
    if (!paOn(@"health_guard", YES)) return 0;
    NSProcessInfoThermalState th = NSProcessInfo.processInfo.thermalState;
    __block float lvl = -1; __block UIDeviceBatteryState bst = UIDeviceBatteryStateUnknown;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIDevice *dv = UIDevice.currentDevice;
        if (!dv.batteryMonitoringEnabled) dv.batteryMonitoringEnabled = YES;
        lvl = dv.batteryLevel; bst = dv.batteryState;
    });
    BOOL lowBat = lvl >= 0 && lvl < 0.15 && bst == UIDeviceBatteryStateUnplugged;
    int level = 0; double delay = 0;
    if (th == NSProcessInfoThermalStateCritical) { level = 3; delay = 6; }
    else if (th == NSProcessInfoThermalStateSerious) { level = 2; delay = 3; }
    if (lowBat) { level = MAX(level, 1); delay = MAX(delay, 3); }
    if (level != gHealthLevel) {
        if (level > 0) agentSay([NSString stringWithFormat:@"提醒:%@%@%@,每步之间会多等 %.0f 秒",
                                th >= NSProcessInfoThermalStateSerious ? (th == NSProcessInfoThermalStateCritical ? @"手机温度过高(严重)" : @"手机发热较严重") : @"",
                                (th >= NSProcessInfoThermalStateSerious && lowBat) ? @"、" : @"",
                                lowBat ? [NSString stringWithFormat:@"电量只剩 %.0f%% 且没充电", lvl * 100] : @"", delay]);
        else agentSay(@"手机温度/电量已恢复正常");
        gHealthLevel = level;
    }
    return delay;
}
void healthReset(void) { gHealthLevel = 0; }

#pragma mark - 任务期间保活

static UIBackgroundTaskIdentifier gBgTask = 0;
static BOOL gBgStarted;
static dispatch_source_t gBgTimer;
static BOOL gKeepStartedAudio;

static void bgRenew(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        UIBackgroundTaskIdentifier old = gBgTask;
        gBgTask = [app beginBackgroundTaskWithName:@"PhoneAgentTask" expirationHandler:^{
            // 到期前系统回调:结束这个,定时器会再申请一个
            UIBackgroundTaskIdentifier cur = gBgTask;
            if (cur != UIBackgroundTaskInvalid) { gBgTask = UIBackgroundTaskInvalid; [UIApplication.sharedApplication endBackgroundTask:cur]; }
        }];
        if (old != UIBackgroundTaskInvalid) [app endBackgroundTask:old];
        resumeKeepAlive();
    });
}

void keepAliveTaskStart(void) {
    if (!paOn(@"keep_alive", YES)) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!gPlayer) { setKeepAlive(YES); gKeepStartedAudio = YES; } else gKeepStartedAudio = NO;
    });
    gBgTask = UIBackgroundTaskInvalid;
    gBgStarted = YES;
    bgRenew();
    if (!gBgTimer) {
        gBgTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(gBgTimer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 20 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(gBgTimer, ^{ bgRenew(); });
        dispatch_resume(gBgTimer);
    }
}

void keepAliveTaskStop(void) {
    if (gBgTimer) { dispatch_source_cancel(gBgTimer); gBgTimer = nil; }
    if (!gBgStarted) return;
    gBgStarted = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBgTask != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:gBgTask]; gBgTask = UIBackgroundTaskInvalid; }
        if (gKeepStartedAudio) { setKeepAlive(NO); gKeepStartedAudio = NO; }
    });
}

#pragma mark - 断网等待

// 断网时每 3 秒探测一次接口地址(任何 HTTP 回应都算通),最多等 maxWait 秒;用户停止任务就返回 NO
BOOL waitForNetwork(NSString *base, double maxWait) {
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:base.length ? base : @"https://www.apple.com"];
    if (!url) return NO;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    BOOL said = NO;
    while (gAgentRunning && CFAbsoluteTimeGetCurrent() - t0 < maxWait) {
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
        r.HTTPMethod = @"HEAD"; r.timeoutInterval = 5;
        __block BOOL ok = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            ok = [resp isKindOfClass:NSHTTPURLResponse.class];
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC));
        if (ok) { if (said) agentSay(@"网络已恢复,继续任务"); return YES; }
        if (!said) { agentSay(@"网络断开了,任务暂停等待网络恢复(最多 2 分钟)……"); said = YES; }
        for (int i = 0; i < 15 && gAgentRunning; i++) usleep(200 * 1000);
    }
    return NO;
}
