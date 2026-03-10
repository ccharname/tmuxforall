# {project} Commander Board

> 更新时间: {time} | 初始预算: N={BUDGET} | 活跃: 2 | 自主范围: [{BUDGET_MIN}, {BUDGET_MAX}] | MAX_AGENTS={MAX_AGENTS}

## 项目目标
> （由指挥官在启动时填写一句话描述）

## 当前阶段
待定

---

## Agent 状态矩阵

| Agent | 角色 | 状态 | 当前任务 | 阻塞 | 上次更新 |
|-------|------|------|---------|------|---------|
| CM | Commander | 🟢就绪 | 等待首个任务 | 无 | {time} |
| PM | Product Manager | 🟢就绪 | 等待派发 | 无 | {time} |

---

## Agent 树（注册记录）

```
CM (Commander)
└── PM (Product Manager)
```

<!-- register-agent.sh 自动追加 -->

---

## 文件锁

| Agent | 文件 | 时间 |
|-------|------|------|

<!-- Agent 编辑文件时写入，完成后删除 -->

---

## 待决策项

> Commander 必须处理以下问题（收到后10分钟内响应）

<!-- 格式：- [ ] [优先级] 问题描述（来自 Agent名, HH:MM） -->

---

## 决策日志

<!-- 格式：- HH:MM 决策描述（理由） -->

---

## 任务队列

### 🔴 待派发
<!-- - 任务名（来源：FD-XXX §N） -->

### 🟡 进行中
<!-- - 任务名（负责：Agent名，开始：HH:MM） -->

### 🟢 已完成
<!-- - 任务名（负责：Agent名，完成：HH:MM，评分：X/10） -->
