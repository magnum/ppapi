# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "fileutils"
require "tmpdir"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"
require_relative "../lib/portfolio_performance_api/portfolio_store"
require_relative "../lib/portfolio_performance_api/checkbox_selection"

class FinecoImportTest < Minitest::Test
  include PortfolioFixtures

  def test_parse_italian_amounts_and_dates
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Estratto conto Fineco"],
      [],
      ["Data_Operazione", "Data_Valuta", "Entrate", "Uscite", "Descrizione"],
      ["01/06/2024", "01/06/2024", "1.234,56", "", "Stipendio"],
      ["02/06/2024", "02/06/2024", "", "12,00", "Commissione"],
      ["not-a-date", "not-a-date", "10,00", "", "skip"],
      ["03/06/2024", "03/06/2024", "10,00", "", ""]
    ])

    assert_equal 2, rows.size
    assert_equal Date.new(2024, 6, 1), rows[0].date
    assert_equal "Stipendio", rows[0].description
    assert_equal 123_456, rows[0].amount_cents
    assert_equal :DEPOSIT, rows[0].type
    assert_equal Date.new(2024, 6, 2), rows[1].date
    assert_equal 1_200, rows[1].amount_cents
    assert_equal :REMOVAL, rows[1].type
  end

  def test_uses_data_valuta_and_builds_note
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Data_Operazione", "Data_Valuta", "Entrate", "Uscite", "Descrizione", "Descrizione_Completa", "Stato", "Moneymap"],
      [Date.new(2026, 8, 14), Date.new(2026, 8, 12), nil, -83.13, "Pagamento Visa Debit", "IPER LONATO", "Contabilizzato", "Alimentari"],
      ["-", Date.new(2026, 8, 15), 4756.96, nil, "Cambio valuta", "Compravendita Divise", "Autorizzato", nil],
      [Date.new(2026, 8, 14), Date.new(2026, 8, 14), 2432, nil, "Stipendio", "Ord: INCODE", "Contabilizzato", "Stipendio"]
    ])

    assert_equal 3, rows.size
    assert_equal Date.new(2026, 8, 12), rows[0].date
    assert_equal :REMOVAL, rows[0].type
    assert_equal 8_313, rows[0].amount_cents
    assert_equal "Pagamento Visa Debit IPER LONATO Categoria: Alimentari", rows[0].description
    assert_equal Date.new(2026, 8, 15), rows[1].date
    assert_equal :DEPOSIT, rows[1].type
    assert_equal 475_696, rows[1].amount_cents
    assert_equal "Cambio valuta Compravendita Divise", rows[1].description
    assert_equal "Stipendio Ord: INCODE Categoria: Stipendio", rows[2].description
  end

  def test_skip_lines_uses_default_fineco_columns
    preamble = Array.new(13) { |index| ["meta #{index}"] }
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows(
      preamble + [
        ["-", Date.new(2026, 8, 15), nil, -99, "VISA DEBIT", "CRYPTO TAX - KOIN...", "Autorizzato", nil],
        [Date.new(2026, 8, 14), Date.new(2026, 8, 12), nil, -22.5, "Pagamento Visa Debit", "CAFFETT.GELAT.", "Contabilizzato", "Hotel Ristoranti e Viaggi"]
      ],
      skip_lines: 13
    )

    assert_equal 2, rows.size
    assert_equal Date.new(2026, 8, 15), rows[0].date
    assert_equal :REMOVAL, rows[0].type
    assert_equal 9_900, rows[0].amount_cents
    assert_equal "VISA DEBIT CRYPTO TAX - KOIN...", rows[0].description
    assert_equal "Pagamento Visa Debit CAFFETT.GELAT. Categoria: Hotel Ristoranti e Viaggi", rows[1].description
  end

  def test_skip_lines_seven_reads_usd_style_export
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows(
      [
        ["Conto Corrente: USD010069756"],
        ["Intestazione Conto Corrente"],
        ["Periodo Dal: 18/05/2026"],
        [],
        ["Risultati Ricerca"],
        [],
        ["Data", "Data_Valuta", "Entrate", "Uscite", "Descrizione", "Descrizione_Completa"],
        [Date.new(2026, 5, 16), Date.new(2026, 5, 16), nil, -100, "Bonifico", "Test USD"],
        ["16/05/2024", "16/05/2024", "50,00", nil, "Bonifico", "Entrata"]
      ],
      skip_lines: 7
    )

    assert_equal 2, rows.size
    assert_equal Date.new(2026, 5, 16), rows[0].date
    assert_equal :REMOVAL, rows[0].type
    assert_equal 10_000, rows[0].amount_cents
    assert_equal "Bonifico Test USD", rows[0].description
    assert_equal Date.new(2024, 5, 16), rows[1].date
    assert_equal :DEPOSIT, rows[1].type
    assert_equal 5_000, rows[1].amount_cents
  end

  def test_parse_import_test_usd_xlsx
    path = File.expand_path("../import/test_usd.xlsx", __dir__)
    skip "missing import/test_usd.xlsx" unless File.file?(path)

    rows = PortfolioPerformanceApi::FinecoXls.parse(path, skip_lines: 7)
    refute_empty rows
    assert rows.any? { |row| row.description.match?(/Compravendita Titoli/i) }
  end

  def test_default_skip_lines_from_env
    previous = ENV["IMPORT_FINECO_XLS_SKIP_LINES"]
    ENV.delete("IMPORT_FINECO_XLS_SKIP_LINES")
    assert_equal 13, PortfolioPerformanceApi::FinecoXls.default_skip_lines
    ENV["IMPORT_FINECO_XLS_SKIP_LINES"] = "12"
    assert_equal 12, PortfolioPerformanceApi::FinecoXls.default_skip_lines
  ensure
    if previous.nil?
      ENV.delete("IMPORT_FINECO_XLS_SKIP_LINES")
    else
      ENV["IMPORT_FINECO_XLS_SKIP_LINES"] = previous
    end
  end

  def test_parse_signed_importo_column
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Data", "Descrizione", "Importo"],
      [Date.new(2024, 7, 1), "Accredito", "100,00"],
      ["02/07/2024", "Addebito", "-25,50"]
    ])

    assert_equal :DEPOSIT, rows[0].type
    assert_equal 10_000, rows[0].amount_cents
    assert_equal :REMOVAL, rows[1].type
    assert_equal 2_550, rows[1].amount_cents
  end

  def test_partition_existing_uses_identity_hash_one_to_one
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    visa = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "VISA DEBIT",
      amount_cents: 9_900,
      type: :REMOVAL
    )
    stipendio = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 16),
      description: "Stipendio",
      amount_cents: 100_000,
      type: :DEPOSIT
    )
    PortfolioPerformanceApi::FinecoImport.append!(client, account, [visa])

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing(
      [visa, visa, stipendio], client, account
    )

    assert_equal ["VISA DEBIT"], existing.map(&:description)
    assert_equal ["VISA DEBIT", "Stipendio"], missing.map(&:description)
  end

  def test_partition_existing_matches_pp_native_by_date_and_amount
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-pp-cash",
      type: :CASH_TRANSFER,
      account: "acc-cash",
      otherAccount: "acc-savings",
      currencyCode: "EUR",
      amount: 550_000,
      note: "Fineco export Movimenti",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 14).to_i)
    )
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 14),
      description: "Cambio valuta Compravendita Divise",
      amount_cents: 550_000,
      type: :REMOVAL,
      offset_account: "Risparmio"
    )

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([row], client, account)
    assert_equal [row], existing
    assert_empty missing
  end

  def test_partition_existing_matches_sale_by_security_and_shares
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-pp-sale",
      type: :SALE,
      account: "acc-cash",
      portfolio: "port-titoli",
      security: "sec-etf",
      currencyCode: "EUR",
      amount: 9_896,
      shares: 1_000_000_000,
      note: "Fineco export Movimenti Dc",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 14).to_i)
    )
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      amount_cents: 9_900,
      type: :DEPOSIT,
      security: "VWCE",
      offset_account: "Deposito titoli"
    )

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([row], client, account)
    assert_equal [row], existing
    assert_empty missing
  end

  def test_fineco_row_and_proto_share_identity
    account = PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-cash",
      name: "EUR010069756",
      currencyCode: "EUR"
    )
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "VISA DEBIT CRYPTO TAX",
      amount_cents: 9_900,
      type: :REMOVAL
    )
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account)
    proto = PortfolioPerformanceApi::TransactionSync.from_proto(tx, account)

    assert_match(/\Appapi import \d{8}T\d{6}\z/, tx.source)
    assert_equal proto.id, PortfolioPerformanceApi::FinecoImport.identity_for(row, account)
    assert_equal proto.id, PortfolioPerformanceApi::TransactionIdentity.id(
      "EUR010069756", Date.new(2026, 8, 15), -9_900, "VISA DEBIT CRYPTO TAX"
    )
  end

  def test_default_security_regexp_extracts_name_between_titoli_and_qta
    text = "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000"
    regexp, fixed = PortfolioPerformanceApi::FinecoImport.parse_match_spec(
      PortfolioPerformanceApi::FinecoImport::DEFAULT_SECURITY_SPEC
    )

    assert_equal "", fixed
    assert_equal "AMAZON.COM", regexp.match(text)[1]
    assert_equal "AMAZON.COM",
                 PortfolioPerformanceApi::FinecoImport.value_from_cells([text], regexp, fixed)
  end

  def test_parse_match_spec_capture_or_fixed_value
    regexp, fixed = PortfolioPerformanceApi::FinecoImport.parse_match_spec(
      "/Compravendita Titoli (.+?) Qta/"
    )
    assert_equal "", fixed
    assert_equal "AMAZON.COM", regexp.match("Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000")[1]

    regexp, account = PortfolioPerformanceApi::FinecoImport.parse_offset_spec(
      "/Compravendita Divise/USD010069756"
    )
    assert_equal "USD010069756", account
    assert "Cambio valuta Compravendita Divise".match?(regexp)
    refute "Stipendio".match?(regexp)

    regexp, account = PortfolioPerformanceApi::FinecoImport.parse_match_spec(
      "/Compravendita Titoli/fineco00109494"
    )
    assert_equal "fineco00109494", account
    assert "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000".match?(regexp)
  end

  def test_apply_matches_sets_security_and_offset_account_from_any_column
    buy = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli",
      amount_cents: 9_900,
      type: :REMOVAL,
      raw: ["15/08/2026", "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000"]
    )
    fx = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 14),
      description: "Cambio valuta",
      amount_cents: 475_696,
      type: :DEPOSIT,
      raw: ["Cambio valuta", "Compravendita Divise"]
    )
    other = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 16),
      description: "Stipendio",
      amount_cents: 100_000,
      type: :DEPOSIT,
      raw: ["Stipendio", "Ord: ACME"]
    )

    PortfolioPerformanceApi::FinecoImport.apply_matches!(
      [buy, fx, other],
      ["/Compravendita Titoli (.+?) Qta/"],
      ["/Compravendita Titoli/fineco00109494", "/Compravendita Divise/USD010069756"]
    )

    assert_equal "AMAZON.COM", buy.security
    assert_equal "fineco00109494", buy.offset_account
    assert_nil fx.security
    assert_equal "USD010069756", fx.offset_account
    assert_nil other.security
    assert_nil other.offset_account
  end

  def test_apply_matches_capture_wins_over_fixed_value
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      amount_cents: 1_000,
      type: :REMOVAL,
      raw: ["Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000"]
    )
    PortfolioPerformanceApi::FinecoImport.apply_matches!(
      [row],
      ["/Compravendita Titoli (.+?) Qta/IGNORED"],
      []
    )

    assert_equal "AMAZON.COM", row.security
  end

  def test_apply_matches_first_pattern_wins
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      amount_cents: 1_000,
      type: :REMOVAL,
      raw: ["Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000"]
    )
    PortfolioPerformanceApi::FinecoImport.apply_matches!(
      [row],
      ["/Compravendita Titoli (.+?) Qta/", "/Titoli (.+)$/"],
      []
    )

    assert_equal "AMAZON.COM", row.security
  end

  def test_validate_matches_requires_known_security_and_account
    client = protobuf_client
    missing_security = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "buy",
      amount_cents: 1_000,
      type: :REMOVAL,
      security: "AMAZON.COM"
    )
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [missing_security])
    end
    assert_includes error.message, "security not found: AMAZON.COM"

    missing_account = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "fx",
      amount_cents: 1_000,
      type: :DEPOSIT,
      offset_account: "USD010069756"
    )
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [missing_account])
    end
    assert_includes error.message, "offset account not found: USD010069756"
  end

  def test_identity_and_proto_include_security_and_offset_account
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      amount_cents: 9_900,
      type: :REMOVAL,
      security: "VWCE",
      offset_account: "Deposito titoli"
    )
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account, client: client)
    proto = PortfolioPerformanceApi::TransactionSync.from_proto(
      tx, account,
      names: PortfolioPerformanceApi::TransactionSync.uuid_names(client),
      security_names: PortfolioPerformanceApi::TransactionSync.security_names(client)
    )

    refute tx.has_otherAccount?
    assert_equal "port-titoli", tx.portfolio
    assert_equal "sec-etf", tx.security
    assert_equal :PURCHASE, tx.type
    refute tx.otherUuid.to_s.empty?
    assert tx.has_otherUpdatedAt?
    assert_equal proto.id, PortfolioPerformanceApi::FinecoImport.identity_for(row, account)
    assert_equal proto.id, PortfolioPerformanceApi::TransactionIdentity.id(
      "Conto corrente", Date.new(2026, 8, 15), -9_900,
      "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      "Deposito titoli",
      "VWCE"
    )

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([row], client, account)
    assert_empty existing
    assert_equal [row], missing

    PortfolioPerformanceApi::FinecoImport.append!(client, account, [row])
    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([row], client, account)
    assert_equal [row], existing
    assert_empty missing
  end

  def test_securities_offset_sets_portfolio_not_other_account
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      amount_cents: 9_900,
      type: :REMOVAL,
      security: "VWCE",
      offset_account: "Deposito titoli"
    )

    PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [row])
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account, client: client)
    proto = PortfolioPerformanceApi::TransactionSync.from_proto(
      tx, account,
      names: PortfolioPerformanceApi::TransactionSync.uuid_names(client),
      security_names: PortfolioPerformanceApi::TransactionSync.security_names(client)
    )

    refute tx.has_otherAccount?
    assert_equal :PURCHASE, tx.type
    assert_equal "port-titoli", tx.portfolio
    assert_equal "Deposito titoli", proto.destination
    assert_equal proto.id, PortfolioPerformanceApi::FinecoImport.identity_for(row, account)
  end

  def test_portfolio_type_from_security_offset_and_sign
    removal = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15), description: "x", amount_cents: 1_000, type: :REMOVAL
    )
    deposit = removal.dup
    deposit.type = :DEPOSIT

    assert_equal :REMOVAL, PortfolioPerformanceApi::FinecoImport.portfolio_type(removal)
    assert_equal :DEPOSIT, PortfolioPerformanceApi::FinecoImport.portfolio_type(deposit)

    removal.offset_account = "Risparmio"
    deposit.offset_account = "Risparmio"
    assert_equal :CASH_TRANSFER, PortfolioPerformanceApi::FinecoImport.portfolio_type(removal)
    assert_equal :CASH_TRANSFER, PortfolioPerformanceApi::FinecoImport.portfolio_type(deposit)

    removal.security = "VWCE"
    deposit.security = "VWCE"
    assert_equal :PURCHASE, PortfolioPerformanceApi::FinecoImport.portfolio_type(removal)
    assert_equal :SALE, PortfolioPerformanceApi::FinecoImport.portfolio_type(deposit)

    removal.offset_account = nil
    deposit.offset_account = nil
    assert_equal :DEPOSIT, PortfolioPerformanceApi::FinecoImport.portfolio_type(removal)
    assert_equal :DEPOSIT, PortfolioPerformanceApi::FinecoImport.portfolio_type(deposit)
  end

  def test_cash_transfer_outbound_and_inbound_accounts
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    outbound = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Cambio valuta Compravendita Divise",
      amount_cents: 198_000_000,
      type: :REMOVAL,
      offset_account: "Risparmio"
    )
    inbound = outbound.dup
    inbound.type = :DEPOSIT
    inbound.amount_cents = 4_648

    out_tx = PortfolioPerformanceApi::FinecoImport.build_transaction(outbound, account, client: client)
    in_tx = PortfolioPerformanceApi::FinecoImport.build_transaction(inbound, account, client: client)

    assert_equal :CASH_TRANSFER, out_tx.type
    assert_equal "acc-cash", out_tx.account
    assert_equal "acc-savings", out_tx.otherAccount

    assert_equal :CASH_TRANSFER, in_tx.type
    assert_equal "acc-savings", in_tx.account
    assert_equal "acc-cash", in_tx.otherAccount

    names = PortfolioPerformanceApi::TransactionSync.uuid_names(client)
    out_proto = PortfolioPerformanceApi::TransactionSync.from_proto(out_tx, account, names: names)
    in_proto = PortfolioPerformanceApi::TransactionSync.from_proto(in_tx, account, names: names)
    assert_equal out_proto.id, PortfolioPerformanceApi::FinecoImport.identity_for(outbound, account)
    assert_equal in_proto.id, PortfolioPerformanceApi::FinecoImport.identity_for(inbound, account)
  end

  def test_sale_with_security_and_offset
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      amount_cents: 9_900,
      type: :DEPOSIT,
      security: "VWCE",
      offset_account: "Deposito titoli"
    )
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account, client: client)

    assert_equal :SALE, tx.type
    assert_equal "acc-cash", tx.account
    assert_equal "port-titoli", tx.portfolio
    assert_equal "sec-etf", tx.security
    assert_equal 1_000_000_000, tx.shares
  end

  def test_cross_currency_offset_is_cash_transfer_with_fx_unit
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
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "USD010069756")
    outbound = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 14),
      description: "Cambio valuta Compravendita Divise",
      amount_cents: 550_000,
      type: :REMOVAL,
      offset_account: "Conto corrente"
    )
    inbound = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 29),
      description: "Cambio valuta Compravendita Divise",
      amount_cents: 4_648,
      type: :DEPOSIT,
      offset_account: "Conto corrente"
    )

    PortfolioPerformanceApi::FinecoImport.assign_types!([outbound, inbound], account, client)
    out_tx = PortfolioPerformanceApi::FinecoImport.build_transaction(outbound, account, client: client)
    in_tx = PortfolioPerformanceApi::FinecoImport.build_transaction(inbound, account, client: client)

    assert_equal :CASH_TRANSFER, outbound.proto_type
    assert_equal :CASH_TRANSFER, inbound.proto_type
    assert_equal "CASH_TRANSFER", PortfolioPerformanceApi::FinecoImport.preview_type(outbound)
    assert_equal "CASH_TRANSFER", PortfolioPerformanceApi::FinecoImport.preview_type(inbound)

    assert_equal :CASH_TRANSFER, out_tx.type
    assert_equal "acc-usd", out_tx.account
    assert_equal "acc-cash", out_tx.otherAccount
    assert_equal "USD", out_tx.currencyCode
    assert_equal 550_000, out_tx.amount
    unit = out_tx.units.first
    assert_equal :GROSS_VALUE, unit.type
    assert_equal 550_000, unit.amount
    assert_equal "USD", unit.currencyCode
    assert_equal "EUR", unit.fxCurrencyCode
    assert_equal (550_000 * 4_000 / 4_648.0).round, unit.fxAmount

    assert_equal :CASH_TRANSFER, in_tx.type
    assert_equal "acc-cash", in_tx.account
    assert_equal "acc-usd", in_tx.otherAccount
    assert_equal "EUR", in_tx.currencyCode
    assert_equal 4_000, in_tx.amount
    in_unit = in_tx.units.first
    assert_equal 4_000, in_unit.amount
    assert_equal "EUR", in_unit.currencyCode
    assert_equal 4_648, in_unit.fxAmount
    assert_equal "USD", in_unit.fxCurrencyCode
    assert in_unit.has_fxRateToBase?
    assert_equal 10, in_unit.fxRateToBase.scale
    assert_equal ["0200f2e14b"].pack("H*"), in_unit.fxRateToBase.value
    assert out_tx.units.first.has_fxRateToBase?
    refute out_tx.otherUuid.to_s.empty?
    assert out_tx.has_otherUpdatedAt?
    refute in_tx.otherUuid.to_s.empty?
    assert in_tx.has_otherUpdatedAt?
  end

  def test_repair_cross_entries_stamps_missing_other_uuid
    client = protobuf_client
    deposit = client.transactions.find { |tx| tx.uuid == "tx-1" }
    transfer = client.transactions.find { |tx| tx.uuid == "tx-3" }
    purchase = client.transactions.find { |tx| tx.uuid == "tx-buy" }

    refute transfer.has_otherUuid?
    refute purchase.has_otherUuid?

    stamped = PortfolioPerformanceApi::FinecoImport.repair_cross_entries!(client)

    assert_equal 2, stamped
    refute transfer.otherUuid.to_s.empty?
    assert transfer.has_otherUpdatedAt?
    refute purchase.otherUuid.to_s.empty?
    refute deposit.has_otherUuid?
    assert_equal 0, PortfolioPerformanceApi::FinecoImport.repair_cross_entries!(client)
  end

  def test_partition_existing_matches_fx_inbound_by_account_currency_amount
    client = protobuf_client
    client.accounts << PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-usd", name: "USD010069756", currencyCode: "USD"
    )
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-fx-in",
      type: :CASH_TRANSFER,
      account: "acc-cash",
      otherAccount: "acc-usd",
      currencyCode: "EUR",
      amount: 4_000,
      note: "Fineco export",
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
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "USD010069756")
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 29),
      description: "Cambio valuta Compravendita Divise",
      amount_cents: 4_648,
      type: :DEPOSIT,
      offset_account: "EUR010069756"
    )

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([row], client, account)
    assert_equal [row], existing
    assert_empty missing
  end

  def test_encode_decimal_matches_portfolio_performance_wire_format
    rate = PortfolioPerformanceApi::FinecoImport.encode_decimal(4_000.to_f / 4_648)
    assert_equal 10, rate.scale
    assert_equal 10, rate.precision
    assert_equal ["0200f2e14b"].pack("H*"), rate.value

    over_one = PortfolioPerformanceApi::FinecoImport.encode_decimal(550_000.to_f / 475_696)
    assert_equal 10, over_one.scale
    assert_equal 11, over_one.precision
    assert_equal ["02b12635e3"].pack("H*"), over_one.value
  end

  def test_extract_shares_from_fineco_qta
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 28),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      amount_cents: 454_364,
      type: :DEPOSIT
    )
    assert_equal 2_000_000_000, PortfolioPerformanceApi::FinecoImport.extract_shares(row)
  end

  def test_deposit_with_matched_security_does_not_write_security
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 28),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      amount_cents: 454_364,
      type: :DEPOSIT,
      security: "AMAZON.COM"
    )
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account, client: client)

    assert_equal :DEPOSIT, tx.type
    refute tx.has_security?
    refute tx.has_portfolio?
    assert_equal PortfolioPerformanceApi::TransactionIdentity.id(
      "Conto corrente", Date.new(2025, 10, 28), 454_364,
      "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      "",
      ""
    ), PortfolioPerformanceApi::FinecoImport.identity_for(row, account)
  end

  def test_buy_sell_rejects_cash_offset
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      amount_cents: 9_900,
      type: :REMOVAL,
      security: "VWCE",
      offset_account: "Risparmio"
    )
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.build_transaction(row, account, client: client)
    end
    assert_includes error.message, "securities account"
  end

  def test_exclude_matching_drops_rows_when_any_column_matches
    rows = PortfolioPerformanceApi::FinecoXls.parse_rows([
      ["Data_Valuta", "Entrate", "Uscite", "Descrizione", "Descrizione_Completa"],
      ["01/06/2024", "10,00", "", "Stipendio", "Ord: ACME"],
      ["02/06/2024", "100,00", "", "Cambio valuta", "Compravendita Divise"],
      ["03/06/2024", "", "5,00", "Canone", "Conto"]
    ])

    kept = PortfolioPerformanceApi::FinecoXls.exclude_matching(rows, "compravendita valute|compravendita divise")
    assert_equal ["Stipendio Ord: ACME", "Canone Conto"], kept.map(&:description)

    excluded, also_kept = PortfolioPerformanceApi::FinecoXls.partition_excluded(
      rows, "compravendita valute|compravendita divise"
    )
    assert_equal ["Cambio valuta Compravendita Divise"], excluded.map(&:description)
    assert_equal kept.map(&:description), also_kept.map(&:description)

    assert_equal rows, PortfolioPerformanceApi::FinecoXls.exclude_matching(rows, "")
    assert_equal rows, PortfolioPerformanceApi::FinecoXls.exclude_matching(rows, nil)
  end

  def test_parse_import_test_xlsx_and_exclude_compravendita
    path = File.expand_path("../import/test.xlsx", __dir__)
    skip "missing import/test.xlsx" unless File.file?(path)

    rows = PortfolioPerformanceApi::FinecoXls.parse(path)
    assert_equal 692, rows.size

    kept = PortfolioPerformanceApi::FinecoXls.exclude_matching(rows, "compravendita")
    assert_equal 688, kept.size
    refute kept.any? { |row| Array(row.raw).any? { |cell| cell.to_s.match?(/compravendita/i) } }
  end

  def test_parse_xlsx_does_not_warn_about_zip_entry_dates
    path = %w[test_eur.xlsx test.xlsx].map { |name| File.expand_path("../import/#{name}", __dir__) }.find { |file| File.file?(file) }
    skip "missing import xlsx" unless path

    _stdout, stderr = capture_io { PortfolioPerformanceApi::FinecoXls.parse(path) }
    refute_includes stderr, "invalid date/time in zip entry"
  end

  def test_find_account_by_name_and_uuid
    client = protobuf_client
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente").uuid
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_account(client, "conto corrente").uuid
    assert_equal "acc-savings", PortfolioPerformanceApi::FinecoImport.find_account(client, "acc-savings").uuid
    assert_nil PortfolioPerformanceApi::FinecoImport.find_account(client, "missing")
    assert_nil PortfolioPerformanceApi::FinecoImport.find_account(client, "Deposito titoli")
    assert_equal :securities, PortfolioPerformanceApi::FinecoImport.find_vehicle(client, "Deposito titoli").kind
    assert_equal "port-titoli", PortfolioPerformanceApi::FinecoImport.find_vehicle(client, "Deposito titoli").uuid
  end

  def test_last_transaction_date_and_proto_mapping
    client = protobuf_client
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-dated",
      type: :DEPOSIT,
      account: "acc-cash",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2024, 3, 10).to_i),
      currencyCode: "EUR",
      amount: 500
    )

    assert_equal Date.new(2024, 3, 10), PortfolioPerformanceApi::FinecoImport.last_transaction_date(client, "acc-cash")
    assert_nil PortfolioPerformanceApi::FinecoImport.last_transaction_date(client, "acc-savings")

    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2024, 3, 11),
      description: "Bonifico ricevuto",
      amount_cents: 25_000,
      type: :DEPOSIT
    )
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(row, account)

    assert_equal :DEPOSIT, tx.type
    assert_equal "acc-cash", tx.account
    assert_equal "EUR", tx.currencyCode
    assert_equal 25_000, tx.amount
    assert_equal "Bonifico ricevuto", tx.note
    assert_equal Time.utc(2024, 3, 11).to_i, tx.date.seconds
    assert tx.uuid.match?(/\A[\da-f-]{36}\z/)
    assert tx.has_updatedAt?
  end

  def test_backup_path_uses_timestamp
    at = Time.new(2026, 8, 16, 2, 10, 11)
    path = PortfolioPerformanceApi::PortfolioStore.backup_path("/tmp/portfolio1.portfolio", at: at)
    assert_equal "/tmp/portfolio1-20260816T021011.portfolio", path
  end

  def test_checkbox_toggle_all_and_navigation
    state = PortfolioPerformanceApi::CheckboxSelection.new(%w[a b c])
    assert_equal 0, state.cursor
    state.toggle
    assert state.all_selected?
    assert_equal %w[a b c], state.selected_items

    state.toggle
    refute state.all_selected?
    assert_equal [], state.selected_items

    state.down
    state.toggle
    assert_equal ["a"], state.selected_items
    state.down
    state.toggle
    assert_equal %w[a b], state.selected_items
    state.up
    state.up
    state.toggle
    assert state.all_selected?
  end

  def test_parse_html_saved_as_xls
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transactions.xls")
      File.write(path, <<~HTML)
        <html><body><table>
          <tr><td>Estratto conto</td></tr>
          <tr><td>Data_Valuta</td><td>Descrizione</td><td>Entrate</td><td>Uscite</td></tr>
          <tr><td>15/07/2024</td><td>Bonifico</td><td>250,00</td><td></td></tr>
          <tr><td>16/07/2024</td><td>Canone</td><td></td><td>3,50</td></tr>
        </table></body></html>
      HTML

      rows = PortfolioPerformanceApi::FinecoXls.parse(path, skip_lines: 0)
      assert_equal 2, rows.size
      assert_equal Date.new(2024, 7, 15), rows[0].date
      assert_equal :DEPOSIT, rows[0].type
      assert_equal 25_000, rows[0].amount_cents
      assert_equal :REMOVAL, rows[1].type
      assert_equal 350, rows[1].amount_cents
    end
  end

  def test_parse_real_xls
    require "spreadsheet"

    Dir.mktmpdir do |dir|
      path = File.join(dir, "transactions.xls")
      book = Spreadsheet::Workbook.new
      sheet = book.create_worksheet
      sheet.row(0).replace ["FinecoBank"]
      sheet.row(2).replace ["Data_Valuta", "Descrizione", "Entrate", "Uscite"]
      sheet.row(3).replace [Date.new(2024, 8, 1), "Stipendio", 1500.0, ""]
      sheet.row(4).replace ["02/08/2024", "Prelievo", "", "50,00"]
      File.open(path, "wb") { |file| book.write(file) }

      rows = PortfolioPerformanceApi::FinecoXls.parse(path, skip_lines: 0)
      assert_equal 2, rows.size
      assert_equal Date.new(2024, 8, 1), rows[0].date
      assert_equal 150_000, rows[0].amount_cents
      assert_equal :DEPOSIT, rows[0].type
      assert_equal :REMOVAL, rows[1].type
      assert_equal 5_000, rows[1].amount_cents
    end
  end

  def test_store_roundtrip_appends_transactions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wallet.portfolio")
      File.binwrite(path, encrypted_protobuf)

      loaded = PortfolioPerformanceApi::PortfolioStore.load(path, password: "secret")
      account = PortfolioPerformanceApi::FinecoImport.find_account(loaded.client, "Conto corrente")
      before = loaded.client.transactions.size
      row = PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 1, 2),
        description: "Fineco import",
        amount_cents: 9_900,
        type: :REMOVAL
      )
      PortfolioPerformanceApi::FinecoImport.append!(loaded.client, account, [row])
      PortfolioPerformanceApi::PortfolioStore.save(loaded)

      reloaded = PortfolioPerformanceApi::PortfolioStore.load(path, password: "secret")
      assert_equal before + 1, reloaded.client.transactions.size
      imported = reloaded.client.transactions.last
      assert_equal :REMOVAL, imported.type
      assert_equal 9_900, imported.amount
      assert_equal "Fineco import", imported.note
      assert_equal "acc-cash", imported.account
      assert_match(/\Appapi import \d{8}T\d{6}\z/, imported.source)
    end
  end

  def test_append_sets_same_import_source_on_batch
    client = protobuf_client
    account = PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente")
    visa = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "VISA DEBIT",
      amount_cents: 9_900,
      type: :REMOVAL
    )
    stipendio = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 16),
      description: "Stipendio",
      amount_cents: 100_000,
      type: :DEPOSIT
    )
    at = Time.utc(2026, 8, 17, 0, 24, 11)
    before = client.transactions.size
    PortfolioPerformanceApi::FinecoImport.append!(client, account, [visa, stipendio], at: at)

    imported = client.transactions.drop(before)
    assert_equal 2, imported.size
    imported.each { |tx| assert_equal "ppapi import 20260817T002411", tx.source }
  end

  def test_encrypted_save_writes_data_entry_pp_reads
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wallet.portfolio")
      File.binwrite(
        path,
        PortfolioPerformanceApi::Decryptor.encrypt(
          zip_protobuf(entry: "data"),
          "secret",
          aes256: true,
          content_type: 2,
          version: 70
        )
      )

      loaded = PortfolioPerformanceApi::PortfolioStore.load(path, password: "secret")
      account = PortfolioPerformanceApi::FinecoImport.find_account(loaded.client, "Conto corrente")
      PortfolioPerformanceApi::FinecoImport.append!(
        loaded.client,
        account,
        [
          PortfolioPerformanceApi::FinecoXls::Row.new(
            date: Date.new(2026, 8, 15),
            description: "VISA DEBIT CRYPTO TAX - KOIN...",
            amount_cents: 9_900,
            type: :REMOVAL
          )
        ]
      )
      PortfolioPerformanceApi::PortfolioStore.save(loaded)

      payload = PortfolioPerformanceApi::Decryptor.decrypt(File.binread(path), "secret")
      names = []
      first = nil
      Zip::File.open_buffer(StringIO.new(payload.zip_bytes)) do |zip|
        zip.each do |entry|
          next if entry.directory?

          names << entry.name
          first ||= entry.get_input_stream.read
        end
      end

      assert_equal ["data"], names
      client = PortfolioPerformanceApi::Proto::PClient.decode(
        PortfolioPerformanceApi::FileReader.strip_proto_magic(first)
      )
      imported = client.transactions.last
      assert_equal :REMOVAL, imported.type
      assert_equal 9_900, imported.amount
      assert_equal "VISA DEBIT CRYPTO TAX - KOIN...", imported.note
      assert_equal "acc-cash", imported.account
    end
  end
end
