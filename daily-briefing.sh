#!/bin/bash
# 오전 일일 브리핑 - 오늘/내일 일정 요약
# Claude Code CLI(Max20 구독) 사용 → API 비용 0

set -euo pipefail

TODAY=$(date +%Y-%m-%d)
DAY3=$(date -v+3d +%Y-%m-%d)
DAY4=$(date -v+4d +%Y-%m-%d)

# 오늘 ~ 3일 뒤 일정
EVENTS=$(gog calendar events "c_ed143b7a18da74192bf446fa7ccefff11a232e9f68de3c60ac604e85924c591b@group.calendar.google.com" \
  --from "${TODAY}T00:00:00+09:00" \
  --to "${DAY4}T00:00:00+09:00" \
  --account kevinpark@webace.co.kr --json 2>/dev/null || echo '{"events":[]}')

# 이번 주 나머지 일정
WEEK_END=$(date -v+7d +%Y-%m-%d)
WEEK_EVENTS=$(gog calendar events "c_ed143b7a18da74192bf446fa7ccefff11a232e9f68de3c60ac604e85924c591b@group.calendar.google.com" \
  --from "${DAY4}T00:00:00+09:00" \
  --to "${WEEK_END}T00:00:00+09:00" \
  --account kevinpark@webace.co.kr --json 2>/dev/null || echo '{"events":[]}')

# 개인 캘린더도 확인 (3일)
PERSONAL=$(gog calendar events primary \
  --from "${TODAY}T00:00:00+09:00" \
  --to "${DAY4}T00:00:00+09:00" \
  --account kevinpark@webace.co.kr --json 2>/dev/null || echo '{"events":[]}')

PROMPT="오늘은 ${TODAY} ($(date +%A))이야. 오전 일일 브리핑을 만들어줘.

먼저 WebSearch 도구로 오늘 부산 날씨와 한국 주요 뉴스 3개를 검색하고,
그 결과를 포함해서 텔레그램 메시지 형식으로 작성해줘. 마크다운 테이블 쓰지 마.

오늘~3일 뒤 일정 (오키씨 공식):
$EVENTS

오늘~3일 뒤 일정 (개인):
$PERSONAL

이번 주 남은 일정:
$WEEK_EVENTS

형식:
🌤 부산 날씨: 맑음 12~19°C 미세먼지 보통

📰 오늘의 뉴스
• 코스피 4%대 급락 - 미국·이란 전쟁 확산 우려
• 서울시장 경선 후보 3명 압축
• AI 반도체 수출 역대 최고

☀️ 오늘 (3/23 월)
• 14:00-16:30 블록체인 세미나 📍부산테크노파크

📌 내일 (3/24 화)
• 일정 없음

📌 모레 (3/25 수)
• 10:00 미팅

📌 3일 뒤 (3/26 목)
• 08:00 세미나

📆 이번 주 남은 일정
• 3/28 14:00 세미나

일정이 하나도 없으면 '오늘 일정 없음 ✨ 여유로운 하루!' 로.
중요한 일정에는 이모지로 강조.
날씨와 뉴스는 제공된 데이터에서 추출해서 포함."

claude --print --allowed-tools "WebSearch" -- "$PROMPT" 2>/dev/null
