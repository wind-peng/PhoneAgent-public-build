// v0.9.29 无障碍树探测:验证能否从本 App 读到其他 App 的界面元素(类型/文字/位置)
// 全部用运行时动态调用私有类,任何一步失败只记录,不会崩溃。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "pa_internal.h"

static NSMutableArray *gAXLog;
static void axl(NSString *s) { if (s) [gAXLog addObject:s]; }

static NSArray *axMethodNames(Class c, BOOL meta) {
    NSMutableArray *r = [NSMutableArray array];
    if (!c) return r;
    unsigned n = 0;
    Method *ms = class_copyMethodList(meta ? object_getClass(c) : c, &n);
    NSArray *keys = @[@"oordinate", @"ystemWide", @"pplication", @"ttribute", @"rame", @"abel", @"raits", @"hildren", @"alue", @"lement", @"ocused", @"extEntry", @"ditable"];
    for (unsigned i = 0; i < n; i++) {
        NSString *s = NSStringFromSelector(method_getName(ms[i]));
        for (NSString *k in keys) if ([s rangeOfString:k].location != NSNotFound) { [r addObject:s]; break; }
    }
    free(ms);
    return r;
}

static id axCallObj(id t, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!t || ![t respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(t, s); } @catch (NSException *e) { axl([NSString stringWithFormat:@"异常 %@: %@", sel, e.reason]); }
    return nil;
}
static id axCallPoint(id t, NSString *sel, CGPoint p) {
    SEL s = NSSelectorFromString(sel);
    if (!t || ![t respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, CGPoint))objc_msgSend)(t, s, p); } @catch (NSException *e) { axl([NSString stringWithFormat:@"异常 %@: %@", sel, e.reason]); }
    return nil;
}
static id axKV(id el, NSString *k) {
    if (!el) return nil;
    @try { return [el valueForKey:k]; } @catch (NSException *e) { return nil; }
}

// 读一个元素的属性
static NSDictionary *axDescribe(id el) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"label", @"value", @"hint", @"identifier", @"traits", @"frame", @"isTextEntry", @"isEditable"]) {
        id v = axKV(el, k);
        if (!v) continue;
        if ([v isKindOfClass:NSValue.class] && strcmp([(NSValue *)v objCType], @encode(CGRect)) == 0) {
            CGRect r = [(NSValue *)v CGRectValue];
            d[k] = @[@(round(r.origin.x)), @(round(r.origin.y)), @(round(r.size.width)), @(round(r.size.height))];
        } else if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class]) {
            d[k] = v;
        } else {
            d[k] = [[v description] substringToIndex:MIN((NSUInteger)80, [[v description] length])];
        }
    }
    NSNumber *tr = d[@"traits"];
    if ([tr isKindOfClass:NSNumber.class]) {
        unsigned long long t = tr.unsignedLongLongValue;
        // 0x400 = SearchField,0x40000 = 私有 TextEntry
        if (t & 0x400ULL) d[@"可输入"] = @"搜索框";
        else if (t & 0x40000ULL) d[@"可输入"] = @"文本框";
        if (t & 0x1ULL) d[@"按钮"] = @YES;
    }
    if ([d[@"isTextEntry"] boolValue] && !d[@"可输入"]) d[@"可输入"] = @"文本框";
    return d;
}

static void axWalk(id el, int depth, NSMutableArray *acc, NSMutableSet *seen) {
    if (!el || depth > 14 || acc.count > 600) return;
    NSString *k = [NSString stringWithFormat:@"%p", (__bridge void *)el];
    NSDictionary *d = axDescribe(el);
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%d", d[@"label"] ?: @"", d[@"frame"] ?: @"", d[@"traits"] ?: @"", depth];
    if ([seen containsObject:key]) return;
    [seen addObject:key]; (void)k;
    NSMutableDictionary *m = [d mutableCopy]; m[@"深度"] = @(depth);
    [acc addObject:m];
    id ch = axCallObj(el, @"children");
    if ([ch isKindOfClass:NSArray.class]) for (id c in ch) axWalk(c, depth + 1, acc, seen);
}

static NSArray *axDescribeAll(id arr) {
    NSMutableArray *r = [NSMutableArray array];
    if (![arr isKindOfClass:NSArray.class]) return r;
    for (id e in arr) { if (r.count > 600) break; [r addObject:axDescribe(e)]; }
    return r;
}

