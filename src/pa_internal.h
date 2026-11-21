// PhoneAgent 主 App 内部共用的头文件(v0.9.2 起 main.m 拆成多个文件)
#pragma once

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <mach/mach.h>
#import <ReplayKit/ReplayKit.h>
#import <Speech/Speech.h>
#import <UserNotifications/UserNotifications.h>
#import <AudioToolbox/AudioToolbox.h>
#import <PhotosUI/PhotosUI.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "shared.h"

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
enum { PAReqNone = 0, PAReqWaiting = 1, PAReqAllow = 2, PAReqAllowAll = 3, PAReqDeny = 4, PAReqStop = 5 };
#define MODEL_W 780
#define MODEL_H 1688

// ---- 跨文件共用的全局变量 ----
extern int gSwipeMode;
extern NSObject *gLock;
extern NSData *gFrame, *gNV12;
extern uint32_t gNW, gNH, gNFmt;
extern int gExtIS;
extern CFAbsoluteTime gFrameT, gHbT;
extern AVAudioPlayer *gPlayer;
extern NSMutableArray *gAgentLog;
extern volatile BOOL gBroadcastStopRequested;
extern RPSystemBroadcastPickerView *gPicker;
extern NSMutableArray *gRunLog;
extern NSString *gTaskStatus, *gTaskResultText, *gLastResultText, *gTaskDisplay, *gLastSpeechText;
extern NSArray *gRunImages;
extern NSMutableArray *gAttachImages, *gAttachNames;
extern NSMutableString *gAttachText;
extern volatile int gReqState;
extern NSString *gReqKind, *gReqText;
extern volatile BOOL gConfirmSkipThisTask;
extern NSMutableArray *gExpSteps;
extern NSString *gExpHint, *gExpReplayID;
extern BOOL gExpReplayAborted;
extern NSString *gToken;
extern volatile BOOL gAgentRunning;
extern volatile BOOL gEscalate;
extern int gStepNo;
extern BOOL gRunImagesSent;
extern NSString *gCurrentModel;
extern NSData *gPrevModelJPEG;

// ---- 跨文件共用的函数 ----
NSString *loadHID(void);
void sendFinger(double nx, double ny, int phase);
CGSize screenSize(void);
void doTap(double x, double y);
void doSwipe(double x1, double y1, double x2, double y2, int steps, int ms);
BOOL doCmdKey(uint32_t usage);
void doShiftKey(void);
BOOL doHomeKey(void);
NSString *loadShot(void);
BOOL broadcastAlive(void);
UIImage *takeScreenshot(NSString **err);
UIImage *resizeToWidth(UIImage *img, CGFloat width);
NSArray *ocrImage(UIImage *img, NSString **err);
NSString *diagReport(void);
BOOL openApp(NSString *bid);
void resumeKeepAlive(void);
NSString *setKeepAlive(BOOL on);
void agentRespond(int st);
NSArray *providerList(void);
void saveProviders(NSArray *list);
NSString *selectedProviderID(void);
NSString *providerDefault(NSString *pid, NSString *field);
NSString *provValue(NSString *pid, NSString *field);
void loadLLMConfig(NSString **key, NSString **base, NSString **model);
NSString *defaultSensitiveWords(void);
NSString *defaultBlockedApps(void);
NSArray *blockedApps(void);
BOOL confirmEnabled(void);
BOOL isBlockedApp(NSString *name, NSString *bid);
NSString *nearestItemText(NSArray *items, double x, double y);
NSString *classifyAction(NSString *target, NSString *risk, NSArray *items, double x, double y, int *category);
BOOL expEnabled(void);
BOOL expReplayEnabled(void);
NSMutableArray *expLoad(void);
void expSave(NSArray *arr);
NSMutableDictionary *expFind(NSString *task, double *score);
NSString *expStepDesc(NSDictionary *st);
NSString *expHintFor(NSString *task);
void expRecord(NSDictionary *step);
NSArray *expAnchors(NSArray *items);
void expFinish(NSString *task, NSString *status);
NSString *frameKey(void);
NSString *startServer(void);
void agentSay(NSString *m);
void doLongPress(double x, double y, int ms);
NSString *bundleForAppName(NSString *name, NSString **info);
NSString *agPostOnce(NSString *base, NSString *key, NSDictionary *body, BOOL honorStop, double timeout, NSString **finish, NSString **err);
BOOL llmErrRetryable(NSString *err);
NSDictionary *callLLM(NSString *base, NSString *key, NSString *model, NSArray *messages, NSString **err);
NSString *memoryText(void);
NSArray *hybridMessages(NSString *task, NSString *history, UIImage *img, NSArray *items, NSString **err);
void testReminder(void);
void agentRun(NSString *task, NSString *base, NSString *key, NSString *model);
