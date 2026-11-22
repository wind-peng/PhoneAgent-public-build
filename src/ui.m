// PhoneAgent:界面
#import "pa_internal.h"

#pragma mark - 界面

// ---- 语音朗读(系统自带的语音合成,中文) ----
@interface PATTS : NSObject <AVSpeechSynthesizerDelegate>
+ (instancetype)shared;
- (void)speak:(NSString *)text;
- (void)stop;
@property (nonatomic, readonly) BOOL speaking;
@end

@implementation PATTS {
    AVSpeechSynthesizer *_syn;
}
+ (instancetype)shared {
    static PATTS *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PATTS new]; s->_syn = [AVSpeechSynthesizer new]; s->_syn.delegate = s; });
    return s;
}
- (BOOL)speaking { return _syn.isSpeaking; }
- (void)speak:(NSString *)text {
    [self stop];
    NSString *t = text.length > 1500 ? [text substringToIndex:1500] : text;
    if (!t.length) return;
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:t];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    [_syn speakUtterance:u];
}
- (void)stop { if (_syn.isSpeaking) [_syn stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.ttsDone" object:nil];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u {
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.ttsDone" object:nil];
}
@end

// ---- 语音输入(在 App 里按麦克风按钮;识别由系统的语音识别完成) ----
@interface PAVoice : NSObject
@property (nonatomic, copy) void (^onText)(NSString *text);
@property (nonatomic, copy) void (^onState)(BOOL listening, NSString *msg);
@property (nonatomic, readonly) BOOL listening;
- (void)toggle;
- (void)stop;
@end

@implementation PAVoice {
    AVAudioEngine *_engine;
    SFSpeechRecognizer *_rec;
    SFSpeechAudioBufferRecognitionRequest *_req;
    SFSpeechRecognitionTask *_task;
    BOOL _listening;
}
- (BOOL)listening { return _listening; }
- (void)notify:(BOOL)on msg:(NSString *)m { if (self.onState) self.onState(on, m); }
- (void)toggle { if (_listening) [self stop]; else [self requestAndStart]; }
- (void)requestAndStart {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [self notify:NO msg:@"没有语音识别权限:请在 设置 → PhoneAgent 里打开“语音识别”"];
                return;
            }
            [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { [self notify:NO msg:@"没有麦克风权限:请在 设置 → PhoneAgent 里打开“麦克风”"]; return; }
                    [self begin];
                });
            }];
        });
    }];
}
- (void)begin {
    _rec = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
    if (!_rec || !_rec.isAvailable) { [self notify:NO msg:@"语音识别暂时不可用(需要联网)"]; return; }
    NSError *e = nil;
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
           options:(AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionAllowBluetooth)
             error:&e];
    [s setActive:YES error:&e];
    _engine = [AVAudioEngine new];
    _req = [SFSpeechAudioBufferRecognitionRequest new];
    _req.shouldReportPartialResults = YES;
    SFSpeechAudioBufferRecognitionRequest *req = _req;
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) { [req appendAudioPCMBuffer:buf]; }];
    [_engine prepare];
    if (![_engine startAndReturnError:&e]) {
        [self notify:NO msg:[NSString stringWithFormat:@"无法启动录音:%@", e.localizedDescription]];
        [self teardown];
        return;
    }
    _listening = YES;
    [self notify:YES msg:@"正在听……说完再点一次结束"];
    __weak PAVoice *w = self;
    _task = [_rec recognitionTaskWithRequest:_req resultHandler:^(SFSpeechRecognitionResult *r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PAVoice *me = w;
            if (!me) return;
            if (r && me.onText) me.onText(r.bestTranscription.formattedString);
            if (err || r.isFinal) { [me stop]; [me finishTask]; }
        });
    }];
}
- (void)teardown {
    if (_engine.isRunning) [_engine stop];
    [_engine.inputNode removeTapOnBus:0];
    _engine = nil;
}
- (void)stop {
    if (!_listening) return;
    _listening = NO;
    [_req endAudio];
    [self teardown];
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [s setActive:YES error:nil];
    resumeKeepAlive();
    [self notify:NO msg:@"语音输入结束"];
}
- (void)finishTask { [_task cancel]; _task = nil; _req = nil; }
@end

