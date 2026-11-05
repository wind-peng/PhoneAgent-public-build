// PhoneAgent M1: 验证 TrollStore App 能否用 IOHID 私有接口"点屏幕"
// 注意:这是未经真机测试的起点代码,私有接口细节可能需要按日志调整。

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;

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
static IOHIDEventSystemClientRef gClient;

static NSString *loadHID(void) {
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
    gClient = pClientCreate(kCFAllocatorDefault);
    if (!gClient) return @"IOHIDEventSystemClientCreate 返回空(多半是 entitlement 没生效)";
    return nil;
}

// phase: 0=按下 1=移动 2=抬起;nx/ny 是 0~1 的归一化坐标
static void sendFinger(double nx, double ny, int phase) {
    uint64_t t = mach_absolute_time();
    BOOL touching = (phase != 2);
    uint32_t mask = (phase == 1) ? 0x4 : 0x3; // 0x1 range, 0x2 touch, 0x4 position
    IOHIDEventRef hand = pCreateDigitizer(kCFAllocatorDefault, t, 3 /*hand*/, 0, 0, mask, 0,
                                          nx, ny, 0, 0, 0, touching, touching, 0);
    pSetInt(hand, 0xb0019, 1); // IsDisplayIntegrated
    IOHIDEventRef finger = pCreateFinger(kCFAllocatorDefault, t, 1, 2, mask, nx, ny, 0,
                                         touching ? 1.0 : 0.0, 0, touching, touching, 0);
    pAppend(hand, finger, 0);
    CFRelease(finger);
    pSetSender(hand, 0x8000000817319372ULL);
    pDispatch(gClient, hand);
    CFRelease(hand);
}

static CGSize screenSize(void) { return UIScreen.mainScreen.bounds.size; } // 竖屏,单位 pt

static void doTap(double x, double y) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(60 * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

static void doSwipe(double x1, double y1, double x2, double y2, int steps, int ms) {
    CGSize s = screenSize();
    sendFinger(x1 / s.width, y1 / s.height, 0);
    for (int i = 1; i <= steps; i++) {
        double k = (double)i / steps;
        usleep(ms * 1000 / steps);
        sendFinger((x1 + (x2 - x1) * k) / s.width, (y1 + (y2 - y1) * k) / s.height, 1);
    }
    sendFinger(x2 / s.width, y2 / s.height, 2);
}

@interface VC : UIViewController
@property (nonatomic, strong) UITextField *xf, *yf;
@property (nonatomic, strong) UILabel *log;
@end

@implementation VC
- (UITextField *)field:(NSString *)ph text:(NSString *)t {
    UITextField *f = [UITextField new];
    f.placeholder = ph; f.text = t;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.keyboardType = UIKeyboardTypeDecimalPad;
    return f;
}
- (UIButton *)btn:(NSString *)title action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    CGSize s = screenSize();
    self.xf = [self field:@"x (pt)" text:[NSString stringWithFormat:@"%d", (int)(s.width / 2)]];
    self.yf = [self field:@"y (pt)" text:[NSString stringWithFormat:@"%d", (int)(s.height / 2)]];
    self.log = [UILabel new];
    self.log.numberOfLines = 0;
    self.log.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    UILabel *tip = [UILabel new];
    tip.numberOfLines = 0;
    tip.text = [NSString stringWithFormat:@"屏幕 %.0f x %.0f pt\n填好坐标,按按钮后 3 秒内按 Home 回到桌面/别的 App,等它自己点。", s.width, s.height];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        tip, self.xf, self.yf,
        [self btn:@"3 秒后点击 (x,y)" action:@selector(onTap)],
        [self btn:@"3 秒后上滑一次" action:@selector(onSwipe)],
        self.log]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 14;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:g.topAnchor constant:24],
        [st.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],
        [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20]]];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)]];
    NSString *err = loadHID();
    [self say:err ? [@"初始化失败: " stringByAppendingString:err] : @"HID 初始化成功"];
}
- (void)say:(NSString *)m {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.log.text = [NSString stringWithFormat:@"%@\n%@", m, self.log.text ?: @""];
    });
}
- (void)runLater:(void (^)(void))block name:(NSString *)name {
    [self.view endEditing:YES];
    if (!gClient) { [self say:@"HID 没初始化,不能执行"]; return; }
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication
        beginBackgroundTaskWithExpirationHandler:^{ [UIApplication.sharedApplication endBackgroundTask:bg]; }];
    [self say:[name stringByAppendingString:@": 3 秒后执行"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        block();
        [self say:[name stringByAppendingString:@": 已发送"]];
        dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication endBackgroundTask:bg]; });
    });
}
- (void)onTap {
    double x = self.xf.text.doubleValue, y = self.yf.text.doubleValue;
    [self runLater:^{ doTap(x, y); } name:[NSString stringWithFormat:@"点击(%.0f,%.0f)", x, y]];
}
- (void)onSwipe {
    CGSize s = screenSize();
    [self runLater:^{ doSwipe(s.width / 2, s.height * 0.75, s.width / 2, s.height * 0.3, 20, 300); } name:@"上滑"];
}
@end

@interface AD : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AD class])); }
}
