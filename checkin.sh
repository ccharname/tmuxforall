#!/bin/bash
# checkin.sh — 定时 check-in 调度（schedule/cancel/list）
# 用法: checkin.sh schedule <minutes> "<note>" <target> | cancel <id> | list
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
STATE_DIR="${TMUXFORALL_STATE_DIR}"
mkdir -p "$STATE_DIR"

ACTION="${1:-list}"

case "$ACTION" in

schedule)
  MINUTES="${2:-10}"
  NOTE="${3:-check-in}"
  TARGET="${4:-}"

  if [[ -z "$TARGET" ]]; then
    echo "用法: checkin.sh schedule <minutes> \"<note>\" <session:window>" >&2
    exit 1
  fi

  ID="checkin-$(date +%s)"
  STATE_FILE="${STATE_DIR}/${ID}.json"
  TRIGGER_TIME="$(date -v+${MINUTES}M '+%Y-%m-%d %H:%M' 2>/dev/null || \
                  date -d "+${MINUTES} minutes" '+%Y-%m-%d %H:%M')"

  # 用 nohup + sleep 实现定时
  nohup bash -c "
    sleep $((MINUTES * 60))
    bash '${SKILL_DIR}/send-msg.sh' '${TARGET}' '## Check-in [${ID}] ${TRIGGER_TIME}

${NOTE}

请汇报当前状态。'
    printf '\\a'
  " >/dev/null 2>&1 &
  CHECKIN_PID=$!

  # 写入 state 文件
  python3 -c "
import json
data = {
  'id': '${ID}',
  'pid': ${CHECKIN_PID},
  'minutes': ${MINUTES},
  'note': '${NOTE}',
  'target': '${TARGET}',
  'trigger_time': '${TRIGGER_TIME}',
  'created': '$(date +%Y-%m-%d\ %H:%M:%S)'
}
with open('${STATE_FILE}', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
"
  echo "[checkin] 已调度 ${ID}: ${MINUTES}分钟后 → ${TARGET}"
  echo "  触发时间: ${TRIGGER_TIME}"
  echo "  PID: ${CHECKIN_PID}"
  echo "  取消: checkin.sh cancel ${ID}"
  ;;

cancel)
  ID="${2:-}"
  if [[ -z "$ID" ]]; then
    echo "用法: checkin.sh cancel <id>" >&2
    exit 1
  fi

  STATE_FILE="${STATE_DIR}/${ID}.json"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "[checkin] 找不到 ${ID}" >&2
    exit 1
  fi

  PID="$(python3 -c "import json; d=json.load(open('${STATE_FILE}')); print(d['pid'])")"
  kill "$PID" 2>/dev/null && echo "[checkin] 已终止 PID ${PID}" || echo "[checkin] 进程已结束"
  rm -f "$STATE_FILE"
  echo "[checkin] ${ID} 已取消"
  ;;

list)
  echo "[checkin] 已调度的 check-in 列表:"
  FOUND=0
  for f in "${STATE_DIR}"/checkin-*.json; do
    [[ -f "$f" ]] || continue
    FOUND=1
    python3 - "$f" <<'PYEOF'
import json, sys, os
d = json.load(open(sys.argv[1]))
pid = d['pid']
alive = os.path.exists(f"/proc/{pid}") or (lambda: __import__('subprocess').call(['kill', '-0', str(pid)], stderr=open('/dev/null','w')) == 0)()
status = "运行中" if alive else "已结束"
print(f"  [{d['id']}] {status} | {d['trigger_time']} | {d['target']} | {d['note'][:40]}")
PYEOF
  done
  if [[ "$FOUND" == "0" ]]; then
    echo "  (无)"
  fi
  ;;

*)
  echo "用法: checkin.sh schedule <minutes> \"<note>\" <target> | cancel <id> | list" >&2
  exit 1
  ;;
esac
