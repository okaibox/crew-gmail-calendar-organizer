#!/usr/bin/env python3
"""Google Gmail/Calendar API 클라이언트.

gog CLI를 대체하여 Google API를 직접 호출한다.
CLI 인터페이스와 Python import 양쪽 모두 지원.

사용법 (CLI):
    python3 lib/google_api.py auth --account EMAIL
    python3 lib/google_api.py gmail messages-search --query "in:inbox" --max 20 --account EMAIL
    python3 lib/google_api.py gmail threads-search --query "in:inbox" --max 50 --account EMAIL
    python3 lib/google_api.py gmail labels-modify THREAD_ID --add LABEL --account EMAIL
    python3 lib/google_api.py gmail labels-create LABEL --account EMAIL
    python3 lib/google_api.py gmail trash --query "subject:[광고]" --max 1000 --account EMAIL
    python3 lib/google_api.py calendar create CAL_ID --summary T --from S --to E --account EMAIL
    python3 lib/google_api.py calendar events CAL_ID --from S --to E --account EMAIL
"""

import argparse
import json
import os
import sys
from datetime import datetime

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError


SCOPES = [
    'https://www.googleapis.com/auth/gmail.modify',
    'https://www.googleapis.com/auth/calendar',
]


# === 인증 ===

class GoogleAuth:
    """OAuth2 인증 + 토큰 자동 갱신."""

    def __init__(self, credentials_file: str, token_file: str):
        self.credentials_file = credentials_file
        self.token_file = token_file
        self._creds = None

    def get_credentials(self) -> Credentials:
        if self._creds and self._creds.valid:
            return self._creds

        creds = None
        if os.path.exists(self.token_file):
            creds = Credentials.from_authorized_user_file(self.token_file, SCOPES)

        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            self._save_token(creds)
        elif not creds or not creds.valid:
            if not os.path.exists(self.credentials_file):
                print(f"credentials.json 없음: {self.credentials_file}", file=sys.stderr)
                print("Google Cloud Console에서 OAuth 클라이언트 ID를 다운로드하세요.", file=sys.stderr)
                sys.exit(1)
            flow = InstalledAppFlow.from_client_secrets_file(self.credentials_file, SCOPES)
            try:
                creds = flow.run_local_server(port=0)
            except Exception:
                creds = flow.run_console()
            self._save_token(creds)

        self._creds = creds
        return creds

    def _save_token(self, creds: Credentials):
        os.makedirs(os.path.dirname(self.token_file), exist_ok=True)
        with open(self.token_file, 'w') as f:
            f.write(creds.to_json())

    def build_gmail_service(self):
        return build('gmail', 'v1', credentials=self.get_credentials())

    def build_calendar_service(self):
        return build('calendar', 'v3', credentials=self.get_credentials())


def load_account_config(account_email: str, project_root: str):
    """accounts.json에서 credentials_file, token_file 경로를 반환."""
    config_path = os.path.join(project_root, 'config', 'accounts.json')
    with open(config_path) as f:
        data = json.load(f)

    credentials_file = os.path.join(
        project_root,
        data.get('credentials_file', '.credentials/credentials.json')
    )

    for acct in data['accounts']:
        if acct['email'] == account_email:
            token_file = os.path.join(
                project_root,
                acct.get('token_file', f'.credentials/token_{account_email}.json')
            )
            return credentials_file, token_file

    # 기본 폴백
    token_file = os.path.join(project_root, f'.credentials/token_{account_email}.json')
    return credentials_file, token_file


def get_auth(account_email: str, project_root: str) -> GoogleAuth:
    cred_file, token_file = load_account_config(account_email, project_root)
    return GoogleAuth(cred_file, token_file)


# === Gmail 클라이언트 ===

