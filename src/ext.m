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
#import "shared.h"

static void postToHost(NSString *path, NSData *body) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return;
    struct timeval tv = {2, 0};
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return; }
    NSString *h = [NSString stringWithFormat:
        @"POST %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        path, (unsigned long)body.length];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (write(s, hd.bytes, hd.length) < 0) { close(s); return; }
    const uint8_t *p = body.bytes; size_t left = body.length;
    while (left > 0) {
        ssize_t n = write(s, p, left);
        if (n <= 0) break;
        p += n; left -= n;
    }
    char buf[128];
    (void)read(s, buf, sizeof buf);
    close(s);
}

@interface SampleHandler : RPBroadcastSampleHandler
@end

@implementation SampleHandler {
    CIContext *_ci;
    CFAbsoluteTime _last;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    volatile int _inflight;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    signal(SIGPIPE, SIG_IGN);
    _ci = [CIContext contextWithOptions:nil];
    _q = dispatch_queue_create("pa.net", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(_timer, ^{
        postToHost(@"/hb?key=" FRAME_KEY, [NSData data]);
    });
    dispatch_resume(_timer);
}

- (void)broadcastFinished {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    postToHost(@"/bye?key=" FRAME_KEY, [NSData data]);
}

- (void)processSampleBuffer:(CMSampleBufferRef)sb withType:(RPSampleBufferType)type {
    if (type != RPSampleBufferTypeVideo) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _last < 0.4 || _inflight) return; // 限速,且上一帧还没发完就丢掉这帧
    _last = now;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    @autoreleasepool {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSData *jpg = [_ci JPEGRepresentationOfImage:ci colorSpace:cs
                                             options:@{(id)kCGImageDestinationLossyCompressionQuality: @0.6}];
        CGColorSpaceRelease(cs);
        if (!jpg) return;
        _inflight = 1;
        dispatch_async(_q, ^{
            postToHost(@"/frame?key=" FRAME_KEY, jpg);
            self->_inflight = 0;
        });
    }
}
@end
