# ZeroQuant 코딩 규칙 (에이전트용)

## 절대 규칙
- `rust_decimal::Decimal` 사용. f64로 금융 계산 절대 금지
- `unwrap()` / `expect()` 프로덕션 금지. `?` 또는 `unwrap_or` 사용
- 모든 에러 케이스 `Result`/`Option` 처리, panic 방지
- 거래소 하드코딩 금지, trait 추상화 사용
- 주석은 한글로 작성

## DB 접속
```bash
podman exec -it trader-timescaledb psql -U trader -d trader -c "SQL문"
```
> `psql`, `redis-cli` 직접 실행 절대 금지. 반드시 `podman exec` 사용.

## 패턴 참조
- 새 trait → `trader-core/src/domain/` 기존 trait 패턴 참조
- 새 API → `trader-api/src/routes/` 기존 라우트 패턴 참조
- 테스트 → `tests/{module}_test.rs` 별도 파일, public API만 테스트

## Crate 의존성 구조
```
trader-core (기반)
├── trader-exchange     (거래소 연동)
├── trader-strategy     (전략 엔진)
├── trader-execution    (주문 실행)
├── trader-risk         (리스크 관리)
├── trader-data         (데이터 수집/저장)
├── trader-analytics    (분석/백테스트) ← trader-data 의존
├── trader-notification (알림)
├── trader-api          (REST/WS API) ← 위 전체 의존
├── trader-cli          (CLI) ← trader-api 의존
└── trader-collector    (수집기) ← trader-core, trader-data 의존
```

## 핵심 타입 위치
| 타입 | 파일 |
|------|------|
| Signal | `trader-core/src/domain/signal.rs` |
| StrategyContext | `trader-core/src/domain/context.rs` |
| MarketData | `trader-core/src/domain/market_data.rs` |
| Strategy trait | `trader-strategy/src/traits.rs` |
| SignalProcessor | `trader-execution/src/signal_processor.rs` |
| ExchangeProvider | `trader-core/src/domain/exchange_provider.rs` |
| AnalyticsProvider | `trader-core/src/domain/analytics_provider.rs` |

## 코드 스타일
- 함수명: `snake_case`
- 타입명: `PascalCase`
- 상수: `UPPER_SNAKE_CASE`
- 모듈: `mod.rs` 또는 `{name}.rs`
- 에러 타입: `thiserror` 사용
- 비동기: `tokio` 런타임, `async fn`
- 직렬화: `serde` (Serialize, Deserialize)
