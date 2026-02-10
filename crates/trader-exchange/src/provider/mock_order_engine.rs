//! Mock 주문 매칭 엔진.
//!
//! 호가창(OrderBook) 기반 VWAP 체결 + 지정가/스톱 주문 미체결 큐 관리를 제공합니다.
//! 기존 `MatchingEngine`은 백테스트용(Kline 기반)이며, 이 엔진은 Paper Trading 전용입니다.
//!
//! # 핵심 기능
//!
//! - 시장가 주문: OrderBook ask/bid 레벨 순서대로 VWAP 체결
//! - 지정가 주문: 즉시 체결 가능이면 체결, 아니면 큐 등록
//! - 스톱 주문: stop_price 도달 시 시장가로 전환
//! - 부분 체결: OrderBook 물량 부족 시 가능한 만큼만 체결
//! - 잔고 예약: 지정가 주문 시 필요 자금 예약 (cancel 시 해제)

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use std::collections::HashMap;
use std::sync::Arc;
use tracing::{debug, info};

use trader_core::{
    OrderBook, OrderBookLevel, OrderRequest, OrderStatusType, OrderType, PendingOrder, Side,
    TickSizeProvider, Ticker,
};

// ==================== 체결 결과 ====================

/// 주문 체결 결과.
#[derive(Debug, Clone)]
pub struct MockOrderFill {
    /// 주문 ID
    pub order_id: String,
    /// 심볼
    pub symbol: String,
    /// 방향
    pub side: Side,
    /// 체결 수량
    pub filled_quantity: Decimal,
    /// 체결 가격 (VWAP)
    pub fill_price: Decimal,
    /// 수수료
    pub commission: Decimal,
    /// 체결 시각
    pub timestamp: DateTime<Utc>,
    /// 전략 ID
    pub strategy_id: String,
    /// 완전 체결 여부
    pub is_fully_filled: bool,
    /// 예약금 해제액 (지정가 체결 시)
    pub released_reservation: Decimal,
}

/// 주문 취소 결과.
#[derive(Debug, Clone)]
pub struct MockCancelResult {
    /// 전략 ID
    pub strategy_id: String,
    /// 해제될 예약금
    pub released_amount: Decimal,
    /// 취소된 주문 ID
    pub order_id: String,
}

/// DB 영속화용 미체결 주문 정보.
///
/// `get_raw_pending_orders()`에서 반환됩니다.
#[derive(Debug, Clone)]
pub struct RawPendingOrder {
    /// 주문 ID
    pub order_id: String,
    /// 심볼
    pub symbol: String,
    /// 방향
    pub side: Side,
    /// 주문 유형
    pub order_type: OrderType,
    /// 원래 수량
    pub quantity: Decimal,
    /// 남은 수량
    pub remaining_quantity: Decimal,
    /// 지정가
    pub price: Option<Decimal>,
    /// 스톱 가격
    pub stop_price: Option<Decimal>,
    /// 예약 금액
    pub reserved_amount: Decimal,
    /// 생성 시각
    pub created_at: DateTime<Utc>,
}

// ==================== 미체결 주문 ====================

/// Mock 미체결 주문 내부 표현.
#[derive(Debug, Clone)]
struct MockPendingOrder {
    /// 주문 ID
    order_id: String,
    /// 심볼
    symbol: String,
    /// 방향
    side: Side,
    /// 주문 유형
    #[allow(dead_code)]
    order_type: OrderType,
    /// 원래 수량
    original_quantity: Decimal,
    /// 남은 수량
    remaining_quantity: Decimal,
    /// 지정가
    price: Option<Decimal>,
    /// 스톱 가격
    stop_price: Option<Decimal>,
    /// 전략 ID
    strategy_id: String,
    /// 예약 금액
    reserved_amount: Decimal,
    /// 생성 시각
    created_at: DateTime<Utc>,
    /// 스톱 트리거 여부
    stop_triggered: bool,
}

// ==================== MockOrderEngine ====================

