#!/bin/bash
# Gmail API 래핑 함수 (python3 lib/google_api.py 기반)
# 사용: source lib/gmail-actions.sh 후 함수 호출

GOOGLE_API="python3 $LIB_DIR/google_api.py"

# === 메일 검색 ===
search_emails() {
  local query="$1"
  local acct="$2"
  local max="${3:-20}"

  $GOOGLE_API gmail messages-search --query "$query" --max "$max" --account "$acct" 2>/dev/null || echo '{"messages":[]}'
}

# === 스레드 검색 ===
search_threads() {
  local query="$1"
  local acct="$2"
  local max="${3:-50}"
  local page_token="${4:-}"

  if [ -z "$page_token" ]; then
    $GOOGLE_API gmail threads-search --query "$query" --max "$max" --account "$acct" 2>/dev/null || echo '{"threads":[]}'
  else
    $GOOGLE_API gmail threads-search --query "$query" --max "$max" --page "$page_token" --account "$acct" 2>/dev/null || echo '{"threads":[]}'
  fi
}

# === 메일 수 카운트 ===
count_messages() {
  local json_data="$1"
  echo "$json_data" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('messages',[])))" 2>/dev/null || echo 0
}

count_threads() {
  local json_data="$1"
  echo "$json_data" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('threads',[])))" 2>/dev/null || echo 0
}

# === 라벨 수정 ===
modify_labels() {
  local thread_id="$1"
  local acct="$2"
  local add_label="${3:-}"
  local remove_label="${4:-}"

  local cmd=($GOOGLE_API gmail labels-modify "$thread_id" --account "$acct")
  [ -n "$add_label" ] && cmd+=(--add "$add_label")
  [ -n "$remove_label" ] && cmd+=(--remove "$remove_label")

  "${cmd[@]}" 2>/dev/null
}

# === 라벨 생성 ===
create_label() {
  local label="$1"
  local acct="$2"

  $GOOGLE_API gmail labels-create "$label" --account "$acct" 2>/dev/null
}

# === 규칙 기반 라벨 적용 (배치) ===
apply_label_batch() {
  local query="$1"
  local label="$2"
  local archive="$3"
  local acct="$4"

  local ids
  ids=$($GOOGLE_API gmail threads-search --query "$query" --all --account "$acct" 2>/dev/null | \
    python3 -c "import json,sys; [print(t['id']) for t in json.load(sys.stdin).get('threads',[])]" 2>/dev/null || true)

  [ -z "$ids" ] && return

  local count
  count=$(echo "$ids" | wc -l | tr -d ' ')

  # 50개씩 배치로 labels-modify 실행
  local remove_arg=""
  [ "$archive" = "true" ] && remove_arg="--remove INBOX"

  echo "$ids" | xargs -n 50 bash -c "
    python3 \"$LIB_DIR/google_api.py\" gmail labels-modify \"\$@\" --add \"$label\" --account \"$acct\" $remove_arg 2>/dev/null || true
  " _

  echo "$count"
}

# === 명시적 광고 삭제 ===
trash_explicit_ads() {
  local acct="$1"

  $GOOGLE_API gmail trash \
    --query 'in:inbox (subject:"(광고)" OR subject:"[광고]" OR subject:"(AD)" OR subject:"[AD]")' \
    --max 1000 --account "$acct" 2>/dev/null || echo 0
}

# === 규칙 기반 분류 실행 (config/labels.json 기반) ===
apply_rules_from_config() {
  local acct="$1"

  python3 -c "
import json

with open('$CONFIG_DIR/labels.json') as f:
    data = json.load(f)

for label_def in data.get('labels', []):
    name = label_def['name']
    archive = label_def.get('default_archive', False)
    rules = label_def.get('rules', [])

    if not rules:
        continue

    from_rules = [r['match'] for r in rules if r['type'] == 'from']
    subj_rules = [r['match'] for r in rules if r['type'] == 'subject']

    parts = []
    if from_rules:
        from_str = ' OR '.join([f'from:{f}' for f in from_rules])
        parts.append(from_str)
    if subj_rules:
        subj_str = ' OR '.join([f'subject:\"{s}\"' for s in subj_rules])
        parts.append(subj_str)

    if parts:
        query = f'in:inbox ({\" OR \".join(parts)})'
        print(f'{name}\t{\"true\" if archive else \"false\"}\t{query}')
" 2>/dev/null | while IFS=$'\t' read -r label archive query; do
    local count
    count=$(apply_label_batch "$query" "$label" "$archive" "$acct")
    [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null && echo "  $label: ${count}건"
  done
}

# === 다음 페이지 토큰 추출 ===
get_next_page_token() {
  local json_data="$1"
  echo "$json_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextPageToken',''))" 2>/dev/null || echo ""
}