// ---- 结果窗口:可以选中文字、一键复制 ----
@interface ResultVC : UIViewController
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIBarButtonItem *speakItem;
@end
@implementation ResultVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"任务结果";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO; tv.selectable = YES; tv.alwaysBounceVertical = YES;
    tv.font = [UIFont systemFontOfSize:16];
    tv.textContainerInset = UIEdgeInsetsMake(14, 12, 14, 12);
    tv.text = self.text;
    [self.view addSubview:tv];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithTitle:@"复制全部" style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)];
    self.speakItem = [[UIBarButtonItem alloc] initWithTitle:[PATTS shared].speaking ? @"停止" : @"朗读" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSpeak)];
    self.navigationItem.rightBarButtonItems = @[copyItem, self.speakItem];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ttsDone) name:@"pa.ttsDone" object:nil];
}
- (void)toggleSpeak {
    if ([PATTS shared].speaking) { [[PATTS shared] stop]; self.speakItem.title = @"朗读"; }
    else { [[PATTS shared] speak:gLastSpeechText.length ? gLastSpeechText : self.text]; self.speakItem.title = @"停止"; }
}
- (void)ttsDone { dispatch_async(dispatch_get_main_queue(), ^{ self.speakItem.title = @"朗读"; }); }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)close { [[PATTS shared] stop]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyAll {
    UIPasteboard.generalPasteboard.string = self.text;
    self.navigationItem.rightBarButtonItem.title = @"已复制";
}
@end

// ---- 记忆窗口:可以自己增删改,也可以让它任务后自动记 ----
@interface MemoryVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UISwitch *sw;
@end
@implementation MemoryVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记忆";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *hint = [UILabel new];
    hint.numberOfLines = 0; hint.font = [UIFont systemFontOfSize:13]; hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"每行一条,可以手动增删改。执行任务时会作为偏好提供给模型,例如:“买东西优先选京东”“我的收货地址默认用公司”“回答请简短”。请不要写密码、银行卡号等敏感信息。";
    UILabel *swl = [UILabel new]; swl.text = @"任务结束后自动记住新的偏好";
    swl.font = [UIFont systemFontOfSize:15];
    self.sw = [UISwitch new];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.sw.on = [d objectForKey:@"memory_auto"] ? [d boolForKey:@"memory_auto"] : YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[swl, self.sw]];
    row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionEqualSpacing;
    self.tv = [UITextView new];
    self.tv.font = [UIFont systemFontOfSize:16];
    self.tv.layer.borderWidth = 1; self.tv.layer.borderColor = UIColor.separatorColor.CGColor; self.tv.layer.cornerRadius = 8;
    self.tv.text = memoryText();
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[hint, row, self.tv]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [st.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [st.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12]]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:self.tv.text ?: @"" forKey:@"memory_text"];
    [d setBool:self.sw.on forKey:@"memory_auto"];
}
- (void)done { [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clearAll { self.tv.text = @""; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self save]; }
@end

// ---- 安全设置:敏感操作确认、禁止进入的 App ----
@interface SafetyVC : UIViewController
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UITextView *wordsTV, *appsTV;
@end
@implementation SafetyVC
- (UILabel *)lab:(NSString *)t small:(BOOL)small {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0; l.text = t;
    l.font = [UIFont systemFontOfSize:small ? 13 : 15 weight:small ? UIFontWeightRegular : UIFontWeightSemibold];
    l.textColor = small ? UIColor.secondaryLabelColor : UIColor.labelColor;
    return l;
}
- (UITextView *)box:(NSString *)text {
    UITextView *tv = [UITextView new];
    tv.font = [UIFont systemFontOfSize:16]; tv.text = text;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone; tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.layer.borderWidth = 1; tv.layer.borderColor = UIColor.separatorColor.CGColor; tv.layer.cornerRadius = 8;
    [tv.heightAnchor constraintEqualToConstant:140].active = YES;
    return tv;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"安全设置";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *swl = [self lab:@"敏感操作前先问我" small:NO];
    self.sw = [UISwitch new]; self.sw.on = confirmEnabled();
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[swl, self.sw]];
    row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionEqualSpacing; row.alignment = UIStackViewAlignmentCenter;
    UILabel *h1 = [self lab:@"开启后,点击“发送/发布/提交/删除”等按钮前会先弹出确认,同时发通知(可以直接在通知里点“允许/拒绝”,不用离开当前 App)并语音提醒。付款、转账、输入支付密码永远不会自动执行,只会请你本人完成,不受这个开关影响。" small:YES];
    self.wordsTV = [self box:[NSUserDefaults.standardUserDefaults stringForKey:@"sens_words"] ?: defaultSensitiveWords()];
    UILabel *h2 = [self lab:@"禁止进入的 App 名称或包名里含有下面任一词,就不会被打开;如果误入了会自动退回主屏幕。" small:YES];
    self.appsTV = [self box:[NSUserDefaults.standardUserDefaults stringForKey:@"blocked_apps"] ?: defaultBlockedApps()];
    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    [rb setTitle:@"恢复默认列表" forState:UIControlStateNormal];
    [rb addTarget:self action:@selector(restore) forControlEvents:UIControlEventTouchUpInside];
    UIButton *tb = [UIButton buttonWithType:UIButtonTypeSystem];
    [tb setTitle:@"测试提醒(点后 5 秒内切到别的 App 看看)" forState:UIControlStateNormal];
    [tb addTarget:self action:@selector(onTest) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[row, h1,
        [self lab:@"敏感词(每行一个;要点击的按钮名或它附近的文字含有这些词,就先确认)" small:NO], self.wordsTV,
        [self lab:@"禁止进入的 App(每行一个)" small:NO], h2, self.appsTV, rb, tb]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:sv]; [sv addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:g.topAnchor], [sv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-16]]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:self.sw.on forKey:@"confirm_on"];
    [d setObject:self.wordsTV.text ?: @"" forKey:@"sens_words"];
    [d setObject:self.appsTV.text ?: @"" forKey:@"blocked_apps"];
}
- (void)done { [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)restore { self.wordsTV.text = defaultSensitiveWords(); self.appsTV.text = defaultBlockedApps(); }
- (void)onTest {
    testReminder();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"测试提醒" message:@"5 秒后会同时发出通知和系统弹窗。请现在回到主屏幕或切到别的 App(比如微信)等着;结果会写在 PhoneAgent 的日志里。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self save]; }
@end

// ---- 经验库:查看、删除、开关 ----
@interface ExpVC : UITableViewController
@property (nonatomic, strong) NSMutableArray *items;
@end
@implementation ExpVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"经验库";
    self.items = expLoad();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clearAll {
    if (!self.items.count) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空经验库" message:@"确定删除所有已保存的经验?" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.items removeAllObjects]; expSave(self.items); [self.tableView reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : MAX((NSInteger)self.items.count, 1); }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"设置" : [NSString stringWithFormat:@"已保存的经验(%lu)", (unsigned long)self.items.count];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 0 ? @"任务成功完成后自动记录步骤。相似的任务会把过往经验作为参考提示给模型;几乎相同的任务会先快速回放(每一步都核对屏幕、用屏幕上的文字重新定位按钮,对不上就中止并交给模型)。多次回放失败的经验会自动淘汰。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = ip.row == 0 ? @"记录并参考经验" : @"相同任务先快速回放";
        UISwitch *sw = [UISwitch new];
        sw.tag = ip.row;
        sw.on = ip.row == 0 ? expEnabled() : expReplayEnabled();
        [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"exp"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"exp"];
    if (!self.items.count) {
        c.textLabel.text = @"还没有经验。任务成功完成后会自动记录。";
        c.textLabel.textColor = UIColor.secondaryLabelColor; c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    NSDictionary *e = self.items[self.items.count - 1 - ip.row]; // 新的在前
    c.textLabel.text = e[@"task"]; c.textLabel.numberOfLines = 2; c.textLabel.textColor = UIColor.labelColor;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%lu 步 · 成功 %d 次 · 失败 %d 次 · 回放 %d 次",
                              (unsigned long)[e[@"steps"] count], [e[@"ok"] intValue], [e[@"fail"] intValue], [e[@"used"] intValue]];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)onSwitch:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:sw.tag == 0 ? @"exp_on" : @"exp_replay_on"]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1 || !self.items.count) return;
    NSUInteger idx = self.items.count - 1 - ip.row;
    NSDictionary *e = self.items[idx];
    NSMutableString *m = [NSMutableString string];
    NSArray *steps = e[@"steps"];
    for (NSUInteger i = 0; i < steps.count; i++) [m appendFormat:@"%lu. %@\n", (unsigned long)i + 1, expStepDesc(steps[i])];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:e[@"task"] message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除这条" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.items removeObjectAtIndex:idx]; expSave(self.items); [self.tableView reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1 && self.items.count > 0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || !self.items.count) return;
    [self.items removeObjectAtIndex:self.items.count - 1 - ip.row];
    expSave(self.items);
    [tv reloadData];
}
@end