static NSString *axProbeRun(void) {
    gAXLog = [NSMutableArray array];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    // 1. 加载框架
    NSArray *libs = @[@"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
                      @"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
                      @"/usr/lib/libAccessibility.dylib"];
    for (NSString *p in libs) axl([NSString stringWithFormat:@"dlopen %@ → %@", p.lastPathComponent, dlopen(p.UTF8String, RTLD_NOW) ? @"OK" : @"失败"]);
    // 2. 打开自动化/无障碍开关(让其他 App 准备好元素信息)
    void (*setAuto)(int) = dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");
    void (*setApp)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    if (setAuto) { setAuto(1); axl(@"_AXSSetAutomationEnabled(1) 已调用"); } else axl(@"无 _AXSSetAutomationEnabled");
    if (setApp) { setApp(1); axl(@"_AXSApplicationAccessibilitySetEnabled(1) 已调用"); } else axl(@"无 _AXSApplicationAccessibilitySetEnabled");
    [NSThread sleepForTimeInterval:1.0];
    // 3. 列出可用方法(以后改代码用)
    Class cE = NSClassFromString(@"AXElement"), cU = NSClassFromString(@"AXUIElement");
    out[@"AXElement类"] = cE ? @"有" : @"无";
    out[@"AXUIElement类"] = cU ? @"有" : @"无";
    out[@"AXElement类方法"] = axMethodNames(cE, YES);
    out[@"AXElement实例方法"] = axMethodNames(cE, NO);
    out[@"AXUIElement类方法"] = axMethodNames(cU, YES);
    // 4. 找一个能按坐标取元素的入口
    id sys = axCallObj(cE, @"systemWideElement");
    axl([NSString stringWithFormat:@"AXElement.systemWideElement → %@", sys ? @"OK" : @"nil"]);
    id sysU = axCallObj(cU, @"uiSystemWideApplication");
    axl([NSString stringWithFormat:@"AXUIElement.uiSystemWideApplication → %@", sysU ? @"OK" : @"nil"]);
    id app = axCallObj(sys, @"systemApplication") ?: axCallObj(sys, @"application");
    id front = nil;
    for (NSString *s in @[@"currentApplications", @"applications"]) {
        id a = axCallObj(sys, s);
        if ([a isKindOfClass:NSArray.class] && [a count]) { front = [a firstObject]; axl([NSString stringWithFormat:@"%@ → %lu 个", s, (unsigned long)[a count]]); break; }
    }
    if (!front) { front = axCallObj(sys, @"currentApplication"); if (front) axl(@"currentApplication → OK"); }
    if (!front && cE) {
        SEL sa = NSSelectorFromString(@"applicationAtCoordinate:");
        if ([cE respondsToSelector:sa]) { @try { front = ((id (*)(id, SEL, CGPoint))objc_msgSend)(cE, sa, CGPointMake(195, 420)); } @catch (NSException *e) {} }
        axl([NSString stringWithFormat:@"applicationAtCoordinate → %@", front ? @"OK" : @"nil"]);
    }
    if (front) out[@"前台App"] = axDescribe(front);
    // 4b. 顺着树读(v0.9.30):三种方式各计时
    NSMutableString *treeSum = [NSMutableString string];
    if (front) {
        for (NSString *m in @[@"explorerElements", @"visibleElements"]) {
            CFAbsoluteTime a0 = CFAbsoluteTimeGetCurrent();
            id arr = axCallObj(front, m);
            NSArray *ds = axDescribeAll(arr);
            int ms0 = (int)((CFAbsoluteTimeGetCurrent() - a0) * 1000);
            out[m] = ds;
            [treeSum appendFormat:@"%@:%lu 个,%d ms\n", m, (unsigned long)ds.count, ms0];
        }
        CFAbsoluteTime a1 = CFAbsoluteTimeGetCurrent();
        NSMutableArray *acc = [NSMutableArray array];
        axWalk(front, 0, acc, [NSMutableSet set]);
        int ms1 = (int)((CFAbsoluteTimeGetCurrent() - a1) * 1000);
        out[@"children递归"] = acc;
        [treeSum appendFormat:@"children 递归:%lu 个,%d ms\n", (unsigned long)acc.count, ms1];
    } else [treeSum appendString:@"没拿到前台 App,树读取跳过\n"];
    if (app) out[@"systemApplication"] = axDescribe(app);

    CGSize sz = UIScreen.mainScreen.bounds.size;
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSMutableArray *els = [NSMutableArray array];
    NSString *how = nil;
    int hits = 0, tries = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    for (CGFloat y = 20; y < sz.height - 10; y += 40) {
        for (CGFloat x = 20; x < sz.width; x += 40) {
            CGPoint p = CGPointMake(x, y);
            id el = nil;
            tries++;
            if (!how || [how isEqualToString:@"A"]) { el = axCallPoint(cE, @"elementAtCoordinate:", p); if (el && !how) how = @"A"; }
            if (!el && (!how || [how isEqualToString:@"P"])) {
                SEL sp = NSSelectorFromString(@"elementAtCoordinate:withVisualPadding:");
                if (cE && [cE respondsToSelector:sp]) { @try { el = ((id (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(cE, sp, p, NO); } @catch (NSException *e) {} }
                if (el && !how) how = @"P";
            }
            if (!el && (!how || [how isEqualToString:@"B"])) { el = axCallPoint(sys, @"elementAtCoordinate:", p); if (el && !how) how = @"B"; }
            if (!el && (!how || [how isEqualToString:@"C"])) {
                id u = axCallPoint(cU, @"uiElementAtCoordinate:", p);
                if (u && cE) {
                    id w = [cE alloc];
                    SEL s = NSSelectorFromString(@"initWithUIElement:");
                    if ([w respondsToSelector:s]) { @try { el = ((id (*)(id, SEL, id))objc_msgSend)(w, s, u); } @catch (NSException *e) {} }
                    if (!el) el = u;
                }
                if (el && !how) how = @"C";
            }
            if (!el) continue;
            hits++;
            NSDictionary *d = axDescribe(el);
            NSString *key = [NSString stringWithFormat:@"%@|%@|%@", d[@"label"] ?: @"", d[@"frame"] ?: @"", d[@"traits"] ?: @""];
            if (seen[key]) continue;
            seen[key] = @YES;
            [els addObject:d];
        }
        if (tries > 40 && hits == 0) { axl(@"前 40 个点都取不到元素,停止网格"); break; }
    }
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
    out[@"取点方式"] = how ?: @"都失败";
    out[@"取点次数"] = @(tries); out[@"命中"] = @(hits); out[@"总耗时ms"] = @((int)ms);
    out[@"元素"] = els;
    out[@"日志"] = gAXLog;

    NSMutableArray *inputs = [NSMutableArray array];
    for (NSDictionary *d in els) if (d[@"可输入"]) [inputs addObject:d];
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HHmmss";
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Documents/ax_probe_%@.json", [f stringFromDate:NSDate.date]];
    NSData *j = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    [j writeToFile:path atomically:YES];

    NSMutableString *sum = [NSMutableString string];
    [sum appendFormat:@"方式 %@,取点 %d 次,命中 %d,不同元素 %lu 个,其中可输入 %lu 个,耗时 %d ms\n", how ?: @"都失败", tries, hits, (unsigned long)els.count, (unsigned long)inputs.count, (int)ms];
    if (front) [sum appendFormat:@"前台 App:%@\n", out[@"前台App"][@"label"] ?: @"?"];
    [sum appendString:treeSum];
    for (NSDictionary *d in inputs) [sum appendFormat:@"【%@】%@ 位置%@\n", d[@"可输入"], d[@"label"] ?: d[@"value"] ?: @"", d[@"frame"] ?: @"?"];
    int shown = 0;
    for (NSDictionary *d in els) {
        if (d[@"可输入"]) continue;
        if (++shown > 15) break;
        [sum appendFormat:@"· %@ %@ t=%@\n", d[@"label"] ?: @"(无文字)", d[@"frame"] ?: @"", d[@"traits"] ?: @""];
    }
    if (!hits) [sum appendFormat:@"%@\n", [gAXLog componentsJoinedByString:@"\n"]];
    [sum appendFormat:@"完整结果:%@", path];
    return sum;
}

void axProbeAfterDelay(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *r = nil;
        @try { r = axProbeRun(); } @catch (NSException *e) { r = [NSString stringWithFormat:@"探测异常:%@", e.reason]; }
        agentSay([@"[无障碍探测] " stringByAppendingString:r]);
    });
}

// ---- v0.9.31:每步读前台 App 的无障碍元素,作为元素列表的主来源 ----
static id gAXFrontCache; static NSString *gAXFrontBid;
static void axInitOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
        dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*setAuto)(int) = dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");
        void (*setApp)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
        if (setAuto) setAuto(1);
        if (setApp) setApp(1);
        [NSThread sleepForTimeInterval:0.8];
    });
}

