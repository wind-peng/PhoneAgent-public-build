# PhoneAgent M1:验证 TrollStore App 能不能"点屏幕"

## 编译
1. 新建一个 GitHub 仓库,把本目录所有文件(包括隐藏的 `.github` 文件夹)原样上传。
2. 进入仓库的 Actions 页面,等 `build-tipa` 跑完(失败的话把日志最后 30 行发给我)。
3. 在运行结果底部的 Artifacts 里下载 `PhoneAgent-tipa`,解压得到 `PhoneAgent.tipa`。

## 安装与测试
1. 用 TrollStore 打开 `PhoneAgent.tipa` 安装。
2. 打开 App,顶部日志应显示"HID 初始化成功"。
3. 填一个桌面上某个图标的坐标(单位是 pt,不是像素),点"3 秒后点击",马上按 Home 回桌面,等 3 秒看图标是否被点开。
4. 再试"3 秒后上滑一次",在桌面或浏览器里看是否滚动。

## 出问题时告诉我
- TrollStore 安装失败:把报错文字发来,多半是某个 entitlement 不被接受,删掉 entitlements.plist 里对应一行重编。
- 初始化失败:把日志第一行发来。
- 初始化成功但点了没反应:告诉我是桌面还是 App 里,我再调整事件参数。