// ---- 主界面 ----
static NSData *attachJPEG(UIImage *img) {
    CGSize sz = img.size;
    CGFloat k = MIN(1.0, 1600.0 / MAX(sz.width, sz.height));
    CGSize ns = CGSizeMake(floor(sz.width * k), floor(sz.height * k));
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIImage *out = [[[UIGraphicsImageRenderer alloc] initWithSize:ns format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
    return UIImageJPEGRepresentation(out, 0.85);
}

#pragma mark - v0.9.6 高级设置 / 触摸校准

@interface PATouchView : UIView
@property (nonatomic, copy) void (^onTouch)(CGPoint p);
@end
@implementation PATouchView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (t && self.onTouch) self.onTouch([t locationInView:nil]);
}
@end

@interface CalibVC : UIViewController
@property (nonatomic, strong) PATouchView *tv;
@property (nonatomic, strong) UILabel *info;
@property (nonatomic, strong) UIView *target;
@property (nonatomic, strong) NSMutableArray *got;
@property (nonatomic, assign) CGPoint expect;
@property (nonatomic, assign) BOOL manual;
@property (nonatomic, assign) int manualIdx;
@property (nonatomic, strong) NSMutableArray *manualRes;
@end
@implementation CalibVC
- (NSArray *)points {
    CGSize s = screenSize();
    return @[[NSValue valueWithCGPoint:CGPointMake(s.width * 0.2, s.height * 0.25)], [NSValue valueWithCGPoint:CGPointMake(s.width * 0.8, s.height * 0.25)],
             [NSValue valueWithCGPoint:CGPointMake(s.width * 0.5, s.height * 0.5)], [NSValue valueWithCGPoint:CGPointMake(s.width * 0.2, s.height * 0.8)],
             [NSValue valueWithCGPoint:CGPointMake(s.width * 0.8, s.height * 0.8)]];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.got = [NSMutableArray array];
    self.tv = [[PATouchView alloc] initWithFrame:self.view.bounds];
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak CalibVC *ws = self;
    self.tv.onTouch = ^(CGPoint p) { [ws touched:p]; };
    [self.view addSubview:self.tv];
    self.target = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    self.target.layer.cornerRadius = 12; self.target.layer.borderWidth = 2; self.target.layer.borderColor = UIColor.systemRedColor.CGColor;
    self.target.userInteractionEnabled = NO; self.target.hidden = YES;
    [self.view addSubview:self.target];
    self.info = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, self.view.bounds.size.width - 32, 260)];
    self.info.numberOfLines = 0; self.info.font = [UIFont systemFontOfSize:14]; self.info.userInteractionEnabled = NO;
    self.info.text = @"触摸校准\n· 自检:程序在 5 个已知位置注入点击,测量这个页面实际收到的位置。\n· 手动:依次点红圈中心,测量你手指的偏差。\n结果会保存;在高级设置里打开“应用触摸校准偏移”才会用于实际操作。";
    [self.view addSubview:self.info];
    UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem]; [b1 setTitle:@"开始自检" forState:UIControlStateNormal];
    [b1 addTarget:self action:@selector(selfTest) forControlEvents:UIControlEventTouchUpInside];
    UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem]; [b2 setTitle:@"手动校准" forState:UIControlStateNormal];
    [b2 addTarget:self action:@selector(manualStart) forControlEvents:UIControlEventTouchUpInside];
    UIButton *b3 = [UIButton buttonWithType:UIButtonTypeSystem]; [b3 setTitle:@"关闭" forState:UIControlStateNormal];
    [b3 addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[b1, b2, b3]];
    row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionFillEqually;
    row.frame = CGRectMake(16, self.view.bounds.size.height - 110, self.view.bounds.size.width - 32, 44);
    row.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:row];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)touched:(CGPoint)p {
    if (self.manual) {
        CGPoint e = self.expect;
        [self.manualRes addObject:@[@(p.x - e.x), @(p.y - e.y)]];
        self.manualIdx++;
        [self manualNext];
        return;
    }
    @synchronized (self.got) { [self.got addObject:[NSValue valueWithCGPoint:p]]; }
}
- (void)saveOffsetX:(double)ox y:(double)oy n:(int)n title:(NSString *)t lines:(NSString *)lines {
    if (n > 0) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setDouble:ox forKey:@"touch_offset_x"]; [d setDouble:oy forKey:@"touch_offset_y"];
    }
    self.info.text = [NSString stringWithFormat:@"%@\n%@\n平均偏移:dx=%.1f pt, dy=%.1f pt(%d 个有效点)\n%@", t, lines,
                      ox, oy, n, n ? @"已保存。偏移在 ±3pt 以内可以忽略;要用于实际操作,在高级设置里打开“应用触摸校准偏移”。" : @"没有有效数据,未保存。"];
}
- (void)selfTest {
    self.manual = NO; self.target.hidden = YES;
    self.info.text = @"自检中,请不要触摸屏幕……";
    NSArray *pts = [self points];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *lines = [NSMutableString string];
        double sx = 0, sy = 0; int n = 0;
        usleep(600 * 1000);
        for (NSValue *v in pts) {
            CGPoint e = v.CGPointValue;
            @synchronized (self.got) { [self.got removeAllObjects]; }
            doTapRaw(e.x, e.y);
            usleep(600 * 1000);
            NSValue *g = nil;
            @synchronized (self.got) { g = self.got.firstObject; }
            if (g) {
                CGPoint p = g.CGPointValue;
                sx += p.x - e.x; sy += p.y - e.y; n++;
                [lines appendFormat:@"注入 (%.0f,%.0f) → 收到 (%.1f,%.1f)\n", e.x, e.y, p.x, p.y];
            } else [lines appendFormat:@"注入 (%.0f,%.0f) → 没收到(HID 注入可能不可用)\n", e.x, e.y];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self saveOffsetX:n ? sx / n : 0 y:n ? sy / n : 0 n:n title:@"自检结果" lines:lines];
        });
    });
}
- (void)manualStart {
    self.manual = YES; self.manualIdx = 0; self.manualRes = [NSMutableArray array];
    [self manualNext];
}
- (void)manualNext {
    NSArray *pts = [self points];
    if (self.manualIdx >= (int)pts.count) {
        self.manual = NO; self.target.hidden = YES;
        double sx = 0, sy = 0; NSMutableString *lines = [NSMutableString string];
        for (NSArray *r in self.manualRes) { sx += [r[0] doubleValue]; sy += [r[1] doubleValue]; [lines appendFormat:@"偏差 (%.1f,%.1f)\n", [r[0] doubleValue], [r[1] doubleValue]]; }
        int n = (int)self.manualRes.count;
        // 手动校准量的是手指偏差,仅供参考,不覆盖自检得到的注入偏移
        self.info.text = [NSString stringWithFormat:@"手动校准结果(手指偏差,仅供参考,不保存)\n%@平均:dx=%.1f, dy=%.1f", lines, n ? sx / n : 0, n ? sy / n : 0];
        return;
    }
    self.expect = [pts[self.manualIdx] CGPointValue];
    self.target.center = self.expect; self.target.hidden = NO;
    self.info.text = [NSString stringWithFormat:@"手动校准 %d/%lu:请点红圈中心", self.manualIdx + 1, (unsigned long)pts.count];
}
@end

// v0.9.18 OCR 自检页:结果可选中复制
@interface OCRTestVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@end
@implementation OCRTestVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"OCR 自检";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(onCopy)];
    self.tv = [UITextView new];
    self.tv.editable = NO; self.tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tv];
    [NSLayoutConstraint activateConstraints:@[
        [self.tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8]]];
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:@"ocr_selftest_last"];
    self.tv.text = [NSString stringWithFormat:@"自检中,约半分钟,别切走……\n\n上一次自检记录(如果上次中途闪退,看最后一行做到哪):\n%@", last ?: @"无"];
    __weak OCRTestVC *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ocrSelfTest(^(NSString *soFar) {
            NSString *t = [soFar copy];
            dispatch_async(dispatch_get_main_queue(), ^{ ws.tv.text = t; });
        });
    });
}
- (void)onCopy { UIPasteboard.generalPasteboard.string = self.tv.text; self.navigationItem.rightBarButtonItem.title = @"已复制"; }
@end