static void axCollect(id el, int depth, NSMutableArray *acc, NSMutableSet *seen, CFAbsoluteTime t0) {
    if (!el || depth > 18 || acc.count > 500 || CFAbsoluteTimeGetCurrent() - t0 > 1.5) return;
    NSString *k = [NSString stringWithFormat:@"%p", (__bridge void *)el];
    if ([seen containsObject:k]) return;
    [seen addObject:k];
    [acc addObject:el];
    id ch = axCallObj(el, @"children");
    if ([ch isKindOfClass:NSArray.class]) for (id c in ch) axCollect(c, depth + 1, acc, seen, t0);
}

// 返回元素列表(屏幕点坐标、中心点),每项:text x y w h ax=YES,可带 axbtn / axin(可输入) / axsel(已选中)
// v0.9.33:无障碍文字整理:人民币→¥;商品卡这类长标签截短,保留价格/销量部分
static id axHitAt(CGPoint p) { // v0.9.34:按坐标取元素(设备上可用的 C 方式)
    Class cU = NSClassFromString(@"AXUIElement"), cE = NSClassFromString(@"AXElement");
    id u = axCallPoint(cU, @"uiElementAtCoordinate:", p);
    if (!u || !cE) return nil;
    id el = nil; id w = [cE alloc]; SEL s = NSSelectorFromString(@"initWithUIElement:");
    if ([w respondsToSelector:s]) { @try { el = ((id (*)(id, SEL, id))objc_msgSend)(w, s, u); } @catch (NSException *e) {} }
    return el;
}
static NSString *axTidy(NSString *t) {
    t = [t stringByReplacingOccurrencesOfString:@"人民币" withString:@"¥"];
    { // v0.9.34:「128.2元」这类写法也统一成 ¥128.2
        static NSRegularExpression *rx; if (!rx) rx = [NSRegularExpression regularExpressionWithPattern:@"(?<![¥\\d.])(\\d+(?:\\.\\d+)?)元" options:0 error:nil];
        if (rx) t = [rx stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@"¥$1"];
    }
    t = [t stringByReplacingOccurrencesOfString:@"¥ " withString:@"¥"];
    while ([t containsString:@"  "]) t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if (t.length <= 50) return t;
    NSRange y = [t rangeOfString:@"¥"];
    if (y.location != NSNotFound && y.location > 26) {
        NSString *tail = [t substringFromIndex:y.location];
        if (tail.length > 28) tail = [tail substringToIndex:28];
        return [NSString stringWithFormat:@"%@… %@", [t substringToIndex:24], tail];
    }
    if (y.location != NSNotFound) return [[t substringToIndex:MIN((NSUInteger)56, t.length)] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"%@…%@", [t substringToIndex:24], [t substringFromIndex:t.length - 26]]; // 没有¥时保留头尾(价格、销量多在末尾)
}
// v0.9.45:找左上角导航栏里的按钮。微信等的返回箭头没有文字,axReadScreen 会把它丢掉;这里按坐标直接问无障碍
NSDictionary *axTopLeftButton(void) {
    @try {
        axInitOnce();
        CGSize sz = UIScreen.mainScreen.bounds.size;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        for (CGFloat y = 50; y <= 112; y += 10)
            for (CGFloat x = 14; x <= 62; x += 16) {
                if (CFAbsoluteTimeGetCurrent() - t0 > 0.8) return nil;
                id el = axHitAt(CGPointMake(x, y));
                if (!el) continue;
                id fv = axKV(el, @"frame");
                if (![fv isKindOfClass:NSValue.class] || strcmp([(NSValue *)fv objCType], @encode(CGRect)) != 0) continue;
                CGRect r = [(NSValue *)fv CGRectValue];
                if (r.size.width < 8 || r.size.height < 8 || r.size.width > sz.width * 0.4 || r.size.height > 80) continue;
                if (CGRectGetMidX(r) > sz.width * 0.3 || CGRectGetMidY(r) > sz.height * 0.15 || CGRectGetMidY(r) < 40) continue;
                NSString *l = axKV(el, @"label"); if (![l isKindOfClass:NSString.class]) l = @"";
                unsigned long long t = [axKV(el, @"traits") unsignedLongLongValue];
                BOOL btn = (t & 0x1ULL) != 0;
                BOOL backWord = [l containsString:@"返回"] || [l.lowercaseString containsString:@"back"];
                if (!btn && !backWord) continue;
                return @{@"x": @(CGRectGetMidX(r)), @"y": @(CGRectGetMidY(r)), @"text": l.length ? l : @"(无文字按钮)"};
            }
    } @catch (NSException *e) {}
    return nil;
}

