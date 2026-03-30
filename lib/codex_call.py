#!/usr/bin/env python3
# Codex CLI 호출 래퍼
# 사용법: python3 codex_call.py <prompt_file>
# 환경변수:
#   CODEX_MODEL    - Codex가 사용할 모델 (선택, 미설정 시 codex 기본값)
#   CODEX_API_KEY 또는 OPENAI_API_KEY - API 키 (codex가 직접 참조)

import os
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        print("사용법: codex_call.py <prompt_file>", file=sys.stderr)
        sys.exit(1)

    if shutil.which("codex") is None:
        print("오류: codex CLI가 설치되지 않았습니다. npm install -g @openai/codex", file=sys.stderr)
        sys.exit(1)

    if not os.environ.get("CODEX_API_KEY") and not os.environ.get("OPENAI_API_KEY"):
        print("오류: CODEX_API_KEY 또는 OPENAI_API_KEY 환경변수가 필요합니다.", file=sys.stderr)
        sys.exit(1)

    prompt_file = sys.argv[1]
    try:
        with open(prompt_file, encoding="utf-8") as f:
            prompt = f.read()
    except OSError as e:
        print(f"프롬프트 파일 읽기 오류: {e}", file=sys.stderr)
        sys.exit(1)

    cmd = ["codex", "exec"]
    model = os.environ.get("CODEX_MODEL")
    if model:
        cmd.extend(["--model", model])
    cmd.append("-")  # stdin에서 프롬프트 읽기

    try:
        result = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=600
        )
        if result.returncode != 0:
            print(f"Codex CLI 오류: {result.stderr.strip()}", file=sys.stderr)
            sys.exit(1)
        print(result.stdout, end="")
    except subprocess.TimeoutExpired:
        print("Codex CLI 타임아웃 (600초)", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("오류: codex 명령을 실행할 수 없습니다.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