@interface AdvancedVC : UIViewController
@property (nonatomic, strong) UITextView *popupTV;
@property (nonatomic, strong) UITextField *bBase, *bKey, *bModel;
@property (nonatomic, strong) UILabel *tokL;
@end
@implementation AdvancedVC
- (UIStackView *)sw:(NSString *)title key:(NSString *)key def:(BOOL)def {
    UILabel *l = [UILabel new];
    l.text = title; l.font = [UIFont systemFontOfSize:15]; l.numberOfLines = 0;
    [l setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UISwitch *s = [UISwitch new];
    s.on = paOn(key, def);
    s.accessibilityIdentifier = key;
    [s setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [s setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [s addTarget:self action:@selector(onSw:) forControlEvents:UIControlEventValueChanged];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[l, s]];
    row.axis = UILayoutConstraintAxisHorizontal; row.alignment = UIStackViewAlignmentCenter; row.spacing = 10;
    return row;
}
- (void)onSw:(UISwitch *)s { [NSUserDefaults.standardUserDefaults setBool:s.on forKey:s.accessibilityIdentifier]; }
- (UILabel *)hdr:(NSString *)t {
    UILabel *l = [UILabel new]; l.text = t; l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; l.textColor = UIColor.secondaryLabelColor; l.numberOfLines = 0;
    return l;
}
- (UITextField *)tf:(NSString *)ph key:(NSString *)k secure:(BOOL)sec {
    UITextField *f = [UITextField new];
    f.placeholder = ph; f.borderStyle = UITextBorderStyleRoundedRect; f.secureTextEntry = sec;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.text = [NSUserDefaults.standardUserDefaults stringForKey:k] ?: @"";
    return f;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"高级设置(v0.9.36)";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.popupTV = [UITextView new];
    self.popupTV.font = [UIFont systemFontOfSize:15];
    self.popupTV.layer.borderWidth = 1; self.popupTV.layer.borderColor = UIColor.separatorColor.CGColor; self.popupTV.layer.cornerRadius = 8;
    self.popupTV.text = [NSUserDefaults.standardUserDefaults stringForKey:@"popup_words"] ?: defaultPopupWords();
    [self.popupTV.heightAnchor constraintEqualToConstant:100].active = YES;
    self.bBase = [self tf:@"备用接口地址(留空 = 同主模型)" key:@"backup_base" secure:NO];
    self.bKey = [self tf:@"备用 API Key(留空 = 同主模型)" key:@"backup_key" secure:YES];
    self.bModel = [self tf:@"备用模型名(留空 = 不启用)" key:@"backup_model" secure:NO];
    UIButton *cal = [UIButton buttonWithType:UIButtonTypeSystem];
    [cal setTitle:@"打开触摸校准页" forState:UIControlStateNormal];
    [cal addTarget:self action:@selector(onCalib) forControlEvents:UIControlEventTouchUpInside];
    self.tokL = [UILabel new];
    self.tokL.numberOfLines = 0; self.tokL.font = [UIFont systemFontOfSize:14];
    self.tokL.text = tokSummary(YES);
    UIButton *tokClr = [UIButton buttonWithType:UIButtonTypeSystem];
    [tokClr setTitle:@"累计清零" forState:UIControlStateNormal];
    [tokClr addTarget:self action:@selector(onTokClear) forControlEvents:UIControlEventTouchUpInside];
    UIButton *cacheT = [UIButton buttonWithType:UIButtonTypeSystem];
    [cacheT setTitle:@"缓存对照测试(带/不带工具各 2 次,约用 1.3 万 token)" forState:UIControlStateNormal];
    cacheT.titleLabel.numberOfLines = 0;
    [cacheT addTarget:self action:@selector(onCacheTest:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *axT = [UIButton buttonWithType:UIButtonTypeSystem];
    [axT setTitle:@"无障碍探测(点后 6 秒内切到微信/淘宝/美团等,停 10 秒再回来看执行记录)" forState:UIControlStateNormal];
    axT.titleLabel.numberOfLines = 0;
    [axT addTarget:self action:@selector(onAXProbe) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self hdr:@"Token 统计(每次任务结束也会在执行记录里显示本次用量)"],
        self.tokL, tokClr, cacheT,
        [self hdr:@"实验"], axT,
        [self sw:@"每次调用模型都在执行记录里写一行 Token 明细(第几步、几张图、输入/缓存/输出)" key:@"token_step_log" def:YES],
        [self hdr:@"模型请求"],
        [self sw:@"用函数调用(tools)输出动作(GLM/DeepSeek;不支持时自动退回 JSON)" key:@"use_tool_calls" def:YES],
        [self sw:@"DeepSeek 分档:常规步骤 deepseek-flash,卡住/规划/完成自检用 deepseek-v4-pro" key:@"ds_tiering" def:YES],
        [self sw:@"常规步骤用低思考强度(更快更省)" key:@"easy_low_effort" def:YES],
        [self sw:@"文字步骤:OCR 足够时不发截图(更快更省)" key:@"text_only_steps" def:YES],
        [self sw:@"允许模型一次给出多个连续动作(逐个核对屏幕)" key:@"multi_action" def:YES],
        [self sw:@"子目标规划 + 完成前自检" key:@"subgoal_plan" def:YES],
        [self sw:@"经验宏回放(相同任务先本地回放,OCR 核对;默认关)" key:@"macro_replay" def:NO],
        [self sw:@"比价任务:每个进过的平台记下商品价格才算完成" key:@"compare_check" def:YES],
        [self sw:@"比价比同款:第一家选销量最高的一款,其他平台搜同款" key:@"compare_same" def:YES],
        [self hdr:@"备用模型(主模型连续限流/出错/格式错误时切换;DeepSeek 会自动在 flash 和 v4-pro 之间切换,无需填写)"],
        self.bBase, self.bKey, self.bModel,
        [self hdr:@"动作执行"],
        [self sw:@"智能等待:动作后等画面稳定(代替固定等待)" key:@"smart_settle" def:YES],
        [self sw:@"输入文字后自动点“搜索”按钮(右上角或键盘上的)" key:@"auto_search" def:YES],
        [self sw:@"自动点搜索前先确认输入框里是要搜的词" key:@"paste_verify" def:YES],
        [self sw:@"任务卡住/来回转圈时提醒模型换路" key:@"stuck_hint" def:YES],
        [self sw:@"被广告带进 App Store/浏览器时自动退回" key:@"stray_return" def:YES],
        [self sw:@"只在屏幕没变化时才附上一步截图(省 token)" key:@"single_image" def:YES],
        [self sw:@"打开 App / 点搜索后本地等页面加载完(少问模型一次 wait)" key:@"local_load_wait" def:YES],
        [self sw:@"点击没反应时在旁边自动重试一次(敏感按钮除外)" key:@"tap_retry" def:YES],
        [self sw:@"新滑动方式(60Hz 匀速、抬手前停顿防甩动)" key:@"smooth_swipe" def:YES],
        [self sw:@"应用触摸校准偏移(先在校准页自检)" key:@"apply_touch_offset" def:NO],
        cal,
        [self hdr:@"本地处理"],
        [self sw:@"广告倒计时时本地等待(不调用模型)" key:@"local_ad_wait" def:YES],
        [self sw:@"弹窗规则:自动点掉下面列表里的按钮" key:@"auto_popup" def:NO],
        self.popupTV,
        [self hdr:@"识别"],
        [self sw:@"读系统无障碍元素(按钮/输入框/图标名称和精确位置;够用时不发截图)" key:@"ax_tree" def:YES],
        [self sw:@"检测无文字小图标(×、返回箭头等)" key:@"icon_detect" def:YES],
        [self sw:@"合并同一行相邻的 OCR 碎片" key:@"ocr_merge" def:NO],
        [self sw:@"Live Text 把隔开的标签拆成单独条目" key:@"ocr_split_gap" def:YES],
        [self sw:@"右上角小字放大再识别一次" key:@"ocr_corner" def:YES],
        [self sw:@"OCR 用 Live Text(相册同款引擎,能认中文;失败自动退回)" key:@"ocr_livetext" def:YES],
        [self hdr:@"自我恢复与长任务"],
        [self sw:@"目标 App 意外退出时自动重新打开" key:@"auto_relaunch" def:YES],
        [self sw:@"录屏画面卡住时暂停提醒" key:@"stale_frame_check" def:YES],
        [self sw:@"断点续跑(每步保存进度,2 小时内可继续)" key:@"checkpoint_on" def:YES],
        [self sw:@"任务期间后台保活" key:@"keep_alive" def:YES],
        [self sw:@"发热/低电量时提醒并放慢" key:@"health_guard" def:YES]]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:sv];
    [sv addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:g.topAnchor], [sv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:20],
        [st.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-20]]];
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    [d setObject:self.popupTV.text ?: @"" forKey:@"popup_words"];
    [d setObject:[self.bBase.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:@"backup_base"];
    [d setObject:[self.bKey.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:@"backup_key"];
    [d setObject:[self.bModel.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:@"backup_model"];
}
- (void)done { [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self save]; }
- (void)onAXProbe {
    axProbeAfterDelay();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无障碍探测" message:@"6 秒后开始。现在切到要测的 App(比如微信聊天页、淘宝首页),停 10 秒左右再回来,结果写在执行记录里。不会点击任何东西。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)onTokClear { tokClearTotal(); self.tokL.text = tokSummary(YES); }
- (void)onCacheTest:(UIButton *)btn {
    if (gAgentRunning) return;
    btn.enabled = NO;
    [btn setTitle:@"缓存测试中…" forState:UIControlStateNormal];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *r = llmCacheTest();
        agentSay([@"[缓存测试] " stringByAppendingString:r]);
        dispatch_async(dispatch_get_main_queue(), ^{
            btn.enabled = YES;
            [btn setTitle:@"缓存对照测试(带/不带工具各 2 次,约用 1.3 万 token)" forState:UIControlStateNormal];
            self.tokL.text = tokSummary(YES);
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"缓存测试结果" message:r preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}
- (void)onOCRTest { [self.navigationController pushViewController:[OCRTestVC new] animated:YES]; }
- (void)onOCRClear {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清除识别缓存" message:@"只把 /var/mobile/Library/Caches/本App 目录改名为 .bak,不动设置和 Key。之后需要从后台划掉 PhoneAgent 再打开。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        UIAlertController *b = [UIAlertController alertControllerWithTitle:@"结果" message:ocrClearCache() preferredStyle:UIAlertControllerStyleAlert];
        [b addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:b animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)onCalib {
    CalibVC *c = [CalibVC new];
    c.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:c animated:YES completion:nil];
}
@end

@interface VC : UIViewController <UITextViewDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIButton *provBtn, *micBtn;
@property (nonatomic, strong) UITextField *keyF, *baseF, *modelF;
@property (nonatomic, strong) UITextView *taskTV;
@property (nonatomic, strong) UILabel *phLabel, *attLabel, *log;
@property (nonatomic, strong) PAVoice *voice;
@property (nonatomic, copy) NSString *voiceBase;
@property (nonatomic, strong) UIView *closingView, *guardView;
@property (nonatomic, strong) UIAlertController *reqAlert;
@end

@implementation VC
- (UIButton *)btn:(NSString *)title action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UITextField *)tf:(NSString *)ph secure:(BOOL)sec {
    UITextField *f = [UITextField new];
    f.placeholder = ph;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.secureTextEntry = sec;
    return f;
}
- (UIStackView *)row:(NSArray *)views {
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:views];
    r.axis = UILayoutConstraintAxisHorizontal; r.distribution = UIStackViewDistributionFillEqually; r.spacing = 8;
    return r;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    __weak VC *wself = self;

    // 模型选择 + 各自的 API 设置
    self.provBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.provBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.provBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    UIButton *addBtn = [self btn:@"＋添加" action:@selector(onAddProvider)];
    UIButton *delBtn = [self btn:@"删除" action:@selector(onDeleteProvider)];
    [delBtn setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [addBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [delBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.provBtn setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *provRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.provBtn, addBtn, delBtn]];
    provRow.axis = UILayoutConstraintAxisHorizontal; provRow.spacing = 16; provRow.alignment = UIStackViewAlignmentCenter;
    self.keyF = [self tf:@"API Key" secure:YES];
    self.baseF = [self tf:@"接口地址" secure:NO];
    self.modelF = [self tf:@"模型名" secure:NO];

    // 任务输入:多行文字 + 语音 + 附件
    self.taskTV = [UITextView new];
    self.taskTV.font = [UIFont systemFontOfSize:16];
    self.taskTV.layer.borderWidth = 1; self.taskTV.layer.borderColor = UIColor.separatorColor.CGColor; self.taskTV.layer.cornerRadius = 8;
    self.taskTV.delegate = self;
    self.taskTV.text = @"";
    self.phLabel = [UILabel new];
    self.phLabel.text = @"输入任务,例如:打开淘宝,搜索保温杯,加入购物车。也可以点下面的麦克风说,或附上图片/文件让模型处理。";
    self.phLabel.numberOfLines = 0; self.phLabel.font = [UIFont systemFontOfSize:15]; self.phLabel.textColor = UIColor.placeholderTextColor;
    self.phLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.taskTV addSubview:self.phLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.phLabel.topAnchor constraintEqualToAnchor:self.taskTV.topAnchor constant:8],
        [self.phLabel.leadingAnchor constraintEqualToAnchor:self.taskTV.leadingAnchor constant:8],
        [self.phLabel.widthAnchor constraintEqualToAnchor:self.taskTV.widthAnchor constant:-16],
        [self.taskTV.heightAnchor constraintEqualToConstant:120]]];
    self.micBtn = [self btn:@"🎤 语音输入" action:@selector(onMic)];
    UIButton *attBtn = [self btn:@"📎 图片/文件" action:@selector(onAttach)];
    self.attLabel = [UILabel new];
    self.attLabel.numberOfLines = 0; self.attLabel.font = [UIFont systemFontOfSize:13]; self.attLabel.textColor = UIColor.secondaryLabelColor;
    self.attLabel.hidden = YES;

    UIButton *startBtn = [self btn:@"开始任务" action:@selector(onStart)];
    UIButton *stopBtn = [self btn:@"停止任务" action:@selector(onStop)];
    UIButton *memBtn = [self btn:@"记忆" action:@selector(onMemory)];
    UIButton *resBtn = [self btn:@"上次结果" action:@selector(onLastResult)];
    UIButton *safeBtn = [self btn:@"安全设置" action:@selector(onSafety)];
    UIButton *expBtn = [self btn:@"经验库" action:@selector(onExp)];
    UIButton *keepBtn = [self btn:@"后台保活 开/关" action:@selector(onKeep)];
    UIButton *diagBtn = [self btn:@"诊断" action:@selector(onDiag)];
    UIButton *advBtn = [self btn:@"高级设置" action:@selector(onAdvanced)];

    // 屏幕广播(截屏必需)
    UILabel *bl = [UILabel new];
    bl.numberOfLines = 0; bl.font = [UIFont systemFontOfSize:14];
    bl.text = @"屏幕广播(截屏必需):点右边按钮 → 选 PhoneAgent → 开始直播";
    RPSystemBroadcastPickerView *pv = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    pv.preferredExtension = @"com.example.phoneagent.broadcast";
    pv.showsMicrophoneButton = NO;
    [pv.widthAnchor constraintEqualToConstant:56].active = YES;
    [pv.heightAnchor constraintEqualToConstant:56].active = YES;
    gPicker = pv;
    UILabel *acl = [UILabel new];
    acl.text = @"任务时自动开启/关闭屏幕录制"; acl.font = [UIFont systemFontOfSize:15]; acl.numberOfLines = 0;
    UISwitch *acs = [UISwitch new];
    NSUserDefaults *ud0 = NSUserDefaults.standardUserDefaults;
    acs.on = [ud0 objectForKey:@"auto_cast"] ? [ud0 boolForKey:@"auto_cast"] : YES;
    [acs addTarget:self action:@selector(onAutoCast:) forControlEvents:UIControlEventValueChanged];
    UIStackView *acrow = [[UIStackView alloc] initWithArrangedSubviews:@[acl, acs]];
    acrow.axis = UILayoutConstraintAxisHorizontal; acrow.alignment = UIStackViewAlignmentCenter;
    acrow.distribution = UIStackViewDistributionEqualSpacing;
    UILabel *ttl = [UILabel new];
    ttl.text = @"任务结果自动语音朗读"; ttl.font = [UIFont systemFontOfSize:15]; ttl.numberOfLines = 0;
    UISwitch *tts = [UISwitch new];
    tts.on = [ud0 objectForKey:@"tts_on"] ? [ud0 boolForKey:@"tts_on"] : YES;
    [tts addTarget:self action:@selector(onTTS:) forControlEvents:UIControlEventValueChanged];
    UIStackView *ttsrow = [[UIStackView alloc] initWithArrangedSubviews:@[ttl, tts]];
    ttsrow.axis = UILayoutConstraintAxisHorizontal; ttsrow.alignment = UIStackViewAlignmentCenter;
    ttsrow.distribution = UIStackViewDistributionEqualSpacing;
    UIStackView *glmrow = [self switchRow:@"GLM 省时思考(平时 high,卡住时自动升到最高)" key:@"glm_adaptive_effort" action:@selector(onGLMAdaptive:)];
    UIStackView *attrow = [self switchRow:@"附件图只在第一步发送(省流量)" key:@"attach_first_only" action:@selector(onAttachFirstOnly:)];
    UIStackView *brow = [[UIStackView alloc] initWithArrangedSubviews:@[bl, pv]];
    brow.axis = UILayoutConstraintAxisHorizontal; brow.spacing = 10; brow.alignment = UIStackViewAlignmentCenter;

    UILabel *tokenL = [UILabel new];
    tokenL.font = [UIFont systemFontOfSize:12]; tokenL.textColor = UIColor.tertiaryLabelColor;
    tokenL.text = [NSString stringWithFormat:@"快捷指令 token:%@", gToken];
    self.log = [UILabel new];
    self.log.numberOfLines = 0;
    self.log.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        provRow, self.keyF, self.baseF, self.modelF,
        self.taskTV, [self row:@[self.micBtn, attBtn]], self.attLabel,
        [self row:@[startBtn, stopBtn]], [self row:@[memBtn, safeBtn]], [self row:@[expBtn, resBtn]],
        acrow, ttsrow, glmrow, attrow, brow, [self row:@[keepBtn, diagBtn]], [self row:@[advBtn]], tokenL, self.log]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:sv];
    [sv addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:g.topAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:20],
        [st.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-20]]];

    // 通知:日志、结果窗口
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.say" object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { [wself say:[n.object description]]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.request" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself presentPendingRequest]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.requestDone" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself dismissRequestAlert]; [[PATTS shared] stop]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself presentPendingRequest]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.speak" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
        if (!([u objectForKey:@"tts_on"] && ![u boolForKey:@"tts_on"])) [[PATTS shared] speak:[n.object description]];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.guard" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself setGuardOverlay:[n.object boolValue]]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.closing" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [wself setClosingOverlay:[n.object boolValue]]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"pa.showResult" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        [wself showResult:[n.object description]];
        NSUserDefaults *ud1 = NSUserDefaults.standardUserDefaults;
        if (!([ud1 objectForKey:@"tts_on"] && ![ud1 boolForKey:@"tts_on"])) [[PATTS shared] speak:gLastSpeechText];
    }];

    // 语音输入
    self.voice = [PAVoice new];
    self.voice.onText = ^(NSString *text) {
        wself.taskTV.text = [(wself.voiceBase ?: @"") stringByAppendingString:text ?: @""];
        wself.phLabel.hidden = wself.taskTV.text.length > 0;
    };
    self.voice.onState = ^(BOOL listening, NSString *msg) {
        [wself.micBtn setTitle:listening ? @"⏹ 点击结束" : @"🎤 语音输入" forState:UIControlStateNormal];
        if (msg.length && !listening) [wself say:msg];
    };

    [self loadFields];
    [self buildProviderMenu];
    [self refreshAttachLabel];

    NSString *e1 = loadHID();
    if (e1) [self say:[@"触摸初始化失败: " stringByAppendingString:e1]];
    NSString *e2 = loadShot();
    if (e2) [self say:[@"截屏初始化失败: " stringByAppendingString:e2]];
    NSString *e3 = startServer();
    if (e3) [self say:[@"本地服务启动失败: " stringByAppendingString:e3]];
    setKeepAlive(YES);
}

