# frozen_string_literal: true

require "optparse"
require "tty-screen"

require_relative "../config"
require_relative "../errors"
require_relative "../fineco_import"
require_relative "../fineco_xls"
require_relative "../row_preview"

module PortfolioPerformanceApi
  class Import
    class Fineco
      PREVIEW_ROWS = 10

      def initialize(session: Session.new)
        @session = session
      end

      def run(argv)
        options = self.class.parse_argv(argv)
        abort "Fineco XLS not found: #{options[:xls]}" unless File.file?(options[:xls])

        backup = nil
        uploaded = false
        drive, loaded, backup = @session.download_and_backup
        account = FinecoImport.find_account(loaded.client, options[:account])
        abort "deposit account not found: #{options[:account]}" unless account

        rows = FinecoXls.parse(options[:xls], skip_lines: options[:skip_lines])
        result = FinecoImport.prepare(
          loaded.client,
          account,
          rows,
          security_specs: options[:match_security],
          offset_specs: options[:match_offset_account],
          exclude: options[:exclude]
        )

        skipped = Array(result.skipped)
        if result.candidates.empty? && result.excluded.empty? && result.existing.empty? && skipped.empty?
          warn "no Fineco transactions found in #{options[:xls]}"
          return
        end

        print_summary(account, loaded.client, options, result, backup)
        confirmed = result.candidates.any? || result.excluded.any? || result.existing.any?
        if confirmed && preview(account.name, result, exclude: options[:exclude]) != "Y"
          puts "#{account.name}: skipped"
          return
        end

        imported = 0
        repaired = 0
        if confirmed
          repaired = FinecoImport.repair_cross_entries!(loaded.client)
          imported = if result.candidates.empty?
            0
          else
            FinecoImport.append!(loaded.client, account, result.candidates, skipped: skipped)
          end
          if imported.positive? || repaired.positive?
            @session.persist(loaded, drive)
            uploaded = true
            puts "Imported #{imported} transactions into #{loaded.path}" if imported.positive?
            puts "Repaired #{repaired} cross-entry UUIDs" if repaired.positive?
            puts "Uploaded portfolio #{File.basename(loaded.path)}"
          elsif skipped.empty?
            warn "nothing to import"
          end
        end
        review_discarded(account.name, skipped)
      rescue Error, ArgumentError, RegexpError => error
        abort error.message
      ensure
        Session.discard_backup(backup) unless uploaded
      end

      def self.parse_argv(argv)
        options = {
          exclude: nil,
          skip_lines: FinecoXls.default_skip_lines,
          match_security: [],
          match_offset_account: []
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: bin/import fineco ACCOUNT [--file XLS] [XLS] [--exclude REGEXP] [--skip-lines N] " \
                        "[--match-security [/REGEXP/VALUE]] [--match-offset-account /REGEXP/VALUE]"
          opts.on("--file PATH", "--xls PATH", "Fineco .xls / .xlsx export (tab-completes as a file)") do |value|
            options[:xls] = File.expand_path(unquote(value))
          end
          opts.on("--exclude REGEXP", "Drop Excel rows matching REGEXP in any column") do |value|
            pattern = unquote(value)
            options[:exclude] = pattern.empty? ? nil : pattern
          end
          opts.on("--skip-lines N", Integer, "Preamble rows to skip (default IMPORT_FINECO_XLS_SKIP_LINES)") do |value|
            options[:skip_lines] = value
          end
          opts.on("--match-security [SPEC]",
                  "Set security from capture or /REGEXP/VALUE (default: #{FinecoImport::DEFAULT_SECURITY_SPEC})") do |value|
            spec = value.nil? ? FinecoImport::DEFAULT_SECURITY_SPEC : unquote(value)
            FinecoImport.parse_match_spec(spec, flag: "--match-security") unless spec.empty?
            options[:match_security] << spec unless spec.empty?
          end
          opts.on("--match-offset-account SPEC", "Set offset account from capture or /REGEXP/VALUE") do |value|
            spec = unquote(value)
            FinecoImport.parse_match_spec(spec, flag: "--match-offset-account")
            options[:match_offset_account] << spec
          end
        end
        rest = parser.parse(Array(argv).map(&:to_s)).map { |value| unquote(value) }
        raise ArgumentError, "--skip-lines must be >= 0" if options[:skip_lines].negative?

        xls = options[:xls]
        if xls.to_s.empty?
          raise ArgumentError, parser.banner if rest.size < 2

          xls = File.expand_path(rest.pop)
        end
        account = rest.join(" ")
        raise ArgumentError, parser.banner if account.empty? || xls.to_s.empty?

        options.merge(account: account, xls: xls)
      end

      def self.discard_backup(path)
        Session.discard_backup(path)
      end

      def self.format_row(row, width: TTY::Screen.width, reason: nil)
        amount = format("%.2f", (row.amount_cents / 100.0).round(2))
        sign = row.type.to_s == "REMOVAL" ? "-" : "+"
        prefix = "#{sign}  #{row.date}  #{FinecoImport.preview_type(row).ljust(16)}  #{amount.rjust(8)}  "
        reason_part = reason.to_s.empty? ? "" : "  #{reason}"
        available = [Integer(width) - 2 - prefix.size - reason_part.size, 0].max
        security = row.security.to_s.empty? ? "" : "S #{row.security}  "
        dest = row.offset_account.to_s.empty? ? "" : " → #{row.offset_account}"
        middle = if dest.size >= available
          truncate_note(dest, available)
        elsif security.size + dest.size >= available
          "#{truncate_note(security, available - dest.size)}#{dest}"
        else
          note = truncate_note(row.description.to_s, available - security.size - dest.size)
          "#{security}#{note}#{dest}"
        end
        "#{prefix}#{middle}#{reason_part}"
      end

      def self.preview_sections(import_rows, excluded_rows, existing_rows = [], exclude: nil, width: TTY::Screen.width)
        sections = []
        excluded_lines = Array(excluded_rows).map { |row| format_row(row, width: width) }
        if exclude || excluded_lines.any?
          sections << RowPreview::Section.new(
            title: "EXCLUDED",
            lines: excluded_lines,
            page_size: PREVIEW_ROWS
          )
        end
        existing_lines = Array(existing_rows).map { |row| format_row(row, width: width) }
        if existing_lines.any?
          sections << RowPreview::Section.new(
            title: "EXISTING",
            lines: existing_lines,
            page_size: PREVIEW_ROWS
          )
        end
        sections << RowPreview::Section.new(
          title: "IMPORT",
          lines: Array(import_rows).map { |row| format_row(row, width: width) },
          counts: { create: Array(import_rows).size, update: 0 },
          page_size: PREVIEW_ROWS
        )
        sections
      end

      def self.discarded_sections(skipped, width: TTY::Screen.width)
        lines = Array(skipped).map { |item| format_row(item.row, width: width, reason: item.reason) }
        [
          RowPreview::Section.new(
            title: "DISCARDED",
            lines: lines,
            page_size: PREVIEW_ROWS
          )
        ]
      end

      def self.unquote(value)
        text = value.to_s.strip
        return text[1..-2] if text.match?(/\A(["']).*\1\z/)

        text
      end

      def self.truncate_note(text, max)
        return "" if max <= 0
        return text if text.length <= max
        return "..."[0, max] if max <= 3

        "#{text[0, max - 3]}..."
      end
      private_class_method :unquote, :truncate_note

      private

      def print_summary(account, client, options, result, backup)
        last_date = FinecoImport.last_transaction_date(client, account.uuid)
        puts "Account #{account.name} (#{account.currencyCode})"
        puts last_date ? "Last portfolio transaction: #{last_date}" : "No dated transactions on this account yet"
        puts "Exclude: #{options[:exclude]}" if options[:exclude]
        options[:match_security].each { |pattern| puts "Match security: #{pattern}" }
        options[:match_offset_account].each { |spec| puts "Match offset account: #{spec}" }
        puts "Already in portfolio: #{result.existing.size}" if result.existing.any?
        puts "Discarded: #{result.skipped.size}" if Array(result.skipped).any?
        puts "Backup: #{backup}"
      end

      def preview(account_name, result, exclude: nil)
        RowPreview.new(
          account_name,
          self.class.preview_sections(result.candidates, result.excluded, result.existing, exclude: exclude),
          page_size: PREVIEW_ROWS,
          prompt: "[#{account_name}] import (Y)es or Esc/Q to skip?",
          choices: %w[Y]
        ).run
      end

      def review_discarded(account_name, skipped)
        return if Array(skipped).empty?

        RowPreview.new(
          account_name,
          self.class.discarded_sections(skipped),
          page_size: PREVIEW_ROWS,
          prompt: "[#{account_name}] discarded #{skipped.size} — Enter/Q to continue",
          choices: [],
          acknowledge: true,
          help: "↑/↓ row  u/v page ±#{PREVIEW_ROWS}  enter/q continue"
        ).run
      end
    end
  end
end