/// Mock 주문 매칭 엔진.
///
/// Paper Trading에서 현실적인 주문 체결을 시뮬레이션합니다.
/// 호가창 기반 VWAP 체결, 지정가 큐, 스톱 주문을 지원합니다.
pub struct MockOrderEngine {
    /// 심볼별 미체결 주문
    pending_orders: HashMap<String, Vec<MockPendingOrder>>,
    /// 주문 ID → 전략 ID 매핑
    order_strategy_map: HashMap<String, String>,
    /// 주문 ID → 예약금 매핑
    reserved_amounts: HashMap<String, Decimal>,
    /// 수수료율
    fee_rate: Decimal,
    /// 슬리피지율
    slippage_rate: Decimal,
    /// 호가 단위 제공자
    tick_size_provider: Option<Arc<dyn TickSizeProvider>>,
    /// 주문 ID 카운터
    next_order_id: u64,
}

impl MockOrderEngine {
    /// 새 엔진 생성.
    pub fn new(fee_rate: Decimal, slippage_rate: Decimal) -> Self {
        Self {
            pending_orders: HashMap::new(),
            order_strategy_map: HashMap::new(),
            reserved_amounts: HashMap::new(),
            fee_rate,
            slippage_rate,
            tick_size_provider: None,
            next_order_id: 1,
        }
    }

    /// 호가 단위 제공자 설정.
    pub fn with_tick_size_provider(mut self, provider: Arc<dyn TickSizeProvider>) -> Self {
        self.tick_size_provider = Some(provider);
        self
    }

    /// 고유 주문 ID 생성.
    fn generate_order_id(&mut self) -> String {
        let id = format!("MOCK-{:08}", self.next_order_id);
        self.next_order_id += 1;
        id
    }

    // ==================== 시장가 주문 ====================

    /// 시장가 주문 체결 (OrderBook VWAP).
    ///
    /// 매수: ask 레벨 순서대로 소진 (오름차순)
    /// 매도: bid 레벨 순서대로 소진 (내림차순)
    ///
    /// 물량 부족 시 부분 체결 가능.
    pub fn submit_market_order(
        &mut self,
        request: &OrderRequest,
        orderbook: &OrderBook,
        strategy_id: &str,
    ) -> Option<MockOrderFill> {
        let order_id = self.generate_order_id();
        let levels = match request.side {
            Side::Buy => &orderbook.asks,
            Side::Sell => &orderbook.bids,
        };

        let (fill_price, filled_qty) = Self::calculate_vwap(levels, request.quantity);

        if filled_qty.is_zero() {
            debug!(
                "[MockEngine] 시장가 체결 실패: 호가창 물량 부족 ({})",
                request.ticker
            );
            return None;
        }

        // 슬리피지 적용
        let slippage = fill_price * self.slippage_rate;
        let execution_price = match request.side {
            Side::Buy => fill_price + slippage,
            Side::Sell => fill_price - slippage,
        };

        let commission = execution_price * filled_qty * self.fee_rate;

        info!(
            "[MockEngine] 시장가 체결: {} {:?} {} @ {} (VWAP)",
            request.ticker, request.side, filled_qty, execution_price
        );

        Some(MockOrderFill {
            order_id,
            symbol: request.ticker.clone(),
            side: request.side,
            filled_quantity: filled_qty,
            fill_price: execution_price,
            commission,
            timestamp: Utc::now(),
            strategy_id: strategy_id.to_string(),
            is_fully_filled: filled_qty >= request.quantity,
            released_reservation: Decimal::ZERO,
        })
    }

    // ==================== 지정가 주문 ====================

