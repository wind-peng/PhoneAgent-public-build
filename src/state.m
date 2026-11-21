// PhoneAgent:全局状态、设置、安全规则、经验库
#import "pa_internal.h"

#pragma mark - 本地 HTTP 接口

// 智能体部分在后面定义,这里先声明
NSMutableArray *gAgentLog; // 最近的任务日志,给 /status 用
volatile BOOL gBroadcastStopRequested; // 任务结束时请扩展关闭录屏
RPSystemBroadcastPickerView *gPicker;   // 界面里的录屏选择按钮(自动开启录屏时要用)
NSMutableArray *gRunLog;          // 本次任务的完整日志(结果窗口用)
NSString *gTaskStatus, *gTaskResultText, *gLastResultText, *gTaskDisplay, *gLastSpeechText;
NSArray *gRunImages;              // 本次任务附带的图片(JPEG 数据)
NSMutableArray *gAttachImages, *gAttachNames; // 界面里已选的附件
NSMutableString *gAttachText;     // 界面里已选文件的文字内容

// ---- 需要用户参与的请求(暂停 / 确认):界面弹窗、通知按钮、URL、HTTP 都可以回应 ----
volatile int gReqState;
NSString *gReqKind, *gReqText;
volatile BOOL gConfirmSkipThisTask;   // 用户选了“本次任务不再问”
void agentRespond(int st) { if (gReqState == PAReqWaiting) gReqState = st; }
// ---- 经验库 ----
NSMutableArray *gExpSteps;            // 本次任务已执行的步骤(成功后存进经验库)
NSString *gExpHint, *gExpReplayID;    // 给模型的参考提示 / 本次回放用到的经验 id
BOOL gExpReplayAborted;               // 回放中途中止过

// 读已保存的设置(空字符串按没有处理)。模型名在界面里存的键是 llm_model。
static NSString *savedSetting(NSString *k, NSString *def) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:k];
    return v.length ? v : def;
}

// ---- 模型提供商:每个提供商各自保存 API Key / 接口地址 / 模型名 ----
static NSArray *defaultProviders(void) {
    return @[
        @{@"id": @"deepseek", @"name": @"DeepSeek", @"base": @"https://api.deepseek.com", @"model": @"deepseek-flash"},
        @{@"id": @"glm", @"name": @"智谱 GLM-5.3", @"base": @"https://open.bigmodel.cn/api/paas/v4", @"model": @"glm-5.3-flash"},
        @{@"id": @"autoglm", @"name": @"智谱 AutoGLM-Phone", @"base": @"https://open.bigmodel.cn/api/paas/v4", @"model": @"autoglm-phone"},
        @{@"id": @"custom", @"name": @"自定义(OpenAI 兼容接口)", @"base": @"", @"model": @""}];
}
// 模型列表保存在本机;没改过就用上面的默认列表。界面里可以添加、删除。
NSArray *providerList(void) {
    NSData *d = [NSUserDefaults.standardUserDefaults dataForKey:@"providers_json"];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([o isKindOfClass:NSArray.class] && [o count]) return o;
    return defaultProviders();
}
void saveProviders(NSArray *list) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    if (d) [NSUserDefaults.standardUserDefaults setObject:d forKey:@"providers_json"];
}
NSString *selectedProviderID(void) {
    NSString *cur = savedSetting(@"provider", @"deepseek");
    NSArray *list = providerList();
    for (NSDictionary *p in list) if ([p[@"id"] isEqualToString:cur]) return cur;
    return [list.firstObject[@"id"] description] ?: @"deepseek";
}
NSString *providerDefault(NSString *pid, NSString *field) {
    for (NSDictionary *p in providerList()) if ([p[@"id"] isEqualToString:pid]) return p[field] ?: @"";
    return @"";
}
NSString *provValue(NSString *pid, NSString *field) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"p_%@_%@", pid, field]];
    if (v.length) return v;
    return [field isEqualToString:@"key"] ? @"" : providerDefault(pid, field);
}
void loadLLMConfig(NSString **key, NSString **base, NSString **model) {
    NSString *pid = selectedProviderID();
    *key = provValue(pid, @"key"); *base = provValue(pid, @"base"); *model = provValue(pid, @"model");
}

