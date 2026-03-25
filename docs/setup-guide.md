# 설치 가이드

## 사전 요구사항

| 도구 | 용도 | 설치 |
| --- | --- | --- |
| python3 | Google API 호출 + JSON 파싱 | macOS 기본 포함 |
| pip | Python 패키지 관리 | macOS 기본 포함 |
| Claude Code CLI | AI 분류 판단 | Max20 구독 |
| bash | 스크립트 실행 | macOS 기본 포함 |

## 설치 절차

### 1. 프로젝트 클론

```bash
git clone <repo-url>
cd gmail-calendar-organizer
```

### 2. Python 의존성 설치

```bash
pip install -r requirements.txt
```

### 3. Google Cloud OAuth 설정

1. [Google Cloud Console](https://console.cloud.google.com/) 접속
2. 프로젝트 선택 (또는 새 프로젝트 생성)
3. **API 및 서비스 > 라이브러리**에서 활성화:
   - Gmail API
   - Google Calendar API
4. **API 및 서비스 > 사용자 인증 정보 > OAuth 클라이언트 ID** 생성
   - 애플리케이션 유형: 데스크톱 앱
5. JSON 다운로드 → `.credentials/credentials.json`으로 저장

### 4. 계정 설정

[config/accounts.json](../config/accounts.json)을 편집하여 Gmail 계정과 캘린더 ID를 설정한다.

```json
{
  "credentials_file": ".credentials/credentials.json",
  "accounts": [
    {
      "email": "your@gmail.com",
      "primary": true,
      "calendar_id": "your_calendar_id@group.calendar.google.com",
      "calendar_name": "내 캘린더",
      "token_file": ".credentials/token_your@gmail.com.json"
    }
  ]
}
```

캘린더 ID 확인 방법: Google Calendar 설정 > 캘린더 > 캘린더 ID 복사

### 5. Gmail OAuth 인증

```bash
# 계정별로 실행 (브라우저에서 OAuth 인증 진행)
python3 lib/google_api.py auth --account your@gmail.com
```

토큰이 `.credentials/token_<account>.json`에 자동 저장된다.
이후 crontab에서는 토큰이 자동 갱신되므로 재인증 불필요.

### 6. Gmail 라벨 생성

```bash
for label in "광고" "금융-결제" "보안" "정부-R&D" "보험" "개발-테크" "도메인-호스팅" "확인필요" "소셜"; do
  python3 lib/google_api.py gmail labels-create "$label" --account your@gmail.com
done
```

### 7. 환경 변수 (선택)

```bash
cp .env.example .env
# CONFIDENCE_THRESHOLD 조정 (기본 0.6)
```

### 8. 테스트 실행

```bash
# API 연결 테스트
python3 lib/google_api.py gmail messages-search --query "in:inbox" --max 3 --account your@gmail.com

# email-watcher 단독 실행
bash bin/email-watcher.sh

# 로그 확인
cat logs/email-$(date +%Y%m%d).jsonl

# 피드백 큐 확인
cat data/queue/pending-classifications.json
```

### 9. crontab 등록

```bash
crontab -e
```

[crontab.txt](../crontab.txt) 내용을 복사하고, `$PROJECT` 경로를 실제 경로로 변경한다.

```cron
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
HOME=/Users/your_user
PROJECT=/path/to/gmail-calendar-organizer

*/5 * * * * bash $PROJECT/bin/email-watcher.sh >> $PROJECT/logs/cron.log 2>&1
*/30 * * * * bash $PROJECT/bin/feedback-processor.sh >> $PROJECT/logs/cron.log 2>&1
0 */6 * * * bash $PROJECT/bin/email-organizer.sh >> $PROJECT/logs/cron.log 2>&1
0 9,18 * * * bash $PROJECT/bin/log-summary.sh >> $PROJECT/logs/cron.log 2>&1
```

## 라벨 커스터마이징

[config/labels.json](../config/labels.json)에서 라벨과 규칙을 추가/수정할 수 있다.

규칙 기반 매핑 예시:

```json
{
  "name": "새라벨",
  "description": "설명",
  "default_archive": true,
  "rules": [
    {"type": "from", "match": "sender@example.com"},
    {"type": "subject", "match": "키워드"}
  ]
}
```

## 문제 해결

### cron이 실행되지 않을 때

```bash
# cron 로그 확인
tail -50 logs/cron.log

# 수동 실행으로 오류 확인
bash bin/email-watcher.sh
```

### Claude CLI 오류

```bash
# Claude Code CLI 설치 확인
which claude

# 인증 확인
claude --print "test" 2>&1
```

### Google API 인증 오류

```bash
# 토큰 재생성 (기존 토큰 삭제 후 재인증)
rm .credentials/token_your@gmail.com.json
python3 lib/google_api.py auth --account your@gmail.com
```
