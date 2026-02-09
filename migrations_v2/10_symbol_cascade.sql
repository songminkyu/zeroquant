-- =============================================================================
-- 10_symbol_cascade
-- Symbol 연쇄 삭제 + 고아 데이터 정리 DB 함수
-- =============================================================================
-- 통합 마이그레이션 파일 (자동 생성)
-- 원본 파일: ["23_"]
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Source: 23_symbol_cascade
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cleanup_orphan_symbol_data()
RETURNS TABLE(table_name TEXT, deleted_count BIGINT) AS $$
DECLARE
    _del BIGINT;
BEGIN

    DELETE FROM score_history WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'score_history'; deleted_count := _del; RETURN NEXT;
    END IF;


    DELETE FROM ohlcv WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'ohlcv'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM ohlcv_metadata WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'ohlcv_metadata'; deleted_count := _del; RETURN NEXT;
    END IF;


    DELETE FROM execution_cache WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'execution_cache'; deleted_count := _del; RETURN NEXT;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_name = 'execution_cache_meta' AND c.column_name = 'symbol') THEN
        DELETE FROM execution_cache_meta WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
        GET DIAGNOSTICS _del = ROW_COUNT;
        IF _del > 0 THEN
            table_name := 'execution_cache_meta'; deleted_count := _del; RETURN NEXT;
        END IF;
    END IF;

    DELETE FROM trade_executions WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'trade_executions'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM position_snapshots WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'position_snapshots'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM positions WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'positions'; deleted_count := _del; RETURN NEXT;
    END IF;


    DELETE FROM mock_executions WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'mock_executions'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM mock_positions WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'mock_positions'; deleted_count := _del; RETURN NEXT;
    END IF;


    DELETE FROM price_snapshot WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'price_snapshot'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM reality_check WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'reality_check'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM watchlist_item WHERE symbol NOT IN (SELECT ticker FROM symbol_info);
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'watchlist_item'; deleted_count := _del; RETURN NEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_orphan_symbol_data() IS
'symbol_info에 없는 심볼의 고아 데이터를 모든 관련 테이블에서 삭제. 삭제된 테이블별 건수 반환.';

CREATE OR REPLACE FUNCTION delete_symbol_cascade(p_ticker TEXT, p_market TEXT)
RETURNS TABLE(table_name TEXT, deleted_count BIGINT) AS $$
DECLARE
    _del BIGINT;
    _symbol_id UUID;
BEGIN
    SELECT id INTO _symbol_id FROM symbol_info WHERE ticker = p_ticker AND market = p_market;

    IF _symbol_id IS NULL THEN
        RAISE EXCEPTION 'symbol_info not found: ticker=%, market=%', p_ticker, p_market;
    END IF;



    DELETE FROM ohlcv WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'ohlcv'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM ohlcv_metadata WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'ohlcv_metadata'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM score_history WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'score_history'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM execution_cache WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'execution_cache'; deleted_count := _del; RETURN NEXT;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'execution_cache_meta' AND column_name = 'symbol') THEN
        DELETE FROM execution_cache_meta WHERE symbol = p_ticker;
        GET DIAGNOSTICS _del = ROW_COUNT;
        IF _del > 0 THEN
            table_name := 'execution_cache_meta'; deleted_count := _del; RETURN NEXT;
        END IF;
    END IF;

    DELETE FROM trade_executions WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'trade_executions'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM position_snapshots WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'position_snapshots'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM positions WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'positions'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM mock_executions WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'mock_executions'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM mock_positions WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'mock_positions'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM price_snapshot WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'price_snapshot'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM reality_check WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'reality_check'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM watchlist_item WHERE symbol = p_ticker;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'watchlist_item'; deleted_count := _del; RETURN NEXT;
    END IF;

    DELETE FROM symbol_info WHERE id = _symbol_id;
    GET DIAGNOSTICS _del = ROW_COUNT;
    IF _del > 0 THEN
        table_name := 'symbol_info'; deleted_count := _del; RETURN NEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION delete_symbol_cascade(TEXT, TEXT) IS
'특정 심볼(ticker+market)의 symbol_info 삭제 시 관련 데이터를 모든 테이블에서 연쇄 삭제. 삭제된 테이블별 건수 반환.';