// ---- 提供商 / 设置 ----
- (void)saveFields {
    NSString *pid = selectedProviderID();
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    [d setObject:[self.keyF.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:[NSString stringWithFormat:@"p_%@_key", pid]];
    [d setObject:[self.baseF.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:[NSString stringWithFormat:@"p_%@_base", pid]];
    [d setObject:[self.modelF.text stringByTrimmingCharactersInSet:ws] ?: @"" forKey:[NSString stringWithFormat:@"p_%@_model", pid]];
}
- (void)loadFields {
    NSString *pid = selectedProviderID();
    self.keyF.text = provValue(pid, @"key");
    self.baseF.text = provValue(pid, @"base");
    self.modelF.text = provValue(pid, @"model");
    self.baseF.placeholder = [providerDefault(pid, @"base") length] ? providerDefault(pid, @"base") : @"接口地址(OpenAI 兼容,例如 https://xxx/v1)";
    self.modelF.placeholder = [providerDefault(pid, @"model") length] ? providerDefault(pid, @"model") : @"模型名";
}
- (void)buildProviderMenu {
    NSString *cur = selectedProviderID();
    NSMutableArray *acts = [NSMutableArray array];
    NSString *curName = @"DeepSeek";
    __weak VC *wself = self;
    for (NSDictionary *p in providerList()) {
        NSString *pid = p[@"id"];
        UIAction *a = [UIAction actionWithTitle:p[@"name"] image:nil identifier:nil handler:^(UIAction *act) { [wself switchProvider:pid]; }];
        if ([pid isEqualToString:cur]) { a.state = UIMenuElementStateOn; curName = p[@"name"]; }
        [acts addObject:a];
    }
    self.provBtn.menu = [UIMenu menuWithTitle:@"选择模型" children:acts];
    self.provBtn.showsMenuAsPrimaryAction = YES;
    [self.provBtn setTitle:[NSString stringWithFormat:@"模型:%@  ▾", curName] forState:UIControlStateNormal];
}
- (void)onAddProvider {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"添加自定义模型"
        message:@"接口需要兼容 OpenAI 的 /chat/completions。接口地址和模型名以后可以在界面里再改。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"名称,例如:通义千问"; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"接口地址,例如 https://xxx/v1";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone; tf.autocorrectionType = UITextAutocorrectionTypeNo; tf.keyboardType = UIKeyboardTypeURL;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"模型名";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone; tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *wac = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        NSString *name = [wac.textFields[0].text stringByTrimmingCharactersInSet:ws];
        NSString *base = [wac.textFields[1].text stringByTrimmingCharactersInSet:ws];
        NSString *model = [wac.textFields[2].text stringByTrimmingCharactersInSet:ws];
        if (!name.length) name = @"自定义模型";
        [self saveFields];
        NSMutableArray *list = [providerList() mutableCopy];
        NSString *pid = [NSString stringWithFormat:@"c%.0f", [NSDate date].timeIntervalSince1970 * 1000];
        [list addObject:@{@"id": pid, @"name": name, @"base": base ?: @"", @"model": model ?: @""}];
        saveProviders(list);
        [NSUserDefaults.standardUserDefaults setObject:pid forKey:@"provider"];
        [self loadFields];
        [self buildProviderMenu];
        [self say:[NSString stringWithFormat:@"已添加模型“%@”,请填写它的 API Key", name]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)onDeleteProvider {
    NSMutableArray *list = [providerList() mutableCopy];
    if (list.count <= 1) { [self say:@"至少要保留一个模型"]; return; }
    NSString *pid = selectedProviderID(), *name = pid;
    for (NSDictionary *p in list) if ([p[@"id"] isEqualToString:pid]) name = p[@"name"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除模型"
        message:[NSString stringWithFormat:@"删除“%@”?它保存的 API Key、接口地址和模型名也会一起删除。", name] preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSMutableArray *rest = [NSMutableArray array];
        for (NSDictionary *p in list) if (![p[@"id"] isEqualToString:pid]) [rest addObject:p];
        saveProviders(rest);
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        for (NSString *f in @[@"key", @"base", @"model"]) [d removeObjectForKey:[NSString stringWithFormat:@"p_%@_%@", pid, f]];
        [d setObject:rest.firstObject[@"id"] forKey:@"provider"];
        [self loadFields];
        [self buildProviderMenu];
        [self say:[NSString stringWithFormat:@"已删除模型“%@”", name]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)switchProvider:(NSString *)pid {
    [self saveFields];
    [NSUserDefaults.standardUserDefaults setObject:pid forKey:@"provider"];
    [self loadFields];
    [self buildProviderMenu];
}

// ---- 日志 / 结果 ----
- (void)say:(NSString *)m {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *t = [NSString stringWithFormat:@"%@\n%@", m, self.log.text ?: @""];
        if (t.length > 6000) t = [t substringToIndex:6000];
        self.log.text = t;
    });
}
// 任务结束、自动关闭录屏的几秒里盖一层遮罩,吞掉点击
// ---- 暂停 / 确认 请求的弹窗(App 在前台时);App 在后台时靠通知,用户点开通知或回到 App 时再弹 ----
- (void)presentPendingRequest {
    if (gReqState != PAReqWaiting || self.reqAlert) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    BOOL confirm = [gReqKind isEqualToString:@"confirm"];
    __weak VC *wself = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:confirm ? @"需要你确认" : @"任务已暂停"
        message:confirm ? gReqText : [gReqText stringByAppendingString:@"\n\n请先去处理(必要时回到对应的 App),处理完点“继续”。"]
        preferredStyle:UIAlertControllerStyleAlert];
    if (confirm) {
        [ac addAction:[UIAlertAction actionWithTitle:@"允许" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqAllow); wself.reqAlert = nil; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"允许,本次任务不再问" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqAllowAll); wself.reqAlert = nil; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"拒绝(跳过这一步)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqDeny); wself.reqAlert = nil; }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { agentRespond(PAReqAllow); wself.reqAlert = nil; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"停止任务" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { agentRespond(PAReqStop); wself.reqAlert = nil; }]];
    self.reqAlert = ac;
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}
- (void)dismissRequestAlert {
    if (self.reqAlert) { [self.reqAlert dismissViewControllerAnimated:YES completion:nil]; self.reqAlert = nil; }
}
- (void)onSafety {
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:[SafetyVC new]] animated:YES completion:nil];
}
- (void)onExp {
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:[ExpVC new]] animated:YES completion:nil];
}

