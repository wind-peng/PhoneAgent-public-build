// PhoneAgentBroadcast:ReplayKit 广播上传扩展。
// 系统把整机屏幕画面交给这里,我们压成 JPEG,用本机 socket 发给主 App(127.0.0.1)。
#import <ReplayKit/ReplayKit.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <string.h>
#import <dlfcn.h>
#import <CoreVideo/CoreVideo.h>
#import "shared.h"

static NSString *postToHost(NSString *path, NSData *body) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return @"";
    struct timeval tv = {2, 0};
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return @""; }
    NSString *h = [NSString stringWithFormat:
        @"POST %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        path, (unsigned long)body.length];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (write(s, hd.bytes, hd.length) < 0) { close(s); return @""; }
    const uint8_t *p = body.bytes; size_t left = body.length;
    while (left > 0) {
        ssize_t n = write(s, p, left);
        if (n <= 0) break;
        p += n; left -= n;
    }
    NSMutableData *resp = [NSMutableData data];
    char buf[512]; ssize_t rn;
    while ((rn = read(s, buf, sizeof buf)) > 0) { [resp appendBytes:buf length:rn]; if (resp.length > 4096) break; }
    close(s);
    return [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding] ?: @"";
}

// 在扩展进程里试一下能不能创建 IOSurface(用来判断这个限制是不是整个 App 都有)
static int iosurfaceWorks(void) {
    void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!h) return -1;
    void *(*create)(CFDictionaryRef) = dlsym(h, "IOSurfaceCreate");
    if (!create) return -1;
    NSDictionary *d = @{@"IOSurfaceWidth": @64, @"IOSurfaceHeight": @64,
                        @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @(0x42475241)};
    void *sf = create((__bridge CFDictionaryRef)d);
    if (sf) { CFRelease(sf); return 1; }
    return 0;
}

@interface SampleHandler : RPBroadcastSampleHandler
@end

@implementation SampleHandler {
    CIContext *_ci;
    CFAbsoluteTime _last;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    volatile int _inflight;
    int _isf;
    CVPixelBufferRef _pending;
    dispatch_queue_t _procQ;
    dispatch_source_t _flushTimer;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    signal(SIGPIPE, SIG_IGN);
    _isf = iosurfaceWorks();
    _ci = [CIContext contextWithOptions:nil];
    _q = dispatch_queue_create("pa.net", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(_timer, ^{
        NSString *resp = postToHost([NSString stringWithFormat:@"/hb?key=%s&is=%d", FRAME_KEY, self->_isf], [NSData data]);
        if ([resp containsString:@"\"cmd\":\"stop\""]) { // 主 App 要求结束录屏(任务已完成)
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *msg = @"任务已结束,屏幕录制已自动关闭";
                [self finishBroadcastWithError:[NSError errorWithDomain:@"PhoneAgent" code:1
                                                               userInfo:@{NSLocalizedDescriptionKey: msg, NSLocalizedFailureReasonErrorKey: msg}]];
            });
        }
    });
    dispatch_resume(_timer);
    // 屏幕静止时系统不会再推新帧,所以"最后一帧"不能因为限速被丢掉:
    // 回调里只暂存最新一帧,由这个定时器每 0.3 秒取出来编码发送(trailing-edge)。
    _procQ = dispatch_queue_create("pa.proc", DISPATCH_QUEUE_SERIAL);
    _flushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _procQ);
    dispatch_source_set_timer(_flushTimer, DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_flushTimer, ^{ [self flushPending]; });
    dispatch_resume(_flushTimer);
}

- (void)broadcastFinished {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (_flushTimer) { dispatch_source_cancel(_flushTimer); _flushTimer = nil; }
    @synchronized (self) { if (_pending) { CVPixelBufferRelease(_pending); _pending = NULL; } }
    postToHost(@"/bye?key=" FRAME_KEY, [NSData data]);
}

- (void)processSampleBuffer:(CMSampleBufferRef)sb withType:(RPSampleBufferType)type {
    if (type != RPSampleBufferTypeVideo) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    @synchronized (self) {
        if (_pending) CVPixelBufferRelease(_pending);
        _pending = CVPixelBufferRetain(pb);
    }
}

- (void)flushPending {
    if (_inflight) return; // 上一帧还没发完,留着最新的等下一轮
    CVPixelBufferRef pb = NULL;
    @synchronized (self) { pb = _pending; _pending = NULL; }
    if (!pb) return;
    @autoreleasepool {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSData *jpg = [_ci JPEGRepresentationOfImage:ci colorSpace:cs
                                             options:@{(id)kCGImageDestinationLossyCompressionQuality: @0.85}];
        CGColorSpaceRelease(cs);
        if (!jpg) { CVPixelBufferRelease(pb); return; }

        // 同时把原始 NV12 数据(去掉行尾填充)一起发过去,主 App 的 OCR 可以直接用,不必再转格式
        uint32_t w = (uint32_t)CVPixelBufferGetWidth(pb), h = (uint32_t)CVPixelBufferGetHeight(pb);
        OSType fmt = CVPixelBufferGetPixelFormatType(pb);
        NSMutableData *nv = nil;
        if (CVPixelBufferGetPlaneCount(pb) == 2 &&
            (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
             fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) {
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            size_t yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0);
            size_t yrb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
            size_t cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1);
            size_t crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            const uint8_t *ys = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
            const uint8_t *cs2 = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
            if (ys && cs2) {
                nv = [NSMutableData dataWithLength:yw * yh + cw * 2 * ch];
                uint8_t *dst = nv.mutableBytes;
                for (size_t r = 0; r < yh; r++) memcpy(dst + r * yw, ys + r * yrb, yw);
                dst += yw * yh;
                for (size_t r = 0; r < ch; r++) memcpy(dst + r * cw * 2, cs2 + r * crb, cw * 2);
            }
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        }
        CVPixelBufferRelease(pb);
        uint32_t hdr[6] = {0x31464150 /* 'PAF1' */, w, h, (uint32_t)jpg.length, (uint32_t)nv.length, (uint32_t)fmt};
        NSMutableData *pkt = [NSMutableData dataWithCapacity:sizeof hdr + jpg.length + nv.length];
        [pkt appendBytes:hdr length:sizeof hdr];
        [pkt appendData:jpg];
        if (nv) [pkt appendData:nv];
        _inflight = 1;
        dispatch_async(_q, ^{
            postToHost(@"/frame?key=" FRAME_KEY, pkt);
            self->_inflight = 0;
        });
    }
}
@end
