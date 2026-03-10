# tmux Commander Reference — 必须正确使用

> Commander 上岗必背。所有 tmux 操作必须使用正确命令，禁止用 send-message 模拟管理操作。

## 核心概念

```
Server → Session(s) → Window(s) → Pane(s)
```

- **Target 语法**: `session:window.pane` (如 `my-project:eng-frontend.0`)
- **Session**: 一组 window 的集合，持久化运行
- **Window**: 占满整个屏幕，可含多个 pane
- **Pane**: window 内的矩形分区，各自独立终端

---

## Session 管理

```bash
# 查看所有 session
tmux list-sessions                    # alias: tmux ls

# 检查 session 是否存在（脚本用，返回 0/1）
tmux has-session -t SESSION_NAME

# 创建 session（-d 后台创建不 attach）
tmux new-session -d -s SESSION_NAME
tmux new-session -d -s SESSION_NAME -n FIRST_WINDOW_NAME

# 销毁 session（慎用！会关闭所有 window 和 pane）
tmux kill-session -t SESSION_NAME

# 销毁除指定 session 外的所有 session
tmux kill-session -a -t SESSION_NAME
```

## Window 管理

```bash
# 列出 session 的所有 window
tmux list-windows -t SESSION_NAME
tmux list-windows -t SESSION_NAME -F "#{window_index}: #{window_name} #{window_active}"

# 新建 window
tmux new-window -t SESSION_NAME                        # 自动编号
tmux new-window -t SESSION_NAME -n WINDOW_NAME         # 指定名字
tmux new-window -t SESSION_NAME -n WINDOW_NAME "COMMAND"  # 创建并执行命令

# 关闭 window（正确的关窗口方式！）
tmux kill-window -t SESSION:WINDOW

# 关闭除指定 window 外的所有 window
tmux kill-window -a -t SESSION:WINDOW

# 重命名 window
tmux rename-window -t SESSION:WINDOW NEW_NAME

# 切换 window（仅 attach 模式有效）
tmux select-window -t SESSION:WINDOW

# 交换 window 位置
tmux swap-window -s SESSION:SRC -t SESSION:DST

# 移动 window 到另一个 session
tmux move-window -s SESSION1:WINDOW -t SESSION2:
```

## Pane 管理

```bash
# 列出 window 的所有 pane
tmux list-panes -t SESSION:WINDOW

# 分割 pane
tmux split-window -t SESSION:WINDOW -h    # 左右分割
tmux split-window -t SESSION:WINDOW -v    # 上下分割

# 关闭 pane
tmux kill-pane -t SESSION:WINDOW.PANE

# 关闭除指定 pane 外的所有 pane
tmux kill-pane -a -t SESSION:WINDOW.PANE

# 调整 pane 大小
tmux resize-pane -t SESSION:WINDOW.PANE -D 10   # 下移 10 行
tmux resize-pane -t SESSION:WINDOW.PANE -U 10   # 上移 10 行
tmux resize-pane -t SESSION:WINDOW.PANE -L 10   # 左移 10 列
tmux resize-pane -t SESSION:WINDOW.PANE -R 10   # 右移 10 列
tmux resize-pane -t SESSION:WINDOW.PANE -x 80 -y 24  # 精确尺寸

# 重启 pane（保留 pane 但重启其中的进程）
tmux respawn-pane -k -t SESSION:WINDOW.PANE          # -k 杀掉当前进程
tmux respawn-pane -k -t SESSION:WINDOW.PANE "COMMAND" # 重启并执行命令
```

## 向 Pane 发送输入

```bash
# 发送按键（key name 模式，会解析 C-c, Enter 等）
tmux send-keys -t SESSION:WINDOW "ls -la" Enter

# 发送文字（literal 模式，-l 不解析特殊键名，适合发送包含特殊字符的文本）
tmux send-keys -l -t SESSION:WINDOW "文字内容"
# 然后单独发 Enter
tmux send-keys -t SESSION:WINDOW Enter

# 发送 Ctrl-C 中断当前进程
tmux send-keys -t SESSION:WINDOW C-c

# 发送 Ctrl-D (EOF)
tmux send-keys -t SESSION:WINDOW C-d

# 发送 Ctrl-Z (suspend)
tmux send-keys -t SESSION:WINDOW C-z

# 发送 Escape
tmux send-keys -t SESSION:WINDOW Escape
```

