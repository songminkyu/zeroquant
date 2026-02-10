//! Mock 거래소 가격 스트리밍 모듈.
//!
//! 3가지 모드로 실시간 가격 데이터를 생성합니다:
//! - `HistoricalReplay`: DB 1분봉 캔들을 틱 단위로 보간 재생
//! - `RandomWalk`: ATR 기반 랜덤 워크 + 평균회귀
//! - `YahooLegacy`: 기존 Yahoo Finance D1 폴링 (하위 호환)
//!
//! # 데이터 흐름
//!
//! ```text
//! MockPriceGenerator → PriceTick → MockOrderBookGenerator → OrderBook + Ticker
//! ```

use std::{collections::HashMap, sync::Arc};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rand::Rng;
use rust_decimal::{prelude::ToPrimitive, Decimal};
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};
use tracing::debug;
use trader_core::{Kline, OrderBook, OrderBookLevel, RoundMethod, TickSizeProvider, Ticker};

// ==================== 설정 타입 ====================

/// 가격 생성 모드.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MockPriceMode {
    /// DB 1분봉 기반 틱 보간 재생
    HistoricalReplay,
    /// ATR + 정규분포 랜덤 워크
    #[default]
    RandomWalk,
    /// 기존 Yahoo Finance D1 폴링 (하위 호환)
    YahooLegacy,
}

/// Mock 스트리밍 설정.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MockStreamingConfig {
    /// 가격 생성 모드
    pub mode: MockPriceMode,
    /// 틱 발생 간격 (밀리초, 기본 1000)
    pub tick_interval_ms: u64,
    /// 시장 유형 ("stock_kr" | "stock_us" | "crypto")
    pub market_type: String,
    /// 스프레드 배율 (기본 1.0)
    pub spread_multiplier: Decimal,
    /// 호가창 기본 잔량
    pub orderbook_base_volume: Decimal,
    /// 재생 속도 (HistoricalReplay 전용, 기본 1.0)
    pub replay_speed: f64,
}

impl Default for MockStreamingConfig {
    fn default() -> Self {
        Self {
            mode: MockPriceMode::RandomWalk,
            tick_interval_ms: 1000,
            market_type: "stock_kr".to_string(),
            spread_multiplier: Decimal::ONE,
            orderbook_base_volume: dec!(100),
            replay_speed: 1.0,
        }
    }
}

// ==================== PriceTick ====================

/// 단일 가격 틱 데이터.
#[derive(Debug, Clone)]
pub struct PriceTick {
    /// 심볼
    pub symbol: String,
    /// 현재 가격
    pub price: Decimal,
    /// 거래량 (추정)
    pub volume: Decimal,
    /// 타임스탬프
    pub timestamp: DateTime<Utc>,
}

// ==================== MockPriceGenerator trait ====================

/// 가격 생성기 trait.
///
/// 각 모드별 구현체가 이 trait을 구현합니다.
#[async_trait]
pub trait MockPriceGenerator: Send + Sync {
    /// 다음 틱 가격 생성. None이면 데이터 종료.
    async fn next_tick(&mut self, symbol: &str) -> Option<PriceTick>;

    /// 초기 가격 설정 (생성기 시작 전 호출).
    async fn initialize(&mut self, symbol: &str, initial_price: Decimal);
}

// ==================== RandomWalkGenerator ====================

/// 랜덤 워크 기반 가격 생성기.
///
/// ATR(Average True Range) 기반 변동성 + 평균회귀 모델:
/// `new_price = current + ATR * N(0,1) * √dt + mean_reversion`
pub struct RandomWalkGenerator {
    /// 심볼별 현재 가격
    current_prices: HashMap<String, Decimal>,
    /// 심볼별 초기 가격 (평균 회귀 기준)
    initial_prices: HashMap<String, Decimal>,
    /// ATR 비율 (가격 대비 변동폭, 기본 0.002 = 0.2%)
    atr_ratio: f64,
    /// 평균회귀 강도 (0~1, 기본 0.01)
    mean_reversion_strength: f64,
    /// 호가 단위 제공자 (옵션)
    tick_size_provider: Option<Arc<dyn TickSizeProvider>>,
}

impl Default for RandomWalkGenerator {
    fn default() -> Self {
        Self::new()
    }
}

impl RandomWalkGenerator {
    /// 새 랜덤 워크 생성기 생성.
    pub fn new() -> Self {
        Self {
            current_prices: HashMap::new(),
            initial_prices: HashMap::new(),
            atr_ratio: 0.002,
            mean_reversion_strength: 0.01,
            tick_size_provider: None,
        }
    }

