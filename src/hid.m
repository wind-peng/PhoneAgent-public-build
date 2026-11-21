// PhoneAgent:IOHID 触摸/按键注入
#import "pa_internal.h"

#pragma mark - 触摸注入 (IOHID)


static IOHIDEventSystemClientRef (*pClientCreate)(CFAllocatorRef);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventRef (*pCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                         uint32_t, uint32_t, double, double, double, double, double,
                                         Boolean, Boolean, uint32_t);
static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                      double, double, double, double, double,
                                      Boolean, Boolean, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int64_t);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pSetFloat)(IOHIDEventRef, uint32_t, double);
static IOHIDEventRef (*pCreateKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
static IOHIDEventSystemClientRef gClient;
int gSwipeMode = 0; // 0 基础;1 +触点半径;2 +半径且移动事件带 Touch;3 +半径、慢速并在起止停顿;4 = 3 + 移动事件带 Range|Touch

NSString *loadHID(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return @"dlopen IOKit 失败";
#define LOAD(var, name) var = dlsym(h, name); if (!var) return @"缺少符号 " name;
    LOAD(pClientCreate, "IOHIDEventSystemClientCreate")
    LOAD(pDispatch, "IOHIDEventSystemClientDispatchEvent")
    LOAD(pCreateDigitizer, "IOHIDEventCreateDigitizerEvent")
    LOAD(pCreateFinger, "IOHIDEventCreateDigitizerFingerEvent")
    LOAD(pAppend, "IOHIDEventAppendEvent")
    LOAD(pSetInt, "IOHIDEventSetIntegerValue")
    LOAD(pSetSender, "IOHIDEventSetSenderID")
    pSetFloat = dlsym(h, "IOHIDEventSetFloatValue");           // 可选
    pCreateKeyboard = dlsym(h, "IOHIDEventCreateKeyboardEvent"); // 可选(Home 键用)
    gClient = pClientCreate(kCFAllocatorDefault);
    if (!gClient) return @"IOHIDEventSystemClientCreate 返回空";
    return nil;
}

// phase: 0=按下 1=移动 2=抬起;nx/ny 是 0~1 的归一化坐标
void sendFinger(double nx, double ny, int phase) {
    uint64_t t = mach_absolute_time();
    BOOL touching = (phase != 2);
    uint32_t mask = (phase == 1) ? 0x4 : 0x3;
    if (phase == 1) { if (gSwipeMode == 2) mask = 0x6; else if (gSwipeMode == 4) mask = 0x7; }
    IOHIDEventRef hand = pCreateDigitizer(kCFAllocatorDefault, t, 3, 0, 0, mask, 0,
                                          nx, ny, 0, 0, 0, touching, touching, 0);
    pSetInt(hand, 0xb0019, 1);
    IOHIDEventRef finger = pCreateFinger(kCFAllocatorDefault, t, 1, 2, mask, nx, ny, 0,
                                         touching ? 1.0 : 0.0, 0, touching, touching, 0);
    if (gSwipeMode >= 1 && pSetFloat) { pSetFloat(finger, 0xb0014, 0.04); pSetFloat(finger, 0xb0015, 0.04); } // 触点半径
    pAppend(hand, finger, 0);
    CFRelease(finger);
    pSetSender(hand, 0x8000000817319372ULL);
    pDispatch(gClient, hand);
    CFRelease(hand);
}

CGSize screenSize(void) { return UIScreen.mainScreen.bounds.size; } // pt

void doTap(double x, double y) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(60 * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

void doSwipe(double x1, double y1, double x2, double y2, int steps, int ms) {
    CGSize s = screenSize();
    if (gSwipeMode >= 3) { if (steps < 40) steps = 40; if (ms < 700) ms = 700; }
    if (steps < 2) steps = 2;
    sendFinger(x1 / s.width, y1 / s.height, 0);
    if (gSwipeMode >= 3) usleep(80 * 1000);
    for (int i = 1; i <= steps; i++) {
        double k = (double)i / steps;
        usleep(ms * 1000 / steps);
        sendFinger((x1 + (x2 - x1) * k) / s.width, (y1 + (y2 - y1) * k) / s.height, 1);
    }
    if (gSwipeMode >= 3) usleep(80 * 1000);
    sendFinger(x2 / s.width, y2 / s.height, 2);
}

// 硬件键盘快捷键:按住左 Command(0xE3)+ 一个字母键(键盘页 0x07):A=0x04,V=0x19
BOOL doCmdKey(uint32_t usage) {
    if (!pCreateKeyboard || !gClient) return NO;
    uint32_t seq[4][2] = {{0xE3, 1}, {usage, 1}, {usage, 0}, {0xE3, 0}};
    for (int i = 0; i < 4; i++) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, seq[i][0], seq[i][1] ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(60 * 1000);
    }
    return YES;
}

// 发一个无害的 Shift 键事件:对系统来说算"用户活动",可以重置自动锁屏计时
void doShiftKey(void) {
    if (!pCreateKeyboard || !gClient) return;
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, 0xE1, down ? true : false, 0);
        if (!e) return;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(40 * 1000);
    }
}

// 用 HID 的"Home 键"(消费者页 Menu)回主屏幕;返回是否发出了事件
BOOL doHomeKey(void) {
    if (!pCreateKeyboard || !gClient) return NO;
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x0C, 0x40, down ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(80 * 1000);
    }
    return YES;
}