**关键区分：`send-keys` vs `send-keys -l`**
- `send-keys "C-c"` → 发送 Ctrl-C 信号
- `send-keys -l "C-c"` → 字面发送字符 "C-c"
- **发消息给 agent**: 用 `-l` 发文字 + 单独发 `Enter`
- **发控制信号**: 不用 `-l`

## 捕获 Pane 输出（巡检用）

```bash
# 捕获可见内容到 stdout（最常用）
tmux capture-pane -t SESSION:WINDOW -p

# 捕获最近 N 行（含滚动历史）
tmux capture-pane -t SESSION:WINDOW -p -S -50        # 最近 50 行
tmux capture-pane -t SESSION:WINDOW -p -S -100       # 最近 100 行

# 捕获全部历史
tmux capture-pane -t SESSION:WINDOW -p -S -

# 捕获指定行范围（0 = 可见区域第一行，负数 = 历史）
tmux capture-pane -t SESSION:WINDOW -p -S -20 -E -1  # 历史第 20 行到倒数第 1 行

# 保留 trailing spaces（避免截断）
tmux capture-pane -t SESSION:WINDOW -p -J             # -J 保留空格+合并换行

# 捕获到 buffer 而非 stdout
tmux capture-pane -t SESSION:WINDOW -b MY_BUFFER
tmux show-buffer -b MY_BUFFER
tmux delete-buffer -b MY_BUFFER
```

## 查询信息

```bash
# 获取 pane 当前目录
tmux display-message -t SESSION:WINDOW -p "#{pane_current_path}"

# 获取 pane 当前命令
tmux display-message -t SESSION:WINDOW -p "#{pane_current_command}"

# 获取 pane 尺寸
tmux display-message -t SESSION:WINDOW -p "#{pane_width}x#{pane_height}"

# 获取 window 信息
tmux display-message -t SESSION:WINDOW -p "#{window_name} #{window_index} #{window_panes}"

# 获取 session 信息
tmux display-message -t SESSION -p "#{session_name} #{session_windows} #{session_attached}"
```

## Pipe Pane（实时监控输出）

```bash
# 将 pane 输出实时写入文件
tmux pipe-pane -t SESSION:WINDOW "cat >> /tmp/pane-output.log"

# 停止 pipe
tmux pipe-pane -t SESSION:WINDOW
```

## Wait-for（进程间同步）

```bash
# 等待信号（阻塞直到收到）
tmux wait-for CHANNEL_NAME

# 发送信号
tmux wait-for -S CHANNEL_NAME

# 锁定/解锁（互斥）
tmux wait-for -L CHANNEL_NAME   # 获取锁
tmux wait-for -U CHANNEL_NAME   # 释放锁
```

---

## Commander 常用操作速查

### 开工程师窗口 + 启动 Claude
```bash
tmux new-window -t my-project -n eng-xxx
sleep 2
tmux send-keys -t my-project:eng-xxx "claude" Enter
```

### 向工程师派发任务
```bash
bash ~/.claude/skills/tmuxforall/send-msg.sh my-project:eng-xxx "任务内容"
```

### 巡检工程师状态
```bash
tmux capture-pane -t my-project:eng-xxx -p -S -30 | tail -15
```

### 批量巡检所有窗口
```bash
for w in eng-frontend eng-backend qa; do
  echo "=== $w ==="
  tmux capture-pane -t my-project:$w -p -S -30 | grep -E "\[DONE\]|\[BLOCKED\]|STATUS|error" | tail -3
  echo
done
```

### 关闭已完成的工程师窗口
```bash
tmux kill-window -t my-project:eng-xxx
```

### 中断工程师正在执行的命令
```bash
tmux send-keys -t my-project:eng-xxx C-c
```

### 重启卡死的工程师 pane
```bash
tmux respawn-pane -k -t my-project:eng-xxx
sleep 1
tmux send-keys -t my-project:eng-xxx "claude" Enter
```

---

## 禁止事项

1. **禁止用 send-message.sh 发 "/exit" 来关窗口** → 用 `tmux kill-window`
2. **禁止用 send-message.sh 发 "Ctrl-C" 文字** → 用 `tmux send-keys C-c`
3. **禁止猜测 session 名** → 先 `tmux list-sessions` 确认
4. **禁止猜测 window 名** → 先 `tmux list-windows -t SESSION` 确认
5. **禁止 kill-server** → 会摧毁所有 session，除非明确要求
6. **禁止 kill-session** 除非明确要求 → 会关闭所有 window

---

*Commander 上岗必背，每次 tmux 操作前回顾此文件。*
