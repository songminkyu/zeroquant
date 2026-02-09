# ZeroQuant TODO v2 — 확장 로드맵

> **마지막 업데이트**: 2026-02-09
> **선행 조건**: v0.9.0 (Mock 거래소 업그레이드) 완료 후 착수
> **참조**: `docs/todo.md` (현행 TODO), `archives/additional.md` (원본 제안)
> **규칙**: 완료 후 작업은 **완료 작업** 섹션으로 이동하고, 상단에선 제거.
---

## 의존 관계 맵
[A] 보안 ──────────────────────────────── 독립, 즉시 착수 가능
[B] 데이터 파이프라인 ──────────────────── 독립, 즉시 착수 가능
├──→ [C] 포트폴리오 & 리스크 ──────── B1(보정 데이터) + B6(환율) 선행 필수
└──→ [D] 전략 라이프사이클 ─────────── B8(Clock Trait) 시너지
[E] 실행 & 컴플라이언스 ──────────────── C와 독립, AUM 기반 판단
[F] 관측성 & 아키텍처 ─────────────────── A~D 안정화 후
[G] 프론트엔드 & UX ───────────────────── 전 구간 병행 가능

병렬 가능 조합:

A + B + G (동시 착수)
C + D (B 완료 후 동시 착수)
E + F (C/D 진행 중 또는 이후)

## [A] 보안 & 인증 기반

> 🔴 라이브 트레이딩 전 필수. 모든 그룹과 독립, 즉시 착수.
> 병렬: B, G와 동시 진행 가능

### A-1: API 인증 체계 구축
- [ ] 전체 API 라우트에 JWT `AuthUser` extractor 적용 (`trader-api/src/routes/`)
- [ ] WebSocket 핸드셰이크 시 토큰 검증 미들웨어 추가 (`trader-api/src/websocket/`)
- [ ] Axum `RequestBodyLimit` 미들웨어 적용 (DoS 방지)
- [ ] `config/default.toml` 기본 시크릿 제거 → 환경변수 필수화

---

## [B] 데이터 파이프라인 & 무결성

> 🔴 모든 분석·백테스트·전략의 신뢰성 기반. C~G의 선행 조건.
> 병렬: A, G와 동시 진행 가능. B1~B3 DB 마이그레이션은 개별 `.sql` 작성 후 `trader migrate consolidate`로 병합.

### B-1: 기업 이벤트 처리 (Corporate Action Handler)
- [ ] `corporate_actions` 테이블 신설 (`event_type`, `symbol`, `ex_date`, `split_factor`, `dividend_amount`)
- [ ] `ohlcv` 테이블에 `adj_close`, `split_factor`, `dividend` 컬럼 추가
- [ ] Backward Adjust 로직 구현 (`trader-data/src/`)
- [ ] Yahoo Finance/KRX에서 Split/Dividend 이벤트 수집기 추가 (`trader-collector/`)
- [ ] `CandleProcessor`가 보정 데이터를 사용하도록 수정 (`trader-analytics/src/`)
- [ ] API 엔드포인트: `POST /api/v1/data/adjust-corporate-actions`, `GET /api/v1/data/events/{symbol}`

### B-2: 시점 데이터 관리 (Point-in-Time)
- [ ] `symbol_fundamental` 테이블에 `announce_date DATE`, `report_period VARCHAR(10)` 추가
- [ ] 펀더멘털 수집기에 공시일 파싱 로직 추가 (`trader-collector/`)
- [ ] 백테스트 쿼리에 `WHERE announce_date <= backtest_time` 조건 강제 (`trader-analytics/`)
- [ ] 기존 펀더멘털 데이터에 대한 `announce_date` 백필(backfill) 스크립트

### B-3: 생존 편향 방지 (Survivorship Bias)
- [ ] `symbol_info` 테이블에 `is_active BOOLEAN DEFAULT TRUE`, `delisted_date DATE` 추가
- [ ] KRX/Yahoo에서 상폐 종목 정보 수집 로직 추가 (`trader-collector/`)
- [ ] 백테스트 유니버스 구성 시 `delisted_date > backtest_time` 종목 포함
- [ ] 시뮬레이션 중 `delisted_date` 도달 시 잔여 포지션 강제 청산 로직 (`trader-analytics/`)

### B-4: 데이터 갭 감지 & 복구
- [ ] OHLCV 갭 감지 모듈 신규 (`trader-data/src/gap_detector.rs`)
- [ ] 거래일 캘린더 대비 누락 일자 스캔 쿼리
- [ ] 감지된 갭에 대한 자동 재수집 트리거 (`trader-collector/`)
- [ ] 갭 상태 리포트 API: `GET /api/v1/data/gaps`

