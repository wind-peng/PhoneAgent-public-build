// PhoneAgent:打开 App、后台保活
#import "pa_internal.h"

#pragma mark - 打开 App

BOOL openApp(NSString *bid) {
    // v0.9.67 小窗模式:任务中打开别的 App 时,改为在 PhoneAgent 的小窗里打开
    if (winEnabled() && gAgentRunning && bid.length && ![bid isEqualToString:NSBundle.mainBundle.bundleIdentifier] && ![bid isEqualToString:@"com.apple.springboard"]) {
        BOOL skip = winSkipped(bid);
        NSString *n = nil;
        BOOL ok = skip ? NO : winOpen(bid, &n);
        if (ok) { agentSay([NSString stringWithFormat:@"小窗:%@", n ?: @"已打开"]); return YES; }
        // v0.9.77:小窗打不开或全黑 → 本次任务改用普通方式(自动开屏幕录制,App 全屏打开)
        agentSay(skip ? @"小窗:这个 App 之前在小窗里是全黑的,改用普通方式(屏幕录制)打开"
                      : [NSString stringWithFormat:@"小窗打开失败:%@;改用普通方式(屏幕录制)打开", n ?: @""]);
        if (!skip && [n containsString:@"全黑"]) winSkipAdd(bid);
        winShutdown();
        winSetFallback(YES);
        if (!winFallbackCast()) { // v0.9.78:录屏没开成就停,不让模型看不见画面乱点
            agentSay(@"任务停止:改用普通方式需要屏幕录制,但没能自动开启");
            gAgentRunning = NO;
            return NO;
        }
    }
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace"));
    if (!ws) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"openApplicationWithBundleID:"), bid);
}

#pragma mark - 后台保活(静音循环)

AVAudioPlayer *gPlayer;

static NSData *silentWav(void) {
    uint32_t rate = 8000, n = rate * 2, dataLen = n; // 1 秒 16bit 单声道
    NSMutableData *d = [NSMutableData data];
    void (^w32)(uint32_t) = ^(uint32_t v) { [d appendBytes:&v length:4]; };
    void (^w16)(uint16_t) = ^(uint16_t v) { [d appendBytes:&v length:2]; };
    [d appendBytes:"RIFF" length:4]; w32(36 + dataLen);
    [d appendBytes:"WAVEfmt " length:8]; w32(16); w16(1); w16(1); w32(rate); w32(rate * 2); w16(2); w16(16);
    [d appendBytes:"data" length:4]; w32(dataLen);
    [d increaseLengthBy:dataLen];
    return d;
}

void resumeKeepAlive(void) {
    if (!gPlayer) return;
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    if (!gPlayer.isPlaying) [gPlayer play];
}

NSString *setKeepAlive(BOOL on) {
    static BOOL observing;
    if (on && !observing) {
        observing = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if ([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) resumeKeepAlive();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (gPlayer) { gPlayer = nil; setKeepAlive(YES); }
        }];
        [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { resumeKeepAlive(); }];
    }
    if (!on) { [gPlayer stop]; gPlayer = nil; return @"后台保活已关"; }
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSError *e = nil;
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e];
    [s setActive:YES error:&e];
    gPlayer = [[AVAudioPlayer alloc] initWithData:silentWav() error:&e];
    if (!gPlayer) return [NSString stringWithFormat:@"保活失败: %@", e.localizedDescription];
    gPlayer.numberOfLoops = -1;
    gPlayer.volume = 0.01;
    [gPlayer play];
    return @"后台保活已开";
}