    /// 지정가 주문 제출.
    ///
    /// 즉시 체결 가능한 가격이면 바로 체결하고, 아니면 큐에 등록합니다.
    ///
    /// # Returns
    /// - `Ok(Some(fill))`: 즉시 체결
    /// - `Ok(None)`: 큐 등록됨
    /// - `Err(...)`: 주문 실패
    pub fn submit_limit_order(
        &mut self,
        request: &OrderRequest,
        ticker: &Ticker,
        strategy_id: &str,
    ) -> Result<(String, Option<MockOrderFill>), String> {
        let order_id = self.generate_order_id();
        let limit_price = request.price.ok_or("지정가 주문에 가격 필수")?;

        // 즉시 체결 가능 여부 확인
        let can_fill_immediately = match request.side {
            Side::Buy => ticker.ask <= limit_price,
            Side::Sell => ticker.bid >= limit_price,
        };

        if can_fill_immediately {
            // 즉시 체결 (슬리피지 없이 지정가로 체결)
            let execution_price = limit_price;
            let commission = execution_price * request.quantity * self.fee_rate;

            info!(
                "[MockEngine] 지정가 즉시 체결: {} {:?} {} @ {}",
                request.ticker, request.side, request.quantity, execution_price
            );

            let fill = MockOrderFill {
                order_id: order_id.clone(),
                symbol: request.ticker.clone(),
                side: request.side,
                filled_quantity: request.quantity,
                fill_price: execution_price,
                commission,
                timestamp: Utc::now(),
                strategy_id: strategy_id.to_string(),
                is_fully_filled: true,
                released_reservation: Decimal::ZERO,
            };

            return Ok((order_id, Some(fill)));
        }

        // 예약금 계산
        let reserved_amount = match request.side {
            Side::Buy => limit_price * request.quantity * (Decimal::ONE + self.fee_rate),
            Side::Sell => Decimal::ZERO, // 매도는 포지션이 담보
        };

        // 큐에 등록
        let pending = MockPendingOrder {
            order_id: order_id.clone(),
            symbol: request.ticker.clone(),
            side: request.side,
            order_type: OrderType::Limit,
            original_quantity: request.quantity,
            remaining_quantity: request.quantity,
            price: Some(limit_price),
            stop_price: None,
            strategy_id: strategy_id.to_string(),
            reserved_amount,
            created_at: Utc::now(),
            stop_triggered: false,
        };

        self.pending_orders
            .entry(request.ticker.clone())
            .or_default()
            .push(pending);
        self.order_strategy_map
            .insert(order_id.clone(), strategy_id.to_string());
        self.reserved_amounts
            .insert(order_id.clone(), reserved_amount);

        debug!(
            "[MockEngine] 지정가 큐 등록: {} {:?} {} @ {} (예약금: {})",
            request.ticker, request.side, request.quantity, limit_price, reserved_amount
        );

        Ok((order_id, None))
    }

    // ==================== 스톱 주문 ====================

    /// 스톱 주문 제출.
    ///
    /// stop_price 도달 전까지 큐에 대기하다가, 도달하면 시장가로 전환됩니다.
    pub fn submit_stop_order(
        &mut self,
        request: &OrderRequest,
        strategy_id: &str,
    ) -> Result<String, String> {
        let order_id = self.generate_order_id();
        let stop_price = request.stop_price.ok_or("스톱 주문에 stop_price 필수")?;

        let reserved_amount = match request.side {
            Side::Buy => {
                stop_price * request.quantity * (Decimal::ONE + self.fee_rate) * dec!(1.05)
            } // 5% 버퍼
            Side::Sell => Decimal::ZERO,
        };

        let pending = MockPendingOrder {
            order_id: order_id.clone(),
            symbol: request.ticker.clone(),
            side: request.side,
            order_type: request.order_type,
            original_quantity: request.quantity,
            remaining_quantity: request.quantity,
            price: request.price,
            stop_price: Some(stop_price),
            strategy_id: strategy_id.to_string(),
            reserved_amount,
            created_at: Utc::now(),
            stop_triggered: false,
        };

        self.pending_orders
            .entry(request.ticker.clone())
            .or_default()
            .push(pending);
        self.order_strategy_map
            .insert(order_id.clone(), strategy_id.to_string());
        self.reserved_amounts
            .insert(order_id.clone(), reserved_amount);

        debug!(
            "[MockEngine] 스톱 주문 등록: {} {:?} {} @ stop={} (예약금: {})",
            request.ticker, request.side, request.quantity, stop_price, reserved_amount
        );

        Ok(order_id)
    }

