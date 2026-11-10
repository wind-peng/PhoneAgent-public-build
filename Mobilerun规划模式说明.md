# Mobilerun 规划模式

本版本新增界面开关：`AI规划模式(Manager→Executor)`。

关闭时，PhoneAgent 按原来的 Direct/AutoGLM 逻辑运行。

开启时，每个任务开始会先由 Manager 根据当前 App 和 OCR 生成最多 6 个子目标，然后将结构化计划交给现有视觉 Executor 执行。Manager 失败时会自动回退到 Direct 模式。

注意：第一版是“任务开始前规划 + 现有执行器执行”。原有支付、转账、删除、提交订单和支付密码拦截逻辑保持不变。AutoGLM 仍使用自己的原生循环，不经过 Manager 规划器。

## 构建

使用原来的 `build.sh` 构建。当前版本使用 iOS 15.0、arm64、ReplayKit 广播扩展和原有 entitlements。

当前 Linux 沙盒没有 Xcode/iOS SDK，未在本机执行 iOS 真机编译；请在 macOS/Xcode 环境运行 `build.sh`，先确认无编译错误，再在测试机打开规划模式做回归测试。
