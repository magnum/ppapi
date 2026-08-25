# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/transaction_sync"
require_relative "../lib/portfolio_performance_api/preview_window"
require_relative "../lib/portfolio_performance_api/row_preview"
require_relative "../lib/portfolio_performance_api/sync_preview"

class PreviewWindowTest < Minitest::Test
  def test_shows_page_from_both_lists
    window = PortfolioPerformanceApi::PreviewWindow.new(
      [%w[p0 p1 p2 p3 p4], %w[s0 s1 s2]],
      page_size: 2
    )

    assert_equal %w[p0 p1], window.visible(0)
    assert_equal %w[s0 s1], window.visible(1)
    assert_equal [1, 2, 5], window.range(0)
    assert_equal [1, 2, 3], window.range(1)
  end

  def test_arrows_move_one_row_and_letters_page
    window = PortfolioPerformanceApi::PreviewWindow.new(
      [(0..9).map(&:to_s), (0..4).map(&:to_s)],
      page_size: 3
    )

    window.down
    assert_equal 1, window.offset
    assert_equal %w[1 2 3], window.visible(0)
    assert_equal %w[1 2 3], window.visible(1)

    window.page_down
    assert_equal 4, window.offset
    assert_equal %w[4 5 6], window.visible(0)
    assert_equal %w[2 3 4], window.visible(1)

    window.page_up
    assert_equal 1, window.offset
    window.up
    assert_equal 0, window.offset
    assert_equal %w[0 1 2], window.visible(0)
  end

  def test_clamps_to_longer_list
    window = PortfolioPerformanceApi::PreviewWindow.new(
      [%w[a b], (0..9).map(&:to_s)],
      page_size: 3
    )
    20.times { window.down }

    assert_equal 7, window.offset
    assert_equal %w[a b], window.visible(0)
    assert_equal %w[7 8 9], window.visible(1)
    3.times { window.page_up }
    assert_equal 0, window.offset
  end

  def test_empty_lists
    window = PortfolioPerformanceApi::PreviewWindow.new([[], []], page_size: 5)
    assert_empty window.visible(0)
    assert_empty window.visible(1)
    assert_equal [0, 0, 0], window.range(0)
    window.down
    assert_equal 0, window.offset
  end

  def test_single_list
    window = PortfolioPerformanceApi::PreviewWindow.new([%w[a b c d]], page_size: 2)
    assert_equal %w[a b], window.visible
    window.page_down
    assert_equal %w[c d], window.visible
    assert_equal [3, 4, 4], window.range
  end

  def test_locked_list_stays_on_first_page
    window = PortfolioPerformanceApi::PreviewWindow.new(
      [(0..9).map(&:to_s), (0..9).map(&:to_s)],
      page_size: 5,
      page_sizes: [3, 5],
      locked: [true, false]
    )

    assert_equal %w[0 1 2], window.visible(0)
    assert_equal %w[0 1 2 3 4], window.visible(1)
    window.page_down
    assert_equal %w[0 1 2], window.visible(0)
    assert_equal %w[5 6 7 8 9], window.visible(1)
    assert_equal [1, 3, 10], window.range(0)
    assert_equal [6, 10, 10], window.range(1)
  end

  def test_format_record_uses_us_decimal
    record = PortfolioPerformanceApi::TransactionSync::Record.new(
      id: "x",
      account_name: "EUR",
      date: Date.new(2026, 8, 15),
      type: "REMOVAL",
      signed_cents: -9_900,
      currency: "EUR",
      description: "VISA DEBIT",
      destination: "USD1",
      uuid: "u1"
    )
    line = PortfolioPerformanceApi::SyncPreview.format_record(record, "+", width: 120)

    assert_includes line, "+  2026-08-15"
    assert_includes line, "-99.00"
    assert_includes line, "VISA DEBIT → USD1"
    refute_includes line, "-99,00"
  end

  def test_format_record_truncates_note_to_shell_width
    record = PortfolioPerformanceApi::TransactionSync::Record.new(
      id: "x",
      account_name: "EUR",
      date: Date.new(2026, 8, 15),
      type: "REMOVAL",
      signed_cents: -9_900,
      currency: "EUR",
      description: "VISA DEBIT CRYPTO TAX #{'X' * 80}",
      destination: "USD1",
      uuid: "u1"
    )
    width = 80
    line = PortfolioPerformanceApi::SyncPreview.format_record(record, "+", width: width)

    assert_equal width - PortfolioPerformanceApi::SyncPreview::ROW_INDENT, line.size
    assert_includes line, "..."
    assert_includes line, "→ USD1"
    refute_includes line, "X" * 80
  end

  def test_lines_for_prefixes_update_and_create
    date = Date.new(2026, 8, 15)
    plan = PortfolioPerformanceApi::TransactionSync::Plan.new(
      create_sheet: [record(date, 100, "New sheet", "DEPOSIT")],
      update_sheet: [record(date, -200, "Fix sheet", "FEE")],
      create_portfolio: [record(date, 300, "New port", "DEPOSIT")],
      update_portfolio: [record(date, -400, "Fix port", "REMOVAL")]
    )
    portfolio, sheet = PortfolioPerformanceApi::SyncPreview.lines_for(plan, width: 120)

    assert_equal 2, portfolio.size
    assert_equal 2, sheet.size
    assert portfolio[0].start_with?("~")
    assert portfolio[1].start_with?("+")
    assert_includes portfolio[0], "Fix port"
    assert_includes sheet[1], "New sheet"
  end

  def test_render_shows_both_section_titles
    preview = PortfolioPerformanceApi::RowPreview.new(
      "Crypto (EUR)",
      [
        { title: "PORTFOLIO", lines: ["+  row p"], counts: { create: 1, update: 0 } },
        { title: "SPREADSHEET", lines: ["~  row s"], counts: { create: 0, update: 1 } }
      ],
      page_size: 5,
      prompt: "[Crypto (EUR)] write (S)spreadsheet, (P)ortfolio or (B)oth?",
      choices: %w[S P B]
    )
    lines = preview.send(:render_lines)

    assert_equal "Crypto (EUR)", lines.first
    assert_includes lines, "PORTFOLIO  +1/~0  1-1/1"
    assert_includes lines, "SPREADSHEET  +0/~1  1-1/1"
    assert_includes lines, "  +  row p"
    assert_includes lines, "  ~  row s"
    assert_includes lines, "[Crypto (EUR)] write (S)spreadsheet, (P)ortfolio or (B)oth?"
    assert lines.last.include?("esc/q skip")
  end

  def test_render_single_import_section
    preview = PortfolioPerformanceApi::RowPreview.new(
      "EUR010069756",
      [{ title: "IMPORT", lines: ["+  row"], counts: { create: 1, update: 0 } }],
      page_size: 5,
      prompt: "[EUR010069756] import (Y)es or Esc/Q to skip?",
      choices: %w[Y]
    )
    lines = preview.send(:render_lines)

    assert_equal "EUR010069756", lines.first
    assert_includes lines, "IMPORT  +1/~0  1-1/1"
    assert_includes lines, "  +  row"
    assert_includes lines, "[EUR010069756] import (Y)es or Esc/Q to skip?"
  end

  def test_render_excluded_above_import
    preview = PortfolioPerformanceApi::RowPreview.new(
      "EUR010069756",
      [
        { title: "EXCLUDED", lines: %w[ex0 ex1 ex2 ex3], page_size: 4, scroll: false },
        { title: "IMPORT", lines: ["+  row"], counts: { create: 1, update: 0 } }
      ],
      page_size: 5,
      prompt: "[EUR010069756] import (Y)es or Esc/Q to skip?",
      choices: %w[Y]
    )
    lines = preview.send(:render_lines)

    excluded_at = lines.index { |line| line.start_with?("EXCLUDED") }
    import_at = lines.index { |line| line.start_with?("IMPORT") }
    assert excluded_at
    assert import_at
    assert excluded_at < import_at
    assert_includes lines, "EXCLUDED  1-4/4"
    assert_includes lines, "  ex0"
    assert_includes lines, "  ex1"
    assert_includes lines, "  ex2"
    assert_includes lines, "  ex3"
    assert_includes lines, "IMPORT  +1/~0  1-1/1"
  end

  def test_q_and_escape_skip_import
    preview = PortfolioPerformanceApi::RowPreview.new(
      "EUR010069756",
      [{ title: "IMPORT", lines: ["+  row"], counts: { create: 1, update: 0 } }],
      page_size: 5,
      prompt: "[EUR010069756] import (Y)es or Esc/Q to skip?",
      choices: %w[Y]
    )
    event = Struct.new(:key, :value, keyword_init: true)
    key = Struct.new(:name)

    assert_equal "N", preview.send(:key_choice, event.new(key: key.new(:escape), value: "\e"))
    assert_equal "N", preview.send(:key_choice, event.new(key: nil, value: "q"))
    assert_equal "N", preview.send(:key_choice, event.new(key: nil, value: "Q"))
    assert_equal "Y", preview.send(:key_choice, event.new(key: nil, value: "y"))
  end

  def test_acknowledge_preview_continues_on_enter
    preview = PortfolioPerformanceApi::RowPreview.new(
      "EUR010069756",
      [{ title: "DISCARDED", lines: ["-  row  matched --exclude"] }],
      page_size: 10,
      prompt: "[EUR010069756] discarded 1 — Enter/Q to continue",
      choices: [],
      acknowledge: true,
      help: "enter/q continue"
    )
    event = Struct.new(:key, :value, keyword_init: true)
    key = Struct.new(:name)
    lines = preview.send(:render_lines)

    assert_includes lines, "DISCARDED  1-1/1"
    assert_includes lines, "enter/q continue"
    assert_equal "N", preview.send(:key_choice, event.new(key: key.new(:return), value: "\r"))
    assert_equal "N", preview.send(:key_choice, event.new(key: nil, value: "q"))
    assert_nil preview.send(:key_choice, event.new(key: nil, value: "y"))
  end

  private

  def record(date, cents, description, type)
    PortfolioPerformanceApi::TransactionSync::Record.new(
      id: description,
      account_name: "EUR",
      date: date,
      type: type,
      signed_cents: cents,
      currency: "EUR",
      description: description,
      destination: "",
      uuid: nil
    )
  end
end