    // ==================== 가격 변동 시 매칭 ====================

    /// 가격 틱 수신 시 미체결 주문 매칭.
    ///
    /// 매 틱마다 호출되어 미체결 큐의 주문을 검사하고, 체결 가능한 주문을 체결합니다.
    /// 스톱 주문은 stop_price 도달 시 시장가로 전환 후 체결 시도합니다.
    pub fn on_price_tick(
        &mut self,
        symbol: &str,
        ticker: &Ticker,
        orderbook: &OrderBook,
    ) -> Vec<MockOrderFill> {
        let mut fills = Vec::new();
        let fee_rate = self.fee_rate;
        let slippage_rate = self.slippage_rate;

        let orders = match self.pending_orders.get_mut(symbol) {
            Some(orders) => orders,
            None => return fills,
        };

        let mut to_remove = Vec::new();

        for (idx, order) in orders.iter_mut().enumerate() {
            // 1. 스톱 주문 트리거 확인
            if let Some(stop_price) = order.stop_price {
                if !order.stop_triggered {
                    let triggered = match order.side {
                        // 매수 스톱: 현재가가 stop_price 이상
                        Side::Buy => ticker.last >= stop_price,
                        // 매도 스톱: 현재가가 stop_price 이하
                        Side::Sell => ticker.last <= stop_price,
                    };

                    if triggered {
                        info!(
                            "[MockEngine] 스톱 트리거: {} {:?} @ {} (stop={})",
                            order.symbol, order.side, ticker.last, stop_price
                        );
                        order.stop_triggered = true;
                        // 시장가로 전환하여 아래에서 체결 시도
                    } else {
                        continue; // 아직 미트리거
                    }
                }
            }

            // 2. 체결 시도
            let should_fill = if order.stop_triggered && order.price.is_none() {
                // 스톱 시장가: 즉시 체결
                true
            } else if let Some(limit_price) = order.price {
                // 지정가/스톱지정가: 가격 조건 확인
                match order.side {
                    Side::Buy => ticker.ask <= limit_price,
                    Side::Sell => ticker.bid >= limit_price,
                }
            } else {
                // 스톱 트리거 후 시장가
                order.stop_triggered
            };

            if !should_fill {
                continue;
            }

            // 3. VWAP 체결
            let levels = match order.side {
                Side::Buy => &orderbook.asks,
                Side::Sell => &orderbook.bids,
            };

            let (fill_price, filled_qty) = Self::calculate_vwap(levels, order.remaining_quantity);

            if filled_qty.is_zero() {
                continue;
            }

            // 지정가 주문은 지정가 이하로 체결 (매수 기준)
            let execution_price = if let Some(limit_price) = order.price {
                match order.side {
                    Side::Buy => fill_price.min(limit_price),
                    Side::Sell => fill_price.max(limit_price),
                }
            } else {
                // 시장가/스톱 시장가는 슬리피지 적용
                let slippage = fill_price * slippage_rate;
                match order.side {
                    Side::Buy => fill_price + slippage,
                    Side::Sell => fill_price - slippage,
                }
            };

            let commission = execution_price * filled_qty * fee_rate;
            let is_fully_filled = filled_qty >= order.remaining_quantity;

            // 예약금 해제 계산
            let released = if is_fully_filled {
                order.reserved_amount
            } else {
                let fill_ratio = filled_qty / order.original_quantity;
                order.reserved_amount * fill_ratio
            };

            order.remaining_quantity -= filled_qty;
            if !is_fully_filled {
                order.reserved_amount -= released;
            }

            fills.push(MockOrderFill {
                order_id: order.order_id.clone(),
                symbol: order.symbol.clone(),
                side: order.side,
                filled_quantity: filled_qty,
                fill_price: execution_price,
                commission,
                timestamp: Utc::now(),
                strategy_id: order.strategy_id.clone(),
                is_fully_filled,
                released_reservation: released,
            });

            if is_fully_filled {
                to_remove.push(idx);
            }
        }

        // 체결 완료된 주문 제거 (역순)
        for idx in to_remove.into_iter().rev() {
            let removed = orders.remove(idx);
            self.order_strategy_map.remove(&removed.order_id);
            self.reserved_amounts.remove(&removed.order_id);
        }

        // 빈 심볼 엔트리 정리
        if orders.is_empty() {
            self.pending_orders.remove(symbol);
        }

        fills
    }