### B-5: Collector 복원력 강화
- [ ] Dead-letter 큐 (실패 심볼 재시도) 구현 (`trader-collector/`)
- [ ] 재시도 정책: 지수 백오프, 최대 3회, 실패 시 알림 발송
- [ ] Collector 헬스 메트릭 Prometheus 노출 (수집 성공/실패 카운트, API 할당량 잔여)

### B-6: FX 환율 서비스
- [ ] `FxRateProvider` trait 정의 (`trader-core/src/domain/`)
- [ ] Yahoo Finance/한국은행 API 기반 환율 수집기 구현 (`trader-data/`)
- [ ] Redis 캐시 (TTL 1시간) + DB 히스토리 저장
- [ ] 포트폴리오 P&L 산출 시 통화 통합 변환 적용

### B-7: 거래소 중립 마켓 캘린더
- [ ] `MarketCalendar` trait 정의 (`trader-core/src/domain/`)
- [ ] KRX, NYSE/NASDAQ, Binance 별 구현 (공휴일, 반일 거래, 점검 시간)
- [ ] 전략·수집기에서 `is_market_open()` 호출을 trait 기반으로 교체

### B-8: Clock Trait 도입
- [ ] `Clock` trait 정의 (`trader-core/src/domain/clock.rs`): `fn now(&self) -> DateTime<Utc>`
- [ ] `SystemClock` 구현 (실시간), `ManualClock` 구현 (백테스트/테스트용)
- [ ] 코드 전반의 `Utc::now()` 직접 호출을 `Clock` trait 호출로 교체
- [ ] 백테스트 엔진에 `ManualClock` 주입, 시간 진행을 엔진이 제어

---

## [C] 포트폴리오 분석 & 리스크 고도화

> 🟡 선행: B1(보정 데이터), B6(환율 서비스) 완료 필수.
> 병렬: D와 동시 진행 가능. 전체 Rust 구현 (`argmin` 크레이트).

### C-1: 포트폴리오 최적화 (Global Optimizer)
- [ ] `trader-analytics/src/optimizer/` 모듈 신규
- [ ] Mean-Variance Optimization — 샤프 비율 최대화 (`argmin`)
- [ ] Risk Parity — 리스크 균등 기여 비중
- [ ] Minimum Variance — 포트폴리오 변동성 최소화
- [ ] 입력: 자산별 기대 수익률 벡터 + 공분산 행렬 (FX 변환 적용)
- [ ] API: `POST /api/v1/portfolio/optimize`, `GET /api/v1/portfolio/efficient-frontier`
- [ ] `AssetAllocation` 전략과 최적 비중 벡터 연동

### C-2: 실시간 VaR (Value at Risk)
- [ ] Parametric VaR — 공분산 행렬 기반 정규분포 가정 (95%, 99%)
- [ ] Historical VaR — TimescaleDB 과거 수익률 시뮬레이션 기반
- [ ] `RiskManager` 파이프라인에 VaR 한도 검증 단계 추가 (`trader-risk/`)
- [ ] VaR 초과 시 신규 진입 강제 차단

### C-3: 섹터/팩터 노출 제한
- [ ] `RiskConfig`에 `max_sector_weight`, `factor_tilt_limit` 필드 추가 (`trader-risk/`)
- [ ] 포트폴리오 레벨 섹터 비중 검증 로직 (`RiskManager::validate_order()` 확장)
- [ ] 특정 팩터(모멘텀, 가치 등) 쏠림 제한

### C-4: 성과 기여도 분석 (Attribution)
- [ ] Brinson Model — 자산배분 효과 vs 종목선정 효과 분해
- [ ] Beta 분석 — 벤치마크(KOSPI/SPY) 대비 민감도 + 상관계수
- [ ] 섹터 기여도 — 섹터 비중 확대/축소로 인한 손익 분해
- [ ] API: `GET /api/v1/portfolio/attribution`

### C-5: 거래 비용 분석 (TCA)
- [ ] `reality_check` 테이블에 `theory_price`, `exec_price`, `slippage_bps` 컬럼 추가
- [ ] Implementation Shortfall 계산: (신호 시점 중간가) - (실제 평균 체결가)
- [ ] Slippage 분류: 호가 공백 손실 vs 통신 지연 손실
- [ ] Market Impact 측정: 주문 직후 호가 변동 분석

