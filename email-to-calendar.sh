#!/bin/bash
# 이메일 → 캘린더 등록 제안 스크립트
# Claude Code CLI(Max20 구독)로 일정 추출, 확인 후 등록
# 사용법: bash email-to-calendar.sh [confirm <proposal_file>]

set -euo pipefail

WORKSPACE="/Users/okai/.openclaw/workspace"
PROPOSALS_DIR="$WORKSPACE/scripts/calendar-proposals"
mkdir -p "$PROPOSALS_DIR"

# confirm 모드: 제안된 일정 등록
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
    
    cmd = ['gog', 'calendar', 'create', p['calendar_id'],
           '--summary', p['summary'],
           '--from', p['start'],
           '--to', p['end'],
           '--account', p['account'],
           '--force']
    
    if p.get('location'):
        cmd.extend(['--location', p['location']])
    if p.get('description'):
        cmd.extend(['--description', p['description']])
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f'  ✅ {p[\"summary\"]} ({p[\"start\"][:10]})')
    else:
        print(f'  ❌ {p[\"summary\"]} 실패: {result.stderr.strip()}')
  "
  rm -f "$PROPOSAL_FILE"
  exit 0
fi

# 스캔 모드: 메일에서 일정 추출
ACCOUNTS=("kevinpark@webace.co.kr" "contact@okyc.kr")
MAIL_DATA=""

for acct in "${ACCOUNTS[@]}"; do
  # 최근 메일 중 일정성 키워드 포함된 것
  INBOX=$(gog gmail search "in:inbox newer_than:1d" --max 20 --account "$acct" --json 2>/dev/null || echo '{"threads":[]}')
  
  # 스레드 중 일정 관련 있을 수 있는 것의 본문도 확인
  THREAD_IDS=$(echo "$INBOX" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('threads', []):
    subj = t.get('subject', '').lower()
    keywords = ['세미나', '설명회', '미팅', '회의', '행사', '마감', '접수', '신청', 'webinar', 'event', 'meeting', 'deadline', '만기', '납부', '제출', '협약']
    if any(k in subj for k in keywords):
        print(t['id'])
" 2>/dev/null)
  
  DETAILS=""
  for tid in $THREAD_IDS; do
    MSG=$(gog gmail messages search "thread:$tid" --max 1 --account "$acct" --json 2>/dev/null | python3 -c "
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

# 현재 캘린더 일정 (중복 방지)
EXISTING=$(gog calendar events primary --from "$(date -u +%Y-%m-%dT00:00:00Z)" --to "$(date -u -v+30d +%Y-%m-%dT00:00:00Z)" --account kevinpark@webace.co.kr --json 2>/dev/null || echo '{"events":[]}')

PROMPT="아래는 두 Gmail 계정의 최근 메일과 현재 캘린더 일정이야.

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
      \"account\": \"kevinpark@webace.co.kr\",
      \"calendar_id\": \"primary\",
      \"source_subject\": \"원본 메일 제목\",
      \"reason\": \"등록 추천 이유\"
    }
  ],
  \"deadlines\": [
    \"마감일/기한 있는 건 설명 (날짜 포함)\"
  ]
}

규칙:
- 이미 캘린더에 있는 건 제외 (중복 방지)
- 모든 일정은 account: \"kevinpark@webace.co.kr\", calendar_id: \"c_ed143b7a18da74192bf446fa7ccefff11a232e9f68de3c60ac604e85924c591b@group.calendar.google.com\" (오키씨 공식일정)으로 등록
- 시간 불명확하면 종일 이벤트로 (시간 T09:00~T18:00)
- 이미 지난 일정은 제외
- 마감일은 deadlines에 따로 정리
- 일정이 없으면 proposals: [] 로
- account는 메일 출처 계정 사용
- 오늘: $(date +%Y-%m-%d)"

RESULT=$(claude --print "$PROMPT" 2>/dev/null)

# JSON 추출 + 제안 파일 저장
PROPOSAL_FILE="$PROPOSALS_DIR/$(date +%Y%m%d_%H%M%S).json"

python3 -c "
import json, sys

raw = sys.stdin.read()
start = raw.find('{')
end = raw.rfind('}') + 1
if start == -1 or end == 0:
    print('일정 추출 없음')
    sys.exit(0)

data = json.loads(raw[start:end])
proposals = data.get('proposals', [])
deadlines = data.get('deadlines', [])

if not proposals and not deadlines:
    print('📅 새로 등록할 일정 없음')
    sys.exit(0)

if proposals:
    # approved 필드 추가 (기본 false, 사용자 확인 후 true로)
    for p in proposals:
        p['approved'] = False
    
    with open('$PROPOSAL_FILE', 'w') as f:
        json.dump(proposals, f, ensure_ascii=False, indent=2)
    
    print('📅 캘린더 등록 제안:')
    for i, p in enumerate(proposals, 1):
        print(f'  {i}. {p[\"summary\"]}')
        print(f'     📆 {p[\"start\"][:16]} ~ {p[\"end\"][:16]}')
        if p.get('location'):
            print(f'     📍 {p[\"location\"]}')
        print(f'     💡 {p[\"reason\"]}')
        print()
    
    print(f'등록하려면: bash $0 confirm $PROPOSAL_FILE')
    print('(제안 파일에서 approved: true 로 변경 후 실행)')

if deadlines:
    print()
    print('⏰ 마감일/기한:')
    for d in deadlines:
        print(f'  • {d}')
" <<< "$RESULT"
