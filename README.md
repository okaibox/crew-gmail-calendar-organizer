# personal-assistant-scripts

Gmail 자동 분류 + 캘린더 + 오전 브리핑 자동화.
Claude Code CLI(Max20 구독)로 처리 — API 비용 0.

## 스크립트

| 파일 | 역할 | 실행 주기 |
|------|------|-----------|
| `email-watcher.sh` | 새 메일 감지 → 분류 → 로그 저장 | 5분마다 |
| `email-organizer.sh` | 전체 받은편지함 정리 | 6시간마다 |
| `email-to-calendar.sh` | 메일에서 일정 추출 → 캘린더 등록 | email-watcher 내부 |
| `email-log-summary.sh` | 로그 요약 → 텔레그램 | 3시간마다 |
| `daily-briefing.sh` | 날씨+뉴스+일정 브리핑 | 매일 08:00 |
| `notify-telegram.sh` | 텔레그램 Bot API 전송 | 유틸 |

## 요구사항

- [gog CLI](https://gogcli.sh) + Gmail/Calendar OAuth 인증
- [Claude Code CLI](https://claude.ai/code) + Max20 구독
- Telegram Bot Token

## 설치

```bash
cp .env.example .env
# .env 수정

# Gmail 라벨 생성
for label in "광고" "금융-결제" "보안" "정부-R&D" "보험" "개발-테크" "도메인-호스팅" "확인필요" "소셜"; do
  gog gmail labels create "$label" --account YOUR_EMAIL --force
done

# crontab 등록 (crontab.txt 참고)
crontab -e
```

## Crontab

```cron
*/5 * * * *  email-watcher.sh      # 새 메일 감지 + 분류
0 */3 * * *  email-log-summary.sh  # 로그 요약 → 텔레그램
0 */6 * * *  email-organizer.sh    # 전체 정리
0 8   * * *  daily-briefing.sh     # 오전 브리핑
```
