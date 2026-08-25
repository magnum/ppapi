# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportKindTest < Minitest::Test
  def test_plain_cash_follows_fineco_sign
    assert_equal :REMOVAL, kind(type: :REMOVAL)
    assert_equal :DEPOSIT, kind(type: :DEPOSIT)
  end

  def test_offset_without_security_is_cash_transfer_either_sign
    assert_equal :CASH_TRANSFER, kind(type: :REMOVAL, offset_account: "EUR010069756")
    assert_equal :CASH_TRANSFER, kind(type: :DEPOSIT, offset_account: "EUR010069756")
  end

  def test_security_and_offset_are_buy_or_sell
    assert_equal :PURCHASE, kind(type: :REMOVAL, security: "VWCE", offset_account: "titoli")
    assert_equal :SALE, kind(type: :DEPOSIT, security: "VWCE", offset_account: "titoli")
  end

  def test_security_without_offset_is_deposit_without_buy_sell
    assert_equal :DEPOSIT, kind(type: :REMOVAL, security: "VWCE")
    assert_equal :DEPOSIT, kind(type: :DEPOSIT, security: "VWCE")
  end

  def test_whitespace_security_or_offset_is_absent
    assert_equal :REMOVAL, kind(type: :REMOVAL, security: "  ", offset_account: "\t")
    assert_equal :CASH_TRANSFER, kind(type: :DEPOSIT, security: " ", offset_account: "EUR")
    assert_equal :DEPOSIT, kind(type: :REMOVAL, security: "VWCE", offset_account: "  ")
  end

  def test_effective_prefers_explicit_proto_type
    row = row_for(type: :REMOVAL, offset_account: "EUR")
    row.proto_type = :DEPOSIT

    assert_equal :CASH_TRANSFER, PortfolioPerformanceApi::FinecoImport.portfolio_type(row)
    assert_equal :DEPOSIT, PortfolioPerformanceApi::FinecoImport.effective_type(row)
  end

  def test_apply_sets_proto_type_on_each_row
    rows = [row_for(type: :REMOVAL, offset_account: "EUR"), row_for(type: :DEPOSIT, security: "VWCE")]
    PortfolioPerformanceApi::FinecoImport.assign_types!(rows, nil, nil)

    assert_equal :CASH_TRANSFER, rows[0].proto_type
    assert_equal :DEPOSIT, rows[1].proto_type
  end

  def test_preview_labels_use_written_proto_type
    inbound = row_for(type: :DEPOSIT, offset_account: "EUR")
    outbound = row_for(type: :REMOVAL, offset_account: "EUR")

    assert_equal "CASH_TRANSFER", PortfolioPerformanceApi::FinecoImport.preview_type(inbound)
    assert_equal "CASH_TRANSFER", PortfolioPerformanceApi::FinecoImport.preview_type(outbound)
    assert_equal "DEPOSIT", PortfolioPerformanceApi::FinecoImport.preview_type(row_for(type: :DEPOSIT))
    assert_equal "PURCHASE",
                 PortfolioPerformanceApi::FinecoImport.preview_type(row_for(type: :REMOVAL, security: "VWCE", offset_account: "t"))
  end

  def test_buy_sell_and_cross_entry_predicates
    assert PortfolioPerformanceApi::FinecoImport.buy_sell?(:PURCHASE)
    assert PortfolioPerformanceApi::FinecoImport.buy_sell?("SALE")
    refute PortfolioPerformanceApi::FinecoImport.buy_sell?(:CASH_TRANSFER)
    assert PortfolioPerformanceApi::FinecoImport.cross_entry?(:SECURITY_TRANSFER)
    refute PortfolioPerformanceApi::FinecoImport.cross_entry?(:DEPOSIT)
  end

  private

  def kind(**fields)
    PortfolioPerformanceApi::FinecoImport.portfolio_type(row_for(**fields))
  end

  def row_for(type:, security: nil, offset_account: nil)
    PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 17),
      description: "x",
      amount_cents: 100,
      type: type,
      security: security,
      offset_account: offset_account
    )
  end
end
