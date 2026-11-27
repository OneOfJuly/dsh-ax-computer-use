// dsh-ax-computer-use — AX-first computer use for DSH (macOS / Windows / Linux).
// Core idea: one round-trip carries MANY verified actions (batch), verified by a11y readback —
// replacing the 20+ round-trip screenshot→guess→click→screenshot visual loop.
// v2: per-platform engines behind one CLI contract (see ARCHITECTURE.md).
import { spawn } from 'node:child_process'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

// ESM: derive the package directory from this module's URL.
const __dirname = path.dirname(fileURLToPath(import.meta.url))

/** Pick the engine for this OS: prebuilt Swift binary (macOS), PowerShell (Windows), Python (Linux). */
function enginePath() {
  switch (process.platform) {
    case 'darwin': return path.join(__dirname, 'bin', 'axc')
    case 'win32': return path.join(__dirname, 'engines', 'axc.ps1')
    case 'linux': return path.join(__dirname, 'engines', 'axc.py')
    default: return path.join(__dirname, 'bin', 'axc')
  }
}

/** Windows engines need powershell -File; *nix engines exec directly. */
function engineCommand(engine) {
  if (process.platform === 'win32') return ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', engine]
  return [engine]
}

/** Run the axc engine; reject on non-zero exit with combined stderr. */
function run(engine, args, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    const c = spawn(engineCommand(engine)[0], [...engineCommand(engine).slice(1), ...args], { timeout: timeoutMs })
    let out = ''
    let err = ''
    c.stdout.on('data', (d) => { out += d })
    c.stderr.on('data', (d) => { err += d })
    c.on('error', (e) => reject(new Error(`引擎启动失败: ${e.message}`)))
    c.on('close', (code) => {
      if (code === 0) resolve(out)
      else reject(new Error(`axc ${args[0]} exit=${code} ${err.trim().slice(0, 400)}`))
    })
  })
}

/** 0700 private temp dir, cleaned by caller. */
function privateDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'axcu-'))
  fs.chmodSync(dir, 0o700)
  return dir
}

function rmRf(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }) } catch { /* ignore */ }
}

/** render 是同步的，execute 里把附件引用存在这里，render 用 token 取回 */
const shotRefs = new Map()

const textOutput = {
  schema: {
    type: 'object', additionalProperties: false,
    properties: { text: { type: 'string' } },
    required: ['text'],
  },
  render: (_args, value) => [{ type: 'text', text: value.text }],
}

const present = (title) => (args) => ({ card: 'generic', title, kind: 'other', rawInput: args })

export const inject = ['tools']