NSArray *axReadScreen(NSString *frontBid, int *msOut, NSString **howOut) {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    if (msOut) *msOut = 0;
    @try {
        axInitOnce();
        gAXLog = [NSMutableArray array];
        Class cE = NSClassFromString(@"AXElement");
        if (!cE) return @[];
        CGSize sz = UIScreen.mainScreen.bounds.size;
        id front = nil;
        if (frontBid.length && [frontBid isEqualToString:gAXFrontBid]) front = gAXFrontCache;
        if (!front) {
            SEL sa = NSSelectorFromString(@"applicationAtCoordinate:");
            if ([cE respondsToSelector:sa]) front = ((id (*)(id, SEL, CGPoint))objc_msgSend)(cE, sa, CGPointMake(sz.width / 2, sz.height / 2));
            gAXFrontCache = front; gAXFrontBid = frontBid;
        }
        if (!front) return @[];
        // 两种读法:explorerElements(淘宝这类)和 children 递归(微信这类),取有文字元素多的
        NSArray *list = nil; NSString *how = @"explorer";
        id ex = axCallObj(front, @"explorerElements");
        NSArray *exArr = [ex isKindOfClass:NSArray.class] ? ex : @[];
        int exLab = 0;
        for (id e in exArr) { NSString *l = axKV(e, @"label"); if ([l isKindOfClass:NSString.class] && l.length) exLab++; }
        list = exArr;
        if (exLab < 12) {
            NSMutableArray *acc = [NSMutableArray array];
            axCollect(front, 0, acc, [NSMutableSet set], CFAbsoluteTimeGetCurrent());
            int chLab = 0;
            for (id e in acc) { NSString *l = axKV(e, @"label"); if ([l isKindOfClass:NSString.class] && l.length) chLab++; }
            if (chLab > exLab) { list = acc; how = @"children"; }
        }
        { // v0.9.34:列表里几乎没有中间区域的内容(京东搜索页商品卡不在列表里),补一次稀疏网格取点
            int content = 0;
            for (id e in list) {
                NSString *l = axKV(e, @"label"); id fv = axKV(e, @"frame");
                if (![l isKindOfClass:NSString.class] || l.length < 6 || ![fv isKindOfClass:NSValue.class] || strcmp([(NSValue *)fv objCType], @encode(CGRect)) != 0) continue;
                CGFloat my = CGRectGetMidY([(NSValue *)fv CGRectValue]);
                if (my > sz.height * 0.15 && my < sz.height * 0.85) content++;
            }
            if (content < 3) {
                NSMutableArray *ml = [list mutableCopy] ?: [NSMutableArray array];
                NSMutableSet *hk = [NSMutableSet set];
                int got = 0;
                for (CGFloat y = sz.height * 0.15; y < sz.height * 0.92; y += 60)
                    for (CGFloat fx = 0.25; fx < 0.8; fx += 0.5) {
                        if (CFAbsoluteTimeGetCurrent() - t0 > 0.6) break;
                        id el = axHitAt(CGPointMake(sz.width * fx, y));
                        if (!el) continue;
                        NSString *l = axKV(el, @"label"); id fv = axKV(el, @"frame");
                        NSString *k = [NSString stringWithFormat:@"%@|%@", l ?: @"", fv ?: @""];
                        if ([hk containsObject:k]) continue;
                        [hk addObject:k]; [ml addObject:el]; got++;
                    }
                if (got) { list = ml; how = [how stringByAppendingString:@"+grid"]; }
            }
        }
        if (howOut) *howOut = how;
        NSMutableArray *out = [NSMutableArray array];
        NSMutableSet *dup = [NSMutableSet set];
        for (id e in list) {
            if (out.count >= 70) break;
            NSString *label = axKV(e, @"label"); if (![label isKindOfClass:NSString.class]) label = @"";
            label = [label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            id fv = axKV(e, @"frame");
            if (![fv isKindOfClass:NSValue.class] || strcmp([(NSValue *)fv objCType], @encode(CGRect)) != 0) continue;
            CGRect full = [(NSValue *)fv CGRectValue];
            CGRect r = CGRectIntersection(full, CGRectMake(0, 0, sz.width, sz.height));
            if (CGRectIsNull(r) || r.size.width < 4 || r.size.height < 4) continue;
            // 只要屏幕上看得见的:露出不到一半的(屏幕外的聊天、横向滚出去的标签)不要
            if (full.size.width > 0 && full.size.height > 0 && (r.size.width * r.size.height) < 0.5 * full.size.width * full.size.height) continue;
            if (r.origin.y + r.size.height <= 46 && r.size.height < 30) continue;            // 状态栏
            if (r.size.width >= sz.width * 0.95 && r.size.height >= sz.height * 0.8) continue; // 整屏容器
            unsigned long long t = [axKV(e, @"traits") unsignedLongLongValue];
            BOOL input = (t & 0x400ULL) || (t & 0x40000ULL);
            if (!label.length && !input) continue;
            if ([label containsString:@"辅助触控"] || [label containsString:@"滚动条"] || [label isEqualToString:@"标签页栏"] || [label isEqualToString:@"工具栏"]) continue;
            NSString *val = axKV(e, @"value");
            NSString *text = label;
            if ([val isKindOfClass:NSString.class] && val.length && val.length <= 40 && ![label containsString:val]) text = [NSString stringWithFormat:@"%@:%@", label, val];
            if (!text.length) text = @"(无文字)";
            text = axTidy(text);
            NSString *dk = [NSString stringWithFormat:@"%@|%d|%d", text, (int)CGRectGetMidX(r), (int)CGRectGetMidY(r)];
            if ([dup containsObject:dk]) continue;
            [dup addObject:dk];
            NSMutableDictionary *d = [@{@"text": text, @"x": @((int)round(CGRectGetMidX(r))), @"y": @((int)round(CGRectGetMidY(r))),
                                        @"w": @((int)round(r.size.width)), @"h": @((int)round(r.size.height)), @"ax": @YES} mutableCopy];
            if (input) d[@"axin"] = (t & 0x400ULL) ? @"搜索框" : @"输入框";
            else if ((t & 0x1ULL) || (t & 0x2ULL)) d[@"axbtn"] = @YES; // v0.9.38:链接也算可点
            else if (t & 0x10000ULL) d[@"axhdr"] = @YES;              // v0.9.38:标题(一般不可点)
            if ([label containsString:@"已选中"]) d[@"axsel"] = @YES;
            [out addObject:d];
        }
        // v0.9.33:被拆开的价格「¥」+「58.60」按位置拼回一个
        for (NSInteger i = (NSInteger)out.count - 1; i >= 0; i--) {
            NSMutableDictionary *a = out[i];
            if (![a[@"text"] isEqualToString:@"¥"]) continue;
            for (NSMutableDictionary *b in out) {
                if (b == a) continue;
                NSString *bt = b[@"text"];
                double dx = [b[@"x"] doubleValue] - [a[@"x"] doubleValue], dy = fabs([b[@"y"] doubleValue] - [a[@"y"] doubleValue]);
                if (dx <= 0 || dx > 40 || dy > 8 || !bt.length) continue;
                if ([bt rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789.万+"] invertedSet]].location != NSNotFound) continue;
                b[@"text"] = [@"¥" stringByAppendingString:bt];
                [out removeObjectAtIndex:i];
                break;
            }
        }
        if (out.count < 3) { gAXFrontCache = nil; gAXFrontBid = nil; } // v0.9.34:读到太少多半是启动时缓存的旧对象,下次重新取
        if (msOut) *msOut = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000);
        return out;
    } @catch (NSException *e) {
        if (msOut) *msOut = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000);
        return @[];
    }
}
