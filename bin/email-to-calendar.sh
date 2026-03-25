#!/bin/bash
# 이메일 → 캘린더 등록 제안 스크립트
# Claude Code CLI로 일정 추출, confidence 기반 자동등록/큐
# 사용법: bash bin/email-to-calendar.sh [confirm <proposal_file>]

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"
source "$SCRIPTS/lib/classifier.sh"
source "$SCRIPTS/lib/gmail-actions.sh"
source "$SCRIPTS/lib/calendar-actions.sh"

PROPOSALS_DIR="$DATA_DIR/proposals"
mkdir -p "$PROPOSALS_DIR"

# === confirm 모드: 제안된 일정 등록 ===
if [ "${1:-}" = "confirm" ] && [ -n "${2:-}" ]; then
  PROPOSAL_FILE="$2"
  if [ ! -f "$PROPOSAL_FILE" ]; then
    echo "파일 없음: $PROPOSAL_FILE"
    exit 1
  fi

  python3 -c "
import json, subprocess, sys

with open('$PROPOSAL_FILE') as f:
    proposals = json.load(f)

for p in proposals:
    if not p.get('approved', False):
        continue

    cmd = ['python3', '$LIB_DIR/google_api.py',
           'calendar', 'create', p['calendar_id'],
           '--summary', p['summary'],
           '--from', p['start'],
           '--to', p['end'],
           '--account', p['account']]

    if p.get('location'):
        cmd.extend(['--location', p['location']])
    if p.get('description'):
        cmd.extend(['--description', p['description']])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f'  등록: {p[\"summary\"]} ({p[\"start\"][:10]})')
    else:
        print(f'  실패: {p[\"summary\"]} - {result.stderr.strip()}')
  "
  rm -f "$PROPOSAL_FILE"
  exit 0
fi

# === 스캔 모드: 메일에서 일정 추출 ===
ACCOUNTS=()
while IFS= read -r line; do ACCOUNTS+=("$line"); done < <(load_accounts)
PRIMARY_ACCT=$(get_primary_account)
MAIL_DATA=""

