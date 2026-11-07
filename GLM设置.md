# 使用智谱 GLM-5.3-Flash(v0.6.1)

## 设置
App 里填:
- API Key:智谱 BigModel 开放平台的 Key
- 接口地址:https://open.bigmodel.cn/api/paas/v4 (留着 deepseek 的地址也行,程序会自动改)
- 模型名:glm-5.3-flash (官方文档里还有 glm-5.3-flashx 等型号,模型名以 glm 开头就会走这套参数)

## 它和 DeepSeek / AutoGLM-Phone 的区别
- GLM-5.3-Flash 是通用的原生多模态模型,走和 DeepSeek 相同的那套"截图 + 本地 OCR 编号 + 网格"的提示词和 JSON 动作。
- AutoGLM-Phone 是专门为手机界面训练的,走它自己的协议(模型名含 autoglm 才启用)。
- 两个都配好,只需要改模型名就能切换,可以对比哪个更准。

## 这一版为 GLM 做的适配
1. 请求参数按智谱文档的推荐值:temperature 1、top_p 0.95、thinking 开启且 clear_thinking=false、reasoning_effort=max;
   max_tokens 提到 16384(思考内容也占 max_tokens,否则会出现"只有思考没有答案")。超时 300 秒。
2. 图片里不再带 detail 字段(那是 DeepSeek 的写法)。
3. 同时发两张图:上一步动作执行之前的屏幕 + 当前屏幕,并提示模型先对比,判断上一步有没有生效。
4. 模型没输出答案时,日志会写出 finish_reason,方便判断是不是 max_tokens 不够。

## 注意
- 官方文档说明 thinking 只能开启、不能关闭,而且推荐 reasoning_effort=max,所以每一步会比较慢(可能几十秒甚至更久)。
  这是"尽量聪明"的取舍;如果觉得太慢,告诉我,我把 reasoning_effort 调低。
- 文档里写 glm-5.3-flash 支持图片(URL 或 Base64 Data URL),这里发的是 Base64 JPEG。