    // ==================== 주문 취소/정정 ====================

    /// 주문 취소.
    pub fn cancel_order(&mut self, order_id: &str) -> Option<MockCancelResult> {
        // 모든 심볼에서 주문 찾기
        for orders in self.pending_orders.values_mut() {
            if let Some(pos) = orders.iter().position(|o| o.order_id == order_id) {
                let removed = orders.remove(pos);
                self.order_strategy_map.remove(order_id);
                self.reserved_amounts.remove(order_id);

                info!(
                    "[MockEngine] 주문 취소: {} (예약금 해제: {})",
                    order_id, removed.reserved_amount
                );

                return Some(MockCancelResult {
                    strategy_id: removed.strategy_id,
                    released_amount: removed.reserved_amount,
                    order_id: removed.order_id,
                });
            }
        }

        None
    }

    /// 주문 정정 (수량/가격 변경).
    pub fn modify_order(
        &mut self,
        order_id: &str,
        new_quantity: Option<Decimal>,
        new_price: Option<Decimal>,
    ) -> Result<Decimal, String> {
        // 주문 찾기
        for orders in self.pending_orders.values_mut() {
            if let Some(order) = orders.iter_mut().find(|o| o.order_id == order_id) {
                let old_reserved = order.reserved_amount;

                if let Some(qty) = new_quantity {
                    order.remaining_quantity = qty;
                    order.original_quantity = qty;
                }
                if let Some(price) = new_price {
                    order.price = Some(price);
                }

                // 예약금 재계산
                let new_reserved = match order.side {
                    Side::Buy => {
                        let price = order.price.unwrap_or(Decimal::ZERO);
                        price * order.remaining_quantity * (Decimal::ONE + self.fee_rate)
                    }
                    Side::Sell => Decimal::ZERO,
                };

                order.reserved_amount = new_reserved;
                self.reserved_amounts
                    .insert(order_id.to_string(), new_reserved);

                let delta = new_reserved - old_reserved;
                debug!(
                    "[MockEngine] 주문 정정: {} (예약금 변동: {:+})",
                    order_id, delta
                );

                return Ok(delta); // 양수면 추가 예약 필요, 음수면 해제
            }
        }

        Err(format!("주문 없음: {}", order_id))
    }

    // ==================== 조회 ====================

    /// 전략별 미체결 주문 목록 조회.
    pub fn get_pending_orders(&self, strategy_id: &str) -> Vec<PendingOrder> {
        self.pending_orders
            .values()
            .flatten()
            .filter(|o| o.strategy_id == strategy_id)
            .map(|o| PendingOrder {
                order_id: o.order_id.clone(),
                ticker: o.symbol.clone(),
                side: o.side,
                price: o.price.unwrap_or(Decimal::ZERO),
                quantity: o.original_quantity,
                filled_quantity: o.original_quantity - o.remaining_quantity,
                status: if o.remaining_quantity < o.original_quantity {
                    OrderStatusType::PartiallyFilled
                } else {
                    OrderStatusType::Open
                },
                created_at: o.created_at,
            })
            .collect()
    }

    /// 전체 미체결 주문 목록 조회.
    pub fn get_all_pending_orders(&self) -> Vec<PendingOrder> {
        self.pending_orders
            .values()
            .flatten()
            .map(|o| PendingOrder {
                order_id: o.order_id.clone(),
                ticker: o.symbol.clone(),
                side: o.side,
                price: o.price.unwrap_or(Decimal::ZERO),
                quantity: o.original_quantity,
                filled_quantity: o.original_quantity - o.remaining_quantity,
                status: if o.remaining_quantity < o.original_quantity {
                    OrderStatusType::PartiallyFilled
                } else {
                    OrderStatusType::Open
                },
                created_at: o.created_at,
            })
            .collect()
    }

