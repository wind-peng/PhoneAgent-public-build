// 主 App 与广播扩展共用。
#ifndef PORT
#define PORT 8201
#endif
// v0.9.3:恢复固定暗号(随机暗号在 TrollStore 下扩展读不到,导致自动录屏失效)
#define FRAME_KEY "pa-frame-7f3c9d2e"
