# ax-computer-use 操作规范（每个使用本插件的会话必须遵守）

> 教训来源：2026-11-21 发布 PR 实战——本可 5 分钟的 API 活，走浏览器点击烧了 1 小时；
> HID cmd+v 通道十几种变体死磕不换路。以下三条是硬规则，不是建议。

## 规矩一：先定预算，超时强制换路

任何 GUI 操作任务开始时，先声明预算并按阶梯选通道：

| 任务类型 | 预算 | 通道阶梯 |
|---|---|---|
| GitHub（PR/issue/文件/release） | ≤5 分钟 | **永远 API/gh CLI**（curl/gh），浏览器是最后手段 |
| 网页表单/业务系统 | ≤2 分钟 | CDP（若可）→ AX 批量 → 视觉坐标 |
| 原生 App 操作 | ≤2 分钟 | AX 批量动作（一个调用跑完整个流程） |
| Electron/CEF（飞书类） | ≤2 分钟 | AX 读 + 视觉坐标 HID 点击 + 键盘 |
| 信息查询/内容抓取 | ≤1 分钟 | web_search/web_fetch → CDP → 才考虑 GUI |

预算烧完 = 立即降到下一档，**不允许在同一档继续加试**。

## 规矩二：3 次无进展 = 通道判死

- 同一目标同一通道连续 3 次尝试无实质进展（无验证通过/无状态变化）→ 此路判死，换下一档。
- 禁止「再试一种变体」第 4 次。2026-11-21 教训：HID cmd+v 试了修饰键序列/事件源/前台态等十余种变体，全部无效（Chromium 只接受 trusted paste），应在第 3 次后转向 AXSetValue。

## 规矩三：死路记档，开局先查

死路结论追加到本文件末尾「通道备忘」节。每次 GUI 任务开局，先扫一眼备忘，跳过全部已知死路。

**问用户 = 最快的通道**：换 2 条通道仍不通时，必须立即问用户一句具体问题
（如「你副屏是不是已经开着这个页面？」），不许憋。用户一句话常解开 20 分钟死局
（实例：m01675「我另一个副屏打开了啊」瞬间解开编辑页定位僵局）。

## 引擎使用要点（批量优先）

- `ax_act` 一个调用跑整串动作：点击→内联验证→下一步，SUMMARY 汇总各步
  confirmed/unverified/suspected_noop/errors。不要一步一调用。
- 每个关键动作带内联验证（read/focus），失败即停，防止坐标漂移连锁错点。
- 截图是兜底不是默认：树能读到的不用截图；坐标换算前才截。
- 网页元素优先 `{"text":"…","role":"…"}` 定位，长索引链 ref 只用于当轮动作。

---

## 通道备忘（死路登记，按日期倒序）

### 2026-11-21 Chrome (v158, pid 82555 时代)
- ✅ AX: killall -9 后 `open -a "Google Chrome" --args --force-renderer-accessibility` 重启
  → reload 页面后 AXWebArea 全出树；**AXSetValue 直写 React input/CodeMirror 100% 可靠**。
- ✅ HID 鼠标点击（会激活 Chrome 到前台）；HID 裸键 space/return（滚页/提交）。
- ✅ `open -a "Google Chrome" "URL"` 导航 100%。
- ✅ GitHub 全流程 API：fork/写文件/开 PR 全部 curl 可做（POST /repos/{o}/{r}/forks、
  PUT /repos/{o}/{r}/contents/{path}、POST /repos/{o}/{r}/pulls）。**首选，勿走网页。**
- ❌ HID cmd/修饰键组合键（paste/copy）：Chromium 只接受 trusted paste，物理序列/共享
  event source/前台态全试过，永远无效。文本粘贴改 AXSetValue。
- ❌ chrome-devtools MCP：独立空白实例，无用户登录态。
- ❌ Chrome --remote-debugging-port：v136+ 默认 profile 禁调试端口。
- ❌ osascript tell app "Google Chrome"：沙箱 -10004。
- ❌ postToPid 键盘事件：不进 Chromium 渲染器（原生 App 有效）。
- ❌ NSRunningApplication.activate(macOS 14+ deprecated 无效)：拉不起 Chrome；
  用 HID 点击窗口/Dock 图标代替。

### 2026-11-21 飞书 Lark (CEF, pid 69971 时代)
- ✅ AX 读树（需 `--force-renderer-accessibility` 重启后）；AXSetValue 写弹窗内 input 有效。
- ✅ 视觉坐标 HID 点击（CEF 元素 AX frame 系统性错误，禁用 frame 点击，用截图坐标换算）。
- ✅ postToPid 键盘 Tab/Return 进 CEF 渲染器（翻月历验证）。
- ❌ CEF web 元素 AXPress：err=0 但不派发 DOM。
- ❌ CDP 端口：`--remote-debugging-port` 参数被 Lark 启动器洗掉（9222/9229/9333 均未开）。
- ❌ postToPid 鼠标：焦点移动但 JS 不触发。

### 通用
- ✅ axc 引擎 DSH bash 下辅助功能/屏幕录制权限全通（探针验证）。
- ❌ swiftc 默认 module cache 路径（/var/folders）沙箱拒 → 必须 -module-cache-path 指向 workspace。
- ❌ 沙箱禁写 ~/.ssh（known_hosts 警告无害）、禁直接 cp 进 DSH profile（用 install_bundle file: 刷新）。

### v0.1.1 批量实测（2026-11-21）
- TextEdit 全任务（新建+三行输入+全选+菜单加粗+验证）：2 轮调用 2.8s 引擎时间
  （对比逐步模式 5-6 轮 ~45s）。提速=砍轮数，引擎只占 ~3s。
- 飞书填工时预估：15-18 轮 → 3-4 轮，3 分钟 → ~1 分钟。
- 用法：一条 ax_act 打包全部动作+内联 read 验证；最终确认只截一张图。
