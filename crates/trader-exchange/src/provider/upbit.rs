//! Upbit ExchangeProvider + MarketDataProvider 구현.
//!
//! UpbitClient를 래핑하여 거래소 중립적인 인터페이스를 제공합니다.

use crate::connector::upbit::UpbitClient;
use async_trait::async_trait;
use std::sync::Arc;
use tracing::debug;
use trader_core::cache::ExchangeCache;
use trader_core::domain::{
    ExchangeProvider, ExecutionHistoryRequest, ExecutionHistoryResponse, MarketDataProvider,
    PendingOrder, ProviderError, QuoteData, StrategyAccountInfo, StrategyPositionInfo,
};

/// Upbit ExchangeProvider 구현.
///
/// UpbitClient를 래핑하여 캐싱 레이어를 추가합니다.
pub struct UpbitExchangeProvider {
    client: Arc<UpbitClient>,
    cache: Arc<ExchangeCache>,
}

/// 하위 호환성을 위한 타입 별칭.
pub type UpbitProvider = UpbitExchangeProvider;

impl UpbitExchangeProvider {
    /// 새 UpbitExchangeProvider 생성.
    pub fn new(client: Arc<UpbitClient>) -> Self {
        Self {
            client,
            cache: Arc::new(ExchangeCache::with_defaults()),
        }
    }

    /// 공용 캐시 참조 반환.
    pub fn exchange_cache(&self) -> Arc<ExchangeCache> {
        Arc::clone(&self.cache)
    }
}

// ==================== ExchangeProvider ====================

#[async_trait]
impl ExchangeProvider for UpbitExchangeProvider {
    async fn fetch_account(&self) -> Result<StrategyAccountInfo, ProviderError> {
        if let Some(cached) = self.cache.get_account().await {
            debug!("Upbit 계좌 정보 캐시 히트");
            return Ok(cached);
        }

        let result = self.client.fetch_account().await?;
        self.cache.set_account(result.clone()).await;
        Ok(result)
    }

    async fn fetch_positions(&self) -> Result<Vec<StrategyPositionInfo>, ProviderError> {
        if let Some(cached) = self.cache.get_positions().await {
            debug!("Upbit 포지션 캐시 히트");
            return Ok(cached);
        }

        let result = self.client.fetch_positions().await?;
        self.cache.set_positions(result.clone()).await;
        Ok(result)
    }

    async fn fetch_pending_orders(&self) -> Result<Vec<PendingOrder>, ProviderError> {
        if let Some(cached) = self.cache.get_pending_orders().await {
            debug!("Upbit 미체결 주문 캐시 히트");
            return Ok(cached);
        }

        let result = self.client.fetch_pending_orders().await?;
        self.cache.set_pending_orders(result.clone()).await;
        Ok(result)
    }

    async fn fetch_execution_history(
        &self,
        _request: &ExecutionHistoryRequest,
    ) -> Result<ExecutionHistoryResponse, ProviderError> {
        // TODO: 체결 내역 조회 구현
        Ok(ExecutionHistoryResponse {
            trades: Vec::new(),
            next_cursor: None,
        })
    }

    fn exchange_name(&self) -> &str {
        "upbit"
    }
}

// ==================== MarketDataProvider ====================

#[async_trait]
impl MarketDataProvider for UpbitExchangeProvider {
    async fn get_quote(&self, symbol: &str) -> Result<QuoteData, ProviderError> {
        self.client.get_quote(symbol).await
    }

    async fn get_quotes(&self, symbols: &[String]) -> Vec<QuoteData> {
        self.client.get_quotes(symbols).await
    }

    fn provider_name(&self) -> &str {
        "upbit"
    }
}
