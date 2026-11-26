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
    // v0.9.44:所有注入坐标统一限制在屏幕内(经验回放、AutoGLM 的滑动之前没限制)
    if (!(nx >= 0)) nx = 0; if (nx > 0.9995) nx = 0.9995;
    if (!(ny >= 0)) ny = 0; if (ny > 0.9995) ny = 0.9995;
    // v0.9.67 小窗模式:App 坐标换到右上角小窗里;PhoneAgent 进了后台就不发(小窗不在屏幕上,会点到别的 App)
    if (winTouchBlocked()) return;
    winMapNorm(&nx, &ny);
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

// v0.9.6:设置里打开“应用触摸校准偏移”时,把校准页测出的平均偏移加到所有注入坐标上(默认关)
void touchAdjust(double *x, double *y) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d boolForKey:@"apply_touch_offset"]) return;
    double ox = [d doubleForKey:@"touch_offset_x"], oy = [d doubleForKey:@"touch_offset_y"];
    if (fabs(ox) > 40 || fabs(oy) > 40) return; // 异常值不用
    CGSize s = screenSize();
    *x = MAX(0, MIN(s.width - 1, *x - ox));
    *y = MAX(0, MIN(s.height - 1, *y - oy));
}

// 不加校准偏移的原始点击(校准自检用)
void doTapRaw(double x, double y) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(60 * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

void doTap(double x, double y) {
    touchAdjust(&x, &y);
    doTapRaw(x, y);
}

// v0.9.6 新滑动:按约 60Hz 均匀发送移动事件(用 mach_wait_until 保证间隔均匀),
// 总时长约 ms 毫秒;到终点后原地停留 holdMs 毫秒(期间继续发同位置的移动事件让速度降为 0)再抬起,避免惯性甩动(fling)。
static void swipeSmoothRaw(double x1, double y1, double x2, double y2, int ms, int holdMs);
void doSwipeSmooth(double x1, double y1, double x2, double y2, int ms, int holdMs) {
    touchAdjust(&x1, &y1); touchAdjust(&x2, &y2);
    swipeSmoothRaw(x1, y1, x2, y2, ms, holdMs);
}

static void swipeSmoothRaw(double x1, double y1, double x2, double y2, int ms, int holdMs) {
    CGSize s = screenSize();
    if (ms < 120) ms = 120;
    if (ms > 2000) ms = 2000;
    if (holdMs < 0) holdMs = 0;
    if (holdMs > 600) holdMs = 600;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t per = (uint64_t)(16.667e6 * tb.denom / tb.numer); // 16.7ms 对应的 mach 时间
    int steps = MAX(4, (int)lround(ms / 16.667));
    sendFinger(x1 / s.width, y1 / s.height, 0);
    uint64_t t = mach_absolute_time();
    // 起点先停一帧,让系统识别为按下而不是点击
    t += per; mach_wait_until(t);
    for (int i = 1; i <= steps; i++) {
        double k = (double)i / steps;
        k = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2; // 缓入缓出:结尾速度趋近 0
        sendFinger((x1 + (x2 - x1) * k) / s.width, (y1 + (y2 - y1) * k) / s.height, 1);
        t += per; mach_wait_until(t);
    }
    int holdSteps = holdMs / 17;
    for (int i = 0; i < holdSteps; i++) {
        sendFinger(x2 / s.width, y2 / s.height, 1);
        t += per; mach_wait_until(t);
    }
    sendFinger(x2 / s.width, y2 / s.height, 2);
}

void doSwipe(double x1, double y1, double x2, double y2, int steps, int ms) {
    touchAdjust(&x1, &y1); touchAdjust(&x2, &y2); // v0.9.44:和平滑滑动一样应用校准偏移(开关默认关)
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