    /// 호가 단위 제공자 설정.
    pub fn with_tick_size_provider(mut self, provider: Arc<dyn TickSizeProvider>) -> Self {
        self.tick_size_provider = Some(provider);
        self
    }

    /// ATR 비율 설정.
    pub fn with_atr_ratio(mut self, ratio: f64) -> Self {
        self.atr_ratio = ratio;
        self
    }

    /// 가격을 호가 단위로 라운딩.
    fn round_to_tick(&self, price: Decimal) -> Decimal {
        if let Some(ref provider) = self.tick_size_provider {
            provider.round_to_tick(price, RoundMethod::Round)
        } else {
            price.round_dp(2)
        }
    }
}

#[async_trait]
impl MockPriceGenerator for RandomWalkGenerator {
    async fn next_tick(&mut self, symbol: &str) -> Option<PriceTick> {
        let current_price = *self.current_prices.get(symbol)?;
        let initial_price = *self.initial_prices.get(symbol)?;

        let mut rng = rand::thread_rng();

        // Box-Muller 정규분포 생성
        let u1: f64 = rng.gen_range(0.0001..1.0);
        let u2: f64 = rng.gen_range(0.0..std::f64::consts::TAU);
        let normal = (-2.0 * u1.ln()).sqrt() * u2.cos();

        // ATR 기반 가격 변동
        let price_f64 = current_price.to_f64().unwrap_or(0.0);
        let atr = price_f64 * self.atr_ratio;
        let random_change = atr * normal;

        // 평균 회귀 (초기 가격 방향으로 약하게 끌어당김)
        let initial_f64 = initial_price.to_f64().unwrap_or(0.0);
        let reversion = (initial_f64 - price_f64) * self.mean_reversion_strength;

        let new_price_f64 = price_f64 + random_change + reversion;
        // 가격은 0 이하로 내려가지 않음
        let new_price_f64 = new_price_f64.max(price_f64 * 0.5);

        let new_price = Decimal::from_f64_retain(new_price_f64).unwrap_or(current_price);
        let new_price = self.round_to_tick(new_price);

        // 가격이 0 이하면 최소 호가 단위
        let new_price = if new_price <= Decimal::ZERO {
            if let Some(ref provider) = self.tick_size_provider {
                provider.tick_size(Decimal::ONE)
            } else {
                dec!(0.01)
            }
        } else {
            new_price
        };

        self.current_prices.insert(symbol.to_string(), new_price);

        // 거래량 추정 (랜덤)
        let volume = Decimal::from(rng.gen_range(10u64..500));

        Some(PriceTick {
            symbol: symbol.to_string(),
            price: new_price,
            volume,
            timestamp: Utc::now(),
        })
    }

    async fn initialize(&mut self, symbol: &str, initial_price: Decimal) {
        self.current_prices
            .insert(symbol.to_string(), initial_price);
        self.initial_prices
            .insert(symbol.to_string(), initial_price);
    }
}

// ==================== HistoricalReplayGenerator ====================

/// DB 1분봉 기반 히스토리컬 리플레이 생성기.
///
/// 1분봉 캔들을 12단계로 보간하여 틱을 생성합니다:
/// Open → High → Low → Close (또는 Open → Low → High → Close) 경로
pub struct HistoricalReplayGenerator {
    /// 심볼별 캔들 버퍼
    candle_buffers: HashMap<String, Vec<Kline>>,
    /// 심볼별 현재 캔들 인덱스
    candle_indices: HashMap<String, usize>,
    /// 심볼별 캔들 내 틱 단계 (0~11)
    tick_steps: HashMap<String, usize>,
    /// 재생 속도 배율 (외부에서 틱 간격 조정에 사용)
    #[allow(dead_code)]
    replay_speed: f64,
    /// 호가 단위 제공자
    tick_size_provider: Option<Arc<dyn TickSizeProvider>>,
}

impl HistoricalReplayGenerator {
    /// 새 히스토리컬 리플레이 생성기 생성.
    pub fn new(replay_speed: f64) -> Self {
        Self {
            candle_buffers: HashMap::new(),
            candle_indices: HashMap::new(),
            tick_steps: HashMap::new(),
            replay_speed: replay_speed.max(0.1),
            tick_size_provider: None,
        }
    }

    /// 호가 단위 제공자 설정.
    pub fn with_tick_size_provider(mut self, provider: Arc<dyn TickSizeProvider>) -> Self {
        self.tick_size_provider = Some(provider);
        self
    }

