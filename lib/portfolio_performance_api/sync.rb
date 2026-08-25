# frozen_string_literal: true

require_relative "errors"
require_relative "decryptor"
require_relative "file_reader"
require_relative "proto/client_pb"
require_relative "config"
require_relative "drive_client"
require_relative "portfolio_store"
require_relative "sheets_client"
require_relative "transaction_sync"
require_relative "sync_preview"

module PortfolioPerformanceApi
  class Sync
    def self.run(argv = [])
      command = Array(argv)[0].to_s
      case command
      when "", "sync" then new.run
      when "cleanup" then new.cleanup
      else abort "Usage: bin/sync [cleanup]"
      end
    end

    def run
      portfolio_id = Config.drive_file_id
      spreadsheet_id = Config.sync_drive_file_id
      password = Config.portfolio_password
      abort "missing PORTFOLIO_GOOGLE_DRIVE_FILE_ID" if portfolio_id.to_s.empty?
      abort "missing SYNC_GOOGLE_DRIVE_FILE_ID" if spreadsheet_id.to_s.empty?
      abort "missing GOOGLE_SERVICE_ACCOUNT_JSON" if Config.service_account_json.to_s.empty?

      session = DriveClient.new(file_id: portfolio_id, scope: DriveClient::SYNC_SCOPE)
      sheets = SheetsClient.new(session: session, spreadsheet_id: spreadsheet_id)

      downloaded = session.download
      loaded = PortfolioStore.load_bytes(
        downloaded.fetch(:bytes),
        password: password,
        path: downloaded.dig(:meta, :name)
      )
      skip_rows = Config.sync_skip_rows
      chunk_size = Config.sync_rows_chunk
      preview_rows = Config.sync_preview_rows
      names = TransactionSync.uuid_names(loaded.client)
      gids = sheets.sheet_gids
      known_sheets = gids.keys
      portfolio_changed = false

      unique_titles(TransactionSync.vehicles(loaded.client)).each do |title, vehicle|
        raw_rows = known_sheets.include?(title) ? sheets.read_rows(title) : []
        sheet_plan, portfolio_plan = account_plans(
          loaded.client, vehicle, raw_rows, names, skip_rows
        )
        puts "#{sheet_link(vehicle.name, spreadsheet_id, gids[title])}: " \
             "spreadsheet +#{sheet_plan.create_sheet.size}/~#{sheet_plan.update_sheet.size}  " \
             "portfolio +#{portfolio_plan.create_portfolio.size}/~#{portfolio_plan.update_portfolio.size}"

        if empty_plan?(sheet_plan) && empty_plan?(portfolio_plan)
          puts "#{vehicle.name}: already in sync"
          next
        end

        choice = preview_account(vehicle.name, sheet_plan, portfolio_plan, preview_rows)
        if choice == "N"
          puts "#{vehicle.name}: skipped"
          next
        end
        if %w[S B].include?(choice)
          unless sheet_plan.create_sheet.empty? && sheet_plan.update_sheet.empty?
            unless known_sheets.include?(title)
              sheets.ensure_sheet(title, known_titles: known_sheets)
              known_sheets << title
            end
            TransactionSync.apply_sheet(
              sheets, title, sheet_plan,
              skip_rows: skip_rows, chunk_size: chunk_size, raw_rows: raw_rows, kind: vehicle.kind
            )
            puts "#{vehicle.name}: spreadsheet written"
          end
        end
        if %w[P B].include?(choice)
          records = portfolio_plan.create_portfolio + portfolio_plan.update_portfolio
          unless records.empty?
            applied = TransactionSync.apply_portfolio!(
              loaded.client,
              vehicle,
              records
            )
            if applied.positive?
              portfolio_changed = true
              names = TransactionSync.uuid_names(loaded.client)
              puts "#{vehicle.name}: portfolio updated"
            else
              puts "#{vehicle.name}: portfolio unchanged"
            end
          end
        end
      end

      if portfolio_changed
        session.upload(PortfolioStore.dump(loaded))
        puts "Uploaded portfolio #{downloaded.dig(:meta, :name)}"
      else
        puts "Portfolio file unchanged"
      end
    rescue Error, ArgumentError => error
      abort error.message
    end

    def cleanup(sheets: nil, spreadsheet_id: nil, skip_rows: nil, titles: nil)
      spreadsheet_id = spreadsheet_id.to_s.empty? ? Config.sync_drive_file_id : spreadsheet_id
      skip_rows = skip_rows.nil? ? Config.sync_skip_rows : skip_rows
      if sheets.nil?
        abort "missing SYNC_GOOGLE_DRIVE_FILE_ID" if spreadsheet_id.to_s.empty?
        abort "missing GOOGLE_SERVICE_ACCOUNT_JSON" if Config.service_account_json.to_s.empty?
        abort "missing PORTFOLIO_GOOGLE_DRIVE_FILE_ID" if Config.drive_file_id.to_s.empty?

        session = DriveClient.new(file_id: Config.drive_file_id, scope: DriveClient::SYNC_SCOPE)
        sheets = SheetsClient.new(session: session, spreadsheet_id: spreadsheet_id)
        downloaded = session.download
        loaded = PortfolioStore.load_bytes(
          downloaded.fetch(:bytes),
          password: Config.portfolio_password,
          path: downloaded.dig(:meta, :name)
        )
        titles ||= unique_titles(TransactionSync.vehicles(loaded.client)).keys
      end
      gids = sheets.respond_to?(:sheet_gids) ? sheets.sheet_gids : {}
      titles ||= gids.keys
      known_sheets = gids.keys
      known_sheets = sheets.sheet_titles if known_sheets.empty?

      clear_rest = false
      titles.each do |title|
        unless known_sheets.include?(title)
          puts "#{title}: no sheet, skipped"
          next
        end
        raw_rows = sheets.read_rows(title)
        unless data_rows?(raw_rows, skip_rows)
          puts "#{title}: already empty"
          next
        end
        unless clear_rest
          choice = confirm_cleanup(spreadsheet_id, title, gid: gids[title])
          if choice == :no
            puts "#{title}: skipped"
            next
          end
          clear_rest = true if choice == :all
        end
        sheets.clear_data_rows(title, skip_rows: skip_rows)
        puts "#{title}: spreadsheet rows cleared"
      end
    rescue Error, ArgumentError => error
      abort error.message
    end

    def self.confirm_choice(answer)
      text = answer.to_s
      return :no if text.empty? || text == "\e" || text.start_with?("\e")

      case text.strip.upcase
      when "Y", "YES" then :yes
      when "A", "ALL" then :all
      else :no
      end
    end

    private

    def account_plans(client, vehicle, raw_rows, names, skip_rows)
      plan = TransactionSync.account_plan(
        client, vehicle, raw_rows, names: names, skip_rows: skip_rows
      )
      TransactionSync.split_plan(plan)
    end

    def empty_plan?(plan)
      plan.create_sheet.empty? && plan.update_sheet.empty? &&
        plan.create_portfolio.empty? && plan.update_portfolio.empty?
    end

    def preview_account(account_name, sheet_plan, portfolio_plan, page_size)
      portfolio_lines, sheet_lines = SyncPreview.lines_for(
        TransactionSync::Plan.new(
          create_sheet: sheet_plan.create_sheet,
          update_sheet: sheet_plan.update_sheet,
          create_portfolio: portfolio_plan.create_portfolio,
          update_portfolio: portfolio_plan.update_portfolio
        )
      )
      SyncPreview.new(
        account_name,
        portfolio_lines,
        sheet_lines,
        page_size: page_size,
        portfolio_counts: {
          create: portfolio_plan.create_portfolio.size,
          update: portfolio_plan.update_portfolio.size
        },
        sheet_counts: {
          create: sheet_plan.create_sheet.size,
          update: sheet_plan.update_sheet.size
        }
      ).run
    end

    def unique_titles(accounts)
      titles = SheetsClient.unique_titles(accounts)
      titles.zip(accounts).to_h
    end

    def data_rows?(raw_rows, skip_rows)
      Array(raw_rows)[(Integer(skip_rows) + 1)..]&.any? { |row| Array(row).any? { |cell| !cell.to_s.strip.empty? } }
    end

    def sheet_link(label, spreadsheet_id, gid = nil)
      SheetsClient.terminal_link(label, SheetsClient.spreadsheet_url(spreadsheet_id, gid: gid))
    end

    def confirm_cleanup(spreadsheet_id, title, gid: nil)
      linked_id = sheet_link(spreadsheet_id, spreadsheet_id)
      linked_sheet = sheet_link(title, spreadsheet_id, gid)
      prompt = "All rows > headers in #{linked_id}, sheet #{linked_sheet} will be deleted: are you sure? y/n/a "
      $stderr.print prompt
      $stderr.flush
      choice = $stdin.tty? ? read_cleanup_key : self.class.confirm_choice($stdin.gets.to_s)
      $stderr.puts({ yes: "y", no: "n", all: "a" }.fetch(choice))
      choice
    end

    def read_cleanup_key
      reader = TTY::Reader.new(interrupt: :exit)
      choice = nil
      reader.on(:keyescape) { choice = :no }
      reader.on(:keypress) do |event|
        choice = :yes if %w[y Y].include?(event.value)
        choice = :no if %w[n N].include?(event.value) || event.value == "\e"
        choice = :all if %w[a A].include?(event.value)
      end
      reader.read_keypress until choice
      choice
    end
  end
end
