# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportBuilderTest < Minitest::Test
  include PortfolioFixtures

  def test_deposit_does_not_write_security_or_cross_entry
    client = protobuf_client
    account = cash(client)
    tx = build(client, account, row(Date.new(2025, 10, 28), "Titoli AMAZON", 454_364, :DEPOSIT, security: "AMAZON.COM"))

    assert_equal :DEPOSIT, tx.type
    refute tx.has_security?
    refute tx.has_portfolio?
    refute tx.has_otherUuid?
    assert_match(/\Appapi import \d{8}T\d{6}\z/, tx.source)
  end

  def test_purchase_and_sale_stamp_cross_entry_and_shares
    client = protobuf_client
    account = cash(client)
    buy = build(
      client,
      account,
      row(
        Date.new(2026, 8, 15),
        "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
        9_900,
        :REMOVAL,
        security: "VWCE",
        offset_account: "Deposito titoli"
      )
    )
    sell = build(
      client,
      account,
      row(
        Date.new(2026, 8, 15),
        "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
        9_900,
        :DEPOSIT,
        security: "VWCE",
        offset_account: "Deposito titoli"
      )
    )

    assert_equal :PURCHASE, buy.type
    assert_equal :SALE, sell.type
    assert_equal "port-titoli", buy.portfolio
    assert_equal "sec-etf", buy.security
    assert_equal 1_000_000_000, buy.shares
    refute buy.otherUuid.to_s.empty?
    assert buy.has_otherUpdatedAt?
    refute buy.has_otherAccount?
  end

  def test_same_currency_transfer_swaps_inbound_legs
    client = protobuf_client
    account = cash(client)
    out = build(client, account, row(Date.new(2026, 8, 15), "giro", 10_000, :REMOVAL, offset_account: "Risparmio"))
    inbound = build(client, account, row(Date.new(2026, 8, 15), "giro", 10_000, :DEPOSIT, offset_account: "Risparmio"))

    assert_equal :CASH_TRANSFER, out.type
    assert_equal "acc-cash", out.account
    assert_equal "acc-savings", out.otherAccount
    assert_equal 10_000, out.amount
    assert_empty out.units

    assert_equal "acc-savings", inbound.account
    assert_equal "acc-cash", inbound.otherAccount
    refute out.otherUuid.to_s.empty?
  end

  def test_cross_currency_transfer_adds_gross_value
    client = protobuf_client
    client.accounts << PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-usd", name: "USD010069756", currencyCode: "USD"
    )
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-fx",
      type: :CASH_TRANSFER,
      account: "acc-cash",
      otherAccount: "acc-usd",
      currencyCode: "EUR",
      amount: 4_000,
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2025, 10, 29).to_i),
      units: [
        PortfolioPerformanceApi::Proto::PTransactionUnit.new(
          type: :GROSS_VALUE,
          amount: 4_000,
          currencyCode: "EUR",
          fxAmount: 4_648,
          fxCurrencyCode: "USD"
        )
      ]
    )
    usd = client.accounts.find { |account| account.uuid == "acc-usd" }
    inbound = build(client, usd, row(Date.new(2025, 10, 29), "Cambio", 4_648, :DEPOSIT, offset_account: "Conto corrente"))

    assert_equal :CASH_TRANSFER, inbound.type
    assert_equal "acc-cash", inbound.account
    assert_equal "acc-usd", inbound.otherAccount
    assert_equal "EUR", inbound.currencyCode
    assert_equal 4_000, inbound.amount
    assert inbound.units.first.has_fxRateToBase?
  end

  def test_buy_sell_rejects_cash_offset_and_missing_client
    client = protobuf_client
    account = cash(client)
    cash_offset = row(
      Date.new(2026, 8, 15),
      "Titoli VWCE Qta/Val.nom. 10",
      9_900,
      :REMOVAL,
      security: "VWCE",
      offset_account: "Risparmio"
    )
    error = assert_raises(ArgumentError) { build(client, account, cash_offset) }
    assert_includes error.message, "securities account"

    error = assert_raises(ArgumentError) { build(nil, account, cash_offset) }
    assert_includes error.message, "client required"

    error = assert_raises(ArgumentError) do
      build(nil, account, row(Date.new(2026, 8, 15), "giro", 1, :REMOVAL, offset_account: "Risparmio"))
    end
    assert_includes error.message, "client required"

    error = assert_raises(ArgumentError) do
      build(
        client,
        account,
        row(
          Date.new(2026, 8, 15),
          "Titoli AMAZON Qta/Val.nom. 1",
          1,
          :REMOVAL,
          security: "AMAZON.COM",
          offset_account: "Deposito titoli"
        )
      )
    end
    assert_includes error.message, "security not found"

    error = assert_raises(ArgumentError) do
      build(client, account, row(Date.new(2026, 8, 15), "giro", 1, :REMOVAL, offset_account: "missing-account"))
    end
    assert_includes error.message, "offset account not found"
  end

  def test_cross_entry_repair_keeps_existing_uuid_and_skips_deposit
    client = protobuf_client
    transfer = client.transactions.find { |tx| tx.uuid == "tx-3" }
    purchase = client.transactions.find { |tx| tx.uuid == "tx-buy" }
    deposit = client.transactions.find { |tx| tx.uuid == "tx-1" }
    transfer.otherUuid = "keep-me"

    stamped = PortfolioPerformanceApi::FinecoImport.repair_cross_entries!(client)

    assert_equal 2, stamped
    assert_equal "keep-me", transfer.otherUuid
    assert transfer.has_otherUpdatedAt?
    refute purchase.otherUuid.to_s.empty?
    refute deposit.has_otherUuid?
    assert_equal 0, PortfolioPerformanceApi::FinecoImport.repair_cross_entries!(client)

    transfer = PortfolioPerformanceApi::Proto::PTransaction.new(uuid: "sec-xfer", type: :SECURITY_TRANSFER)
    client.transactions << transfer
    assert_equal 1, PortfolioPerformanceApi::FinecoImport.repair_cross_entries!(client)
    refute transfer.otherUuid.to_s.empty?
  end

  def test_writer_stamps_same_source_on_batch
    client = protobuf_client
    account = cash(client)
    at = Time.utc(2026, 8, 17, 0, 24, 11)
    before = client.transactions.size
    imported = PortfolioPerformanceApi::FinecoImport.append!(
      client,
      account,
      [
        row(Date.new(2026, 8, 15), "VISA", 9_900, :REMOVAL),
        row(Date.new(2026, 8, 16), "Stipendio", 100_000, :DEPOSIT)
      ],
      at: at
    )

    assert_equal 2, imported
    client.transactions.drop(before).each do |tx|
      assert_equal "ppapi import 20260817T002411", tx.source
    end
  end

  def test_prepare_matches_types_excludes_and_partitions
    client = protobuf_client
    account = cash(client)
    rows = [
      row(Date.new(2026, 8, 14), "Cambio valuta Compravendita Divise", 100, :DEPOSIT),
      row(Date.new(2026, 8, 15), "VISA DEBIT", 9_900, :REMOVAL),
      row(
        Date.new(2026, 8, 16),
        "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
        9_900,
        :REMOVAL,
        raw: ["Compravendita Titoli VWCE Qta/Val.nom. 10,000000"]
      )
    ]
    result = PortfolioPerformanceApi::FinecoImport.prepare(
      client,
      account,
      rows,
      security_specs: ["/Compravendita Titoli (.+?) Qta/"],
      offset_specs: ["/Compravendita Titoli/Deposito titoli", "/Compravendita Divise/Risparmio"],
      exclude: "cambio valuta"
    )

    assert_equal ["Cambio valuta Compravendita Divise"], result.excluded.map(&:description)
    visa = result.candidates.find { |item| item.description == "VISA DEBIT" }
    buy = result.candidates.find { |item| item.description.include?("VWCE") }
    assert visa
    assert buy
    assert_equal :REMOVAL, visa.proto_type
    assert_equal :PURCHASE, buy.proto_type
    assert_equal "VWCE", buy.security
    assert_equal "Deposito titoli", buy.offset_account
    assert_empty result.existing
    assert_equal 1, result.skipped.size
    assert_equal "matched --exclude", result.skipped.first.reason
  end

  def test_prepare_rejects_unknown_matched_security
    client = protobuf_client
    account = cash(client)
    rows = [
      row(
        Date.new(2026, 8, 16),
        "Compravendita Titoli AMAZON.COM Qta/Val.nom. 1,000000",
        1_000,
        :REMOVAL,
        raw: ["Compravendita Titoli AMAZON.COM Qta/Val.nom. 1,000000"]
      )
    ]

    result = PortfolioPerformanceApi::FinecoImport.prepare(
      client,
      account,
      rows,
      security_specs: ["/Compravendita Titoli (.+?) Qta/"],
      offset_specs: ["/Compravendita Titoli/Deposito titoli"]
    )

    assert_empty result.candidates
    assert_equal 1, result.skipped.size
    assert_equal "security not found: AMAZON.COM", result.skipped.first.reason
    assert_includes result.skipped.first.row.description, "AMAZON.COM"
  end

  private

  def cash(client)
    client.accounts.find { |account| account.uuid == "acc-cash" }
  end

  def build(client, account, row)
    PortfolioPerformanceApi::FinecoImport.build_transaction(row, account, client: client)
  end

  def row(date, description, cents, type, security: nil, offset_account: nil, raw: nil)
    PortfolioPerformanceApi::FinecoXls::Row.new(
      date: date,
      description: description,
      amount_cents: cents,
      type: type,
      security: security,
      offset_account: offset_account,
      raw: raw
    )
  end
end
