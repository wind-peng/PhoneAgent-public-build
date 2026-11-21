// 主 App 与广播扩展共用。
#ifndef PORT
#define PORT 8200
#endif
// v0.9.2 起不再写死暗号:主 App 首次启动时随机生成,存在 App Group 共享偏好里(并备份一份到本机文件),扩展从同一处读取。
#define PA_APP_GROUP @"group.com.example.phoneagent.shared"
#define PA_FRAME_KEY_NAME @"frame_key"
#define PA_FRAME_KEY_FILE @"/var/mobile/Library/PhoneAgent/frame_key"
