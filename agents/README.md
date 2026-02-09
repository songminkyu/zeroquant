# ZeroQuant Multi-Agent System

> Claude CLI(`claude -p`) 기반 멀티에이전트 자동 구현 시스템

## 개요

`docs/todo_v2.md`의 34개 작업 항목을 5종 에이전트 파이프라인으로 자동 구현합니다.

```
Explorer → Architect → [Migrator] → Implementer → Validator
 (탐색)     (설계)      (DB변경)      (구현)        (검증)
```

## 빠른 시작

```powershell
# 단일 작업 실행
.\agents\run.ps1 -Command run -Task B-8

# 설계만 (DryRun — 코드 변경 없음)
.\agents\run.ps1 -Command plan -Task B-8

# 그룹 실행 (B 그룹 전체)
.\agents\run.ps1 -Command run -Group B

# Phase 실행 (A+B+G 병렬)
.\agents\run.ps1 -Command run -Phase 1

# workspace 빌드 검증
.\agents\run.ps1 -Command validate

# 전체 진행 상태
.\agents\run.ps1 -Command status
```

## 디렉토리 구조

```
agents/
├── run.ps1                      # 메인 CLI 진입점
├── README.md                    # 이 파일
├── config/
│   ├── rules.md                 # CLAUDE.md 코딩 규칙 (에이전트용 축약)
│   └── prompts/
│       ├── explorer.md          # Explorer 시스템 프롬프트
│       ├── architect.md         # Architect 시스템 프롬프트
│       ├── implementer.md       # Implementer 시스템 프롬프트
│       ├── validator.md         # Validator 시스템 프롬프트
│       └── migrator.md          # Migrator 시스템 프롬프트
├── scripts/
│   ├── invoke-agent.ps1         # Claude CLI 래퍼 (공통)
│   ├── run-task.ps1             # 단일 작업 파이프라인
│   ├── run-group.ps1            # 그룹 실행
│   └── run-phase.ps1            # Phase 실행
├── tasks/                       # 작업 정의 (34개 JSON)
│   ├── A-1.json
│   ├── B-1.json ... B-8.json
│   ├── C-1.json ... C-5.json
│   ├── D-1.json ... D-5.json
│   ├── E-1.json ... E-6.json
│   ├── F-1.json ... F-6.json
│   └── G-1.json ... G-3.json
└── output/                      # 에이전트 출력 (gitignored)
    └── .gitkeep
```

## 에이전트 5종

| 에이전트 | 역할 | 모델 | 도구 | Max Turns |
|----------|------|------|------|-----------|
| **Explorer** | 코드베이스 탐색 | sonnet | Read, Glob, Grep, Serena MCP | 20 |
| **Architect** | 구현 설계 | opus | Read, Glob, Grep | 15 |
| **Implementer** | 코드 생성/편집 | opus | Read, Write, Edit, Bash(cargo) | 50 |
| **Validator** | 빌드/테스트 검증 | sonnet | Bash(cargo), Read, Glob, Grep | 10 |
| **Migrator** | DB 마이그레이션 | sonnet | Write, Read, Bash(podman exec) | 15 |

## 파이프라인 흐름

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Explorer    │───▶│  Architect   │───▶│  Migrator    │ (DB 변경 시)
│  (탐색)      │    │  (설계)      │    │  (마이그레이션)│
└─────────────┘    └─────────────┘    └──────┬──────┘
                                             │
                   ┌─────────────┐    ┌──────▼──────┐
                   │  Validator   │◀──│ Implementer  │
                   │  (검증)      │    │  (구현)      │
                   └──────┬──────┘    └─────────────┘
                          │
                    실패 시 재시도 (최대 2회)
                          │
                   ┌──────▼──────┐
                   │   완료/실패   │
                   └─────────────┘
```

## 작업 그룹 & Phase

| Phase | 그룹 | 설명 | 실행 방식 |
|-------|------|------|-----------|
| 1 | A + B + G | 보안 + 데이터 + 프론트엔드 | 병렬 |
| 2 | C + D | 포트폴리오 + 전략 라이프사이클 | 병렬 |
| 3 | E + F | 실행 + 관측성 | 병렬 |

## 중단 복구

각 작업의 `output/{task_id}/progress.json`에 진행 상태가 기록됩니다.

```json
{
  "completed_steps": ["01-explore", "02-design"],
  "status": "in_progress",
  "started_at": "2026-02-10T...",
  "last_updated": "2026-02-10T..."
}
```

- 재실행 시 완료된 단계는 자동 건너뜀
- `-Force` 플래그로 전체 재실행 가능

## 주요 플래그

| 플래그 | 설명 |
|--------|------|
| `-DryRun` | 설계까지만 (코드 변경 없음) |
| `-Force` | 완료된 단계도 재실행 |
| `-StopOnFailure` | 그룹 내 실패 시 중단 |

## 출력 파일

각 작업은 `output/{task_id}/` 디렉토리에 단계별 결과를 저장합니다:

```
output/B-8/
├── 01-explore.json          # Explorer 탐색 결과
├── 02-design.md             # Architect 설계서
├── 02.5-migrate.json        # Migrator 결과 (DB 변경 시)
├── 03-implement.json        # Implementer 구현 결과
├── 04-validate.json         # Validator 검증 결과
├── 03-fix-1.json            # 재시도 1 구현 (실패 시)
├── 04-validate-retry1.json  # 재시도 1 검증 (실패 시)
└── progress.json            # 진행 상태
```

## 필수 요건

- **Claude CLI** (`claude`) 설치 및 인증 완료
- **PowerShell 5.1+** (Windows 기본 제공)
- **Rust toolchain** (`cargo`, `rustfmt`, `clippy`)
- **Podman** (DB/Redis 컨테이너 접속 시)