export function apply(ctx, _config) {
  const engine = enginePath()
  try { fs.chmodSync(engine, 0o755) } catch { /* already executable */ }

  const tools = [
    defineTool(ctx, {
      name: 'ax_windows',
      description:
        '列出当前屏幕上所有可见窗口（pid / 窗口号 / 应用名 / 标题 / 位置大小）。\n' +
        '操作任何应用的第一步：从这里拿 pid 和窗口号。标题可用于 ax_act 的 win 定位。',
      parameters: {
        pid: { type: 'integer', description: '可选：只列这个进程的窗口' },
      },
      output: textOutput,
      presentCall: present('AX 窗口列表'),
      async execute(args) {
        const a = ['winlist']
        if (args && args.pid) a.push('--pid', String(args.pid))
        const out = await run(engine, a)
        return { text: `pid\t窗口号\t应用\t标题\t几何\n${out}` }
      },
    }),

    defineTool(ctx, {
      name: 'ax_tree',
      description:
        '读取应用的无障碍元素树：每行 = [ref] 角色 t=标题 v=值（含 FOCUS 焦点标记）；无标题的可点击节点会带 press 与 @x,y 中心坐标，输入框带 ph=占位符。\n' +
        '**用 clickable 只看可交互元素，通常小很多**；用 text 关键字做全深度搜索，只输出命中节点（>> 标记）及其祖先路径，ref 可直接用于 ax_act；\n' +
        '网页内容很深（Electron 的 webarea 在 depth 9～10）时，用 root 指定某个 ref 只展开它的子树，避免整棵树被截断。\n' +
        '注意：动态网页（播放中视频等）索引会漂移——**操作时优先用 ax_act 的 text 定位**，别依赖长 ref。',
      parameters: {
        pid: { type: 'integer', required: true, description: '目标进程 pid（来自 ax_windows）' },
        win: { type: 'integer', description: '窗口序号（应用内第几个 AX 窗口，默认 0）' },
        depth: { type: 'integer', description: '展开深度（默认 18；Electron 网页内容常在 10～14 层）' },
        max: { type: 'integer', description: '最多输出节点数（默认 80）' },
        clickable: { type: 'boolean', description: '只列按钮/链接/勾选框等可交互元素' },
        text: { type: 'string', description: '全深度搜索标题/值/占位符含此关键字的节点，输出命中及其祖先路径' },
        root: { type: 'string', description: '只展开此 ref（来自上一次 ax_tree）的子树，ref 仍按窗口根编号' },
        menu: { type: 'boolean', description: '展开菜单子树（默认修剪菜单条，省 token）' },
      },
      output: textOutput,
      presentCall: present('AX 元素树'),
      async execute(args) {
        const a = ['axtree', '--pid', String(args.pid)]
        if (args.win != null) a.push('--win', String(args.win))
        if (args.depth != null) a.push('--depth', String(args.depth))
        if (args.max != null) a.push('--max', String(args.max))
        if (args.clickable) a.push('--clickable')
        if (args.text) a.push('--text', String(args.text))
        if (args.root) a.push('--root', String(args.root))
        if (args.menu) a.push('--menu')
        const out = await run(engine, a)
        return { text: out }
      },
    }),

    defineTool(ctx, {
      name: 'ax_act',
      description:
        '核心工具：**一次调用批量执行多个动作，每个动作自带验证**（读回/焦点/窗口变化 → confirmed / suspected_noop / ERR）。\n' +
        '这是比视觉循环快 10 倍的关键：把「填表单+点提交+验证」打包成一个 actions 数组。\n' +
        '定位：{"path":"1.0.0:AXCheckBox"} 或 **推荐 {"text":"提交","role":"AXButton"}**（搜文字，免疫动态页面；多处匹配用 "nth":1）。\n' +
        '动作类型：press / set{value} / type{文本,追加} / key{"cmd+a"} / focus / menu{"格式>字体>粗体"} / read / frame / click{x,y 或 ocr:"文字"} / ocr{text} / wait{ms} / scroll{dy}。\n' +
        'v2 组合 op：{"op":"dropdown","x":..,"y":..,"search":"示例","pick":"ALPHA","verify":{"text":"项目","contains":"ALPHA"}} = 开下拉→HID 输入过滤→OCR 点选→读回验证（CEF/antd 表单神器）；{"op":"remember","key":"类别","x":..,"y":..} / recall = 空间坐标缓存（表单字段位置跨会话稳定，缓存后直接点）；{"op":"read_errors"} = 扫描表单校验错误（提交后必加，报 FORM_ERROR）。\n' +
        'click 还支持 ocr 定位（自绘 UI 神器）：{"op":"click","ocr":"搜索"} = 引擎内 Vision OCR 找文字并点其中心，一轮替代截图循环；{"op":"ocr","text":"关键词"} 列出全部命中坐标；{"op":"click","shot":[x,y]} = 直接用 ax_shot 截图里的像素坐标（引擎按最近一次截图换算成屏幕坐标）。\n' +
        'click/press 自带取证：hid 未指定时，坐标落在网页内容上会自动走 HID（结果标 autohid，不必手动 hid:1）；没有 verify 的 click 用 窗口变化/焦点变化/点击点附近屏幕变化 自动判定 confirmed/unverified；也可加 "verify":{"path":…,"contains":…} 内联校验。\n' +
        '每次调用返回：逐动作状态行 + SUMMARY + FOCUS 前后 + WINDOWS 窗口变化。confirmed=已验证成功；unverified/suspected_noop=执行了但没观察到变化（用 read/ocr/shot 复核或换定位方式重试）。\n' +
        '典型流程：ax_windows → ax_tree --clickable → 一条 ax_act 批量完成 → 看 SUMMARY 决定是否需要补救动作。',
      parameters: {
        pid: { type: 'integer', required: true, description: '目标进程 pid（来自 ax_windows）' },
        actions: { type: 'string', required: true, description: 'JSON 数组，如 [{"op":"set","text":"用户名","value":"tom"},{"op":"press","text":"登录","role":"AXButton"}]' },
        abort_on_error: { type: 'integer', description: '默认 1：任一动作 suspected_noop/ERR 立即中止剩余动作并报 ABORTED at action[N]（防连锁错点）。传 0 关闭。' },
        abort_on_unverified: { type: 'integer', description: '1 = 更严格：unverified 结果也中止（网页关键提交前用）。' },
      },
      output: textOutput,
      presentCall: present('AX 批量动作'),
      async execute(args) {
        let actions = String(args.actions ?? '').trim()
        if (!actions.startsWith('[')) actions = `[${actions}]`
        JSON.parse(actions) // validate before spawning
        const extra = []
        if (args.abort_on_error === 0) extra.push('--abort_on_error', '0')
        if (args.abort_on_unverified === 1) extra.push('--abort_on_unverified', '1')
        const out = await run(engine, ['axact', '--pid', String(args.pid), '--json', actions, ...extra], 120000)
        return { text: out }
      },
    }),

    defineTool(ctx, {
      name: 'ax_read',
      description:
        '读单个元素：角色 / 标题 / 值 / 焦点态 / 可交互动作列表 / 位置大小。\n' +
        '定位同 ax_act：path 或 text(+role+nth)。用于确认某元素当前状态（如勾选框是否已选中）。',
      parameters: {
        pid: { type: 'integer', required: true, description: '目标进程 pid' },
        path: { type: 'string', description: '元素 ref（来自 ax_tree）' },
        text: { type: 'string', description: '按文字定位（推荐）' },
        role: { type: 'string', description: '配合 text 的角色过滤，如 AXButton' },
        nth: { type: 'integer', description: '多处匹配时选第几个（0 起）' },
      },
      output: textOutput,
      presentCall: present('AX 元素读取'),
      async execute(args) {
        if (!args.path && !args.text) throw new Error('需要 path 或 text')
        if (!args.path) {
          const loc = { text: args.text }
          if (args.role) loc.role = args.role
          if (args.nth != null) loc.nth = args.nth
          const out = await run(engine, ['axact', '--pid', String(args.pid), '--json', JSON.stringify([{ op: 'read', ...loc }])], 60000)
          return { text: out }
        }
        const a = ['axread', '--pid', String(args.pid), '--path', String(args.path)]
        const out = await run(engine, a)
        return { text: out }
      },
    }),

    defineTool(ctx, {
      name: 'ax_shot',
      description:
        '窗口截图（JPEG 压缩，长边默认 1280，约为原图 1/20 的 token）。\n' +
        'AX 是主力、截图是兜底：树读不到的（自绘 canvas、验证码、纯图形界面）才用。截的是该 pid 最大可见窗口。\n' +
        '返回文本里带 img×scale×origin 映射：屏幕坐标 = origin + 图片像素 × scale；不想手算就用 ax_act 的 {"op":"click","shot":[px,py]}。',
      parameters: {
        pid: { type: 'integer', required: true, description: '目标进程 pid' },
        max: { type: 'integer', description: '长边像素上限（默认 1280）' },
      },
      output: {
        schema: {
          type: 'object', additionalProperties: false,
          properties: { text: { type: 'string' }, token: { type: 'string' } },
          required: ['text', 'token'],
        },
        render: (_args, value) => {
          const blocks = [{ type: 'text', text: value.text }]
          const ref = shotRefs.get(value.token)
          if (ref) { shotRefs.delete(value.token); blocks.push({ type: 'image', attachment: ref }) }
          return blocks
        },
      },
      presentCall: present('AX 截图'),
      async execute(args) {
        const dir = privateDir()
        try {
          const file = path.join(dir, `shot-${Date.now()}.jpg`)
          const a = ['shot', '--pid', String(args.pid), '--out', file]
          if (args.max != null) a.push('--max', String(args.max))
          const out = await run(engine, a, 60000)
          const buf = fs.readFileSync(file)
          const attachments = ctx.get('attachments')
          if (attachments) {
            const [ref] = await attachments.saveImages([{ data: buf, mediaType: 'image/jpeg', name: `ax-${Date.now()}.jpg` }])
            const token = crypto.randomUUID()
            shotRefs.set(token, ref)
            if (shotRefs.size > 20) shotRefs.delete(shotRefs.keys().next().value)
            return { text: `截图 OK（${Math.round(buf.length / 1024)}KB JPEG）。${out}`, token }
          }
          return { text: `截图已存 ${file}（附件库不可用）\n${out}`, token: '' }
        } finally {
          rmRf(dir)
        }
      },
    }),

    defineTool(ctx, {
      name: 'ax_relaunch',
      description:
        '带参数重启一个应用（先退出再 open -a 带参，登录态不丢）。\n' +
        '用于 Electron/Chromium 应用开启无障碍树：例如飞书需 --force-renderer-accessibility，\n' +
        'Chrome 调试需 --remote-debugging-port=9229。**重启会打断该应用当前使用，先征得用户同意**。',
      parameters: {
        app: { type: 'string', required: true, description: '应用名（如「飞书」「Feishu」「Google Chrome」）' },
        args: { type: 'string', description: '附加启动参数，空格分隔，如 --force-renderer-accessibility' },
      },
      output: textOutput,
      presentCall: present('AX 带参重启'),
      async execute(args) {
        const a = ['relaunch', '--app', String(args.app)]
        if (args.args) a.push('--args', String(args.args))
        const out = await run(engine, a, 90000)
        return { text: out }
      },
    }),
  ]

  for (const t of tools) ctx.tools.register(t)
}

function defineTool(_ctx, options) {
  // {key:{type,required,description}} → JSON schema {type:'object',properties,required}
  const properties = {}
  const required = []
  for (const [key, node] of Object.entries(options.parameters ?? {})) {
    const { required: isRequired, ...rest } = node
    properties[key] = rest
    if (isRequired) required.push(key)
  }
  return {
    name: options.name,
    description: options.description,
    parameters: { type: 'object', properties, ...(required.length ? { required } : {}) },
    output: { schema: options.output.schema, render: options.output.render },
    ...(options.presentCall ? { presentCall: options.presentCall } : {}),
    execute: options.execute,
  }
}
