# Gmail + Calendar 자동화

Mac Mini에서 crontab으로 구동하는 **이메일 자동 분류** + **캘린더 일정 자동 등록** 시스템.

Claude Code CLI(Max20 구독)로 AI 판단 — API 비용 0.

## 핵심 기능

### 1. 이메일 자동 분류

- 5분마다 새 메일을 감지하여 AI가 라벨 분류
- 규칙 기반(발신자/제목) + AI 기반(Claude) 2단계 처리
- confidence가 낮은 분류는 피드백 큐로 → 사용자 확인 후 처리
- 사용자 피드백을 메모리에 저장하여 분류 정확도 지속 개선

### 2. 캘린더 일정 등록

- 이메일 스레드에서 일정/마감일 자동 감지
- 확정 일정은 자동 등록, 불확실한 일정은 큐로
- 중복 방지 (기존 캘린더 확인)

## 아키텍처

```text
Gmail ─(5분)─> email-watcher.sh ─┬─ 규칙 기반 → 즉시 분류
                                  ├─ Claude AI → 확신 높음 → 자동 처리
                                  ├─ Claude AI → 확신 낮음 → 피드백 큐
                                  └─ 일정 감지 → 자동등록/큐
                                                      │
                                              사용자 리뷰 (Claude Code)
                                                      │
                                              feedback-processor.sh
                                              ├─ 액션 실행
                                              ├─ 메모리 업데이트
                                              └─ 로그 기록
```

## 디렉토리 구조

```text
├── bin/              실행 스크립트 (cron 진입점)
├── lib/              공통 함수 라이브러리
├── config/           설정 + 프롬프트 템플릿
├── data/             런타임 데이터 (메모리, 큐, 상태)
├── logs/             로그 파일
└── docs/             문서
```

## 스크립트

| 파일 | 역할 | 실행 주기 |
|------|------|-----------|
| `bin/email-watcher.sh` | 새 메일 감지 → AI 분류 → 로그 | 5분마다 |
| `bin/email-organizer.sh` | 전체 받은편지함 정리 | 6시간마다 |
| `bin/email-to-calendar.sh` | 메일에서 일정 추출 → 등록/제안 | email-watcher 내부 |
| `bin/feedback-processor.sh` | 피드백 큐 처리 → 메모리 업데이트 | 30분마다 |
| `bin/log-summary.sh` | 로그 요약 생성 | 매일 09:00, 18:00 |

## 요구사항

- python3 + Google API 클라이언트 (`pip install -r requirements.txt`)
- [Claude Code CLI](https://claude.ai/code) + Max20 구독
- Google Cloud OAuth 클라이언트 (`.credentials/credentials.json`)

## 설치

```bash
# 1. Python 의존성 설치
pip install -r requirements.txt

# 2. Google Cloud OAuth 설정
# Google Cloud Console에서 OAuth 클라이언트 ID 다운로드
# .credentials/credentials.json으로 저장

# 3. 계정 인증 (브라우저 OAuth)
python3 lib/google_api.py auth --account kevinpark@webace.co.kr
python3 lib/google_api.py auth --account contact@okyc.kr

# 4. Gmail 라벨 생성
for label in "광고" "금융-결제" "보안" "정부-R&D" "보험" "개발-테크" "도메인-호스팅" "확인필요" "소셜"; do
  python3 lib/google_api.py gmail labels-create "$label" --account kevinpark@webace.co.kr
done

# 5. crontab 등록
crontab -e  # crontab.txt 참고
```

## 피드백 큐 사용법

AI가 확신이 낮은 분류/일정은 `data/queue/`에 저장됩니다.

```bash
# 방법 1: Claude Code 대화형
# 프로젝트 디렉토리에서 Claude Code를 열고:
# "피드백 큐 확인해줘"

# 방법 2: 직접 편집
# data/queue/pending-classifications.json의 "decision" 필드를 설정
# "approve" / "reject" / "modify"
# 그 후: bash bin/feedback-processor.sh
```

## 라벨

| 라벨 | 설명 | 자동보관 |
| ------ | ------ | -------- |
| 소셜 | SNS 알림 | O |
| 광고 | 광고, 뉴스레터 | O |
| 금융-결제 | 결제, 청구서 | O |
| 보안 | 보안 알림 | O |
| 정부-R&D | 정부 지원사업 | X |
| 보험 | 보험 관련 | X |
| 개발-테크 | 개발 도구 알림 | O |
| 도메인-호스팅 | 도메인 만료 | X |
| 확인필요 | 사용자 확인 필요 | X |

## 문서

- [아키텍처](docs/architecture.md)
- [데이터 흐름](docs/data-flow.md)
- [메모리 시스템](docs/memory-system.md)
- [피드백 큐](docs/feedback-queue.md)
- [설치 가이드](docs/setup-guide.md)