for acct in "${ACCOUNTS[@]}"; do
  INBOX=$(search_threads "in:inbox newer_than:1d" "$acct" 20)

  # 일정 관련 키워드 포함 스레드 필터
  THREAD_IDS=$(echo "$INBOX" | python3 -c "
import json, sys
data = json.load(sys.stdin)
keywords = $(python3 -c "
import json
with open('$CONFIG_DIR/labels.json') as f:
    print(json.dumps(json.load(f).get('schedule_keywords', [])))
" 2>/dev/null)
for t in data.get('threads', []):
    subj = t.get('subject', '').lower()
    if any(k in subj for k in keywords):
        print(t['id'])
" 2>/dev/null)

  DETAILS=""
  for tid in $THREAD_IDS; do
    MSG=$(python3 "$LIB_DIR/google_api.py" gmail messages-search --query "thread:$tid" --max 1 --account "$acct" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
msgs = data.get('messages', [])
if msgs:
    m = msgs[0]
    print(json.dumps({'id': m.get('id',''), 'subject': m.get('subject',''), 'snippet': m.get('snippet',''), 'date': m.get('date','')}, ensure_ascii=False))
" 2>/dev/null || true)
    if [ -n "$MSG" ]; then
      DETAILS+="$MSG
"
    fi
  done

  MAIL_DATA+="
=== $acct ===
스레드 목록:
$INBOX

일정 관련 메일 상세:
$DETAILS
"
done

# 캘린더 ID
CALENDAR_ID=$(get_calendar_id "$PRIMARY_ACCT")

# 현재 캘린더 일정 (중복 방지)
EXISTING=$(list_events "$CALENDAR_ID" "$(date -u +%Y-%m-%dT00:00:00Z)" "$(date -u -v+30d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u --date='+30 days' +%Y-%m-%dT00:00:00Z)" "$PRIMARY_ACCT")

PROMPT="아래는 Gmail 계정의 최근 메일과 현재 캘린더 일정이야.

메일에서 캘린더에 등록할만한 일정/마감일/이벤트를 찾아서 JSON으로만 출력해줘.

현재 캘린더:
$EXISTING

메일 데이터:
$MAIL_DATA

출력 형식 (JSON만, 설명 없이):
{
  \"proposals\": [
    {
      \"summary\": \"일정 제목\",
      \"start\": \"2026-03-25T14:00:00+09:00\",
      \"end\": \"2026-03-25T16:00:00+09:00\",
      \"location\": \"장소 (없으면 빈 문자열)\",
      \"description\": \"메일 출처 요약\",
      \"account\": \"$PRIMARY_ACCT\",
      \"calendar_id\": \"$CALENDAR_ID\",
      \"source_subject\": \"원본 메일 제목\",
      \"reason\": \"등록 추천 이유\",
      \"confidence\": 0.9
    }
  ],
  \"deadlines\": [
    \"마감일/기한 있는 건 설명 (날짜 포함)\"
  ]
}

규칙:
- 이미 캘린더에 있는 건 제외
- 시간 불명확하면 종일 이벤트 (09:00~18:00)
- 이미 지난 일정은 제외
- 마감일은 deadlines에 따로 정리
- confidence: 날짜/시간 명시적 0.9+, 추정 0.5~0.7
- 오늘: $(date +%Y-%m-%d)"

RESULT=$(claude --print --allowed-tools "" -- "$PROMPT" 2>/dev/null)

# JSON 추출 + confidence 기반 분기
PROPOSAL_FILE="$PROPOSALS_DIR/$(date +%Y%m%d_%H%M%S).json"
THRESHOLD="${CONFIDENCE_THRESHOLD:-0.6}"

python3 -c "
import json, sys, subprocess, os

raw = sys.stdin.read()
start = raw.find('{')
end = raw.rfind('}') + 1
if start == -1 or end == 0:
    print('일정 추출 없음')
    sys.exit(0)

data = json.loads(raw[start:end])
proposals = data.get('proposals', [])
deadlines = data.get('deadlines', [])
threshold = float('$THRESHOLD')

if not proposals and not deadlines:
    print('새로 등록할 일정 없음')
    sys.exit(0)

auto_registered = []
queued = []

for p in proposals:
    conf = p.get('confidence', 0.8)
    if conf >= threshold:
        # 자동 등록
        cmd = ['python3', '$LIB_DIR/google_api.py',
               'calendar', 'create', p.get('calendar_id', 'primary'),
               '--summary', p['summary'],
               '--from', p['start'],
               '--to', p['end'],
               '--account', p.get('account', '$PRIMARY_ACCT')]
        if p.get('location'):
            cmd.extend(['--location', p['location']])
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0:
            auto_registered.append(p)
            print(f'  자동 등록: {p[\"summary\"]} ({p[\"start\"][:16]}) conf:{conf:.1f}')
        else:
            print(f'  등록 실패: {p[\"summary\"]} - {r.stderr.strip()}')
    else:
        queued.append(p)

# 큐에 추가
if queued:
    queue_file = os.path.join('$QUEUE_DIR', 'pending-calendars.json')
    try:
        with open(queue_file) as f:
            q = json.load(f)
    except:
        q = {'pending': []}

    for p in queued:
        q['pending'].append({
            'id': f'cal-{p[\"start\"][:10].replace(\"-\",\"\")}',
            'created': '$NOW_KST',
            'source_info': p.get('source_subject', ''),
            'account': p.get('account', '$PRIMARY_ACCT'),
            'proposal': {
                'summary': p['summary'],
                'start': p['start'],
                'end': p['end'],
                'location': p.get('location', ''),
                'description': p.get('description', '')
            },
            'calendar_id': p.get('calendar_id', 'primary'),
            'confidence': p.get('confidence', 0.5),
            'reason': p.get('reason', ''),
            'decision': None
        })
        print(f'  큐 추가: {p[\"summary\"]} conf:{p.get(\"confidence\",0.5):.1f}')

    with open(queue_file, 'w') as f:
        json.dump(q, f, ensure_ascii=False, indent=2)

if deadlines:
    print()
    print('마감일/기한:')
    for d in deadlines:
        print(f'  - {d}')

print(f'\n자동등록: {len(auto_registered)}건, 확인필요: {len(queued)}건')
" <<< "$RESULT"
