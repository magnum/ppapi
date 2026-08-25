# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/transaction_sync"

# Regression: shares/quote/per_share must round-trip through the sheet
# without being quantized to 2 decimals (previously parse_extra routed
# them through parse_signed_cents, losing precision and causing sync
# to propose the same portfolio updates forever).
class TransactionSyncRoundtripTest < Minitest::Test
  SYNC = PortfolioPerformanceApi::TransactionSync
  SCALE = SYNC::SHARE_SCALE

  def parse_extra(key, value)
    SYNC.send(:parse_extra, key, value)
  end

  def test_shares_roundtrip_keeps_full_precision
    raw = (0.0323 * SCALE).round # 3_230_000
    cell = SYNC.send(:format_extra, :shares, raw)
    assert_equal raw, parse_extra(:shares, cell)
    assert_equal raw, parse_extra(:shares, cell.to_s)
  end

  def test_shares_with_eight_decimals
    raw = 1_095_538 # 0.01095538 BTC
    cell = SYNC.send(:format_extra, :shares, raw)
    assert_equal raw, parse_extra(:shares, cell)
  end

  def test_quote_roundtrip_keeps_more_than_two_decimals
    quote = 1544.07 / 6 # 257.345
    assert_in_delta quote, parse_extra(:quote, quote), 1e-9
    assert_in_delta quote, parse_extra(:quote, quote.to_s), 1e-9
    assert_in_delta quote, parse_extra(:per_share, quote.to_s), 1e-9
  end

  def test_decimal_parsing_handles_locale_separators
    assert_in_delta 1234.5678, parse_extra(:quote, "1.234,5678"), 1e-9
    assert_in_delta 1234.5678, parse_extra(:quote, "1,234.5678"), 1e-9
    assert_in_delta 0.0323, parse_extra(:quote, "0,0323"), 1e-9
  end

  def test_fees_taxes_net_still_parse_as_cents
    assert_equal 1234, parse_extra(:fees, "12.34")
    assert_equal 1234, parse_extra(:taxes, "-12.34")
    assert_equal 1234, parse_extra(:net, 12.339)
  end

  def test_extra_equal_uses_relative_tolerance
    assert SYNC.send(:extra_equal?, :quote, 257.345, 257.34500000000003)
    refute SYNC.send(:extra_equal?, :quote, 257.345, 257.35)
    assert SYNC.send(:extra_equal?, :shares, 3_230_000, 3_230_000)
    refute SYNC.send(:extra_equal?, :shares, 3_230_000, 3_000_000)
  end

  def test_same_proto_ignores_derived_extras
    keys = SYNC::SECURITIES_EXTRA_KEYS - SYNC::DERIVED_EXTRA_KEYS - SYNC::SECURITY_REF_KEYS
    assert_includes keys, :shares
    refute_includes keys, :quote
    refute_includes keys, :net
    refute_includes keys, :symbol
    refute_includes keys, :isin
  end
end
