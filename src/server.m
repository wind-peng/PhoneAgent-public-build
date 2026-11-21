// PhoneAgent:本地 HTTP 接口
#import "pa_internal.h"

NSString *gToken;

NSString *frameKey(void) { return @FRAME_KEY; }

static void sendResp(int c, int code, NSString *ctype, NSData *body) {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        code, ctype, (unsigned long)body.length];
    NSData *hd = [head dataUsingEncoding:NSUTF8StringEncoding];
    write(c, hd.bytes, hd.length);
    const uint8_t *p = body.bytes; size_t left = body.length;
    while (left > 0) {
        ssize_t n = write(c, p, left);
        if (n <= 0) break;
        p += n; left -= n;
    }
    close(c);
}

static void sendJSON(int c, int code, id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data];
    sendResp(c, code, @"application/json; charset=utf-8", d);
}

static void handleClient(int c) {
    {   // 防止客户端连上后不发数据/不收数据把线程一直卡住;对方断开时写入也不要触发 SIGPIPE
        struct timeval tv = {5, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        int on = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    }
    NSMutableData *raw = [NSMutableData data];
    char buf[65536];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange he = NSMakeRange(NSNotFound, 0);
    while (he.location == NSNotFound && raw.length < 262144) {
        ssize_t n = read(c, buf, sizeof buf);
        if (n <= 0) break;
        [raw appendBytes:buf length:n];
        he = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
    }
    if (he.location == NSNotFound) { close(c); return; }
    NSString *head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, he.location)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    NSUInteger bodyStart = he.location + 4;
    long long clen = 0;
    for (NSString *ln in [head componentsSeparatedByString:@"\r\n"])
        if ([ln.lowercaseString hasPrefix:@"content-length:"]) clen = [[ln substringFromIndex:15] longLongValue];
    if (clen < 0 || clen > 8 * 1024 * 1024) { close(c); return; }
    while (raw.length < bodyStart + clen) {
        ssize_t n = read(c, buf, sizeof buf);
        if (n <= 0) break;
        [raw appendBytes:buf length:n];
    }
    NSData *body = (clen > 0 && raw.length >= bodyStart + clen)
        ? [raw subdataWithRange:NSMakeRange(bodyStart, (NSUInteger)clen)] : nil;
    NSArray *parts = [[[head componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
    if (parts.count < 2) { close(c); return; }
    NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://h" stringByAppendingString:parts[1]]];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
    NSString *path = uc.path ?: @"/";
    CGSize s = screenSize();

    if ([path isEqualToString:@"/ping"]) {
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"version": @"0.9.20", @"broadcast": @(broadcastAlive())});
        return;
    }
    if ([path isEqualToString:@"/frame"] || [path isEqualToString:@"/hb"] || [path isEqualToString:@"/bye"]) {
        NSString *fk = frameKey();
        if (!fk.length || ![q[@"key"] isEqualToString:fk]) {
            sendJSON(c, 403, @{@"ok": @NO});
            return;
        }
        BOOL was = broadcastAlive();
        @synchronized (gLock) {
            if ([path isEqualToString:@"/bye"]) {
                gHbT = 0;
                gBroadcastStopRequested = NO;
            } else {
                gHbT = CFAbsoluteTimeGetCurrent();
                if (q[@"is"]) gExtIS = [q[@"is"] intValue];
                if (body.length && [path isEqualToString:@"/frame"]) {
                    NSData *jpg = body, *nv = nil; uint32_t w = 0, h = 0, fmt = 0;
                    if (body.length >= 24 && memcmp(body.bytes, "PAF1", 4) == 0) {
                        uint32_t hd[6]; memcpy(hd, body.bytes, 24);
                        uint32_t jl = hd[3], nl = hd[4];
                        if (24 + (uint64_t)jl + nl <= body.length) {
                            w = hd[1]; h = hd[2]; fmt = hd[5];
                            jpg = [body subdataWithRange:NSMakeRange(24, jl)];
                            nv = nl ? [body subdataWithRange:NSMakeRange(24 + jl, nl)] : nil;
                        }
                    }
                    gFrame = jpg; gNV12 = nv; gNW = w; gNH = h; gNFmt = fmt; gFrameT = gHbT;
                }
            }
        }
        BOOL now = broadcastAlive();
        if (!was && now) [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"广播扩展已连接(扩展内创建 IOSurface:%@)", gExtIS == 1 ? @"成功" : gExtIS == 0 ? @"失败" : @"未知"]];
        if (was && !now) [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"广播已停止"];
        sendJSON(c, 200, @{@"ok": @YES, @"cmd": gBroadcastStopRequested ? @"stop" : @""});
        return;
    }
    if (![q[@"token"] isEqualToString:gToken]) {
        sendJSON(c, 403, @{@"ok": @NO, @"error": @"token 不对"});
        return;
    }
    if ([path isEqualToString:@"/tap"]) {
        doTap([q[@"x"] doubleValue], [q[@"y"] doubleValue]);
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/swipe"]) {
        int ms = q[@"ms"] ? [q[@"ms"] intValue] : 300;
        doSwipe([q[@"x1"] doubleValue], [q[@"y1"] doubleValue],
                [q[@"x2"] doubleValue], [q[@"y2"] doubleValue], 20, ms);
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/open"]) {
        BOOL ok = openApp(q[@"bundle"] ?: @"");
        sendJSON(c, 200, @{@"ok": @(ok)});
    } else if ([path isEqualToString:@"/screenshot"]) {
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { sendJSON(c, 500, @{@"ok": @NO, @"error": err ?: @"未知错误"}); return; }
        img = resizeToWidth(img, [q[@"w"] doubleValue]);
        sendResp(c, 200, @"image/jpeg", UIImageJPEGRepresentation(img, 0.6));
    } else if ([path isEqualToString:@"/task"]) {
        // 给快捷指令/Siri 用:GET /task?token=..&text=<URL 编码的任务>,或 POST 正文直接放任务文字
        NSString *task = q[@"text"];
        if (!task.length && body.length) task = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSString *key = nil, *base = nil, *model = nil; loadLLMConfig(&key, &base, &model);
        if (!task.length) { sendJSON(c, 400, @{@"ok": @NO, @"error": @"没有任务文字"}); return; }
        if (!key.length || !base.length || !model.length) {
            sendJSON(c, 400, @{@"ok": @NO, @"error": @"还没保存 API 设置:请先在 App 里点一次“开始任务”或“看图测试”"});
            return;
        }
        if (gAgentRunning) { sendJSON(c, 409, @{@"ok": @NO, @"error": @"已有任务在运行"}); return; }
        {
            NSUserDefaults *u2 = NSUserDefaults.standardUserDefaults;
            BOOL autoCast = [u2 objectForKey:@"auto_cast"] ? [u2 boolForKey:@"auto_cast"] : YES;
            if (!autoCast && !broadcastAlive()) { sendJSON(c, 409, @{@"ok": @NO, @"error": @"屏幕广播没开,请先在 PhoneAgent 里开启,或打开“任务时自动开启/关闭屏幕录制”开关"}); return; }
        }
        agentSay([NSString stringWithFormat:@"收到语音任务:%@", task]);
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"收到语音任务:%@", task]];
        gRunImages = nil; gTaskDisplay = task;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(task, base, key, model); });
        sendJSON(c, 200, @{@"ok": @YES, @"task": task});
    } else if ([path isEqualToString:@"/respond"]) {
        // 回应“暂停/确认”请求:action = allow|resume(允许/继续) allowall(允许且本次不再问) deny(拒绝) stop(停止任务)
        NSString *a = q[@"action"] ?: @"";
        int st = ([a isEqualToString:@"allow"] || [a isEqualToString:@"resume"]) ? PAReqAllow : [a isEqualToString:@"allowall"] ? PAReqAllowAll :
                 [a isEqualToString:@"deny"] ? PAReqDeny : [a isEqualToString:@"stop"] ? PAReqStop : 0;
        if (!st) { sendJSON(c, 400, @{@"ok": @NO, @"error": @"action 应为 allow/resume/allowall/deny/stop"}); return; }
        agentRespond(st);
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/stop"]) {
        gAgentRunning = NO;
        sendJSON(c, 200, @{@"ok": @YES});
    } else if ([path isEqualToString:@"/status"]) {
        NSArray *lines;
        @synchronized (gLock) { lines = [gAgentLog copy] ?: @[]; }
        NSUInteger n = lines.count > 15 ? lines.count - 15 : 0;
        sendJSON(c, 200, @{@"ok": @YES, @"running": @(gAgentRunning), @"waiting": @(gReqState == PAReqWaiting), @"broadcast": @(broadcastAlive()),
                           @"log": [lines subarrayWithRange:NSMakeRange(n, lines.count - n)]});
    } else if ([path isEqualToString:@"/ocr"]) {
        NSString *err = nil;
        UIImage *img = takeScreenshot(&err);
        if (!img) { sendJSON(c, 500, @{@"ok": @NO, @"error": err ?: @"未知错误"}); return; }
        NSArray *items = ocrImage(img, &err);
        if (!items) { sendJSON(c, 500, @{@"ok": @NO, @"error": err ?: @"未知错误"}); return; }
        sendJSON(c, 200, @{@"ok": @YES, @"w": @(s.width), @"h": @(s.height), @"items": items});
    } else {
        sendJSON(c, 404, @{@"ok": @NO, @"error": @"未知接口"});
    }
}

NSString *startServer(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return @"socket 失败";
    int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock, (struct sockaddr *)&a, sizeof a) != 0) { close(sock); return [NSString stringWithFormat:@"bind %d 失败(端口被占用?)", PORT]; }
    if (listen(sock, 8) != 0) { close(sock); return @"listen 失败"; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (1) {
            int c = accept(sock, NULL, NULL);
            if (c < 0) continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ handleClient(c); });
        }
    });
    return nil;
}