    /// 특정 주문의 예약금 조회.
    pub fn get_reserved_amount(&self, order_id: &str) -> Decimal {
        self.reserved_amounts
            .get(order_id)
            .copied()
            .unwrap_or(Decimal::ZERO)
    }

    /// 전략별 총 예약금 조회.
    pub fn get_total_reserved(&self, strategy_id: &str) -> Decimal {
        self.pending_orders
            .values()
            .flatten()
            .filter(|o| o.strategy_id == strategy_id)
            .map(|o| o.reserved_amount)
            .sum()
    }

    /// 미체결 주문 전체 초기화.
    pub fn clear(&mut self) {
        self.pending_orders.clear();
        self.order_strategy_map.clear();
        self.reserved_amounts.clear();
    }

    /// 특정 전략의 미체결 주문 초기화.
    pub fn clear_strategy(&mut self, strategy_id: &str) -> Decimal {
        let mut released = Decimal::ZERO;

        for orders in self.pending_orders.values_mut() {
            let drain: Vec<usize> = orders
                .iter()
                .enumerate()
                .filter(|(_, o)| o.strategy_id == strategy_id)
                .map(|(i, _)| i)
                .collect();

            for idx in drain.into_iter().rev() {
                let removed = orders.remove(idx);
                released += removed.reserved_amount;
                self.order_strategy_map.remove(&removed.order_id);
                self.reserved_amounts.remove(&removed.order_id);
            }
        }

        // 빈 심볼 엔트리 정리
        self.pending_orders.retain(|_, orders| !orders.is_empty());

        released
    }

    /// DB에서 복원된 미체결 주문을 엔진에 등록.
    ///
    /// `load_state()` 시 사용. 주문 ID 카운터도 함께 업데이트합니다.
    #[allow(clippy::too_many_arguments)]
    pub fn restore_pending_order(
        &mut self,
        order_id: String,
        symbol: String,
        side: Side,
        order_type: OrderType,
        original_quantity: Decimal,
        remaining_quantity: Decimal,
        price: Option<Decimal>,
        stop_price: Option<Decimal>,
        strategy_id: String,
        reserved_amount: Decimal,
        created_at: DateTime<Utc>,
    ) {
        // 주문 ID 카운터 업데이트 (복원된 ID보다 큰 값 유지)
        if let Some(num_str) = order_id.strip_prefix("MOCK-") {
            if let Ok(num) = num_str.parse::<u64>() {
                if num >= self.next_order_id {
                    self.next_order_id = num + 1;
                }
            }
        }

        let pending = MockPendingOrder {
            order_id: order_id.clone(),
            symbol: symbol.clone(),
            side,
            order_type,
            original_quantity,
            remaining_quantity,
            price,
            stop_price,
            strategy_id: strategy_id.clone(),
            reserved_amount,
            created_at,
            stop_triggered: false,
        };

        self.pending_orders.entry(symbol).or_default().push(pending);
        self.order_strategy_map
            .insert(order_id.clone(), strategy_id);
        debug!(
            "미체결 주문 복원: {} (예약금: {})",
            order_id, reserved_amount
        );
        self.reserved_amounts.insert(order_id, reserved_amount);
    }

    /// DB 저장용 미체결 주문 내부 정보 추출.
    ///
    /// `save_strategy_state()`에서 사용합니다.
    pub fn get_raw_pending_orders(&self, strategy_id: &str) -> Vec<RawPendingOrder> {
        self.pending_orders
            .values()
            .flatten()
            .filter(|o| o.strategy_id == strategy_id)
            .map(|o| RawPendingOrder {
                order_id: o.order_id.clone(),
                symbol: o.symbol.clone(),
                side: o.side,
                order_type: o.order_type,
                quantity: o.original_quantity,
                remaining_quantity: o.remaining_quantity,
                price: o.price,
                stop_price: o.stop_price,
                reserved_amount: o.reserved_amount,
                created_at: o.created_at,
            })
            .collect()
    }

    // ==================== VWAP 계산 ====================