// 自动开启录屏的盲点期间:透明的吞点击层(盖在 PhoneAgent 自己的界面上,系统面板在它上面)
- (void)setGuardOverlay:(BOOL)on {
    if (!on) { [self.guardView removeFromSuperview]; self.guardView = nil; return; }
    if (self.guardView) return;
    UIView *v = [[UIView alloc] initWithFrame:self.view.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.backgroundColor = UIColor.clearColor;
    v.userInteractionEnabled = YES;
    [self.view addSubview:v];
    self.guardView = v;
}
- (void)setClosingOverlay:(BOOL)on {
    if (!on) { [self.closingView removeFromSuperview]; self.closingView = nil; return; }
    if (self.closingView) return;
    UIWindow *w = self.view.window ?: UIApplication.sharedApplication.windows.firstObject;
    if (!w) return;
    UIView *v = [[UIView alloc] initWithFrame:w.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    v.userInteractionEnabled = YES;
    UILabel *l = [UILabel new];
    l.text = @"任务已结束,正在关闭屏幕录制……"; l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium]; l.textAlignment = NSTextAlignmentCenter;
    l.frame = CGRectMake(0, w.bounds.size.height * 0.3, w.bounds.size.width, 30);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    [w addSubview:v];
    self.closingView = v;
}
- (void)showResult:(NSString *)text {
    gLastResultText = text;
    void (^present)(void) = ^{
        ResultVC *r = [ResultVC new];
        r.text = text;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:r];
        [self presentViewController:nav animated:YES completion:nil];
    };
    if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:present];
    else present();
}
- (void)onLastResult {
    if (!gLastResultText.length) { [self say:@"还没有任务结果"]; return; }
    [self showResult:gLastResultText];
}
- (void)onMemory {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[MemoryVC new]];
    [self presentViewController:nav animated:YES completion:nil];
}