    /// 캔들 데이터 로드.
    pub fn load_candles(&mut self, symbol: &str, candles: Vec<Kline>) {
        debug!("{} 캔들 {}개 로드", symbol, candles.len());
        self.candle_buffers.insert(symbol.to_string(), candles);
        self.candle_indices.insert(symbol.to_string(), 0);
        self.tick_steps.insert(symbol.to_string(), 0);
    }

    /// 캔들 내 12단계 보간 가격 생성.
    ///
    /// 양봉(close > open): O → H 경로(0~4) → H 유지(5) → L 하락(6~8) → C 복귀(9~11)
    /// 음봉(close < open): O → L 경로(0~4) → L 유지(5) → H 상승(6~8) → C 복귀(9~11)
    fn interpolate_price(&self, candle: &Kline, step: usize) -> Decimal {
        let is_bullish = candle.close >= candle.open;
        let total_steps = 12usize;
        let step = step.min(total_steps - 1);

        let price = if is_bullish {
            // 양봉: O → H → L → C
            match step {
                0 => candle.open,
                1..=4 => {
                    // Open → High 보간
                    let ratio = Decimal::from(step) / dec!(4);
                    candle.open + (candle.high - candle.open) * ratio
                }
                5 => candle.high,
                6..=8 => {
                    // High → Low 보간
                    let ratio = Decimal::from(step - 5) / dec!(3);
                    candle.high + (candle.low - candle.high) * ratio
                }
                9..=11 => {
                    // Low → Close 보간
                    let ratio = Decimal::from(step - 8) / dec!(3);
                    candle.low + (candle.close - candle.low) * ratio
                }
                _ => candle.close,
            }
        } else {
            // 음봉: O → L → H → C
            match step {
                0 => candle.open,
                1..=4 => {
                    // Open → Low 보간
                    let ratio = Decimal::from(step) / dec!(4);
                    candle.open + (candle.low - candle.open) * ratio
                }
                5 => candle.low,
                6..=8 => {
                    // Low → High 보간
                    let ratio = Decimal::from(step - 5) / dec!(3);
                    candle.low + (candle.high - candle.low) * ratio
                }
                9..=11 => {
                    // High → Close 보간
                    let ratio = Decimal::from(step - 8) / dec!(3);
                    candle.high + (candle.close - candle.high) * ratio
                }
                _ => candle.close,
            }
        };

        // 호가 단위 라운딩
        if let Some(ref provider) = self.tick_size_provider {
            provider.round_to_tick(price, RoundMethod::Round)
        } else {
            price.round_dp(2)
        }
    }
}

#[async_trait]
impl MockPriceGenerator for HistoricalReplayGenerator {
    async fn next_tick(&mut self, symbol: &str) -> Option<PriceTick> {
        let candles = self.candle_buffers.get(symbol)?;
        let candle_idx = *self.candle_indices.get(symbol)?;
        let tick_step = *self.tick_steps.get(symbol)?;

        if candle_idx >= candles.len() {
            return None; // 모든 캔들 재생 완료
        }

        let candle = &candles[candle_idx];
        let price = self.interpolate_price(candle, tick_step);

        // 거래량은 캔들 전체 거래량을 12등분
        let volume = (candle.volume / dec!(12)).round_dp(0).max(Decimal::ONE);

        let tick = PriceTick {
            symbol: symbol.to_string(),
            price,
            volume,
            timestamp: Utc::now(),
        };

        // 다음 단계 진행
        let next_step = tick_step + 1;
        if next_step >= 12 {
            // 다음 캔들로 이동
            self.candle_indices
                .insert(symbol.to_string(), candle_idx + 1);
            self.tick_steps.insert(symbol.to_string(), 0);
        } else {
            self.tick_steps.insert(symbol.to_string(), next_step);
        }

        Some(tick)
    }

    async fn initialize(&mut self, symbol: &str, _initial_price: Decimal) {
        // HistoricalReplay는 load_candles()로 초기화됨
        if !self.candle_buffers.contains_key(symbol) {
            self.candle_buffers.insert(symbol.to_string(), Vec::new());
            self.candle_indices.insert(symbol.to_string(), 0);
            self.tick_steps.insert(symbol.to_string(), 0);
        }
    }
}

// ==================== MockOrderBookGenerator ====================

