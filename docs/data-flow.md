# 데이터 흐름

## 전체 흐름도

```mermaid
sequenceDiagram
    participant CRON as crontab
    participant EW as email-watcher
    participant GMAIL as Gmail API
    participant AI as Claude CLI
    participant DATA as data/
    participant USER as 사용자
    participant FP as feedback-processor

    loop 5분마다
        CRON->>EW: 실행
        EW->>GMAIL: 새 메일 조회 (newer_than:6m)
        GMAIL-->>EW: 메일 목록

        Note over EW: 일정 스레드 필터링

        EW->>AI: 일정 추출 프롬프트
        AI-->>EW: JSON (has_schedule, confidence)

        alt confidence >= 0.6
            EW->>GMAIL: 캘린더 자동 등록
        else confidence < 0.6
            EW->>DATA: queue/pending-calendars.json 추가
        end

        EW->>AI: 분류 프롬프트 (메모리 컨텍스트 포함)
        AI-->>EW: JSON (actions, confidence)

        alt confidence >= 0.6
            EW->>GMAIL: 라벨링 + 보관
        else confidence < 0.6
            EW->>DATA: queue/pending-classifications.json 추가
        end

        EW->>DATA: logs/ 기록
        EW->>DATA: state.json 업데이트
    end

    USER->>DATA: queue/ 파일 리뷰 + decision 설정

    loop 30분마다
        CRON->>FP: 실행
        FP->>DATA: queue/ 읽기

        alt decision != null
            FP->>GMAIL: 액션 실행 (라벨링/캘린더)
            FP->>DATA: memory/ 업데이트
            FP->>DATA: queue/ 처리완료 항목 제거
        end
    end
```

## 이메일 분류 흐름

```mermaid
flowchart TD
    A[새 메일 도착] --> B{규칙 기반 매칭?}
    B -->|from/subject 매칭| C[즉시 라벨링 + 보관]
    B -->|매칭 안됨| D[Claude AI 분류]

    D --> E{confidence 수준}
    E -->|>= 0.6| F[자동 라벨링]
    E -->|< 0.6| G[피드백 큐]

    G --> H[사용자 리뷰]
    H --> I{decision}
    I -->|approve| J[AI 제안대로 실행]
    I -->|modify| K[사용자 지정 라벨로 실행]
    I -->|reject| L[무시]

    J --> M[메모리 업데이트]
    K --> M
    L --> M
    M --> N[발신자 패턴 학습]
    M --> O[분류 규칙 추가]
```

## 데이터 저장 흐름

```mermaid
flowchart LR
    subgraph "입력"
        GMAIL[Gmail 메일]
        USER_FB[사용자 피드백]
    end

    subgraph "처리"
        CLASSIFY[AI 분류]
        SCHEDULE[일정 추출]
        FEEDBACK[피드백 처리]
    end

    subgraph "저장"
        EMAIL_LOG[logs/email-*.jsonl]
        ACTIONS_LOG[logs/actions-*.jsonl]
        RULES[memory/classification-rules.json]
        SENDER[memory/sender-patterns.json]
        HISTORY[memory/user-corrections.jsonl]
        QUEUE[queue/pending-*.json]
    end

    GMAIL --> CLASSIFY --> EMAIL_LOG
    CLASSIFY --> ACTIONS_LOG
    CLASSIFY -->|low confidence| QUEUE
    GMAIL --> SCHEDULE -->|low confidence| QUEUE
    USER_FB --> FEEDBACK
    FEEDBACK --> RULES
    FEEDBACK --> SENDER
    FEEDBACK --> HISTORY
    FEEDBACK --> ACTIONS_LOG
```

## 로그 파일 구조

| 파일 | 형식 | 내용 | 보존 |
| --- | --- | --- | --- |
| email-YYYYMMDD.jsonl | JSONL | 이메일 처리 결과 (제목, 발신자, 라벨, urgency) | 일별 |
| actions-YYYYMMDD.jsonl | JSONL | 실행된 액션 (라벨링, 캘린더 등록) | 일별 |
| feedback-YYYYMMDD.jsonl | JSONL | 피드백 처리 결과 | 일별 |
| summary-YYYYMMDD.txt | 텍스트 | 일일 요약 | 일별 |
| cron.log | 텍스트 | cron 실행 stdout/stderr | 누적 |
