# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/ko/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- macOS mktemp 버그: `.txt` 접미사로 인해 LLM 호출이 즉시 실패하던 문제 수정 (common.sh)
- Phase 1 LLM 실패 시 전체 스레드가 분류 없이 `_processed` 처리되던 버그 수정 (watcher)

### Changed

- Claude CLI 직접 호출을 Ollama REST API 기반 `llm_call()`로 교체 (llm, classifier, watcher, consolidator)
