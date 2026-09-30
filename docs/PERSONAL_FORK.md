# 个人定制版记录（Personal fork）

本仓库是 [rusty4444/hermes-android](https://github.com/rusty4444/hermes-android) 的 fork（`nobody3020252232/hermes-android`），**仅供本人自用**的定制版。

- 每次 push 到 `main` 自动构建 APK：Actions → **Personal APK** → 最新 run → artifact `hermes-personal-apk-*`。
- APK 用个人签名密钥（repo secrets `PERSONAL_*`）签名，可原地覆盖升级本轮及以后的所有版本。
- 首次安装前需卸载官方签名的原版 Hermes（签名不同，安卓不允许直接覆盖安装）。
- 本地签名材料备份在 Mac 的 `~/hermes-signing/`。

## 改动逐轮记录

### R1 — 2026-09-30
- 聊天底部输入栏瘦身：右侧按钮 48dp→40dp；移除"朗读回复"（音量）开关；输入框可视宽度增加。
- 移除会话页顶部与输入框上方重复的一栏（模型 / 思考强度 / 项目 / 连接状态）；连接异常时在标题栏右侧显示 10dp 圆点（橙=重连中、红=离线），正常时不显示。
- 同步更新测试：`test/chat_history_scroll_test.dart`（移除 "Spoken replies"、尺寸断言 48→40）。
- 新增 CI：`Personal APK` workflow（每轮 push 自动出 APK）。

## 待办（用户提出的其余改动）

- R2：界面中文化 + 设置里可切换语言（默认中文）。
- R3：流式消息滚动行为——停在底部才自动跟随；用户上翻时不打扰。
- R4：会话历史本地缓存（打开会话不再每次全量拉取）。
- R5：长任务中"假发送失败"（服务端已接受，APP 却提示失败并回填输入框）修复。