---

## [D] 전략 라이프사이클 & 테스트 인프라

> 🟡 선행: B8(Clock Trait) 시너지. CI(D-6)는 B와 동시 착수 권장.
> 병렬: C와 동시 진행 가능.

### D-1: 전략 파라미터 버전 관리
- [ ] `strategy_run_snapshots` 테이블 신설 (strategy_id, version, params_json, started_at)
- [ ] 라이브/페이퍼 실행 시작 시 현재 파라미터 자동 스냅샷 저장
- [ ] API: `GET /api/v1/strategies/{id}/history` — 과거 실행 파라미터 조회

### D-2: 전략 파라미터 최적화
- [ ] `ParameterGrid` 러너 — 파라미터 조합 생성 + 순차 백테스트 실행
- [ ] Bayesian 최적화 (선택적 — `argmin` 활용)
- [ ] 최적화 결과 비교 테이블 + 상위 N개 설정 추천
- [ ] API: `POST /api/v1/backtest/optimize`

### D-3: 전략 비교 리포트
- [ ] 동일 기간 N개 전략 병렬 백테스트 API
- [ ] 성과 지표 병렬 비교 (CAGR, MDD, Sharpe, 승률 등)
- [ ] 프론트엔드 비교 차트 컴포넌트

### D-4: 백테스트 회귀 테스트
- [ ] 기준 결과(baseline) 저장 메커니즘
- [ ] `cargo test` 시 현재 백테스트 결과 vs baseline 자동 비교
- [ ] 시그널 변경 감지 시 diff 리포트 출력

### D-5: 통합 테스트 추가
- [ ] API → Strategy → Execution → DB 핵심 경로 통합 테스트 (`tests/`)
- [ ] 백테스트 엔진 end-to-end 테스트 (알려진 데이터 → 기대 시그널 검증)
- [ ] Paper Trading 세션 생성 → 시그널 처리 → 포지션 확인 흐름

### D-6: 최소 CI 파이프라인
- [ ] `.github/workflows/ci.yml` 생성
- [ ] `cargo fmt --check` + `cargo clippy -- -D warnings` + `cargo test`
- [ ] 프론트엔드: `npm run lint` + `npm run build`
- [ ] PR 머지 게이트로 설정

---

## [E] 실행 계층 & 컴플라이언스

> 🟠 E1~E3: AUM 증가 시 단계적 도입. E4~E6: 라이브 운영 시작과 함께 도입.
> 병렬: C, D와 독립 진행 가능.

### E-1: 스마트 주문 집행 (Algo Execution)
- [ ] `ExecutionAlgo` trait 정의 (`trader-execution/src/algo/`)
- [ ] TWAP — 시간 분할 매매 (`duration`, `slice_count`)
- [ ] Iceberg — 빙산 주문 (`visible_qty`, `variance`)
- [ ] POV — 거래량 연동 (`participation_rate`)
- [ ] Parent Order → Child Order 분할 + 순차 전송 로직

### E-2: 내부 상계 시스템 (Internal Netting)
- [ ] 중앙 `OrderManager` 신규 — 전략별 신호 주기적 수집 (예: 1분)
- [ ] 동일 심볼 매수/매도 상계 처리 후 순 주문만 거래소 전송
- [ ] 상계 로그 기록 (절감 수수료·슬리피지 추적)

### E-3: Smart Order Router
- [ ] 전략 → `Intent` (무엇을, 몇 주, 긴급도) 발행
- [ ] SOR → `Intent` → 실제 `Order[]` 변환 (알고리즘 선택·분할)
- [ ] `LiveExecutor`에서 의사결정/집행 로직 분리

### E-4: 불변 감사 로그 (Audit Trail)
- [ ] `audit_log` append-only 테이블 (INSERT만 허용, UPDATE/DELETE 차단)
- [ ] 모든 주문 생성·체결·취소 이벤트 자동 기록
- [ ] 감사 로그 조회 API: `GET /api/v1/audit/trades`

### E-5: 세금 Lot 추적
- [ ] FIFO/LIFO/특정 Lot 지정 방식의 취득원가 계산 모듈 (`trader-analytics/`)
- [ ] 기존 `GET /api/v1/journal/cost-basis/{symbol}` 확장
- [ ] 연간 양도소득세 리포트 생성 API

