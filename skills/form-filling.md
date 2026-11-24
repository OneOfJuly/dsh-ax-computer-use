# 配方：Web 表单填报（CEF / antd / Electron 混合表单）

适用：飞书工时、内部业务系统、任何 antd/element 类 React 表单。
核心循环：**批量动作 → verify 内联校验 → read_errors → SUMMARY 判断**。

## 标准流程（一轮 axact 完成主填报）

```
ax_act --pid N --json '[
  {"op":"dropdown","x":843,"y":181,"pick":"实施项目","verify":{"text":"请选择","contains":"实施","wait":900}},
  {"op":"dropdown","x":843,"y":228,"search":"示例","pick":"ALPHA","verify":{"text":"请选择","contains":"ALPHA"}},
  {"op":"set","text":"项目日常维护","target":{"text":"工作内容","role":"AXTextArea"}},
  {"op":"read_errors"}
]'
```

- `dropdown` = 开下拉 → HID 输入 search 过滤 → OCR 点选 pick → verify 读回。
  可搜索的 antd combobox **必须用 search**，别翻全量列表（选项常超一屏）。
- `remember/recall`：第一次成功后把字段坐标记下来（`{"op":"remember","key":"类别","x":843,"y":181}`），
  下次直接 `{"op":"dropdown","key":"类别",...}`，跳过 OCR 定位。
- `read_errors` 放在提交动作之后：命中校验错误会抛 FORM_ERROR 并 abort，
  让你在污染后续字段前就看到「工作时长不能大于5」这类提示。

## 失败模式速查

| 症状 | 原因 | 对策 |
|---|---|---|
| 下拉开了但 OCR MISS | 选项不在首屏 | 加 search 参数先过滤 |
| verify 抓到旧值 | 读回太快 | verify.wait 加到 1200 |
| click 落空无反应 | 窗口非前台（首击被激活吃掉） | 引擎会自动 activate+重试；仍不行就手动 osascript activate |
| AXPress 没反应 | CEF div 按钮不吃 AXPress | 一律 hid 坐标点击 |
| 时长类字段被拦 | 单位是「天」不是显示的「小时」 | 用快捷按钮（如 8小时=1）或 read_errors 看报错原文 |