// ---- 开始 / 停止 ----
- (void)onStart {
    [self.view endEditing:YES];
    [self saveFields];
    if (self.voice.listening) [self.voice stop];
    [[PATTS shared] stop];
    if (gAgentRunning) { [self say:@"已有任务在运行"]; return; }
    NSString *key = nil, *base = nil, *model = nil;
    loadLLMConfig(&key, &base, &model);
    NSString *task = [self.taskTV.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!task.length) { [self say:@"请先输入任务(可以用麦克风说)"]; return; }
    if (!key.length) { [self say:@"请先填写当前所选模型的 API Key"]; return; }
    if (!base.length || !model.length) { [self say:@"接口地址和模型名都要填"]; return; }
    NSString *full = gAttachText.length ? [task stringByAppendingFormat:@"\n\n【用户附带的文件内容】\n%@", gAttachText] : task;
    gTaskDisplay = task;
    gRunImages = [gAttachImages copy];
    if (!gPlayer) setKeepAlive(YES);
    if (!broadcastAlive()) [self say:@"提醒:屏幕广播还没开,没有广播会截屏失败"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(full, base, key, model); });
}
- (void)onTTS:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"tts_on"]; if (!sw.on) [[PATTS shared] stop]; }
- (void)onAutoCast:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"auto_cast"]; }
- (void)onGLMAdaptive:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"glm_adaptive_effort"]; }
- (void)onAttachFirstOnly:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"attach_first_only"]; }
// 一行“文字 + 开关”,开关状态存在 NSUserDefaults 的 key 里(没存过时默认开)
- (UIStackView *)switchRow:(NSString *)title key:(NSString *)key action:(SEL)action {
    UILabel *l = [UILabel new];
    l.text = title; l.font = [UIFont systemFontOfSize:15]; l.numberOfLines = 0;
    [l setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UISwitch *sw = [UISwitch new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    sw.on = [ud objectForKey:key] ? [ud boolForKey:key] : YES;
    [sw setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[l, sw]];
    row.axis = UILayoutConstraintAxisHorizontal; row.alignment = UIStackViewAlignmentCenter; row.spacing = 10;
    return row;
}
- (void)onStop { gAgentRunning = NO; agentRespond(PAReqStop); [self say:@"正在停止任务……"]; }
- (void)onKeep { [self say:setKeepAlive(gPlayer == nil)]; }
- (void)onDiag { [self say:diagReport()]; }
- (void)onAdvanced {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[AdvancedVC new]];
    [self presentViewController:nav animated:YES completion:nil];
}
// 11:启动时发现 2 小时内没跑完的任务:询问是否继续
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL asked;
    if (asked) return;
    asked = YES;
    if (gOCRGuardTripped) [self say:@"上次 OCR 精确模式运行中闪退了,已自动关闭精确模式(可在高级设置里重新打开)"];
    if (gAgentRunning) return;
    NSDictionary *cp = cpLoad();
    if (!cp) return;
    NSString *shown = [cp[@"display"] length] ? cp[@"display"] : cp[@"task"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"继续上次任务?"
        message:[NSString stringWithFormat:@"上次的任务没有完成(做到第 %@ 步):\n%@", cp[@"step"], shown.length > 120 ? [shown substringToIndex:120] : shown]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"继续上次任务" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (gAgentRunning) return;
        NSString *key = nil, *base = nil, *model = nil;
        loadLLMConfig(&key, &base, &model);
        if (!key.length || !base.length || !model.length) { [self say:@"请先填写当前所选模型的 API 设置"]; return; }
        gResumeCP = cp; gTaskDisplay = shown; gRunImages = nil;
        if (!gPlayer) setKeepAlive(YES);
        NSString *task = cp[@"task"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ agentRun(task, base, key, model); });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { cpClear(); }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ---- 语音 ----
- (void)onMic {
    if (!self.voice.listening) self.voiceBase = self.taskTV.text.length ? [self.taskTV.text stringByAppendingString:@" "] : @"";
    [self.voice toggle];
}
- (void)textViewDidChange:(UITextView *)tv { self.phLabel.hidden = tv.text.length > 0; }

// ---- 附件(图片 / 文件) ----
- (void)refreshAttachLabel {
    NSUInteger ni = gAttachImages.count;
    BOOL hasText = gAttachText.length > 0;
    if (!ni && !hasText) { self.attLabel.hidden = YES; return; }
    self.attLabel.hidden = NO;
    self.attLabel.text = [NSString stringWithFormat:@"已附带:%@%@%@(随任务一起发给模型;点“图片/文件”可清除)",
                          ni ? [NSString stringWithFormat:@"%lu 张图片", (unsigned long)ni] : @"",
                          (ni && hasText) ? @"、" : @"",
                          hasText ? [NSString stringWithFormat:@"文件文字 %lu 字", (unsigned long)gAttachText.length] : @""];
}
- (void)onAttach {
    [self.view endEditing:YES];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"附件" message:@"图片会随任务发给模型(需要所选模型支持看图);文件会把文字内容放进任务里(支持 txt/md/csv/json/pdf 等文本类文件,也可以选图片文件)" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从相册选图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = 5;
        cfg.filter = [PHPickerFilter imagesFilter];
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pk.delegate = self;
        [self presentViewController:pk animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"选择文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
        dp.delegate = self;
        dp.allowsMultipleSelection = YES;
        [self presentViewController:dp animated:YES completion:nil];
    }]];
    if (gAttachImages.count || gAttachText.length) {
        [ac addAction:[UIAlertAction actionWithTitle:@"清除所有附件" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [gAttachImages removeAllObjects]; [gAttachNames removeAllObjects]; [gAttachText setString:@""];
            [self refreshAttachLabel];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *r in results) {
        if (![r.itemProvider canLoadObjectOfClass:UIImage.class]) continue;
        [r.itemProvider loadObjectOfClass:UIImage.class completionHandler:^(id obj, NSError *err) {
            if (![obj isKindOfClass:UIImage.class]) return;
            NSData *jpg = attachJPEG((UIImage *)obj);
            if (!jpg.length) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [gAttachImages addObject:jpg];
                [gAttachNames addObject:@"相册图片"];
                [self refreshAttachLabel];
            });
        }];
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSArray *imgExt = @[@"jpg", @"jpeg", @"png", @"heic", @"gif", @"bmp", @"tiff"];
    for (NSURL *url in urls) {
        NSString *ext = url.pathExtension.lowercaseString, *name = url.lastPathComponent;
        if ([imgExt containsObject:ext]) {
            UIImage *im = [UIImage imageWithContentsOfFile:url.path];
            NSData *jpg = im ? attachJPEG(im) : nil;
            if (jpg.length) { [gAttachImages addObject:jpg]; [gAttachNames addObject:name]; }
            else [self say:[NSString stringWithFormat:@"无法读取图片:%@", name]];
            continue;
        }
        NSString *text = nil;
        if ([ext isEqualToString:@"pdf"]) {
            PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
            text = doc.string;
            if (!text.length) { [self say:[NSString stringWithFormat:@"PDF 里没有可提取的文字(可能是扫描件,请改成图片附上):%@", name]]; continue; }
        } else {
            text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
            if (!text) {
                NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
                text = [NSString stringWithContentsOfURL:url encoding:gb error:nil];
            }
            if (!text) { [self say:[NSString stringWithFormat:@"暂不支持这种文件(docx、xlsx 等请先转成 txt 或 pdf):%@", name]]; continue; }
        }
        if (text.length > 30000) text = [[text substringToIndex:30000] stringByAppendingString:@"\n……(内容过长,已截断)"];
        [gAttachText appendFormat:@"--- 文件:%@ ---\n%@\n\n", name, text];
        [gAttachNames addObject:name];
    }
    if (gAttachText.length > 80000) [gAttachText setString:[gAttachText substringToIndex:80000]];
    [self refreshAttachLabel];
}
@end

