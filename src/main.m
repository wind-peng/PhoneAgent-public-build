// PhoneAgent v0.2
// 在 v0.1(点击/滑动)基础上增加:截屏、Vision OCR、本地 HTTP 接口(127.0.0.1:8200)、后台保活。
// 注意:截屏用的是私有接口,未经真机测试,失败时界面日志会写明原因。



#import "pa_internal.h"

// 入口:界面和 App 代理在 ui.m 里
int main(int argc, char *argv[]) {
    // lab14:-pahud 是悬浮层进程,-pahudexit 结束它
    if (argc > 1 && strcmp(argv[1], "-pahud") == 0) return paHudMain(argc, argv);
    if (argc > 1 && strcmp(argv[1], "-pahudexit") == 0) return paHudExitMain();
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AD"); }
}