// ---- 安全设置:敏感操作确认、禁止进入的 App ----
NSString *defaultSensitiveWords(void) { return @"发送\n发布\n提交\n删除\n清空\n退出登录\n注销\n卸载\n授权\n拨打\n呼叫\n预订\n报名\n转发"; }
NSString *defaultBlockedApps(void) { return @"银行\n支付宝\n云闪付\n数字人民币\n京东金融\n蚂蚁财富\n钱包\nWallet"; }
static NSArray *splitList(NSString *t) {
    NSMutableArray *out = [NSMutableArray array];
    NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@"\n,，、;；"];
    for (NSString *p in [t componentsSeparatedByCharactersInSet:seps]) {
        NSString *x = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (x.length) [out addObject:x];
    }
    return out;
}
static NSArray *sensitiveWords(void) { return splitList([NSUserDefaults.standardUserDefaults stringForKey:@"sens_words"] ?: defaultSensitiveWords()); }
NSArray *blockedApps(void) { return splitList([NSUserDefaults.standardUserDefaults stringForKey:@"blocked_apps"] ?: defaultBlockedApps()); }
BOOL confirmEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"confirm_on"] ? [d boolForKey:@"confirm_on"] : YES;
}
BOOL isBlockedApp(NSString *name, NSString *bid) {
    for (NSString *e in blockedApps())
        if ([name localizedCaseInsensitiveContainsString:e] || [bid localizedCaseInsensitiveContainsString:e]) return YES;
    return NO;
}
// 涉及花钱的词:永远不自动点击,只能请用户本人完成(不受“敏感操作确认”开关影响)
static NSArray *moneyWords(void) {
    return @[@"支付", @"付款", @"结算", @"提交订单", @"立即购买", @"去支付", @"转账", @"汇款", @"充值", @"红包", @"免密支付", @"支付密码"];
}
// 点击位置附近(OCR 框外扩 25pt)的文字
static NSString *textNear(NSArray *items, double x, double y) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *it in items) {
        double dx = fabs([it[@"x"] doubleValue] - x), dy = fabs([it[@"y"] doubleValue] - y);
        double hw = [it[@"w"] doubleValue] / 2 + 25, hh = [it[@"h"] doubleValue] / 2 + 25;
        if (dx <= hw && dy <= hh) [parts addObject:it[@"text"] ?: @""];
    }
    return [parts componentsJoinedByString:@" "];
}
// 恰好落在某个 OCR 框里(外扩 12pt)的那段文字,没有就返回空
NSString *nearestItemText(NSArray *items, double x, double y) {
    NSString *best = @""; double bd = 1e9;
    for (NSDictionary *it in items) {
        double dx = fabs(x - [it[@"x"] doubleValue]), dy = fabs(y - [it[@"y"] doubleValue]);
        double hw = [it[@"w"] doubleValue] / 2 + 12, hh = [it[@"h"] doubleValue] / 2 + 12;
        if (dx <= hw && dy <= hh && dx + dy < bd) { bd = dx + dy; best = it[@"text"] ?: @""; }
    }
    return best;
}
// category:2 = 涉及花钱(只能用户本人操作),1 = 需要先征得用户同意
static NSString *sensitiveMatch(NSString *text, int *category) {
    if (!text.length) return nil;
    for (NSString *w in moneyWords()) if ([text containsString:w]) { *category = 2; return w; }
    if (!confirmEnabled()) return nil;
    for (NSString *w in sensitiveWords()) if ([text localizedCaseInsensitiveContainsString:w]) { *category = 1; return w; }
    return nil;
}
// 综合“按钮名 + 点击位置附近的文字 + 模型写的风险说明”判断这一步是否敏感
NSString *classifyAction(NSString *target, NSString *risk, NSArray *items, double x, double y, int *category) {
    NSString *near = items.count ? textNear(items, x, y) : @"";
    NSString *blob = [NSString stringWithFormat:@"%@ %@ %@", target ?: @"", near, risk ?: @""];
    int cat = 0;
    NSString *w = sensitiveMatch(blob, &cat);
    // 只有安全设置中的敏感词命中时才请求确认；模型的 risk 仅用于辅助判断和日志，
    // 不再因为模型自行填写 risk 就绕过用户的敏感词设置强制弹确认。
    *category = cat;
    return w;
}

