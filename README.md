# PhoneAgent v0.2:截屏 + OCR + 本地接口 + 后台保活

## 编译
和上一版一样:把本目录所有文件(含隐藏的 `.github` 文件夹)上传到 GitHub 仓库,
Actions 跑完后下载 `PhoneAgent-tipa`,解压出 `PhoneAgent.tipa`,用 TrollStore 安装(会覆盖旧版)。

## 测试(按顺序)
1. 打开 App,看日志。应该有:
   - 触摸: 初始化成功
   - 截屏: 符号加载成功
   - HTTP 服务: 127.0.0.1:8200,并显示 6 位 token
   - 后台保活已开
2. 点"3 秒后 截屏 + OCR",马上切到一个有文字的 App(比如设置),等 3 秒,回来看日志:
   会显示截屏分辨率、耗时、OCR 识别到的文字及坐标(单位 pt,可直接喂给点击)。
3. 在 Safari 打开 `http://127.0.0.1:8200/ping`,应返回 JSON。
   再试 `http://127.0.0.1:8200/ocr?token=你的token`、`/screenshot?token=...&w=540`。

## 接口(都在手机本机 127.0.0.1:8200,除 /ping 外都要 ?token=)
- /ping
- /tap?x=&y=
- /swipe?x1=&y1=&x2=&y2=&ms=
- /open?bundle=com.apple.mobilesafari
- /screenshot?w=540        (JPEG,w 可缩小宽度)
- /ocr                     (JSON,items 里 x/y 是文字中心点,单位 pt)

## 出问题时告诉我
- 日志里"截屏失败"后面的文字(例如"全黑"或"缺少符号")。
- Safari 打不开 /ping 时,说明服务没起来或被系统挂起,把日志发我。