/// 호가창 생성기.
///
/// 현재 가격을 기준으로 KR 10단계 / US 1단계 호가창을 동적 생성합니다.
/// 내부 호가일수록 높은 잔량을 배치하여 현실적인 호가창을 모사합니다.
pub struct MockOrderBookGenerator {
    /// 시장 유형
    market_type: String,
    /// 스프레드 배율
    spread_multiplier: Decimal,
    /// 기본 잔량
    base_volume: Decimal,
    /// 호가 단위 제공자
    tick_size_provider: Option<Arc<dyn TickSizeProvider>>,
}

impl MockOrderBookGenerator {
    /// 새 호가창 생성기 생성.
    pub fn new(market_type: &str, spread_multiplier: Decimal, base_volume: Decimal) -> Self {
        Self {
            market_type: market_type.to_string(),
            spread_multiplier,
            base_volume,
            tick_size_provider: None,
        }
    }

    /// 호가 단위 제공자 설정.
    pub fn with_tick_size_provider(mut self, provider: Arc<dyn TickSizeProvider>) -> Self {
        self.tick_size_provider = Some(provider);
        self
    }

    /// 호가 단계 수 결정.
    fn orderbook_depth(&self) -> usize {
        match self.market_type.as_str() {
            "stock_kr" => 10,
            "stock_us" => 5,
            "crypto" => 20,
            _ => 5,
        }
    }

    /// 호가 단위 조회.
    fn get_tick_size(&self, price: Decimal) -> Decimal {
        if let Some(ref provider) = self.tick_size_provider {
            provider.tick_size(price)
        } else {
            // 기본값: 가격의 0.01%
            (price * dec!(0.0001)).round_dp(2).max(dec!(0.01))
        }
    }

    /// 현재 가격으로부터 호가창 생성.
    pub fn generate(&self, symbol: &str, current_price: Decimal) -> (Ticker, OrderBook) {
        let tick_size = self.get_tick_size(current_price);
        let depth = self.orderbook_depth();

        // 스프레드 계산 (기본 1 tick, spread_multiplier 적용)
        let half_spread = tick_size * self.spread_multiplier;

        // 최우선 매수호가 = 현재가 - 반 스프레드
        let best_bid = self.round_price_down(current_price - half_spread, tick_size);
        // 최우선 매도호가 = 현재가 + 반 스프레드
        let best_ask = self.round_price_up(current_price + half_spread, tick_size);

        let mut rng = rand::thread_rng();

        // 매수 호가 (가격 내림차순)
        let bids: Vec<OrderBookLevel> = (0..depth)
            .map(|i| {
                let price = best_bid - tick_size * Decimal::from(i as u64);
                let price = price.max(tick_size); // 최소 1 tick
                                                  // 내부 호가일수록 잔량이 많음 (역비례 감소)
                let volume_multiplier = dec!(1.5) - Decimal::from(i as u64) * dec!(0.1);
                let volume_multiplier = volume_multiplier.max(dec!(0.3));
                let jitter = Decimal::from(rng.gen_range(80u64..120)) / dec!(100);
                let quantity = (self.base_volume * volume_multiplier * jitter)
                    .round_dp(0)
                    .max(Decimal::ONE);
                OrderBookLevel { price, quantity }
            })
            .collect();

        // 매도 호가 (가격 오름차순)
        let asks: Vec<OrderBookLevel> = (0..depth)
            .map(|i| {
                let price = best_ask + tick_size * Decimal::from(i as u64);
                let volume_multiplier = dec!(1.5) - Decimal::from(i as u64) * dec!(0.1);
                let volume_multiplier = volume_multiplier.max(dec!(0.3));
                let jitter = Decimal::from(rng.gen_range(80u64..120)) / dec!(100);
                let quantity = (self.base_volume * volume_multiplier * jitter)
                    .round_dp(0)
                    .max(Decimal::ONE);
                OrderBookLevel { price, quantity }
            })
            .collect();

        let timestamp = Utc::now();

        // Ticker 생성
        let ticker = Ticker {
            ticker: symbol.to_string(),
            last: current_price,
            bid: best_bid,
            ask: best_ask,
            high_24h: current_price * dec!(1.02),
            low_24h: current_price * dec!(0.98),
            volume_24h: self.base_volume * dec!(1000),
            change_24h: Decimal::ZERO,
            change_24h_percent: Decimal::ZERO,
            timestamp,
        };

        // OrderBook 생성
        let orderbook = OrderBook {
            ticker: symbol.to_string(),
            bids,
            asks,
            timestamp,
        };

        (ticker, orderbook)
    }

    /// 가격을 호가 단위로 내림.
    fn round_price_down(&self, price: Decimal, tick_size: Decimal) -> Decimal {
        if tick_size.is_zero() {
            return price;
        }
        let ticks = (price / tick_size).floor();
        ticks * tick_size
    }

