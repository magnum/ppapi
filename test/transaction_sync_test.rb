# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"
require_relative "../lib/portfolio_performance_api/transaction_sync"
require_relative "../lib/portfolio_performance_api/sheets_client"

class TransactionSyncTest < Minitest::Test
  include PortfolioFixtures

  def test_identity_hash_uses_account_date_value_description
    date = Date.new(2026, 8, 15)
    first = PortfolioPerformanceApi::TransactionSync.identity_id("EUR010069756", date, -9_900, "VISA DEBIT")
    same = PortfolioPerformanceApi::TransactionSync.identity_id("EUR010069756", date, -9_900, "VISA DEBIT")
    other_amount = PortfolioPerformanceApi::TransactionSync.identity_id("EUR010069756", date, -9_901, "VISA DEBIT")
    other_note = PortfolioPerformanceApi::TransactionSync.identity_id("EUR010069756", date, -9_900, "VISA DEBIT ")
    other_account = PortfolioPerformanceApi::TransactionSync.identity_id("USD1", date, -9_900, "VISA DEBIT")
    other_dest = PortfolioPerformanceApi::TransactionSync.identity_id("EUR010069756", date, -9_900, "VISA DEBIT", "USD1")
    other_security = PortfolioPerformanceApi::TransactionSync.identity_id(
      "EUR010069756", date, -9_900, "VISA DEBIT", "", "AMAZON.COM"
    )

    assert_equal first, same
    assert_equal first, other_note
    refute_equal first, other_amount
    refute_equal first, other_account
    refute_equal first, other_dest
    refute_equal first, other_security
    refute_equal other_dest, other_security
    assert_match(/\A[\da-f]{64}\z/, first)
    assert_equal first, PortfolioPerformanceApi::TransactionIdentity.id("EUR010069756", date, -9_900, "VISA DEBIT")
  end

  def test_from_proto_and_sheet_row_share_identity
    account = PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-cash",
      name: "EUR010069756",
      currencyCode: "EUR"
    )
    tx = PortfolioPerformanceApi::FinecoImport.build_transaction(
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 15),
        description: "VISA DEBIT CRYPTO TAX",
        amount_cents: 9_900,
        type: :REMOVAL
      ),
      account
    )
    proto = PortfolioPerformanceApi::TransactionSync.from_proto(tx, account)
    sheet = PortfolioPerformanceApi::TransactionSync.from_sheet_row(
      ["2026-08-15", "REMOVAL", "-99,00", "EUR", "VISA DEBIT CRYPTO TAX", "", ""],
      "EUR010069756",
      currency: "EUR"
    )

    assert_equal proto.id, sheet.id
    assert_equal(-9_900, proto.signed_cents)
    assert_equal "REMOVAL", proto.type
    refute_includes PortfolioPerformanceApi::TransactionSync.to_sheet_row(proto), proto.id
  end

  def test_zero_amount_inbound_delivery_round_trips
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2022, 1, 28).to_i)
    tx = PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "u-dust",
      type: :INBOUND_DELIVERY,
      portfolio: "port-crypto",
      date: stamp,
      currencyCode: "EUR",
      amount: 0,
      shares: 1_000_000,
      note: "Airdrop"
    )
    vehicle = PortfolioPerformanceApi::TransactionSync::Vehicle.new(
      kind: :securities, name: "Crypto", uuid: "port-crypto", currency: "EUR"
    )
    proto = PortfolioPerformanceApi::TransactionSync.from_proto(tx, vehicle)
    row = PortfolioPerformanceApi::TransactionSync.to_sheet_row(proto)
    parsed = PortfolioPerformanceApi::TransactionSync.from_sheet_row(row, "Crypto", currency: "EUR")
    plan = PortfolioPerformanceApi::TransactionSync.plan([proto], [parsed])

    assert_equal 0, proto.signed_cents
    assert_equal 0.0, row[2]
    assert_equal proto.id, parsed.id
    assert_equal "u-dust", parsed.uuid
    assert_empty plan.create_sheet
    assert_empty plan.update_sheet
    assert_empty plan.create_portfolio
  end

  def test_cash_transfer_uses_destination_account_name
    client = protobuf_client
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 14).to_i)
    client.transactions.each { |tx| tx.date = stamp unless tx.has_date? }
    names = PortfolioPerformanceApi::TransactionSync.uuid_names(client)
    cash = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |vehicle| vehicle.name == "Conto corrente" }
    savings = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |vehicle| vehicle.name == "Risparmio" }
    titles = PortfolioPerformanceApi::TransactionSync.vehicles(client).map(&:name)

    assert_includes titles, "Deposito titoli"
    from_cash = client.transactions.filter_map { |tx| PortfolioPerformanceApi::TransactionSync.from_proto(tx, cash, names: names) }
    from_savings = client.transactions.filter_map { |tx| PortfolioPerformanceApi::TransactionSync.from_proto(tx, savings, names: names) }
    transfer = from_cash.find { |record| record.type == "CASH_TRANSFER" }
    inbound = from_savings.find { |record| record.type == "CASH_TRANSFER" }

    assert_equal "Risparmio", transfer.destination
    assert_equal "Conto corrente", inbound.destination
    refute_equal transfer.id, inbound.id
  end

  def test_securities_purchase_sets_cash_destination
    client = protobuf_client
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 13).to_i)
    client.transactions.each { |tx| tx.date = stamp unless tx.has_date? }
    client.transactions.find { |tx| tx.type == :PURCHASE }.account = "acc-cash"
    names = PortfolioPerformanceApi::TransactionSync.uuid_names(client)
    securities = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |vehicle| vehicle.kind == :securities }
    cash = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |vehicle| vehicle.name == "Conto corrente" }
    buy = client.transactions.filter_map { |tx| PortfolioPerformanceApi::TransactionSync.from_proto(tx, securities, names: names) }.first
    cash_buy = client.transactions.filter_map { |tx| PortfolioPerformanceApi::TransactionSync.from_proto(tx, cash, names: names) }
               .find { |record| record.type == "PURCHASE" }

    assert_equal "PURCHASE", buy.type
    assert_equal "Conto corrente", buy.destination
    assert_equal "Deposito titoli", cash_buy.destination
  end

  def test_parse_sheet_skips_leading_rows
    rows = [
      ["titolo"],
      ["note"],
      %w[date type amount currency description destination uuid],
      ["2026-08-15", "REMOVAL", "-99.00", "EUR", "VISA DEBIT", "", "u-new"],
      ["2026-08-12", "CASH_TRANSFER", "100.00", "EUR", "Giroconto", "USD010069756", "u-old"]
    ]
    parsed = PortfolioPerformanceApi::TransactionSync.parse_sheet(
      rows, "EUR010069756", currency: "EUR", skip_rows: 2
    )
    visa = parsed.find { |record| record.description == "VISA DEBIT" }
    transfer = parsed.find { |record| record.description == "Giroconto" }

    assert_equal 4, visa.row_number
    assert_equal 5, transfer.row_number
    assert_equal "USD010069756", transfer.destination
    assert_equal transfer.id, PortfolioPerformanceApi::TransactionSync.identity_id(
      "EUR010069756", Date.new(2026, 8, 12), 10_000, "Giroconto", "USD010069756"
    )
  end

  def test_plan_matches_hash_then_create_or_update_in_place
    date = Date.new(2026, 8, 14)
    only_portfolio = record("EUR", date, 243_200, "Stipendio", "DEPOSIT", "p1")
    only_sheet = record("EUR", date, -1_700, "Nuova riga", "REMOVAL", nil, 4)
    shared_portfolio = record("EUR", date, -8_313, "Iper", "REMOVAL", "p2")
    shared_sheet = record("EUR", date, -8_313, "Iper", "FEE", "p2", 7)

    plan = PortfolioPerformanceApi::TransactionSync.plan(
      [only_portfolio, shared_portfolio],
      [only_sheet, shared_sheet]
    )

    assert_equal ["Stipendio"], plan.create_sheet.map(&:description)
    assert_nil plan.create_sheet.first.row_number
    assert_equal ["Nuova riga"], plan.create_portfolio.map(&:description)
    assert_equal ["FEE"], plan.update_portfolio.map(&:type)
    assert_empty plan.update_sheet

    missing_uuid = record("EUR", date, -8_313, "Iper", "FEE", nil, 7)
    plan = PortfolioPerformanceApi::TransactionSync.plan([shared_portfolio], [missing_uuid])
    assert_equal [7], plan.update_sheet.map(&:row_number)
    assert_equal ["p2"], plan.update_sheet.map(&:uuid)
  end

  def test_plan_rewrites_stale_sheet_destination_after_rename
    date = Date.new(2017, 12, 1)
    proto = record("Crypto", date, -9_900, "Koinly sale", "SALE", "u1", nil, "Crypto EUR")
    sheet = record("Crypto", date, -9_900, "Koinly sale", "SALE", "u1", 3, "Crypto (EUR)")
    cash = PortfolioPerformanceApi::TransactionSync::Vehicle.new(
      kind: :deposit, name: "Crypto EUR", uuid: "cash", currency: "EUR"
    )
    names_index = { "Crypto EUR" => cash, "crypto eur" => cash }

    plan = PortfolioPerformanceApi::TransactionSync.plan([proto], [sheet], names_index: names_index)

    assert_empty plan.update_portfolio
    assert_equal ["Crypto EUR"], plan.update_sheet.map(&:destination)
    assert_equal [3], plan.update_sheet.map(&:row_number)
  end

  def test_plan_sheet_destination_wins_when_it_is_a_different_account
    date = Date.new(2017, 12, 1)
    proto = record("Crypto", date, -9_900, "Koinly sale", "SALE", "u1", nil, "Crypto EUR")
    sheet = record("Crypto", date, -9_900, "Koinly sale", "SALE", "u1", 3, "EUR010069756")
    cash = PortfolioPerformanceApi::TransactionSync::Vehicle.new(
      kind: :deposit, name: "Crypto EUR", uuid: "cash", currency: "EUR"
    )
    bank = PortfolioPerformanceApi::TransactionSync::Vehicle.new(
      kind: :deposit, name: "EUR010069756", uuid: "bank", currency: "EUR"
    )
    names_index = {
      "Crypto EUR" => cash, "crypto eur" => cash,
      "EUR010069756" => bank, "eur010069756" => bank
    }

    plan = PortfolioPerformanceApi::TransactionSync.plan([proto], [sheet], names_index: names_index)

    assert_empty plan.update_sheet
    assert_equal ["EUR010069756"], plan.update_portfolio.map(&:destination)
  end

  def test_plan_rewrites_sheet_destination_that_now_points_at_self
    date = Date.new(2024, 4, 19)
    proto = record("Moneyfarm GPM", date, -1_500_000, "Rendiconto", "PURCHASE", "u2", nil, "Moneyfarm GPM EUR")
    sheet = record("Moneyfarm GPM", date, -1_500_000, "Rendiconto", "PURCHASE", "u2", 4, "Moneyfarm GPM")
    cash = PortfolioPerformanceApi::TransactionSync::Vehicle.new(
      kind: :deposit, name: "Moneyfarm GPM EUR", uuid: "gpm-cash", currency: "EUR"
    )
    titles = PortfolioPerformanceApi::TransactionSync::Vehicle.new(
      kind: :securities, name: "Moneyfarm GPM", uuid: "gpm-sec", currency: "EUR"
    )
    names_index = {
      "Moneyfarm GPM EUR" => cash, "moneyfarm gpm eur" => cash,
      "Moneyfarm GPM" => titles, "moneyfarm gpm" => titles
    }

    plan = PortfolioPerformanceApi::TransactionSync.plan([proto], [sheet], names_index: names_index)

    assert_empty plan.update_portfolio
    assert_equal ["Moneyfarm GPM EUR"], plan.update_sheet.map(&:destination)
  end

  def test_plan_pairs_duplicate_identities_one_to_one
    date = Date.new(2022, 1, 28)
    note = "Bonifico SEPA Italia | Ord: INPS"
    portfolio = [
      record("EUR", date, 3_000, note, "DEPOSIT", "u1"),
      record("EUR", date, 3_000, note, "DEPOSIT", "u2"),
      record("EUR", date, 3_000, note, "DEPOSIT", "u3")
    ]
    sheet = [
      record("EUR", date, 3_000, note, "DEPOSIT", nil, 3),
      record("EUR", date, 3_000, note, "DEPOSIT", nil, 4),
      record("EUR", date, 3_000, note, "DEPOSIT", nil, 5)
    ]

    plan = PortfolioPerformanceApi::TransactionSync.plan(portfolio, sheet)
    assert_equal [3, 4, 5], plan.update_sheet.map(&:row_number)
    assert_equal %w[u1 u2 u3], plan.update_sheet.map(&:uuid)
    assert_empty plan.create_sheet
    assert_empty plan.create_portfolio

    second = PortfolioPerformanceApi::TransactionSync.plan(portfolio, plan.update_sheet)
    assert_empty second.update_sheet
    assert_empty second.create_sheet
    assert_empty second.create_portfolio
    assert_empty second.update_portfolio
  end

  def test_plan_matches_uuid_before_shared_identity
    date = Date.new(2022, 1, 28)
    note = "Bonifico SEPA Italia | Ord: INPS"
    portfolio = [
      record("EUR", date, 3_000, note, "DEPOSIT", "u1"),
      record("EUR", date, 3_000, note, "DEPOSIT", "u2")
    ]
    sheet = [
      record("EUR", date, 3_000, note, "DEPOSIT", "u2", 3),
      record("EUR", date, 3_000, note, "DEPOSIT", "u1", 4)
    ]

    plan = PortfolioPerformanceApi::TransactionSync.plan(portfolio, sheet)
    assert_empty plan.update_sheet
    assert_empty plan.create_sheet
    assert_empty plan.create_portfolio
  end

  def test_find_sheet_row_by_runtime_hash
    rows = [
      record("EUR", Date.new(2026, 8, 12), -8_313, "Iper", "REMOVAL", "a", 3),
      record("EUR", Date.new(2026, 8, 15), -9_900, "VISA", "REMOVAL", "b", 2)
    ]
    hash = PortfolioPerformanceApi::TransactionSync.identity_id("EUR", Date.new(2026, 8, 15), -9_900, "VISA")
    found = PortfolioPerformanceApi::TransactionSync.find_sheet_row(rows, hash)

    assert_equal 2, found.row_number
    assert_equal "VISA", found.description
    assert_nil PortfolioPerformanceApi::TransactionSync.find_sheet_row(rows, "missing")
  end

  def test_apply_creates_transfer_by_account_name
    client = protobuf_client
    cash = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |vehicle| vehicle.name == "Conto corrente" }
    created = record("Conto corrente", Date.new(2026, 8, 15), 10_000, "Giroconto", "CASH_TRANSFER", nil, nil, "Risparmio")

    PortfolioPerformanceApi::TransactionSync.apply_portfolio!(client, cash, [created])
    imported = client.transactions.last
    assert_equal :CASH_TRANSFER, imported.type
    assert_equal "acc-cash", imported.account
    assert_equal "acc-savings", imported.otherAccount
    assert_equal "Giroconto", imported.note
  end

  def test_apply_creates_and_updates_portfolio
    client = protobuf_client
    account = client.accounts.find { |item| item.uuid == "acc-cash" }
    before = client.transactions.size
    created = record("Conto corrente", Date.new(2026, 8, 15), -9_900, "VISA DEBIT", "REMOVAL")
    existing = client.transactions.find { |tx| tx.uuid == "tx-1" }
    existing.date = Google::Protobuf::Timestamp.new(seconds: Time.utc(2024, 1, 1).to_i)
    existing.note = "Old deposit"
    update = PortfolioPerformanceApi::TransactionSync.from_proto(existing, account)
    changed = record(account.name, update.date, update.signed_cents, update.description, "INTEREST", existing.uuid)

    applied = PortfolioPerformanceApi::TransactionSync.apply_portfolio!(client, account, [created, changed])
    assert_equal 2, applied
    assert_equal before + 1, client.transactions.size
    imported = client.transactions.last
    assert_equal :REMOVAL, imported.type
    assert_equal 9_900, imported.amount
    assert_equal "VISA DEBIT", imported.note
    assert_equal :INTEREST, existing.type
  end

  def test_sanitize_sheet_title
    assert_equal "A", PortfolioPerformanceApi::SheetsClient.column_letter(1)
    assert_equal "G", PortfolioPerformanceApi::SheetsClient.column_letter(7)
    assert_equal "N", PortfolioPerformanceApi::SheetsClient.column_letter(14)
    assert_equal "Z", PortfolioPerformanceApi::SheetsClient.column_letter(26)
    assert_equal "AA", PortfolioPerformanceApi::SheetsClient.column_letter(27)
    assert_equal "EUR010069756", PortfolioPerformanceApi::SheetsClient.sanitize_title("EUR010069756")
    assert_equal "Conto-titoli", PortfolioPerformanceApi::SheetsClient.sanitize_title("Conto/titoli")
    assert_equal "Account", PortfolioPerformanceApi::SheetsClient.sanitize_title("   ")
    assert_equal 100, PortfolioPerformanceApi::SheetsClient.sanitize_title("A" * 140).size
  end

  def test_sheet_title_and_account_name_round_trip
    deposit = PortfolioPerformanceApi::SheetsClient.sheet_title(:deposit, "EUR010069756")
    securities = PortfolioPerformanceApi::SheetsClient.sheet_title(:securities, "Moneyfarm GPM")
    same = PortfolioPerformanceApi::SheetsClient.unique_titles(
      [
        PortfolioPerformanceApi::TransactionSync::Vehicle.new(kind: :deposit, name: "Foo", uuid: "a", currency: "EUR"),
        PortfolioPerformanceApi::TransactionSync::Vehicle.new(kind: :securities, name: "Foo", uuid: "b", currency: "EUR"),
        PortfolioPerformanceApi::TransactionSync::Vehicle.new(kind: :deposit, name: "Foo", uuid: "c", currency: "EUR")
      ]
    )

    assert_equal "deposit - EUR010069756", deposit
    assert_equal "securities - Moneyfarm GPM", securities
    assert_equal "EUR010069756", PortfolioPerformanceApi::SheetsClient.account_name(deposit)
    assert_equal "Moneyfarm GPM", PortfolioPerformanceApi::SheetsClient.account_name(securities)
    assert_equal :deposit, PortfolioPerformanceApi::SheetsClient.sheet_kind(deposit)
    assert_equal :securities, PortfolioPerformanceApi::SheetsClient.sheet_kind(securities)
    assert_equal "legacy", PortfolioPerformanceApi::SheetsClient.account_name("legacy")
    assert_equal ["deposit - Foo", "securities - Foo", "deposit - Foo (2)"], same
  end

  def test_spreadsheet_url_and_terminal_link
    url = PortfolioPerformanceApi::SheetsClient.spreadsheet_url("ssid")
    sheet = PortfolioPerformanceApi::SheetsClient.spreadsheet_url("ssid", gid: 42)
    linked = PortfolioPerformanceApi::SheetsClient.terminal_link("EUR010069756", sheet)

    assert_equal "https://docs.google.com/spreadsheets/d/ssid/edit", url
    assert_equal "https://docs.google.com/spreadsheets/d/ssid/edit?gid=42#gid=42", sheet
    assert_includes linked, "\e]8;;#{sheet}\e\\"
    assert_includes linked, "EUR010069756"
    assert_includes linked, "\e]8;;\e\\"
  end

  def test_sheet_row_has_destination_and_no_id
    row = PortfolioPerformanceApi::TransactionSync.to_sheet_row(
      record("EUR", Date.new(2026, 8, 15), 4_756_96, "Cambio", "CASH_TRANSFER", "u1", nil, "USD010069756")
    )
    assert_equal ["2026-08-15", "CASH_TRANSFER", 4756.96, "EUR", "Cambio", "USD010069756", "u1"], row
    assert_kind_of Numeric, row[2]
    assert_equal %w[date type amount currency description destination uuid],
                 PortfolioPerformanceApi::TransactionSync::HEADERS
  end

  def test_sheet_amount_is_us_decimal_number
    negative = PortfolioPerformanceApi::TransactionSync.to_sheet_row(
      record("EUR", Date.new(2026, 8, 15), -9_900, "VISA", "REMOVAL")
    )
    parsed = PortfolioPerformanceApi::TransactionSync.from_sheet_row(
      ["2026-08-15", "DEPOSIT", 4756.96, "EUR", "Cambio", "USD1", "u1"],
      "EUR",
      currency: "EUR"
    )
    us_formatted = PortfolioPerformanceApi::TransactionSync.parse_signed_cents("4,756.96")
    eu_formatted = PortfolioPerformanceApi::TransactionSync.parse_signed_cents("4.756,96")

    assert_equal(-99.0, negative[2])
    assert_equal 475_696, parsed.signed_cents
    assert_equal 475_696, us_formatted
    assert_equal 475_696, eu_formatted
  end

  def test_materialize_sheet_updates_in_place_and_appends
    raw = [
      ["keep"],
      %w[date type amount currency description destination uuid],
      ["2026-08-12", "REMOVAL", -83.13, "EUR", "Iper", "", "p2"],
      ["2026-08-13", "DEPOSIT", 10.0, "EUR", "Old", "", "keep"]
    ]
    date = Date.new(2026, 8, 12)
    plan = PortfolioPerformanceApi::TransactionSync::Plan.new(
      create_sheet: [record("EUR", Date.new(2026, 8, 15), -9_900, "VISA", "REMOVAL", "p3")],
      update_sheet: [record("EUR", date, -8_313, "Iper", "FEE", "p2", 3)],
      create_portfolio: [],
      update_portfolio: []
    )
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet(raw, plan, skip_rows: 1, kind: :deposit)

    assert_equal ["keep"], grid[0]
    assert_equal PortfolioPerformanceApi::TransactionSync.headers_for(:deposit), grid[1]
    assert_equal ["2026-08-12", "FEE", -83.13, "EUR", "Iper", "", "p2"], grid[2][0, 7]
    assert_equal ["2026-08-13", "DEPOSIT", 10.0, "EUR", "Old", "", "keep"], grid[3][0, 7]
    assert_equal ["2026-08-15", "REMOVAL", -99.0, "EUR", "VISA", "", "p3"], grid[4][0, 7]
  end

  def test_sheet_chunks_split_from_start_row
    grid = Array.new(5) { |index| ["r#{index}"] }
    chunks = PortfolioPerformanceApi::TransactionSync.sheet_chunks(grid, start_row: 2, chunk_size: 2)

    assert_equal 2, chunks.size
    assert_equal({ start_row: 2, end_row: 3, values: [["r1"], ["r2"]] }, chunks[0])
    assert_equal({ start_row: 4, end_row: 5, values: [["r3"], ["r4"]] }, chunks[1])
  end

  def test_apply_sheet_writes_chunks_not_rows
    sheets = FakeSheets.new
    date = Date.new(2026, 8, 15)
    plan = PortfolioPerformanceApi::TransactionSync::Plan.new(
      create_sheet: [record("EUR", date, 100, "A", "DEPOSIT", "u1"), record("EUR", date, 200, "B", "DEPOSIT", "u2")],
      update_sheet: [],
      create_portfolio: [],
      update_portfolio: []
    )

    created, updated = PortfolioPerformanceApi::TransactionSync.apply_sheet(
      sheets, "EUR", plan, skip_rows: 0, chunk_size: 2, raw_rows: [], kind: :deposit
    )

    assert_equal 2, created
    assert_equal 0, updated
    assert_equal 2, sheets.chunks.size
    assert_equal 1, sheets.chunks[0][:start_row]
    assert_equal 2, sheets.chunks[0][:end_row]
    assert_kind_of Numeric, sheets.chunks[0][:values][1][2]
    assert_equal 3, sheets.chunks[1][:start_row]
  end

  def test_write_chunks_expands_grid_before_writing_past_row_limit
    session = GridSession.new(
      title: "deposit - EUR010069756",
      sheet_id: 7,
      row_count: 1001
    )
    sheets = PortfolioPerformanceApi::SheetsClient.new(session: session, spreadsheet_id: "ssid")
    grid = Array.new(2001) { ["x"] }

    sheets.write_chunks("deposit - EUR010069756", grid, start_row: 1, chunk_size: 1000)

    expand = session.calls.find { |call| call[:body].to_s.include?("updateSheetProperties") }
    refute_nil expand
    body = JSON.parse(expand[:body])
    assert_equal 2001, body.dig("requests", 0, "updateSheetProperties", "properties", "gridProperties", "rowCount")
    assert session.calls.count { |call| call[:method] == :put } >= 2
  end

  def test_extra_columns_are_not_part_of_identity
    header = %w[date type amount currency description destination uuid security shares source]
    mapping = PortfolioPerformanceApi::TransactionSync.column_mapping(header)
    first = PortfolioPerformanceApi::TransactionSync.from_sheet_row(
      ["2026-08-15", "REMOVAL", "-99.00", "EUR", "VISA", "", "", "VWCE", "10", "import"],
      "EUR",
      currency: "EUR",
      mapping: mapping
    )
    second = PortfolioPerformanceApi::TransactionSync.from_sheet_row(
      ["2026-08-15", "REMOVAL", "-99.00", "EUR", "VISA", "", "", "AMZN", "2", "other"],
      "EUR",
      currency: "EUR",
      mapping: mapping
    )

    assert_equal first.id, second.id
    assert_equal first.id, PortfolioPerformanceApi::TransactionSync.identity_id("EUR", first.date, -9_900, "VISA")
    assert_equal "VWCE", first.extras[:security]
    assert_equal 1_000_000_000, first.extras[:shares]
    assert_equal "import", first.extras[:source]
  end

  def test_deposit_extras_fill_sheet_and_sheet_wins_on_portfolio
    client = protobuf_client
    client.securities.first.isin = "IE00BK5BQT80"
    client.securities.first.tickerSymbol = "VWCE"
    account = client.accounts.find { |item| item.uuid == "acc-cash" }
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 15).to_i)
    tx = PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "u-extra",
      type: :DEPOSIT,
      account: "acc-cash",
      date: stamp,
      currencyCode: "EUR",
      amount: 100_000,
      shares: 1_000_000_000,
      note: "Buy VWCE",
      security: "sec-etf",
      source: "ppapi import 20260815T120000"
    )
    client.transactions << tx
    header = %w[date type amount currency description destination uuid security shares per\ share offset\ account note source]
    raw = [
      header,
      ["2026-08-15", "DEPOSIT", 1000.0, "EUR", "Buy VWCE", "", "u-extra", "", "", "", "Risparmio", "", ""]
    ]
    vehicle = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |item| item.name == "Conto corrente" }
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(client, vehicle, raw)
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet(raw, plan, kind: :deposit)

    assert_equal header, grid[0]
    filled = grid[1]
    assert_equal "VWCE", filled[7]
    assert_in_delta 10.0, filled[8]
    assert_in_delta 100.0, filled[9]
    assert_equal "Risparmio", filled[10]
    assert_equal "Buy VWCE", filled[11]
    assert_equal "ppapi import 20260815T120000", filled[12]
    assert_includes plan.update_sheet.map(&:uuid), "u-extra"
    assert_equal "Risparmio", plan.update_portfolio.first.destination
  end

  def test_securities_extras_round_trip_and_apply
    client = protobuf_client
    client.securities.first.isin = "IE00BK5BQT80"
    client.securities.first.tickerSymbol = "VWCE"
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 13).to_i)
    buy = client.transactions.find { |tx| tx.uuid == "tx-buy" }
    buy.date = stamp
    buy.account = "acc-cash"
    buy.units << PortfolioPerformanceApi::Proto::PTransactionUnit.new(
      type: :FEE, amount: 150, currencyCode: "EUR"
    )
    buy.units << PortfolioPerformanceApi::Proto::PTransactionUnit.new(
      type: :TAX, amount: 50, currencyCode: "EUR"
    )
    header = %w[date type amount currency description destination uuid symbol isin shares quote fees taxes net\ transaction\ value]
    raw = [header]
    vehicle = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |item| item.kind == :securities }
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(client, vehicle, raw)
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet(raw, plan, kind: :securities)
    created = grid[1]

    assert_equal header, grid[0]
    assert_equal "VWCE", created[7]
    assert_equal "IE00BK5BQT80", created[8]
    assert_in_delta 1.0, created[9]
    assert_in_delta 1000.0, created[10]
    assert_in_delta 1.5, created[11]
    assert_in_delta 0.5, created[12]
    assert_in_delta 1000.0, created[13]

    sheet_row = created.dup
    sheet_row[11] = 2.0
    sheet_row[12] = 1.0
    second = PortfolioPerformanceApi::TransactionSync.account_plan(client, vehicle, [header, sheet_row])
    assert_equal [2_00], second.update_portfolio.map { |record| record.extras[:fees] }
    assert_equal [1_00], second.update_portfolio.map { |record| record.extras[:taxes] }

    PortfolioPerformanceApi::TransactionSync.apply_portfolio!(client, vehicle, second.update_portfolio)
    assert_equal 200, buy.units.find { |unit| unit.type == :FEE }.amount
    assert_equal 100, buy.units.find { |unit| unit.type == :TAX }.amount
  end

  def test_plan_does_not_update_portfolio_when_ticker_only_differs_by_case
    date = Date.new(2026, 8, 13)
    proto = record(
      "Deposito titoli", date, -100_000, "VWCE", "PURCHASE", "tx-buy", nil, "Conto corrente",
      extras: { symbol: "VWCE", isin: "IE00BK5BQT80", shares: 100_000_000 }
    )
    sheet = record(
      "Deposito titoli", date, -100_000, "VWCE", "PURCHASE", "tx-buy", 2, "Conto corrente",
      extras: { symbol: "vwce", isin: "ie00bk5bqt80", shares: 100_000_000 }
    )
    security = PortfolioPerformanceApi::Proto::PSecurity.new(
      uuid: "sec-etf", name: "VWCE", isin: "IE00BK5BQT80", tickerSymbol: "VWCE"
    )

    plan = PortfolioPerformanceApi::TransactionSync.plan(
      [proto],
      [sheet],
      extra_keys: PortfolioPerformanceApi::TransactionSync::SECURITIES_EXTRA_KEYS,
      securities: [security]
    )

    assert_empty plan.update_portfolio
    assert_empty plan.create_portfolio
  end

  def test_apply_portfolio_returns_zero_when_existing_transaction_is_unchanged
    client = protobuf_client
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 13).to_i)
    buy = client.transactions.find { |tx| tx.uuid == "tx-buy" }
    buy.date = stamp
    vehicle = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |item| item.kind == :securities }
    names = PortfolioPerformanceApi::TransactionSync.uuid_names(client)
    proto = PortfolioPerformanceApi::TransactionSync.from_proto(
      buy, vehicle, names: names, security_names: { "sec-etf" => "VWCE" },
      securities: { "sec-etf" => client.securities.first }
    )

    applied = PortfolioPerformanceApi::TransactionSync.apply_portfolio!(client, vehicle, [proto])
    assert_equal 0, applied
  end

  def test_apply_creates_deposit_with_security_shares_and_source
    client = protobuf_client
    cash = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |item| item.name == "Conto corrente" }
    created = record(
      "Conto corrente", Date.new(2026, 8, 15), -99_000, "Titoli VWCE", "PURCHASE", nil, nil, "Deposito titoli",
      extras: { security: "VWCE", shares: 500_000_000, source: "sheet", note: "custom note" }
    )

    PortfolioPerformanceApi::TransactionSync.apply_portfolio!(client, cash, [created])
    imported = client.transactions.last
    assert_equal :PURCHASE, imported.type
    assert_equal "sec-etf", imported.security
    assert_equal 500_000_000, imported.shares
    assert_equal "sheet", imported.source
    assert_equal "custom note", imported.note
    assert_equal "port-titoli", imported.portfolio
  end

  def test_materialize_keeps_unknown_columns
    raw = [
      %w[date type amount currency description destination uuid memo security],
      ["2026-08-12", "REMOVAL", -83.13, "EUR", "Iper", "", "p2", "keep", ""]
    ]
    date = Date.new(2026, 8, 12)
    proto = record("EUR", date, -8_313, "Iper", "REMOVAL", "p2", 2, "", extras: { security: "VWCE" })
    plan = PortfolioPerformanceApi::TransactionSync::Plan.new(
      create_sheet: [],
      update_sheet: [proto],
      create_portfolio: [],
      update_portfolio: []
    )
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet(raw, plan, kind: :deposit)

    assert_equal(
      %w[date type amount currency description destination uuid memo security] +
        ["shares", "per share", "offset account", "note", "source"],
      grid[0]
    )
    assert_equal "keep", grid[1][7]
    assert_equal "VWCE", grid[1][8]
  end

  def test_adds_missing_extra_columns_from_portfolio
    client = protobuf_client
    stamp = Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 15).to_i)
    tx = PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "u-cols",
      type: :DEPOSIT,
      account: "acc-cash",
      date: stamp,
      currencyCode: "EUR",
      amount: 100_000,
      shares: 1_000_000_000,
      note: "Buy VWCE",
      security: "sec-etf",
      source: "ppapi import"
    )
    client.transactions << tx
    raw = [
      %w[date type amount currency description destination uuid],
      ["2026-08-15", "DEPOSIT", 1000.0, "EUR", "Buy VWCE", "", "u-cols"]
    ]
    vehicle = PortfolioPerformanceApi::TransactionSync.vehicles(client).find { |item| item.name == "Conto corrente" }
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(client, vehicle, raw)
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet(raw, plan, kind: :deposit)

    assert_equal PortfolioPerformanceApi::TransactionSync.headers_for(:deposit), grid[0]
    assert_includes plan.update_sheet.map(&:uuid), "u-cols"
    assert_equal "VWCE", grid[1][7]
    assert_in_delta 10.0, grid[1][8]
    assert_in_delta 100.0, grid[1][9]
    assert_equal "Buy VWCE", grid[1][11]
    assert_equal "ppapi import", grid[1][12]
    assert_equal grid[1][0, 7], raw[1]
  end

  def test_reads_legacy_id_column_without_using_it
    mapping = PortfolioPerformanceApi::TransactionSync.column_mapping(
      %w[id date type amount currency description uuid]
    )
    record = PortfolioPerformanceApi::TransactionSync.from_sheet_row(
      ["ignored-hash", "2026-08-15", "REMOVAL", "-99.00", "EUR", "VISA", "u1"],
      "EUR",
      currency: "EUR",
      mapping: mapping
    )
    assert_equal Date.new(2026, 8, 15), record.date
    assert_equal "VISA", record.description
    assert_equal record.id, PortfolioPerformanceApi::TransactionSync.identity_id("EUR", record.date, -9_900, "VISA")
  end

  private

  class FakeSheets
    attr_reader :chunks

    def initialize
      @chunks = []
    end

    def write_chunks(_title, grid, start_row:, chunk_size:)
      @chunks.concat(
        PortfolioPerformanceApi::TransactionSync.sheet_chunks(grid, start_row: start_row, chunk_size: chunk_size)
      )
    end
  end

  class GridSession
    attr_reader :calls

    def initialize(title:, sheet_id:, row_count:)
      @title = title
      @sheet_id = sheet_id
      @row_count = row_count
      @calls = []
    end

    def api_request(uri, method: :get, body: nil, content_type: nil)
      @calls << { uri: uri.to_s, method: method, body: body, content_type: content_type }
      payload = if method == :get
        {
          "sheets" => [
            {
              "properties" => {
                "sheetId" => @sheet_id,
                "title" => @title,
                "gridProperties" => { "rowCount" => @row_count, "columnCount" => 26 }
              }
            }
          ]
        }
      else
        {}
      end
      Struct.new(:body).new(payload.to_json)
    end
  end

  def record(account_name, date, signed_cents, description, type, uuid = nil, row_number = nil, destination = "", extras: nil)
    PortfolioPerformanceApi::TransactionSync::Record.new(
      id: PortfolioPerformanceApi::TransactionSync.identity_id(account_name, date, signed_cents, description, destination),
      account_name: account_name,
      date: date,
      type: type,
      signed_cents: signed_cents,
      currency: "EUR",
      description: description,
      destination: destination,
      uuid: uuid,
      row_number: row_number,
      extras: extras
    )
  end
end