@interface AD : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AD
// phoneagent://task?token=XXXXXX&text=任务文字   或   phoneagent://stop?token=XXXXXX
// 给快捷指令用:打开 URL 会把 PhoneAgent 唤醒到前台,避免它在后台被挂起。token 不对一律忽略。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    NSURLComponents *uc = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
    NSString *cmd = uc.host ?: @"";
    if (![q[@"token"] isEqualToString:gToken]) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"收到 phoneagent:// 请求,但 token 不对,已忽略"];
        return YES;
    }
    if ([cmd isEqualToString:@"resume"] || [cmd isEqualToString:@"allow"]) { agentRespond(PAReqAllow); return YES; }
    if ([cmd isEqualToString:@"allowall"]) { agentRespond(PAReqAllowAll); return YES; }
    if ([cmd isEqualToString:@"deny"]) { agentRespond(PAReqDeny); return YES; }
    if ([cmd isEqualToString:@"stop"]) { gAgentRunning = NO; agentRespond(PAReqStop); return YES; }
    if (![cmd isEqualToString:@"task"]) return YES;
    // 把收到的 URL 原样记到日志里(token 打码),方便排查快捷指令到底传了什么
    NSString *raw = url.absoluteString ?: @"";
    NSString *tok = q[@"token"];
    if (tok.length) raw = [raw stringByReplacingOccurrencesOfString:tok withString:@"***"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say"
        object:[NSString stringWithFormat:@"收到 URL:%@\n参数名:%@", raw.length > 300 ? [raw substringToIndex:300] : raw, [q.allKeys componentsJoinedByString:@","]]];
    // 兼容几种参数名;都没有时取除 token 外最长的那个参数值
    NSString *task = q[@"text"] ?: q[@"t"] ?: q[@"task"] ?: q[@"q"] ?: @"";
    if (!task.length) {
        for (NSString *k in q) {
            if ([k isEqualToString:@"token"]) continue;
            if ([q[k] length] > task.length) task = q[k];
        }
    }
    // 快捷指令有时会把已经编码过的文字再编码一次,这里再解一层
    if ([task containsString:@"%"]) { NSString *d2 = [task stringByRemovingPercentEncoding]; if (d2.length) task = d2; }
    task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = nil, *base = nil, *model = nil; loadLLMConfig(&key, &base, &model);
    NSString *say = nil;
    if (!task.length) say = @"收到语音任务,但文字是空的(听写可能没识别到内容,或快捷指令里的变量没接对,看上面“收到 URL”那行)";
    else if (!key.length || !base.length || !model.length) say = @"收到语音任务,但还没保存 API 设置:请先在 App 里点一次“开始任务”或“看图测试”";
    else if (gAgentRunning) say = @"收到语音任务,但已有任务在运行";
    if (say) { [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:say]; return YES; }
    agentSay([NSString stringWithFormat:@"收到语音任务:%@", task]);
    [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:[NSString stringWithFormat:@"收到语音任务:%@", task]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUserDefaults *u2 = NSUserDefaults.standardUserDefaults;
        BOOL autoCast = [u2 objectForKey:@"auto_cast"] ? [u2 boolForKey:@"auto_cast"] : YES;
        if (!autoCast) { // 没打开“自动开启录屏”才需要现成的广播;冷启动后扩展要重新连上,最多等 6 秒
            for (int i = 0; i < 30 && !broadcastAlive(); i++) usleep(200 * 1000);
            if (!broadcastAlive()) {
                [NSNotificationCenter.defaultCenter postNotificationName:@"pa.say" object:@"屏幕广播没开,任务未执行:请先开启屏幕广播,或打开界面里“任务时自动开启/关闭屏幕录制”的开关"];
                return;
            }
        }
        if (gAgentRunning) return;
        gRunImages = nil; gTaskDisplay = task;
        agentRun(task, base, key, model); // 开关打开时,agentRun 会自己检查录屏并自动开启
    });
    return YES;
}

// 通知(带按钮):暂停/确认请求时发出,用户可以不离开当前 App,直接在通知里点“继续/允许/拒绝/停止”
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *a = response.actionIdentifier;
    if ([a isEqualToString:@"allow"] || [a isEqualToString:@"resume"]) agentRespond(PAReqAllow);
    else if ([a isEqualToString:@"allowall"]) agentRespond(PAReqAllowAll);
    else if ([a isEqualToString:@"deny"]) agentRespond(PAReqDeny);
    else if ([a isEqualToString:@"stop"]) agentRespond(PAReqStop);
    completionHandler(); // 点通知本身只是打开 App,界面里会弹出对应的确认框
}

- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    signal(SIGPIPE, SIG_IGN);
    gOCRGuardTripped = ocrCrashGuardCheck(); // 上次精确 OCR 中途闪退 → 自动关闭精确模式
    gLock = [NSObject new];
    gAgentLog = [NSMutableArray array];
    gRunLog = [NSMutableArray array];
    gAttachImages = [NSMutableArray array];
    gAttachNames = [NSMutableArray array];
    gAttachText = [NSMutableString string];
    gExpSteps = [NSMutableArray array];
    {   // 通知:注册带按钮的类别并请求权限
        UNUserNotificationCenter *nc = UNUserNotificationCenter.currentNotificationCenter;
        nc.delegate = self;
        UNNotificationAction *aOK = [UNNotificationAction actionWithIdentifier:@"allow" title:@"允许" options:UNNotificationActionOptionNone];
        UNNotificationAction *aAll = [UNNotificationAction actionWithIdentifier:@"allowall" title:@"允许,本次任务不再问" options:UNNotificationActionOptionNone];
        UNNotificationAction *aNo = [UNNotificationAction actionWithIdentifier:@"deny" title:@"拒绝(跳过这一步)" options:UNNotificationActionOptionDestructive];
        UNNotificationAction *aStop = [UNNotificationAction actionWithIdentifier:@"stop" title:@"停止任务" options:UNNotificationActionOptionDestructive];
        UNNotificationAction *aCont = [UNNotificationAction actionWithIdentifier:@"resume" title:@"继续" options:UNNotificationActionOptionNone];
        UNNotificationCategory *cConfirm = [UNNotificationCategory categoryWithIdentifier:@"PA_CONFIRM" actions:@[aOK, aAll, aNo, aStop] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
        UNNotificationCategory *cPause = [UNNotificationCategory categoryWithIdentifier:@"PA_PAUSE" actions:@[aCont, aStop] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
        [nc setNotificationCategories:[NSSet setWithObjects:cConfirm, cPause, nil]];
        [nc requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *err) {}];
    }
    {   // 旧版本只有一套 API 设置:迁移到对应的提供商名下
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if (![d boolForKey:@"migrated_v7"]) {
            NSString *k = [d stringForKey:@"llm_key"], *b = [d stringForKey:@"llm_base"], *m = [d stringForKey:@"llm_model"] ?: [d stringForKey:@"llm_model2"];
            if (k.length) {
                NSString *lm = m.lowercaseString, *pid = @"deepseek";
                if ([lm containsString:@"autoglm"]) pid = @"autoglm";
                else if ([lm hasPrefix:@"glm"]) pid = @"glm";
                else if (b.length && ![b.lowercaseString containsString:@"deepseek"]) pid = @"custom";
                [d setObject:k forKey:[NSString stringWithFormat:@"p_%@_key", pid]];
                if (b.length) [d setObject:b forKey:[NSString stringWithFormat:@"p_%@_base", pid]];
                if (m.length) [d setObject:m forKey:[NSString stringWithFormat:@"p_%@_model", pid]];
                [d setObject:pid forKey:@"provider"];
            }
            [d setBool:YES forKey:@"migrated_v7"];
        }
    }

    gSwipeMode = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"swipe_mode"];
    gToken = [NSUserDefaults.standardUserDefaults stringForKey:@"token"];
    if (!gToken) {
        gToken = [NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)];
        [NSUserDefaults.standardUserDefaults setObject:gToken forKey:@"token"];
    }
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
