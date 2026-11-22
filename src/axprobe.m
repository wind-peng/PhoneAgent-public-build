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