    /// OrderBook 레벨을 순서대로 소진하며 VWAP 계산.
    ///
    /// `levels`는 매수 시 asks (오름차순), 매도 시 bids (내림차순).
    fn calculate_vwap(levels: &[OrderBookLevel], target_quantity: Decimal) -> (Decimal, Decimal) {
        if levels.is_empty() {
            return (Decimal::ZERO, Decimal::ZERO);
        }

        let mut remaining = target_quantity;
        let mut total_cost = Decimal::ZERO;
        let mut total_qty = Decimal::ZERO;

        for level in levels {
            if remaining.is_zero() {
                break;
            }

            let fill_qty = remaining.min(level.quantity);
            total_cost += level.price * fill_qty;
            total_qty += fill_qty;
            remaining -= fill_qty;
        }

        if total_qty.is_zero() {
            (Decimal::ZERO, Decimal::ZERO)
        } else {
            let vwap = total_cost / total_qty;
            (vwap, total_qty)
        }
    }
}

// ==================== 테스트 ====================

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;
    use trader_core::TimeInForce;

    fn create_test_orderbook(symbol: &str, mid_price: Decimal) -> OrderBook {
        let tick = dec!(100);
        OrderBook {
            ticker: symbol.to_string(),
            bids: vec![
                OrderBookLevel {
                    price: mid_price - tick,
                    quantity: dec!(100),
                },
                OrderBookLevel {
                    price: mid_price - tick * dec!(2),
                    quantity: dec!(200),
                },
                OrderBookLevel {
                    price: mid_price - tick * dec!(3),
                    quantity: dec!(300),
                },
            ],
            asks: vec![
                OrderBookLevel {
                    price: mid_price + tick,
                    quantity: dec!(100),
                },
                OrderBookLevel {
                    price: mid_price + tick * dec!(2),
                    quantity: dec!(200),
                },
                OrderBookLevel {
                    price: mid_price + tick * dec!(3),
                    quantity: dec!(300),
                },
            ],
            timestamp: Utc::now(),
        }
    }

    fn create_test_ticker(symbol: &str, price: Decimal) -> Ticker {
        Ticker {
            ticker: symbol.to_string(),
            last: price,
            bid: price - dec!(100),
            ask: price + dec!(100),
            high_24h: price * dec!(1.02),
            low_24h: price * dec!(0.98),
            volume_24h: dec!(100000),
            change_24h: Decimal::ZERO,
            change_24h_percent: Decimal::ZERO,
            timestamp: Utc::now(),
        }
    }

    fn create_buy_request(symbol: &str, qty: Decimal, price: Option<Decimal>) -> OrderRequest {
        OrderRequest {
            ticker: symbol.to_string(),
            side: Side::Buy,
            order_type: if price.is_some() {
                OrderType::Limit
            } else {
                OrderType::Market
            },
            quantity: qty,
            price,
            stop_price: None,
            time_in_force: TimeInForce::GTC,
            client_order_id: None,
            strategy_id: None,
        }
    }

    #[test]
    fn test_market_order_buy_vwap() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), dec!(0.0001));
        let orderbook = create_test_orderbook("005930", dec!(70000));
        let request = create_buy_request("005930", dec!(150), None);

        let fill = engine.submit_market_order(&request, &orderbook, "test_strategy");
        assert!(fill.is_some());

        let fill = fill.unwrap();
        assert_eq!(fill.symbol, "005930");
        assert_eq!(fill.filled_quantity, dec!(150));
        // VWAP: (70100 * 100 + 70200 * 50) / 150 = 70133.33...
        assert!(fill.fill_price > dec!(70100));
        assert!(fill.fill_price < dec!(70200));
        assert!(fill.commission > Decimal::ZERO);
    }

    #[test]
    fn test_market_order_partial_fill() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), Decimal::ZERO);
        let orderbook = create_test_orderbook("005930", dec!(70000));
        // 호가창 총 잔량(600)보다 많은 수량 주문
        let request = create_buy_request("005930", dec!(1000), None);

        let fill = engine.submit_market_order(&request, &orderbook, "test_strategy");
        assert!(fill.is_some());
        let fill = fill.unwrap();
        assert_eq!(fill.filled_quantity, dec!(600)); // 부분 체결
        assert!(!fill.is_fully_filled);
    }

    #[test]
    fn test_limit_order_immediate_fill() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), Decimal::ZERO);
        let ticker = create_test_ticker("005930", dec!(70000));
        // ask(70100) 이상 지정가 → 즉시 체결
        let request = create_buy_request("005930", dec!(10), Some(dec!(70200)));

        let result = engine.submit_limit_order(&request, &ticker, "test_strategy");
        assert!(result.is_ok());
        let (_, fill) = result.unwrap();
        assert!(fill.is_some());
        assert_eq!(fill.unwrap().fill_price, dec!(70200));
    }

    #[test]
    fn test_limit_order_queued() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), Decimal::ZERO);
        let ticker = create_test_ticker("005930", dec!(70000));
        // ask(70100) 미만 지정가 → 큐 등록
        let request = create_buy_request("005930", dec!(10), Some(dec!(69500)));

        let result = engine.submit_limit_order(&request, &ticker, "test_strategy");
        assert!(result.is_ok());
        let (order_id, fill) = result.unwrap();
        assert!(fill.is_none());

        // 미체결 목록에 있어야 함
        let pending = engine.get_pending_orders("test_strategy");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].order_id, order_id);

        // 예약금 확인
        let reserved = engine.get_reserved_amount(&order_id);
        assert!(reserved > Decimal::ZERO);
    }

    #[test]
    fn test_limit_order_fill_on_tick() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), Decimal::ZERO);
        let ticker = create_test_ticker("005930", dec!(70000));
        let request = create_buy_request("005930", dec!(10), Some(dec!(69500)));

        let (_, _) = engine
            .submit_limit_order(&request, &ticker, "test_strategy")
            .unwrap();

        // 가격 하락 → 체결
        let new_ticker = create_test_ticker("005930", dec!(69400));
        let orderbook = create_test_orderbook("005930", dec!(69400));
        let fills = engine.on_price_tick("005930", &new_ticker, &orderbook);

        assert_eq!(fills.len(), 1);
        assert!(fills[0].fill_price <= dec!(69500)); // 지정가 이하 체결
    }

    #[test]
    fn test_cancel_order() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), Decimal::ZERO);
        let ticker = create_test_ticker("005930", dec!(70000));
        let request = create_buy_request("005930", dec!(10), Some(dec!(69500)));

        let (order_id, _) = engine
            .submit_limit_order(&request, &ticker, "test_strategy")
            .unwrap();

        let result = engine.cancel_order(&order_id);
        assert!(result.is_some());
        let cancel = result.unwrap();
        assert_eq!(cancel.strategy_id, "test_strategy");
        assert!(cancel.released_amount > Decimal::ZERO);

        // 미체결 목록에서 제거됨
        let pending = engine.get_pending_orders("test_strategy");
        assert!(pending.is_empty());
    }

    #[test]
    fn test_stop_order_trigger() {
        let mut engine = MockOrderEngine::new(dec!(0.00015), Decimal::ZERO);
        let mut request = create_buy_request("005930", dec!(10), None);
        request.order_type = OrderType::StopLoss;
        request.stop_price = Some(dec!(71000));

        let order_id = engine.submit_stop_order(&request, "test_strategy");
        assert!(order_id.is_ok());

        // 스톱 미도달
        let ticker = create_test_ticker("005930", dec!(70000));
        let orderbook = create_test_orderbook("005930", dec!(70000));
        let fills = engine.on_price_tick("005930", &ticker, &orderbook);
        assert!(fills.is_empty());

        // 스톱 도달 → 시장가 체결
        let ticker = create_test_ticker("005930", dec!(71100));
        let orderbook = create_test_orderbook("005930", dec!(71100));
        let fills = engine.on_price_tick("005930", &ticker, &orderbook);
        assert_eq!(fills.len(), 1);
    }
}