// ---- 经验库:存取、相似度、提示 ----
BOOL expEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"exp_on"] ? [d boolForKey:@"exp_on"] : YES;
}
BOOL expReplayEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"exp_replay_on"] ? [d boolForKey:@"exp_replay_on"] : YES;
}
NSMutableArray *expLoad(void) {
    NSData *d = [NSUserDefaults.standardUserDefaults dataForKey:@"exp_json"];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    return [o isKindOfClass:NSMutableArray.class] ? o : [NSMutableArray array];
}
void expSave(NSArray *arr) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
    if (d) [NSUserDefaults.standardUserDefaults setObject:d forKey:@"exp_json"];
}
static NSSet *expBigrams(NSString *t) {
    NSMutableString *s = [NSMutableString string];
    NSCharacterSet *skip = [NSCharacterSet characterSetWithCharactersInString:@" \t\n,.。,!?;:、“”\"'()[]【】"];
    for (NSUInteger i = 0; i < t.length; i++) { unichar c = [t characterAtIndex:i]; if (![skip characterIsMember:c]) [s appendFormat:@"%C", c]; }
    NSString *n = s.lowercaseString;
    NSMutableSet *set = [NSMutableSet set];
    if (n.length < 2) { if (n.length) [set addObject:n]; return set; }
    for (NSUInteger i = 0; i + 1 < n.length; i++) [set addObject:[n substringWithRange:NSMakeRange(i, 2)]];
    return set;
}
// 两句任务的相似度(字对的重合比例,0~1)
static double expSim(NSString *a, NSString *b) {
    NSSet *A = expBigrams(a ?: @""), *B = expBigrams(b ?: @"");
    if (!A.count || !B.count) return 0;
    NSMutableSet *inter = [A mutableCopy]; [inter intersectSet:B];
    NSMutableSet *uni = [A mutableCopy]; [uni unionSet:B];
    return (double)inter.count / (double)uni.count;
}
NSMutableDictionary *expFind(NSString *task, double *score) {
    NSMutableDictionary *best = nil; double bs = 0;
    for (NSMutableDictionary *e in expLoad()) { double sc = expSim(task, e[@"task"]); if (sc > bs) { bs = sc; best = e; } }
    *score = bs;
    return best;
}
NSString *expStepDesc(NSDictionary *st) {
    NSString *a = st[@"a"] ?: @"", *t = st[@"t"] ?: @"";
    if ([a isEqualToString:@"open_app"]) return [NSString stringWithFormat:@"打开 App「%@」", st[@"name"] ?: @""];
    if ([a isEqualToString:@"tap"]) return t.length ? [NSString stringWithFormat:@"点击「%@」", t] : @"点击一个没有文字的图标";
    if ([a isEqualToString:@"double_tap"]) return t.length ? [NSString stringWithFormat:@"双击「%@」", t] : @"双击";
    if ([a isEqualToString:@"long_press"]) return t.length ? [NSString stringWithFormat:@"长按「%@」", t] : @"长按";
    if ([a isEqualToString:@"input_text"]) return [NSString stringWithFormat:@"在%@输入「%@」", t.length ? [NSString stringWithFormat:@"「%@」", t] : @"输入框", st[@"text"] ?: @""];
    if ([a isEqualToString:@"swipe"]) return @"滑动";
    if ([a isEqualToString:@"home"]) return @"回主屏幕";
    if ([a isEqualToString:@"back"]) return @"返回";
    if ([a isEqualToString:@"ask_user"]) return [NSString stringWithFormat:@"请用户处理:%@", st[@"text"] ?: @""];
    return a;
}
// 给模型的参考:最相似的两条成功经验(相似度 >= 0.3)
NSString *expHintFor(NSString *task) {
    if (!expEnabled() || !task.length) return @"";
    NSMutableArray *scored = [NSMutableArray array];
    for (NSDictionary *e in expLoad()) {
        double sc = expSim(task, e[@"task"]);
        if (sc >= 0.3) [scored addObject:@{@"s": @(sc), @"e": e}];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"s"] compare:a[@"s"]]; }];
    if (!scored.count) return @"";
    NSMutableString *h = [NSMutableString stringWithString:@"过往成功经验(仅供参考,界面可能已经变化,一切以当前截图为准):"];
    for (NSUInteger i = 0; i < MIN((NSUInteger)2, scored.count); i++) {
        NSDictionary *e = scored[i][@"e"];
        NSArray *steps = e[@"steps"];
        NSMutableArray *ds = [NSMutableArray array];
        for (NSUInteger k = 0; k < MIN((NSUInteger)15, steps.count); k++) [ds addObject:[NSString stringWithFormat:@"%lu) %@", (unsigned long)k + 1, expStepDesc(steps[k])]];
        [h appendFormat:@"\n· 任务「%@」:%@", e[@"task"], [ds componentsJoinedByString:@" "]];
    }
    return h;
}
void expRecord(NSDictionary *step) {
    if (!gExpSteps) gExpSteps = [NSMutableArray array];
    if (gExpSteps.count < 80) [gExpSteps addObject:step];
}
// 屏幕上有代表性的几段文字(用来在回放时核对“现在的屏幕和当时是不是同一个页面”)
NSArray *expAnchors(NSArray *items) {
    NSArray *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int ya = [a[@"y"] intValue] / 12, yb = [b[@"y"] intValue] / 12;
        if (ya != yb) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
        return [(NSNumber *)a[@"x"] compare:(NSNumber *)b[@"x"]];
    }];
    NSCharacterSet *plain = [NSCharacterSet characterSetWithCharactersInString:@"0123456789:%. "];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in sorted) {
        NSString *t = [it[@"text"] description];
        if (t.length < 2 || t.length > 12 || [out containsObject:t]) continue;
        if ([t rangeOfCharacterFromSet:plain.invertedSet].location == NSNotFound) continue; // 纯数字/时间/电量
        [out addObject:t];
        if (out.count >= 6) break;
    }
    return out;
}
// 任务结束时存进经验库:成功完成才存;已有几乎相同的经验就合并(留步数更少的那条)
void expFinish(NSString *task, NSString *status) {
    if (!expEnabled()) return;
    NSMutableArray *all = expLoad();
    BOOL ok = [status isEqualToString:@"已完成"];
    NSMutableDictionary *target = nil;
    if (gExpReplayID.length) for (NSMutableDictionary *e in all) if ([e[@"id"] isEqualToString:gExpReplayID]) target = e;
    if (!target && ok) {
        double sc = 0; NSMutableDictionary *best = nil;
        for (NSMutableDictionary *e in all) { double v = expSim(task, e[@"task"]); if (v > sc) { sc = v; best = e; } }
        if (best && sc >= 0.9) target = best;
    }
    if (target) {
        if (gExpReplayAborted) target[@"fail"] = @([target[@"fail"] intValue] + 1);
        else if (ok) target[@"ok"] = @([target[@"ok"] intValue] + 1);
        if (ok && gExpSteps.count >= 2 && gExpSteps.count < [target[@"steps"] count]) target[@"steps"] = [gExpSteps copy];
        if ([target[@"fail"] intValue] >= 3 && [target[@"fail"] intValue] > [target[@"ok"] intValue]) [all removeObject:target]; // 老是失效的经验自动淘汰
    } else if (ok && gExpSteps.count >= 2 && gExpSteps.count <= 60) {
        [all addObject:[@{@"id": [NSUUID UUID].UUIDString, @"task": task ?: @"", @"created": @([NSDate date].timeIntervalSince1970),
                          @"used": @0, @"ok": @1, @"fail": @0, @"steps": [gExpSteps copy]} mutableCopy]];
    }
    while (all.count > 100) [all removeObjectAtIndex:0];
    expSave(all);
}