### E-6: 전략 상태 영속화 (Graceful Shutdown)
- [ ] `StrategyState` 직렬화 → DB/파일 저장 (`on_shutdown` 훅)
- [ ] DCA 그리드 레벨, 트레일링 스톱 고점, 인메모리 상태 대상
- [ ] 재시작 시 마지막 저장 상태에서 복원

---

## [F] 관측성 & 아키텍처 확장

> 🔵 선행: A~D 안정화 후. 전략 50개+ 또는 고빈도 처리 시 도입.
> 병렬: F1~F4 관측성은 조기 착수 가능, F5~F6 아키텍처는 후반.

### F-1: 분산 트레이싱 (OpenTelemetry)
- [ ] `opentelemetry` + `tracing-opentelemetry` 의존성 추가
- [ ] API → Strategy → Exchange → DB 요청 상관관계 추적
- [ ] Jaeger/Zipkin 연동 설정

### F-2: Collector 헬스 메트릭
- [ ] 수집 성공/실패 카운트, API 할당량 잔여 Prometheus 게이지
- [ ] 수집 주기 이상 감지 알림 (AlertManager 룰)

### F-3: DB 연결풀 & 슬로우 쿼리 모니터링
- [ ] 연결풀 사용률 Prometheus 메트릭 노출
- [ ] `pg_stat_statements` 기반 슬로우 쿼리 자동 감지 + 알림
- [ ] Redis `maxmemory` 환경변수화 (`docker-compose.yml`)

### F-4: 에러 트래커 영속화
- [ ] 인메모리 `DashMap` → DB 영속 저장 병행
- [ ] 에러 이력 조회 API + 재시작 후에도 이력 유지

### F-5: Actor Model 전환
- [ ] 전략별 독립 Tokio Task + mpsc 채널 메시지 기반 통신
- [ ] `StrategyContext`의 `Arc<RwLock<>>` 제거 → 전략 로컬 상태
- [ ] 락 경합 벤치마크 (전환 전/후 비교)

### F-6: Event Bus (Pub/Sub)
- [ ] 시스템 이벤트 정의: `MarketEvent`, `SignalEvent`, `OrderEvent`, `SystemAlert`
- [ ] 전략 → `SignalEvent` 발행, `OrderExecutor` 구독 처리
- [ ] Audit Logger, Dashboard 등 신규 컨슈머를 구독만으로 추가

---

## [G] 프론트엔드 & UX

> 🟢 전 구간 병행 가능. 백엔드 작업과 독립.

### G-1: 차트 시각화 강화
- [ ] RouteState 구간 시각화 — ATTACK/WAIT/OVERHEAT 배경색 밴드 렌더링
- [ ] 비매매 지표 마커 — RSI 과매수/과매도(•), Golden/Dead Cross(x), TTM Squeeze(Bar)
- [ ] 캔들 패턴 라벨 — 48개 패턴 약어(H, E, D) 캔들 위 오버레이
- [ ] 줌 레벨 기반 마커 필터링 — Zoom Out 시 매매만, Zoom In 시 보조 마커 표시

### G-2: 툴팁 & 인터랙션 강화
- [ ] 매매 마커 호버 시 RSI/MACD/RouteState/Score 컨텍스트 툴팁
- [ ] `SignalDetailPopup` 확장 — 진입 근거 + 당시 지표 값 표시

### G-3: 시스템 UX 개선
- [ ] UTC → KST 타임존 변환 유틸리티 + 사용자 설정 연동
- [ ] 다크/라이트 테마 토글 (TailwindCSS `dark:` 활성화 + `localStorage`)
- [ ] 페이지 레벨 `<ErrorBoundary>` + 로딩 스켈레톤 시스템
- [ ] 모바일 반응형 레이아웃 검증 + 뷰포트 대응

---

## 우선순위 요약

| 순서 | 그룹 | 병렬 가능 | 예상 규모 |
|:----:|:----:|:---------:|:---------:|
| 1 | **A** 보안 | B, G와 동시 | Small |
| 1 | **B** 데이터 | A, G와 동시 | Large |
| 1 | **G** 프론트엔드 | A, B와 동시 | Medium |
| 2 | **C** 포트폴리오 | D와 동시 | Large |
| 2 | **D** 전략 라이프사이클 | C와 동시 (D-6 CI는 1단계로 조기 착수) | Large |
| 3 | **E** 실행 & 컴플라이언스 | E4~E6 라이브 시 즉시, E1~E3 AUM 기반 | Medium-Large |
| 4 | **F** 관측성 & 아키텍처 | F1~F4 조기 가능, F5~F6 후반 | Large |

## 완료 작업