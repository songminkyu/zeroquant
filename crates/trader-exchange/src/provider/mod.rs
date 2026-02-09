//! ExchangeProvider 및 MarketDataProvider 구현체.
//!
//! 거래소 중립적인 ExchangeProvider, MarketDataProvider trait의 구현체들을 제공합니다.
//!
//! # Provider 구조
//!
//! 모든 거래소는 `XXXExchangeProvider` 패턴을 따릅니다:
//! - [`KisExchangeProvider`]: KIS 국내/해외/ISA 계좌 통합 Provider
//! - [`BinanceProvider`]: Binance 거래소 Provider
//! - [`MockExchangeProvider`]: 테스트/시뮬레이션용 Mock Provider

mod binance;
mod bithumb;
mod db_investment;
mod kis;
mod ls_sec;
mod mock;
pub mod mock_order_engine;
pub mod mock_streaming;
mod upbit;

pub use binance::{BinanceExchangeProvider, BinanceProvider};
pub use bithumb::{BithumbExchangeProvider, BithumbProvider};
pub use db_investment::{DbInvestmentExchangeProvider, DbInvestmentProvider};
pub use kis::{KisExchangeProvider, KisProvider};
pub use ls_sec::{LsSecExchangeProvider, LsSecProvider};
pub use mock::{MockConfig, MockExchangeProvider, MockMarketStream};
pub use mock_order_engine::{MockOrderEngine, RawPendingOrder};
pub use mock_streaming::{MockOrderBookGenerator, MockPriceGenerator, MockPriceMode, MockStreamingConfig};
pub use upbit::{UpbitExchangeProvider, UpbitProvider};