class GmailClient:
    def __init__(self, auth: GoogleAuth):
        self.service = auth.build_gmail_service()
        self._label_cache = None

    def _get_label_map(self) -> dict:
        """라벨 이름 → ID 매핑 (캐싱)."""
        if self._label_cache is not None:
            return self._label_cache

        result = self.service.users().labels().list(userId='me').execute()
        self._label_cache = {}
        for label in result.get('labels', []):
            self._label_cache[label['name']] = label['id']
        return self._label_cache

    def _resolve_label_id(self, label_name: str) -> str:
        """라벨 이름을 ID로 변환. 시스템 라벨은 이름 그대로."""
        system_labels = {
            'INBOX', 'SENT', 'TRASH', 'SPAM', 'DRAFT', 'UNREAD',
            'STARRED', 'IMPORTANT', 'CATEGORY_PERSONAL', 'CATEGORY_SOCIAL',
            'CATEGORY_PROMOTIONS', 'CATEGORY_UPDATES', 'CATEGORY_FORUMS'
        }
        if label_name in system_labels:
            return label_name
        label_map = self._get_label_map()
        return label_map.get(label_name, label_name)

    def search_messages(self, query: str, max_results: int = 20) -> dict:
        """메시지 검색. 제목 + 본문 텍스트 포함."""
        result = self.service.users().messages().list(
            userId='me', q=query, maxResults=max_results
        ).execute()

        messages = []
        for msg_ref in result.get('messages', []):
            msg = self.service.users().messages().get(
                userId='me', id=msg_ref['id'],
                format='full'
            ).execute()

            headers = {h['name']: h['value']
                       for h in msg.get('payload', {}).get('headers', [])}

            # 본문 텍스트 추출
            body_text = self._extract_body(msg.get('payload', {}))
            # 너무 길면 잘라서 토큰 절약
            if len(body_text) > 1000:
                body_text = body_text[:1000] + '...'

            messages.append({
                'id': msg['id'],
                'threadId': msg.get('threadId', ''),
                'subject': headers.get('Subject', ''),
                'from': headers.get('From', ''),
                'date': headers.get('Date', ''),
                'snippet': msg.get('snippet', ''),
                'body': body_text,
                'labelIds': msg.get('labelIds', []),
            })

        return {'messages': messages}

    @staticmethod
    def _extract_body(payload: dict) -> str:
        """payload에서 텍스트 본문 추출 (재귀)."""
        import base64

        # 단일 파트
        if payload.get('mimeType', '').startswith('text/plain'):
            data = payload.get('body', {}).get('data', '')
            if data:
                return base64.urlsafe_b64decode(data).decode('utf-8', errors='replace')

        # multipart
        for part in payload.get('parts', []):
            if part.get('mimeType', '').startswith('text/plain'):
                data = part.get('body', {}).get('data', '')
                if data:
                    return base64.urlsafe_b64decode(data).decode('utf-8', errors='replace')
            # 중첩 multipart
            if part.get('parts'):
                text = GmailClient._extract_body(part)
                if text:
                    return text

        # text/plain 없으면 snippet 폴백
        return ''

    def search_threads(self, query: str, max_results: int = 50,
                       page_token: str = None, fetch_all: bool = False) -> dict:
        """스레드 검색. batch API로 한 번에 메타데이터 조회."""
        all_threads = []
        next_page = page_token

        while True:
            kwargs = {'userId': 'me', 'q': query, 'maxResults': max_results}
            if next_page:
                kwargs['pageToken'] = next_page

            result = self.service.users().threads().list(**kwargs).execute()
            thread_refs = result.get('threads', [])

            if not thread_refs:
                break

            # batch API로 한 번에 메타데이터 조회
            thread_map = {}

            def _make_callback(tid):
                def _cb(req_id, response, exception):
                    if exception:
                        thread_map[tid] = {'id': tid, 'subject': '', 'from': '', 'date': '', 'snippet': ''}
                        return
                    subject = from_addr = date = ''
                    if response.get('messages'):
                        first_msg = response['messages'][0]
                        for h in first_msg.get('payload', {}).get('headers', []):
                            if h['name'] == 'Subject': subject = h['value']
                            elif h['name'] == 'From': from_addr = h['value']
                            elif h['name'] == 'Date': date = h['value']
                    thread_map[tid] = {
                        'id': tid, 'subject': subject, 'from': from_addr,
                        'date': date, 'snippet': response.get('snippet', '')
                    }
                return _cb

            batch = self.service.new_batch_http_request()
            for ref in thread_refs:
                tid = ref['id']
                batch.add(
                    self.service.users().threads().get(
                        userId='me', id=tid,
                        format='metadata',
                        metadataHeaders=['Subject', 'From', 'Date']
                    ),
                    callback=_make_callback(tid)
                )
            batch.execute()

            # 원래 순서 유지
            for ref in thread_refs:
                if ref['id'] in thread_map:
                    all_threads.append(thread_map[ref['id']])

            next_page = result.get('nextPageToken')
            if not fetch_all or not next_page:
                break

        output = {'threads': all_threads}
        if not fetch_all and result.get('nextPageToken'):
            output['nextPageToken'] = result['nextPageToken']
        return output

    def modify_labels(self, thread_ids: list, add_labels: list = None,
                      remove_labels: list = None) -> int:
        """스레드 라벨 추가/제거. gog gmail labels modify 대체."""
        add_ids = [self._resolve_label_id(l) for l in (add_labels or [])]
        remove_ids = [self._resolve_label_id(l) for l in (remove_labels or [])]

        body = {}
        if add_ids:
            body['addLabelIds'] = add_ids
        if remove_ids:
            body['removeLabelIds'] = remove_ids

        success = 0
        for tid in thread_ids:
            try:
                self.service.users().threads().modify(
                    userId='me', id=tid, body=body
                ).execute()
                success += 1
            except HttpError:
                pass
        return success

    def create_label(self, label_name: str, hidden: bool = False,
                     bg_color: str = None, text_color: str = None) -> dict:
        """라벨 생성. hidden=True면 Gmail UI에서 숨김."""
        body = {
            'name': label_name,
            'labelListVisibility': 'labelHide' if hidden else 'labelShow',
            'messageListVisibility': 'hide' if hidden else 'show',
        }
        if bg_color and text_color:
            body['color'] = {
                'backgroundColor': bg_color,
                'textColor': text_color,
            }
        try:
            result = self.service.users().labels().create(
                userId='me', body=body
            ).execute()
            self._label_cache = None
            return result
        except HttpError as e:
            if e.resp.status == 409:
                return {}  # 이미 존재
            raise

    def update_label(self, label_name: str, bg_color: str = None,
                     text_color: str = None, hidden: bool = None) -> dict:
        """기존 라벨 색상/가시성 업데이트."""
        label_map = self._get_label_map()
        label_id = label_map.get(label_name)
        if not label_id:
            return {}
        body = {}
        if bg_color and text_color:
            body['color'] = {
                'backgroundColor': bg_color,
                'textColor': text_color,
            }
        if hidden is not None:
            body['labelListVisibility'] = 'labelHide' if hidden else 'labelShow'
            body['messageListVisibility'] = 'hide' if hidden else 'show'
        if not body:
            return {}
        try:
            return self.service.users().labels().update(
                userId='me', id=label_id, body=body
            ).execute()
        except HttpError:
            return {}

    def trash_messages(self, query: str, max_results: int = 1000) -> int:
        """메시지 삭제(trash). gog gmail trash 대체."""
        result = self.service.users().messages().list(
            userId='me', q=query, maxResults=max_results
        ).execute()

        count = 0
        for msg_ref in result.get('messages', []):
            try:
                self.service.users().messages().trash(
                    userId='me', id=msg_ref['id']
                ).execute()
                count += 1
            except HttpError:
                pass
        return count


