# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/transaction_sync"
require_relative "../lib/portfolio_performance_api/transaction_types"

class TransactionTypesTest < Minitest::Test
  include PortfolioFixtures

  TYPES = PortfolioPerformanceApi::TransactionTypes
  SYNC = PortfolioPerformanceApi::TransactionSync

  def test_java_xml_names_map_to_protobuf_enums
    assert_equal "PURCHASE", TYPES.normalize("BUY")
    assert_equal "SALE", TYPES.normalize("SELL")
    assert_equal "FEE", TYPES.normalize("FEES")
    assert_equal "TAX", TYPES.normalize("TAXES")
    assert_equal "DIVIDEND", TYPES.normalize("DIVIDENDS")
    assert_equal "FEE_REFUND", TYPES.normalize("FEES_REFUND")
    assert_equal "INBOUND_DELIVERY", TYPES.normalize("DELIVERY_INBOUND")
    assert_equal "OUTBOUND_DELIVERY", TYPES.normalize("DELIVERY_OUTBOUND")
    assert_equal "CASH_TRANSFER", TYPES.normalize("TRANSFER_IN")
    assert_equal "CASH_TRANSFER", TYPES.normalize("TRANSFER_OUT")
    assert_equal "SECURITY_TRANSFER", TYPES.normalize("TRANSFER_IN", kind: :securities)
    refute TYPES.proto?("BUY")
    refute TYPES.proto?("FEES")
    refute TYPES.proto?("TRANSFER_IN")
    refute TYPES.proto?("DIVIDENDS")
  end

  def test_italian_and_csv_labels
    assert_equal "PURCHASE", TYPES.normalize("Compra")
    assert_equal "REMOVAL", TYPES.normalize("Prelievo")
    assert_equal "FEE", TYPES.normalize("Commissioni")
    assert_equal "TAX", TYPES.normalize("Tasse")
    assert_equal "CASH_TRANSFER", TYPES.normalize("Transfer (Inbound)")
    assert_equal "CASH_TRANSFER", TYPES.normalize("Trasferimento (in entrata)")
    assert_equal "INBOUND_DELIVERY", TYPES.normalize("Delivery (Inbound)")
    assert_equal "INBOUND_DELIVERY", TYPES.normalize("Trasferimento Titoli (in entrata)")
  end

  def test_unknown_type_falls_back_to_sign_not_raw_upcase
    assert_equal "DEPOSIT", TYPES.normalize("FOOBAR", 1_000)
    assert_equal "REMOVAL", TYPES.normalize("FOOBAR", -1_000)
    assert_nil TYPES.normalize("FOOBAR")
    assert_nil TYPES.coerce("FEE", kind: :securities)
  end

  def test_sheet_java_names_become_proto_types
    buy = SYNC.from_sheet_row(
      ["2026-08-15", "BUY", "-99.00", "EUR", "VWCE", "", ""],
      "EUR",
      currency: "EUR"
    )
    fees = SYNC.from_sheet_row(
      ["2026-08-15", "FEES", "-2.50", "EUR", "Canone", "", ""],
      "EUR",
      currency: "EUR"
    )
    taxes = SYNC.from_sheet_row(
      ["2026-08-15", "TAXES", "-1.00", "EUR", "Bollo", "", ""],
      "EUR",
      currency: "EUR"
    )
    dividends = SYNC.from_sheet_row(
      ["2026-08-15", "DIVIDENDS", "10.00", "EUR", "Coupon", "", ""],
      "EUR",
      currency: "EUR"
    )
    transfer = SYNC.from_sheet_row(
      ["2026-08-15", "TRANSFER_IN", "50.00", "EUR", "Giro", "Risparmio", ""],
      "EUR",
      currency: "EUR"
    )
    unknown = SYNC.from_sheet_row(
      ["2026-08-15", "FOOBAR", "-9.00", "EUR", "Visa", "", ""],
      "EUR",
      currency: "EUR"
    )
    fee_on_securities = SYNC.from_sheet_row(
      ["2026-08-15", "FEE", "-9.00", "EUR", "Canone", "", ""],
      "Crypto",
      currency: "EUR",
      kind: :securities
    )
    deposit_on_securities = SYNC.from_sheet_row(
      ["2026-08-15", "DEPOSIT", "10.00", "EUR", "Airdrop", "", ""],
      "Crypto",
      currency: "EUR",
      kind: :securities
    )

    assert_equal "PURCHASE", buy.type
    assert_equal "FEE", fees.type
    assert_equal "TAX", taxes.type
    assert_equal "DIVIDEND", dividends.type
    assert_equal "CASH_TRANSFER", transfer.type
    assert_equal "REMOVAL", unknown.type
    assert_nil fee_on_securities
    assert_equal "INBOUND_DELIVERY", deposit_on_securities.type
  end

  def test_apply_skips_java_names_and_incomplete_cross_entries
    client = protobuf_client
    cash = SYNC.vehicles(client).find { |vehicle| vehicle.name == "Conto corrente" }
    before = client.transactions.size
    created = [
      SYNC::Record.new(
        id: "a", account_name: "Conto corrente", date: Date.new(2026, 8, 15),
        type: "BUY", signed_cents: -9_900, currency: "EUR", description: "orphan buy",
        destination: "", uuid: "", extras: {}
      ),
      SYNC::Record.new(
        id: "b", account_name: "Conto corrente", date: Date.new(2026, 8, 15),
        type: "FEES", signed_cents: -250, currency: "EUR", description: "canone",
        destination: "", uuid: "", extras: {}
      )
    ]

    applied = SYNC.apply_portfolio!(client, cash, created)

    assert_equal 1, applied
    assert_equal before + 1, client.transactions.size
    assert_equal :FEE, client.transactions.last.type
    refute_includes client.transactions.map { |tx| tx.type.to_s }, "BUY"
    refute_includes client.transactions.map { |tx| tx.type.to_s }, "FEES"
  end

  def test_purchase_without_security_is_not_written
    client = protobuf_client
    cash = SYNC.vehicles(client).find { |vehicle| vehicle.name == "Conto corrente" }
    before = client.transactions.size
    created = SYNC::Record.new(
      id: "c", account_name: "Conto corrente", date: Date.new(2026, 8, 15),
      type: "PURCHASE", signed_cents: -9_900, currency: "EUR", description: "VWCE",
      destination: "Deposito titoli", uuid: "", extras: {}
    )

    applied = SYNC.apply_portfolio!(client, cash, [created])

    assert_equal 0, applied
    assert_equal before, client.transactions.size
  end

  def test_cash_transfer_without_counterpart_uuid_is_not_loadable
    tx = PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "u1",
      type: :CASH_TRANSFER,
      account: "acc-cash",
      otherAccount: "acc-savings",
      currencyCode: "EUR",
      amount: 10_000
    )
    refute TYPES.loadable?(tx)

    tx.otherUuid = "other"
    assert TYPES.loadable?(tx)
  end
end