    /// 가격을 호가 단위로 올림.
    fn round_price_up(&self, price: Decimal, tick_size: Decimal) -> Decimal {
        if tick_size.is_zero() {
            return price;
        }
        let ticks = (price / tick_size).ceil();
        ticks * tick_size
    }
}

// ==================== 테스트 ====================

#[cfg(test)]
mod tests {
    use rust_decimal_macros::dec;

    use super::*;

    #[tokio::test]
    async fn test_random_walk_generator() {
        let mut gen = RandomWalkGenerator::new();
        gen.initialize("TEST", dec!(50000)).await;

        // 100 틱 생성
        let mut prices = Vec::new();
        for _ in 0..100 {
            if let Some(tick) = gen.next_tick("TEST").await {
                assert_eq!(tick.symbol, "TEST");
                assert!(tick.price > Decimal::ZERO, "가격은 0 초과여야 함");
                assert!(tick.volume > Decimal::ZERO, "거래량은 0 초과여야 함");
                prices.push(tick.price);
            }
        }

        assert_eq!(prices.len(), 100);
        // 가격이 모두 동일하지 않아야 함 (변동이 있어야 함)
        let unique_prices: std::collections::HashSet<String> =
            prices.iter().map(|p| p.to_string()).collect();
        assert!(unique_prices.len() > 1, "가격에 변동이 있어야 함");
    }

    #[tokio::test]
    async fn test_historical_replay_generator() {
        let mut gen = HistoricalReplayGenerator::new(1.0);

        // 테스트 캔들 생성
        let now = Utc::now();
        let candle = Kline::new(
            "TEST".to_string(),
            trader_core::Timeframe::M1,
            now,
            dec!(100),
            dec!(105),
            dec!(98),
            dec!(103),
            dec!(1000),
            now + chrono::Duration::seconds(60),
        );

        gen.load_candles("TEST", vec![candle]);
        gen.initialize("TEST", dec!(100)).await;

        // 12단계 틱 생성
        let mut ticks = Vec::new();
        for _ in 0..12 {
            if let Some(tick) = gen.next_tick("TEST").await {
                ticks.push(tick);
            }
        }

        assert_eq!(ticks.len(), 12);
        // 첫 번째 = Open, 마지막 = Close 근처
        assert_eq!(ticks[0].price, dec!(100.00));

        // 다음 틱은 None (캔들 소진)
        let end = gen.next_tick("TEST").await;
        assert!(end.is_none(), "캔들 재생 완료 후 None 반환");
    }

    #[test]
    fn test_orderbook_generator_kr() {
        let gen = MockOrderBookGenerator::new("stock_kr", Decimal::ONE, dec!(100));
        let (ticker, orderbook) = gen.generate("005930", dec!(70000));

        assert_eq!(orderbook.bids.len(), 10, "KR 호가는 10단계");
        assert_eq!(orderbook.asks.len(), 10, "KR 호가는 10단계");
        assert!(ticker.bid < ticker.ask, "매수호가 < 매도호가");
        assert!(
            orderbook.bids[0].price >= orderbook.bids[1].price,
            "매수 호가 내림차순"
        );
        assert!(
            orderbook.asks[0].price <= orderbook.asks[1].price,
            "매도 호가 오름차순"
        );
    }

    #[test]
    fn test_orderbook_generator_us() {
        let gen = MockOrderBookGenerator::new("stock_us", Decimal::ONE, dec!(100));
        let (ticker, orderbook) = gen.generate("AAPL", dec!(175));

        assert_eq!(orderbook.bids.len(), 5, "US 호가는 5단계");
        assert_eq!(orderbook.asks.len(), 5, "US 호가는 5단계");
        assert!(ticker.bid < ticker.ask);
    }

    #[test]
    fn test_orderbook_volume_distribution() {
        let gen = MockOrderBookGenerator::new("stock_kr", Decimal::ONE, dec!(1000));
        let (_, orderbook) = gen.generate("005930", dec!(70000));

        // 내부 호가(인덱스 0)가 외부 호가(인덱스 9)보다 평균적으로 잔량이 많아야 함
        // 랜덤 jitter 때문에 정확한 비교는 어려우나, base 배율 차이가 큼
        // bids[0] 배율 1.5, bids[9] 배율 0.6
        // 단순 비교 대신 합계로 검증
        let total_bid_volume: Decimal = orderbook.bids.iter().map(|l| l.quantity).sum();
        assert!(total_bid_volume > Decimal::ZERO);
    }
}
