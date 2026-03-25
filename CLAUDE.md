# Gmail + Calendar 자동화

Mac Mini에서 crontab으로 구동하는 이메일 자동 분류 + 캘린더 일정 등록 시스템.
Google API 직접 호출 + Claude Code CLI(Max20 구독) 기반 — API 비용 0.

## 핵심 명령어

```bash
# Google API (lib/google_api.py를 통해 호출, OAuth 인증)
python3 lib/google_api.py gmail messages-search --query "in:inbox newer_than:6m" --max 20 --account EMAIL
python3 lib/google_api.py gmail labels-modify THREAD_ID --add LABEL --remove INBOX --account EMAIL
python3 lib/google_api.py gmail labels-create LABEL --account EMAIL
python3 lib/google_api.py calendar create CALENDAR_ID --summary TITLE --from START --to END --account EMAIL

# 최초 인증 (브라우저 OAuth)
python3 lib/google_api.py auth --account EMAIL

# AI 분류 (구독 기반, 도구 사용 금지)
claude --print --allowed-tools "" -- "프롬프트"
```

## 디렉토리 구조

- `bin/` — 실행 스크립트 (cron 진입점)
- `lib/` — 공통 함수 라이브러리 (모든 bin/ 스크립트가 source)
- `config/` — 설정 파일 + 프롬프트 템플릿
- `data/` — 런타임 데이터 (메모리, 큐, 상태) — .gitignore
- `logs/` — 로그 파일 — .gitignore
- `docs/` — 문서

## 피드백 큐 처리 방법

사용자가 "피드백 확인" 요청 시:
1. `data/queue/pending-*.json` 파일 읽기
2. 각 항목을 사용자에게 보여주기
3. 사용자 결정 받기 (approve/reject/modify)
4. JSON에 `decision` 필드 업데이트
5. `bin/feedback-processor.sh` 실행

## 메모리 시스템

- `data/memory/classification-rules.json` — 학습된 분류 규칙
- `data/memory/sender-patterns.json` — 발신자별 패턴
- `data/memory/user-corrections.jsonl` — 수정 이력 (append-only)

메모리는 Claude 프롬프트의 컨텍스트로 주입되어 분류 정확도를 높인다.

## 코딩 규칙

- bash + python3 (Google API는 lib/google_api.py 모듈로 호출)
- 모든 bin/ 스크립트는 `source "$LIB_DIR/common.sh"` 필수
- 에러 처리: `set -euo pipefail`
- 설정값은 config/ 에서 로드 (하드코딩 금지)
- 프롬프트는 config/prompts/ 템플릿 사용
- 한국어 사용자 메시지
