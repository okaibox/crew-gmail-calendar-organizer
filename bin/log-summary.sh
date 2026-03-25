#!/bin/bash
# 로그 요약 생성 → 로컬 파일 저장
# 피드백 큐 미결건 표시 포함

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"

SUMMARY_FILE="$LOG_DIR/summary-${TODAY}.txt"

# 로그 없거나 비어있으면
if [ ! -f "$EMAIL_LOG" ] || [ ! -s "$EMAIL_LOG" ]; then
  echo "[$NOW_KST] 처리된 메일 없음" >> "$SUMMARY_FILE"
  exit 0
fi

LOG_CONTENT=$(cat "$EMAIL_LOG")

# 피드백 큐 미결건 카운트
PENDING_COUNT=$(python3 -c "
import json, os

total = 0
queue_dir = '$QUEUE_DIR'
for f in ['pending-classifications.json', 'pending-calendars.json', 'pending-labels.json']:
    path = os.path.join(queue_dir, f)
    try:
        with open(path) as fh:
            data = json.load(fh)
        total += len([i for i in data.get('pending', []) if i.get('decision') is None])
    except:
        pass
print(total)
" 2>/dev/null || echo 0)

# 프롬프트 템플릿 로드
TEMPLATE=$(cat "$PROMPTS_DIR/summarize-log.txt")

# Claude로 요약
SUMMARY=$(claude --print --allowed-tools "" -- "${TEMPLATE}

피드백 큐 미결건: ${PENDING_COUNT}건

로그:
$LOG_CONTENT" 2>/dev/null)

if [ -n "$SUMMARY" ]; then
  {
    echo "=== $NOW_KST ==="
    echo "$SUMMARY"
    echo ""
  } >> "$SUMMARY_FILE"
fi