# === Calendar 클라이언트 ===

class CalendarClient:
    def __init__(self, auth: GoogleAuth):
        self.service = auth.build_calendar_service()

    def create_event(self, calendar_id: str, summary: str, start: str, end: str,
                     location: str = None, description: str = None) -> dict:
        """이벤트 생성. gog calendar create 대체."""
        event = {
            'summary': summary,
            'start': {'dateTime': start},
            'end': {'dateTime': end},
        }
        if location:
            event['location'] = location
        if description:
            event['description'] = description

        return self.service.events().insert(
            calendarId=calendar_id, body=event
        ).execute()

    def list_events(self, calendar_id: str, time_min: str, time_max: str) -> dict:
        """이벤트 조회. gog calendar events 대체."""
        result = self.service.events().list(
            calendarId=calendar_id,
            timeMin=time_min,
            timeMax=time_max,
            singleEvents=True,
            orderBy='startTime',
        ).execute()

        events = []
        for item in result.get('items', []):
            start = item.get('start', {})
            end = item.get('end', {})
            events.append({
                'id': item.get('id', ''),
                'summary': item.get('summary', ''),
                'start': start.get('dateTime', start.get('date', '')),
                'end': end.get('dateTime', end.get('date', '')),
                'location': item.get('location', ''),
            })

        return {'events': events}


# === CLI ===

