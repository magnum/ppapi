# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "fileutils"
require "tmpdir"

require_relative "../lib/portfolio_performance_api/import"
require_relative "../lib/portfolio_performance_api/fineco_import"
require_relative "../lib/portfolio_performance_api/fineco_xls"

class ImportTest < Minitest::Test
  def test_only_fineco_provider_is_registered
    assert_equal ["fineco"], PortfolioPerformanceApi::Import::PROVIDERS.keys
    assert_equal PortfolioPerformanceApi::Import::Fineco,
                 PortfolioPerformanceApi::Import.provider_class("fineco")
    assert_equal PortfolioPerformanceApi::Import::Fineco,
                 PortfolioPerformanceApi::Import.provider_class("FINECO")
    assert_nil PortfolioPerformanceApi::Import.provider_class("unknown")
    refute_operator PortfolioPerformanceApi::Import::Fineco, :<, PortfolioPerformanceApi::Import
  end

  def test_backup_path_uses_import_backup_timestamp
    at = Time.new(2026, 8, 16, 16, 7, 0)
    path = PortfolioPerformanceApi::Import.backup_path("/tmp/portfolio1.portfolio", at: at)
    assert_equal "/tmp/portfolio1-import-backup-20260816T160700.portfolio", path
  end

  def test_fineco_parse_argv_account_and_xls
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["EUR010069756", "./movements.xlsx"]
    )

    assert_equal "EUR010069756", options[:account]
    assert_equal File.expand_path("./movements.xlsx"), options[:xls]
    assert_nil options[:exclude]
    assert_equal PortfolioPerformanceApi::FinecoXls.default_skip_lines, options[:skip_lines]
    assert_empty options[:match_security]
    assert_empty options[:match_offset_account]
  end

  def test_fineco_parse_argv_exclude
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["EUR010069756", "./movements.xlsx", "--exclude", "compravendita valute"]
    )

    assert_equal "EUR010069756", options[:account]
    assert_equal "compravendita valute", options[:exclude]
  end

  def test_fineco_parse_argv_skip_lines_override
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["USD010069756", "import/test_usd.xlsx", "--skip-lines=7"]
    )

    assert_equal "USD010069756", options[:account]
    assert_equal 7, options[:skip_lines]
  end

  def test_fineco_parse_argv_match_flags
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      [
        "EUR010069756", "./movements.xlsx",
        "--match-security", "/Compravendita Titoli (.+?) Qta/",
        "--match-offset-account", "/Compravendita Divise/USD010069756"
      ]
    )

    assert_equal ["/Compravendita Titoli (.+?) Qta/"], options[:match_security]
    assert_equal ["/Compravendita Divise/USD010069756"], options[:match_offset_account]
  end

  def test_fineco_parse_argv_match_security_default_pattern
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["EUR010069756", "./movements.xlsx", "--match-security"]
    )

    assert_equal [PortfolioPerformanceApi::FinecoImport::DEFAULT_SECURITY_SPEC], options[:match_security]
  end

  def test_fineco_parse_argv_rejects_invalid_offset_spec
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::Import::Fineco.parse_argv(
        ["EUR010069756", "./movements.xlsx", "--match-offset-account", "Compravendita Divise"]
      )
    end
    assert_includes error.message, "--match-offset-account"
  end

  def test_fineco_parse_argv_multiple_match_flags
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      [
        "EUR010069756", "./movements.xlsx",
        "--match-security", "/Compravendita Titoli (.+?) Qta/",
        "--match-security", "/Acquisto (.+)$/",
        "--match-offset-account", "/Compravendita Divise/USD010069756",
        "--match-offset-account", "/Bonifico USD/EUR010069756"
      ]
    )

    assert_equal ["/Compravendita Titoli (.+?) Qta/", "/Acquisto (.+)$/"], options[:match_security]
    assert_equal ["/Compravendita Divise/USD010069756", "/Bonifico USD/EUR010069756"],
                 options[:match_offset_account]
  end

  def test_fineco_parse_argv_skip_lines_rejects_negative
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::Import::Fineco.parse_argv(
        ["USD010069756", "import/test_usd.xlsx", "--skip-lines", "-1"]
      )
    end
    assert_includes error.message, "--skip-lines"
  end

  def test_fineco_parse_argv_blank_exclude_is_omitted
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["EUR010069756", "./movements.xlsx", "--exclude", ""]
    )

    assert_nil options[:exclude]
  end

  def test_fineco_parse_argv_account_name_with_spaces
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["EUR010069756", "test", "import/test_eur.xlsx"]
    )

    assert_equal "EUR010069756 test", options[:account]
    assert_equal File.expand_path("import/test_eur.xlsx"), options[:xls]
  end

  def test_fineco_parse_argv_optional_quotes_around_account
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ['"EUR010069756 test"', "import/test_eur.xlsx", "--exclude", '""']
    )

    assert_equal "EUR010069756 test", options[:account]
    assert_nil options[:exclude]
  end

  def test_fineco_parse_argv_quoted_account_from_shell
    options = PortfolioPerformanceApi::Import::Fineco.parse_argv(
      ["EUR010069756 test", "./movements.xlsx"]
    )

    assert_equal "EUR010069756 test", options[:account]
  end

  def test_fineco_parse_argv_requires_account_and_xls
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::Import::Fineco.parse_argv(["EUR010069756"])
    end
    assert_includes error.message, "bin/import fineco"
  end

  def test_fineco_format_row_uses_us_decimal
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "VISA DEBIT CRYPTO TAX",
      amount_cents: 9_900,
      type: :REMOVAL
    )
    line = PortfolioPerformanceApi::Import::Fineco.format_row(row, width: 120)

    assert_includes line, "-  2026-08-15"
    assert_includes line, "99.00"
    assert_includes line, "VISA DEBIT CRYPTO TAX"
    refute_includes line, "99,00"
    refute_match(/S /, line)
  end

  def test_fineco_format_row_shows_security_before_description
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      amount_cents: 9_900,
      type: :REMOVAL,
      security: "AMAZON.COM",
      offset_account: "USD010069756"
    )
    line = PortfolioPerformanceApi::Import::Fineco.format_row(row, width: 160)
    security_at = line.index("S AMAZON.COM")
    note_at = line.index("Compravendita Titoli")
    dest_at = line.index("→ USD010069756")

    assert security_at
    assert note_at
    assert dest_at
    assert_operator security_at, :<, note_at
    assert_operator note_at, :<, dest_at
    refute_includes line, "[AMAZON.COM]"
    assert_includes line, "PURCHASE"
  end

  def test_fineco_format_row_shows_written_transfer_type
    inbound = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 29),
      description: "Cambio valuta Compravendita Divise",
      amount_cents: 4_648,
      type: :DEPOSIT,
      offset_account: "EUR010069756"
    )
    outbound = inbound.dup
    outbound.type = :REMOVAL
    outbound.amount_cents = 550_000

    inbound_line = PortfolioPerformanceApi::Import::Fineco.format_row(inbound, width: 160)
    outbound_line = PortfolioPerformanceApi::Import::Fineco.format_row(outbound, width: 160)
    assert_includes inbound_line, "CASH_TRANSFER"
    assert_includes outbound_line, "CASH_TRANSFER"
    refute_includes inbound_line, "TRANSFER_IN"
    refute_includes outbound_line, "TRANSFER_OUT"
  end

  def test_preview_sections_puts_excluded_above_import
    excluded = [
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 14),
        description: "Cambio valuta Compravendita Divise",
        amount_cents: 475_696,
        type: :DEPOSIT
      )
    ]
    imported = [
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 15),
        description: "VISA DEBIT CRYPTO TAX",
        amount_cents: 9_900,
        type: :REMOVAL
      )
    ]
    sections = PortfolioPerformanceApi::Import::Fineco.preview_sections(
      imported, excluded, exclude: "compravendita", width: 120
    )

    assert_equal %w[EXCLUDED IMPORT], sections.map(&:title)
    assert_equal 10, sections[0].page_size
    refute_equal false, sections[0].scroll
    assert_equal 1, sections[0].lines.size
    assert_includes sections[0].lines.first, "Compravendita Divise"
    assert_equal 1, sections[1].counts[:create]
    assert_includes sections[1].lines.first, "VISA DEBIT CRYPTO TAX"
  end

  def test_preview_sections_omits_excluded_without_filter
    imported = [
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 15),
        description: "Stipendio",
        amount_cents: 10_000,
        type: :DEPOSIT
      )
    ]
    sections = PortfolioPerformanceApi::Import::Fineco.preview_sections(imported, [], exclude: nil)

    assert_equal ["IMPORT"], sections.map(&:title)
  end

  def test_preview_sections_puts_existing_between_excluded_and_import
    excluded = [
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 14),
        description: "Cambio valuta",
        amount_cents: 100,
        type: :DEPOSIT
      )
    ]
    existing = [
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 15),
        description: "Already there",
        amount_cents: 9_900,
        type: :REMOVAL
      )
    ]
    imported = [
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 16),
        description: "New row",
        amount_cents: 50_000,
        type: :DEPOSIT
      )
    ]
    sections = PortfolioPerformanceApi::Import::Fineco.preview_sections(
      imported, excluded, existing, exclude: "cambio", width: 120
    )

    assert_equal %w[EXCLUDED EXISTING IMPORT], sections.map(&:title)
    assert_equal 10, sections[1].page_size
    assert_equal 10, sections[2].page_size
    refute_equal false, sections[1].scroll
    refute_equal false, sections[2].scroll
    assert_includes sections[1].lines.first, "Already there"
    assert_includes sections[2].lines.first, "New row"
  end

  def test_preview_sections_cap_existing_and_import_at_ten
    excluded = (1..15).map do |index|
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 1),
        description: "Excluded #{index}",
        amount_cents: 50,
        type: :DEPOSIT
      )
    end
    existing = (1..15).map do |index|
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 1),
        description: "Existing #{index}",
        amount_cents: 100,
        type: :DEPOSIT
      )
    end
    imported = (1..15).map do |index|
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 2),
        description: "Import #{index}",
        amount_cents: 200,
        type: :REMOVAL
      )
    end
    sections = PortfolioPerformanceApi::Import::Fineco.preview_sections(
      imported, excluded, existing, exclude: "excluded", width: 120
    )
    excluded_section, existing_section, import_section = sections

    assert_equal 15, excluded_section.lines.size
    assert_equal 15, existing_section.lines.size
    assert_equal 15, import_section.lines.size
    assert_equal [10, 10, 10], sections.map(&:page_size)

    preview = PortfolioPerformanceApi::RowPreview.new(
      "EUR",
      sections,
      page_size: PortfolioPerformanceApi::Import::Fineco::PREVIEW_ROWS,
      prompt: "import?",
      choices: %w[Y]
    )
    window = preview.instance_variable_get(:@window)
    assert_equal [10, 10, 10], (0..2).map { |index| window.visible(index).size }
    assert_includes window.visible(0).first, "Excluded 1"
    assert_includes window.visible(1).first, "Existing 1"
    assert_includes window.visible(2).first, "Import 1"
    window.down
    assert_includes window.visible(0).first, "Excluded 2"
    assert_includes window.visible(1).first, "Existing 2"
    assert_includes window.visible(2).first, "Import 2"
  end

  def test_preview_sections_shows_every_excluded_row
    excluded = (1..7).map do |index|
      PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, index),
        description: "Cambio valuta #{index}",
        amount_cents: 100,
        type: :DEPOSIT
      )
    end
    sections = PortfolioPerformanceApi::Import::Fineco.preview_sections(
      [], excluded, exclude: "cambio", width: 120
    )

    assert_equal 7, sections[0].lines.size
    assert_equal 10, sections[0].page_size
    refute_equal false, sections[0].scroll
    assert(sections[0].lines.all? { |line| line.include?("Cambio valuta") })
  end

  def test_format_row_puts_discard_reason_last
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 1,000000",
      amount_cents: 1_000,
      type: :REMOVAL,
      security: "AMAZON.COM",
      offset_account: "Deposito titoli"
    )
    line = PortfolioPerformanceApi::Import::Fineco.format_row(
      row, width: 160, reason: "security not found: AMAZON.COM"
    )

    assert_includes line, "PURCHASE"
    assert line.end_with?("security not found: AMAZON.COM")
    assert_operator line.index("PURCHASE"), :<, line.index("security not found")
  end

  def test_discarded_sections_are_scrollable_ten_rows_with_reason
    skipped = (1..15).map do |index|
      row = PortfolioPerformanceApi::FinecoXls::Row.new(
        date: Date.new(2026, 8, 1),
        description: "Dropped #{index}",
        amount_cents: 100,
        type: :DEPOSIT
      )
      PortfolioPerformanceApi::FinecoImport::Skipped.new(row: row, reason: "matched --exclude")
    end
    sections = PortfolioPerformanceApi::Import::Fineco.discarded_sections(skipped, width: 120)

    assert_equal ["DISCARDED"], sections.map(&:title)
    assert_equal 15, sections[0].lines.size
    assert_equal 10, sections[0].page_size
    refute_equal false, sections[0].scroll
    assert_includes sections[0].lines.first, "Dropped 1"
    assert sections[0].lines.first.end_with?("matched --exclude")

    preview = PortfolioPerformanceApi::RowPreview.new(
      "EUR",
      sections,
      page_size: PortfolioPerformanceApi::Import::Fineco::PREVIEW_ROWS,
      prompt: "continue?",
      choices: [],
      acknowledge: true
    )
    window = preview.instance_variable_get(:@window)
    assert_equal 10, window.visible(0).size
    assert_includes window.visible(0).first, "Dropped 1"
    window.down
    assert_includes window.visible(0).first, "Dropped 2"
  end

  def test_copies_backup_without_changing_source
    Dir.mktmpdir do |dir|
      source = File.join(dir, "wallet.portfolio")
      File.write(source, "original")
      backup = PortfolioPerformanceApi::Import.backup_path(source, at: Time.new(2026, 8, 16, 12, 0, 0))
      FileUtils.cp(source, backup)
      File.write(source, "imported")

      assert_equal "imported", File.read(source)
      assert_equal "original", File.read(backup)
      assert_equal File.join(dir, "wallet-import-backup-20260816T120000.portfolio"), backup
    end
  end

  def test_discard_backup_deletes_unused_copy
    Dir.mktmpdir do |dir|
      backup = File.join(dir, "wallet-import-backup-20260816T120000.portfolio")
      File.write(backup, "original")
      PortfolioPerformanceApi::Import::Fineco.discard_backup(backup)
      refute_path_exists backup

      PortfolioPerformanceApi::Import::Fineco.discard_backup(nil)
      PortfolioPerformanceApi::Import::Fineco.discard_backup(File.join(dir, "missing.portfolio"))
    end
  end
end
