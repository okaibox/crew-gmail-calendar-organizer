#!/bin/bash
# Calendar API 래핑 함수 (python3 lib/google_api.py 기반)
# 사용: source lib/calendar-actions.sh 후 함수 호출

GOOGLE_API="python3 $LIB_DIR/google_api.py"

# === 캘린더 이벤트 생성 ===
create_event() {
  local calendar_id="$1"
  local summary="$2"
  local start="$3"
  local end="$4"
  local acct="$5"
  local location="${6:-}"

  local cmd=($GOOGLE_API calendar create "$calendar_id"
    --summary "$summary"
    --from "$start"
    --to "$end"
    --account "$acct")

  [ -n "$location" ] && cmd+=(--location "$location")

  "${cmd[@]}" 2>/dev/null
}

# === 캘린더 이벤트 조회 ===
list_events() {
  local calendar_id="$1"
  local from="$2"
  local to="$3"
  local acct="$4"

  $GOOGLE_API calendar events "$calendar_id" --from "$from" --to "$to" --account "$acct" 2>/dev/null || echo '{"events":[]}'
}

# === 일정 추출 결과 처리 (confidence 기반 분기) ===
process_schedule_result() {
  local result_json="$1"
  local acct="$2"
  local source_info="${3:-이메일 스레드}"
  local threshold="${CONFIDENCE_THRESHOLD:-0.6}"

  echo "$result_json" | python3 -c "
import json, sys, subprocess, os

raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])

if not data.get('has_schedule'):
    sys.exit(0)

threshold = float('$threshold')
acct = '$acct'
source = '$source_info'
queue_dir = '$QUEUE_DIR'
now_kst = '$NOW_KST'
lib_dir = '$LIB_DIR'

conf = data.get('confidence', 0.8)
summary = data.get('summary', '일정')
start_t = data.get('start', '')
end_t = data.get('end', '')
location = data.get('location', '')
description = data.get('description', '')

if not start_t:
    sys.exit(0)

# 캘린더 ID 조회
cal_id_proc = subprocess.run(['bash', '-c', f'source $LIB_DIR/common.sh && get_calendar_id {acct}'],
                              capture_output=True, text=True)
calendar_id = cal_id_proc.stdout.strip() or 'primary'

if conf >= threshold:
    # 자동 등록
    cmd = ['python3', os.path.join(lib_dir, 'google_api.py'),
           'calendar', 'create', calendar_id,
           '--summary', summary,
           '--from', start_t,
           '--to', end_t,
           '--account', acct]
    if location:
        cmd.extend(['--location', location])

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        print(f'CALENDAR_ADDED:{summary} ({start_t[:16]})')
    else:
        print(f'CALENDAR_FAILED:{summary} - {r.stderr.strip()}')
else:
    # 피드백 큐로
    item = {
        'id': f'cal-{now_kst.replace(\" \",\"\").replace(\":\",\"\").replace(\"-\",\"\")}',
        'created': now_kst,
        'source_info': source,
        'account': acct,
        'proposal': {
            'summary': summary,
            'start': start_t,
            'end': end_t,
            'location': location,
            'description': description
        },
        'calendar_id': calendar_id,
        'confidence': conf,
        'reason': f'confidence {conf:.1f} < {threshold}',
        'decision': None
    }
    queue_file = os.path.join(queue_dir, 'pending-calendars.json')
    try:
        with open(queue_file) as f:
            q = json.load(f)
    except:
        q = {'pending': []}
    q['pending'].append(item)
    with open(queue_file, 'w') as f:
        json.dump(q, f, ensure_ascii=False, indent=2)
    print(f'CALENDAR_QUEUED:{summary} (conf:{conf:.1f})')
" 2>/dev/null
}
