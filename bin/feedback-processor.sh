#!/bin/bash
# 피드백 큐 처리기 - 사용자가 결정한 항목 실행 + 메모리 업데이트
# 30분마다 cron 실행 또는 수동 실행

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"
source "$SCRIPTS/lib/gmail-actions.sh"
source "$SCRIPTS/lib/calendar-actions.sh"

FEEDBACK_LOG="$LOG_DIR/feedback-${TODAY}.jsonl"

# === 분류 피드백 처리 ===
process_classification_queue() {
  local queue_file="$QUEUE_DIR/pending-classifications.json"
  [ ! -f "$queue_file" ] && return

  python3 -c "
import json, sys, subprocess, os

queue_file = '$queue_file'
memory_dir = '$MEMORY_DIR'
feedback_log = '$FEEDBACK_LOG'
now_kst = '$NOW_KST'

with open(queue_file) as f:
    data = json.load(f)

remaining = []
processed = 0

for item in data.get('pending', []):
    decision = item.get('decision')
    if decision is None:
        remaining.append(item)
        continue

    email_id = item.get('email_id', '')
    acct = item.get('account', '')

    if decision == 'approve':
        # AI 제안대로 실행
        label = item['ai_suggestion']['label']
        archive = item['ai_suggestion']['archive']
        if label and label != '분류안함' and email_id:
            cmd = ['python3', os.path.join('$LIB_DIR', 'google_api.py'), 'gmail', 'labels-modify', email_id, '--account', acct, '--add', label]
            if archive: cmd.extend(['--remove', 'INBOX'])
            subprocess.run(cmd, capture_output=True)
        final_label = label

    elif decision == 'reject':
        final_label = None

    elif decision == 'modify':
        # 사용자 지정 라벨 사용
        label = item.get('user_label', '')
        if label and email_id:
            cmd = ['python3', os.path.join('$LIB_DIR', 'google_api.py'), 'gmail', 'labels-modify', email_id, '--account', acct, '--add', label]
            if item.get('user_archive', False): cmd.extend(['--remove', 'INBOX'])
            subprocess.run(cmd, capture_output=True)
        final_label = label
    else:
        remaining.append(item)
        continue

    # 사용자 수정 이력 기록
    correction = {
        'time': now_kst,
        'type': 'classification',
        'email_id': email_id,
        'original_label': item['ai_suggestion']['label'],
        'corrected_label': final_label or '(거부)',
        'decision': decision,
        'reason': item.get('user_note', '')
    }
    with open(os.path.join(memory_dir, 'user-corrections.jsonl'), 'a') as f:
        f.write(json.dumps(correction, ensure_ascii=False) + '\n')

    # 피드백 로그
    with open(feedback_log, 'a') as f:
        f.write(json.dumps({
            'time': now_kst,
            'queue_id': item.get('id', ''),
            'decision': decision,
            'original_label': item['ai_suggestion']['label'],
            'final_label': final_label or '(거부)',
            'memory_updated': True
        }, ensure_ascii=False) + '\n')

    # 발신자 패턴 업데이트 (approve/modify일 때)
    if decision in ('approve', 'modify') and final_label:
        sender = item.get('from', '')
        if sender:
            patterns_file = os.path.join(memory_dir, 'sender-patterns.json')
            try:
                with open(patterns_file) as f:
                    patterns = json.load(f)
            except:
                patterns = {'version': 1, 'last_updated': None, 'patterns': {}}

            if sender in patterns['patterns']:
                patterns['patterns'][sender]['count'] += 1
                patterns['patterns'][sender]['label'] = final_label
                patterns['patterns'][sender]['last_seen'] = now_kst[:10]
            else:
                patterns['patterns'][sender] = {
                    'label': final_label,
                    'archive': item.get('user_archive', item['ai_suggestion'].get('archive', False)),
                    'count': 1,
                    'last_seen': now_kst[:10]
                }
            patterns['last_updated'] = now_kst
            with open(patterns_file, 'w') as f:
                json.dump(patterns, f, ensure_ascii=False, indent=2)

    # 분류 규칙 업데이트 (modify일 때 - AI가 틀렸으므로 새 규칙 학습)
    if decision == 'modify' and final_label:
        sender = item.get('from', '')
        rules_file = os.path.join(memory_dir, 'classification-rules.json')
        try:
            with open(rules_file) as f:
                rules_data = json.load(f)
        except:
            rules_data = {'version': 1, 'last_updated': None, 'rules': [], 'label_descriptions': {}}

        rules_data['rules'].append({
            'id': f'rule-{len(rules_data[\"rules\"]) + 1:03d}',
            'pattern': {
                'from_contains': sender if sender else None,
                'subject_contains': None
            },
            'action': {
                'label': final_label,
                'archive': item.get('user_archive', False)
            },
            'confidence': 0.8,
            'source': 'user_feedback',
            'created': now_kst[:10],
            'applied_count': 0
        })
        rules_data['last_updated'] = now_kst
        with open(rules_file, 'w') as f:
            json.dump(rules_data, f, ensure_ascii=False, indent=2)

    processed += 1

# 큐 업데이트
data['pending'] = remaining
with open(queue_file, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

if processed > 0:
    print(f'분류 피드백 처리: {processed}건')
" 2>/dev/null
}

# === 캘린더 피드백 처리 ===
process_calendar_queue() {
  local queue_file="$QUEUE_DIR/pending-calendars.json"
  [ ! -f "$queue_file" ] && return

  python3 -c "
import json, sys, subprocess, os

queue_file = '$queue_file'
feedback_log = '$FEEDBACK_LOG'
now_kst = '$NOW_KST'

with open(queue_file) as f:
    data = json.load(f)

remaining = []
processed = 0

for item in data.get('pending', []):
    decision = item.get('decision')
    if decision is None:
        remaining.append(item)
        continue

    proposal = item.get('proposal', {})

    if decision == 'approve':
        cmd = ['python3', os.path.join('$LIB_DIR', 'google_api.py'),
               'calendar', 'create', item.get('calendar_id', 'primary'),
               '--summary', proposal.get('summary', ''),
               '--from', proposal.get('start', ''),
               '--to', proposal.get('end', ''),
               '--account', item.get('account', '')]
        if proposal.get('location'):
            cmd.extend(['--location', proposal['location']])
        r = subprocess.run(cmd, capture_output=True, text=True)
        status = 'success' if r.returncode == 0 else 'failed'
        print(f'캘린더 등록: {proposal.get(\"summary\",\"\")} [{status}]')

    elif decision == 'modify':
        # 사용자 수정값 사용
        mod = item.get('modified_proposal', proposal)
        cmd = ['python3', os.path.join('$LIB_DIR', 'google_api.py'),
               'calendar', 'create', item.get('calendar_id', 'primary'),
               '--summary', mod.get('summary', ''),
               '--from', mod.get('start', ''),
               '--to', mod.get('end', ''),
               '--account', item.get('account', '')]
        if mod.get('location'):
            cmd.extend(['--location', mod['location']])
        r = subprocess.run(cmd, capture_output=True, text=True)
        status = 'success' if r.returncode == 0 else 'failed'
        print(f'캘린더 등록(수정): {mod.get(\"summary\",\"\")} [{status}]')

    elif decision == 'reject':
        print(f'캘린더 거부: {proposal.get(\"summary\",\"\")}')

    # 피드백 로그
    with open(feedback_log, 'a') as f:
        f.write(json.dumps({
            'time': now_kst,
            'queue_id': item.get('id', ''),
            'type': 'calendar',
            'decision': decision,
            'summary': proposal.get('summary', '')
        }, ensure_ascii=False) + '\n')

    processed += 1

data['pending'] = remaining
with open(queue_file, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

if processed > 0:
    print(f'캘린더 피드백 처리: {processed}건')
" 2>/dev/null
}

# === 라벨 피드백 처리 ===
process_label_queue() {
  local queue_file="$QUEUE_DIR/pending-labels.json"
  [ ! -f "$queue_file" ] && return

  python3 -c "
import json, sys, subprocess, os

queue_file = '$queue_file'
feedback_log = '$FEEDBACK_LOG'
now_kst = '$NOW_KST'
memory_dir = '$MEMORY_DIR'

with open(queue_file) as f:
    data = json.load(f)

remaining = []
processed = 0

for item in data.get('pending', []):
    decision = item.get('decision')
    if decision is None:
        remaining.append(item)
        continue

    if decision == 'approve':
        label_name = item.get('suggested_name', '')
        for acct in item.get('accounts', []):
            subprocess.run(['python3', os.path.join('$LIB_DIR', 'google_api.py'),
                          'gmail', 'labels-create', label_name,
                          '--account', acct], capture_output=True)
        print(f'새 라벨 생성: {label_name}')

        # classification-rules.json의 label_descriptions에 추가
        rules_file = os.path.join(memory_dir, 'classification-rules.json')
        try:
            with open(rules_file) as f:
                rules_data = json.load(f)
        except:
            rules_data = {'version': 1, 'rules': [], 'label_descriptions': {}}
        rules_data.setdefault('label_descriptions', {})[label_name] = item.get('reason', '')
        with open(rules_file, 'w') as f:
            json.dump(rules_data, f, ensure_ascii=False, indent=2)

    elif decision == 'reject':
        print(f'라벨 거부: {item.get(\"suggested_name\",\"\")}')

    with open(feedback_log, 'a') as f:
        f.write(json.dumps({
            'time': now_kst,
            'queue_id': item.get('id', ''),
            'type': 'label',
            'decision': decision,
            'label': item.get('suggested_name', '')
        }, ensure_ascii=False) + '\n')

    processed += 1

data['pending'] = remaining
with open(queue_file, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

if processed > 0:
    print(f'라벨 피드백 처리: {processed}건')
" 2>/dev/null
}

# === 메인 실행 ===
process_classification_queue
process_calendar_queue
process_label_queue