def main():
    parser = argparse.ArgumentParser(description='Google API CLI')
    parser.add_argument(
        '--project-root',
        default=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    subparsers = parser.add_subparsers(dest='service')

    # auth
    auth_parser = subparsers.add_parser('auth')
    auth_parser.add_argument('--account', required=True)

    # gmail
    gmail_parser = subparsers.add_parser('gmail')
    gmail_sub = gmail_parser.add_subparsers(dest='action')

    ms = gmail_sub.add_parser('messages-search')
    ms.add_argument('--query', required=True)
    ms.add_argument('--max', type=int, default=20)
    ms.add_argument('--account', required=True)

    ts = gmail_sub.add_parser('threads-search')
    ts.add_argument('--query', required=True)
    ts.add_argument('--max', type=int, default=50)
    ts.add_argument('--account', required=True)
    ts.add_argument('--page', default=None)
    ts.add_argument('--all', action='store_true', dest='fetch_all')

    lm = gmail_sub.add_parser('labels-modify')
    lm.add_argument('thread_ids', nargs='+')
    lm.add_argument('--account', required=True)
    lm.add_argument('--add', default=None)
    lm.add_argument('--remove', default=None)

    lc = gmail_sub.add_parser('labels-create')
    lc.add_argument('name')
    lc.add_argument('--account', required=True)
    lc.add_argument('--hidden', action='store_true')
    lc.add_argument('--bg-color', default=None)
    lc.add_argument('--text-color', default=None)

    lu = gmail_sub.add_parser('labels-update')
    lu.add_argument('name')
    lu.add_argument('--account', required=True)
    lu.add_argument('--hidden', action='store_true', default=None)
    lu.add_argument('--bg-color', default=None)
    lu.add_argument('--text-color', default=None)

    tr = gmail_sub.add_parser('trash')
    tr.add_argument('--query', required=True)
    tr.add_argument('--max', type=int, default=1000)
    tr.add_argument('--account', required=True)

    # calendar
    cal_parser = subparsers.add_parser('calendar')
    cal_sub = cal_parser.add_subparsers(dest='action')

    cc = cal_sub.add_parser('create')
    cc.add_argument('calendar_id')
    cc.add_argument('--summary', required=True)
    cc.add_argument('--from', dest='start', required=True)
    cc.add_argument('--to', dest='end', required=True)
    cc.add_argument('--account', required=True)
    cc.add_argument('--location', default=None)
    cc.add_argument('--description', default=None)

    ce = cal_sub.add_parser('events')
    ce.add_argument('calendar_id')
    ce.add_argument('--from', dest='start', required=True)
    ce.add_argument('--to', dest='end', required=True)
    ce.add_argument('--account', required=True)

    args = parser.parse_args()

    if not args.service:
        parser.print_help()
        sys.exit(1)

    project_root = args.project_root

    # auth 명령
    if args.service == 'auth':
        auth = get_auth(args.account, project_root)
        auth.get_credentials()
        print(f"인증 완료: {args.account}")
        return

    # gmail 명령
    if args.service == 'gmail':
        auth = get_auth(args.account, project_root)
        client = GmailClient(auth)

        if args.action == 'messages-search':
            result = client.search_messages(args.query, args.max)
            print(json.dumps(result, ensure_ascii=False))

        elif args.action == 'threads-search':
            result = client.search_threads(
                args.query, args.max, args.page, args.fetch_all
            )
            print(json.dumps(result, ensure_ascii=False))

        elif args.action == 'labels-modify':
            add_labels = [args.add] if args.add else None
            remove_labels = [args.remove] if args.remove else None
            count = client.modify_labels(args.thread_ids, add_labels, remove_labels)
            print(json.dumps({'modified': count}, ensure_ascii=False))

        elif args.action == 'labels-create':
            client.create_label(args.name, hidden=args.hidden,
                                bg_color=args.bg_color, text_color=args.text_color)
            print(json.dumps({'created': args.name}, ensure_ascii=False))

        elif args.action == 'labels-update':
            client.update_label(args.name, bg_color=args.bg_color,
                                text_color=args.text_color, hidden=args.hidden)
            print(json.dumps({'updated': args.name}, ensure_ascii=False))

        elif args.action == 'trash':
            count = client.trash_messages(args.query, args.max)
            print(str(count))

        else:
            gmail_parser.print_help()
            sys.exit(1)

    # calendar 명령
    elif args.service == 'calendar':
        auth = get_auth(args.account, project_root)
        client = CalendarClient(auth)

        if args.action == 'create':
            client.create_event(
                args.calendar_id, args.summary, args.start, args.end,
                args.location, args.description
            )
            print(json.dumps({'created': args.summary}, ensure_ascii=False))

        elif args.action == 'events':
            result = client.list_events(args.calendar_id, args.start, args.end)
            print(json.dumps(result, ensure_ascii=False))

        else:
            cal_parser.print_help()
            sys.exit(1)


if __name__ == '__main__':
    main()
