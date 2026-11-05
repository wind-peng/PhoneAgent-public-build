# PhoneAgent v0.3.0:ReplayKit 广播截屏

思路:不再自己截屏(IOSurface 在你的系统上创建不了),改让系统的"屏幕广播"把整机画面交给
扩展 PhoneAgentBroadcast.appex,扩展压成 JPEG 后用本机 socket 推给主 App。
主 App 的 /screenshot、/ocr 和"截屏+OCR"按钮会优先用广播画面(日志里显示"方法R"),
没有广播时才回退到旧的四种方法。

## 编译安装
和以前一样上传 GitHub → Actions → 下载 PhoneAgent-tipa → TrollStore 安装(覆盖旧版)。
注意:这次的 .tipa 里带了 PlugIns/PhoneAgentBroadcast.appex。

## 测试
1. 打开 App,/ping 的 version 应为 0.3.0。
2. 在 App 里找到"屏幕广播"那一行,点右边的小图标按钮。
   - 弹出的列表里应该能看到 PhoneAgent,选它,点"开始直播"(3 秒倒计时)。
   - 如果列表里没有 PhoneAgent,请告诉我(说明扩展没被系统识别)。
3. 开始后 App 日志应出现"广播扩展已连接"。
4. 点"3 秒后 截屏 + OCR",切到设置等 3 秒,回来看日志是否显示"方法R"以及识别结果。
5. 停止广播:点状态栏的红色胶囊/控制中心的录屏按钮。

## 注意
- 广播画面只在屏幕变化时才有新帧,动作之后建议等约 1 秒再取。
- 广播期间屏幕顶部会有录屏指示,这是系统行为。
- /frame、/hb、/bye 用 src/shared.h 里的 FRAME_KEY 做暗号,可以自己改成别的字符串。

## 出问题时告诉我
- 选择列表里有没有 PhoneAgent
- 日志里是否出现"广播扩展已连接"
- 截屏+OCR 的日志(包括失败时 R:... A:... 那一行)
