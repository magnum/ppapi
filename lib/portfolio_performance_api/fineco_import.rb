# frozen_string_literal: true

require "date"
require "securerandom"
require "time"

require_relative "fineco_xls"
require_relative "proto/client_pb"
require_relative "transaction_identity"
require_relative "transaction_sync"
require_relative "transaction_types"

module PortfolioPerformanceApi
  # Fineco row → Portfolio Performance transaction.
  module FinecoImport
    DEFAULT_SECURITY_SPEC = "/Compravendita Titoli\\s+(.+?)\\s+Qta/"
    CROSS_ENTRY_TYPES = TransactionTypes::CROSS_ENTRY
    SHARE_DIVISOR = 100_000_000
    SHARE_MATCH_DAYS = 7
    CASH_MATCH_DAYS = 1
    ExistingTx = Struct.new(:id, :date, :cents, :security, :shares, keyword_init: true)
    Skipped = Struct.new(:row, :reason, keyword_init: true)
    Result = Struct.new(:excluded, :existing, :candidates, :skipped, keyword_init: true)

    module_function

    def prepare(client, account, rows, security_specs: [], offset_specs: [], exclude: nil)
      excluded, kept = FinecoXls.partition_excluded(rows, exclude)
      apply_matches!(kept, security_specs, offset_specs)
      assign_types!(kept, account, client)
      invalid, valid = partition_invalid(kept, account, client)
      existing, candidates = partition_existing(valid, client, account)
      skipped = skipped_rows(excluded, "matched --exclude") +
                invalid +
                skipped_rows(existing, "already in portfolio")
      Result.new(excluded: excluded, existing: existing, candidates: candidates, skipped: skipped)
    end

    def append!(client, account, rows, at: Time.now.utc, skipped: nil)
      list = Array(rows)
      repair_cross_entries!(client, at: at)
      source = import_source(at: at)
      imported = 0
      list.each do |row|
        client.transactions << build_transaction(row, account, client: client, source: source)
        imported += 1
      rescue ArgumentError => error
        raise unless skipped

        skipped << Skipped.new(row: row, reason: error.message)
      end
      imported
    end

    # --- types -------------------------------------------------------------

    def filled?(value)
      !value.to_s.strip.empty?
    end

    def buy_sell?(type)
      %w[PURCHASE SALE].include?(type.to_s)
    end

    def cross_entry?(type)
      CROSS_ENTRY_TYPES.include?(type.to_s)
    end

    def portfolio_type(row, account: nil, client: nil)
      security = filled?(row.security)
      offset = filled?(row.offset_account)
      inflow = row.type.to_s != "REMOVAL"

      if security && offset
        inflow ? :SALE : :PURCHASE
      elsif security
        :DEPOSIT
      elsif offset
        :CASH_TRANSFER
      else
        row.type
      end
    end

    def assign_types!(rows, account, client)
      Array(rows).each { |row| row.proto_type = portfolio_type(row, account: account, client: client) }
    end

    def effective_type(row, account: nil, client: nil)
      row.proto_type || portfolio_type(row, account: account, client: client)
    end

    def preview_type(row, account: nil, client: nil)
      type = effective_type(row, account: account, client: client)
      (TransactionTypes.coerce(type, kind: :deposit) || type).to_s
    end

    # --- match specs -------------------------------------------------------

    def parse_match_spec(spec, flag: "--match")
      rule = Match.parse(spec, flag: flag)
      [rule.regexp, rule.fixed]
    end

    def parse_offset_spec(spec)
      parse_match_spec(spec, flag: "--match-offset-account")
    end

    def compile_regexp(pattern)
      Match.compile(pattern)
    end

    def capturing?(regexp)
      Match.new(regexp).capturing?
    end

    def value_from_cells(cells, regexp, fixed = "")
      Match.new(regexp, fixed).extract(cells)
    end

    def extract_from_cells(cells, regexp)
      value_from_cells(cells, regexp, "")
    end

    def apply_matches!(rows, security_specs, offset_specs)
      securities = Array(security_specs).filter_map do |spec|
        next if spec.to_s.strip.empty?

        Match.parse(spec, flag: "--match-security")
      end
      offsets = Array(offset_specs).map { |spec| Match.parse(spec, flag: "--match-offset-account") }

      Array(rows).each do |row|
        cells = FinecoXls.row_cells(row)
        row.security = first_match(cells, securities) unless filled?(row.security)
        row.offset_account = first_match(cells, offsets) unless filled?(row.offset_account)
      end
      rows
    end

    def validate_matches!(client, rows, account: nil)
      Array(rows).each do |row|
        reason = match_skip_reason(row, client, account)
        raise ArgumentError, reason if reason
      end
    end

    def match_skip_reason(row, client, account = nil)
      if filled?(row.security) && find_security(client, row.security).nil?
        return "security not found: #{row.security}"
      end
      if filled?(row.offset_account) && find_vehicle(client, row.offset_account).nil?
        return "offset account not found: #{row.offset_account}"
      end
      if filled?(row.security) && filled?(row.offset_account)
        vehicle = find_vehicle(client, row.offset_account)
        unless vehicle&.kind == :securities
          return "buy/sell offset must be a securities account: #{row.offset_account}"
        end
      end

      type = TransactionTypes.coerce(effective_type(row, account: account, client: client), kind: :deposit)
      return "unsupported Portfolio Performance type: #{effective_type(row)}" if type.nil?

      nil
    end

    def partition_invalid(rows, account, client)
      invalid = []
      valid = []
      Array(rows).each do |row|
        reason = match_skip_reason(row, client, account)
        if reason
          invalid << Skipped.new(row: row, reason: reason)
        else
          valid << row
        end
      end
      [invalid, valid]
    end

    def skipped_rows(rows, reason)
      Array(rows).map { |row| Skipped.new(row: row, reason: reason) }
    end

    # --- identity / already imported --------------------------------------

    def identity_for(row, account, client: nil)
      type = effective_type(row, account: account, client: client)
      security = buy_sell?(type) ? row.security.to_s : ""
      TransactionIdentity.id(
        account.name,
        row.date,
        TransactionSync.signed_cents(type, row.amount_cents),
        row.description,
        row.offset_account.to_s,
        security
      )
    end

    def partition_existing(rows, client, account)
      remaining = portfolio_existing(client, account)
      existing = []
      missing = []
      Array(rows).each do |row|
        index = take_existing_index(remaining, row, account, client: client)
        if index
          remaining.delete_at(index)
          existing << row
        else
          missing << row
        end
      end
      [existing, missing]
    end

    def portfolio_existing(client, account)
      names = TransactionSync.uuid_names(client)
      secs = TransactionSync.security_names(client)
      client.transactions.filter_map do |tx|
        rec = TransactionSync.from_proto(tx, account, names: names, security_names: secs)
        next unless rec

        security = ""
        if tx.respond_to?(:has_security?) && tx.has_security?
          security = secs[tx.security].to_s.strip
        end
        ExistingTx.new(
          id: rec.id,
          date: rec.date,
          cents: amount_in_account_cents(tx, account),
          security: security,
          shares: tx.shares.to_i
        )
      end
    end

    def portfolio_identities(client, account)
      portfolio_existing(client, account).map(&:id)
    end

    # --- write proto -------------------------------------------------------

    def import_source(at: Time.now.utc)
      "ppapi import #{at.utc.strftime("%Y%m%dT%H%M%S")}"
    end

    def build_transaction(row, account, client: nil, source: nil, at: Time.now.utc)
      now = at.utc
      date = Time.utc(row.date.year, row.date.month, row.date.day)
      type = TransactionTypes.coerce(effective_type(row, account: account, client: client), kind: :deposit)
      raise ArgumentError, "unsupported Portfolio Performance type: #{effective_type(row)}" if type.nil?

      tx = Proto::PTransaction.new(
        uuid: SecureRandom.uuid,
        type: type,
        account: account.uuid,
        date: Google::Protobuf::Timestamp.new(seconds: date.to_i),
        currencyCode: account.currencyCode,
        amount: row.amount_cents,
        shares: buy_sell?(type) ? extract_shares(row) : 0,
        note: row.description,
        updatedAt: Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec),
        source: source || import_source(at: now)
      )
      assign_counterparts!(tx, row, account, client)
      assert_pp_safe!(tx)
      tx
    end

    def assert_pp_safe!(tx)
      type = tx.type.to_s
      unless TransactionTypes.proto?(type)
        raise ArgumentError, "unsupported Portfolio Performance type: #{type}"
      end
      return if TransactionTypes.loadable?(tx)

      raise ArgumentError, "transaction is not loadable by Portfolio Performance: #{type}"
    end

    def repair_cross_entries!(client, at: Time.now.utc)
      stamped = 0
      client.transactions.each do |tx|
        next unless cross_entry?(tx.type)

        missing = tx.otherUuid.to_s.empty? || !tx.has_otherUpdatedAt?
        stamp_cross_entry!(tx, at: at)
        stamped += 1 if missing
      end
      stamped
    end

    def extract_shares(row)
      text = ([row.description] + FinecoXls.row_cells(row)).compact.join(" ")
      match = text.match(%r{Qta/Val\.nom\.\s*([\d.,]+)}i)
      return 0 unless match

      (Float(italian_number(match[1])) * SHARE_DIVISOR).round
    rescue ArgumentError
      0
    end

    def italian_number(value)
      text = value.to_s.strip.gsub(/[€$£\s]/, "")
      if text.include?(",") && text.include?(".")
        text.delete(".").tr(",", ".")
      elsif text.include?(",")
        text.tr(",", ".")
      else
        text
      end
    end

    # --- lookup ------------------------------------------------------------

    def find_account(client, name)
      find_named(client.accounts, name)
    end

    def find_security(client, name)
      find_named(client.securities, name)
    end

    def find_vehicle(client, name, kind: nil)
      text = name.to_s.strip
      return if text.empty?

      vehicles = TransactionSync.vehicles(client)
      vehicles = vehicles.select { |item| item.kind == kind } if kind
      vehicles.find { |item| item.name == text } ||
        vehicles.find { |item| item.name.casecmp?(text) } ||
        vehicles.find { |item| item.uuid == text }
    end

    def last_transaction_date(client, account_uuid)
      client.transactions.filter_map do |tx|
        next unless tx.has_account? && tx.account == account_uuid
        next unless tx.has_date?

        Time.at(tx.date.seconds).utc.to_date
      end.max
    end

    # --- FX ----------------------------------------------------------------

    def convert_cents(client, from_account, to_account, cents, date)
      return cents if from_account.currencyCode.to_s == to_account.currencyCode.to_s

      (Integer(cents) * fx_rate(client, from_account, to_account, date)).round
    end

    def encode_decimal(rate)
      scale = 10
      unscaled = (Float(rate) * (10**scale)).round
      Proto::PDecimal.new(
        scale: scale,
        precision: unscaled.abs.to_s.length,
        value: biginteger_bytes(unscaled)
      )
    end

    def amount_in_account_cents(tx, account)
      code = account.currencyCode.to_s
      return tx.amount if tx.currencyCode.to_s == code

      unit = tx.units.find do |item|
        item.type.to_s == "GROSS_VALUE" &&
          item.has_fxCurrencyCode? && item.fxCurrencyCode.to_s == code &&
          item.has_fxAmount?
      end
      unit ? unit.fxAmount : tx.amount.abs
    end

    def rate_from_unit(unit, from_code, to_code)
      if unit.currencyCode.to_s == from_code && unit.fxCurrencyCode.to_s == to_code
        unit.fxAmount.to_f / unit.amount
      elsif unit.currencyCode.to_s == to_code && unit.fxCurrencyCode.to_s == from_code
        unit.amount.to_f / unit.fxAmount
      else
        raise ArgumentError,
              "FX unit #{unit.currencyCode}/#{unit.fxCurrencyCode} does not match #{from_code}/#{to_code}"
      end
    end

    class Match
      attr_reader :regexp, :fixed

      def initialize(regexp, fixed = "")
        @regexp = regexp
        @fixed = fixed.to_s.strip
      end

      def self.parse(spec, flag: "--match")
        text = spec.to_s.strip
        raise ArgumentError, "invalid #{flag} #{spec.inspect} (expected /REGEXP/ or /REGEXP/VALUE)" if text.empty?

        text = "/#{text}/" unless text.start_with?("/")
        match = text.match(%r{\A/(.*)/(.*)\z}m)
        if match.nil? || match[1].empty?
          raise ArgumentError, "invalid #{flag} #{spec.inspect} (expected /REGEXP/ or /REGEXP/VALUE)"
        end

        rule = new(compile(match[1]), match[2])
        unless rule.capturing? || !rule.fixed.empty?
          raise ArgumentError, "invalid #{flag} #{spec.inspect} (need a capture group or /REGEXP/VALUE)"
        end

        rule
      end

      def self.compile(pattern)
        text = pattern.to_s.strip
        raise ArgumentError, "empty regexp" if text.empty?

        Regexp.new(text, Regexp::IGNORECASE)
      end

      def capturing?
        return true unless regexp.names.empty?

        unescaped = regexp.source.gsub(/\\./, "")
        unescaped.match?(/\([^?]/) || unescaped.match?(/\(\?</)
      end

      def extract(cells)
        Array(cells).each do |cell|
          match = regexp.match(cell.to_s)
          next unless match

          captured = match.captures.find { |value| value && !value.strip.empty? }
          return captured.strip if captured
          return fixed unless fixed.empty?
        end
        nil
      end
    end

    def first_match(cells, rules)
      rules.each do |rule|
        value = rule.extract(cells)
        return value if value
      end
      nil
    end

    def find_named(collection, name)
      text = name.to_s.strip
      return if text.empty?

      collection.find { |item| item.name == text } ||
        collection.find { |item| item.name.casecmp?(text) } ||
        collection.find { |item| item.uuid == text }
    end

    def take_existing_index(remaining, row, account, client:)
      id = identity_for(row, account, client: client)
      index = remaining.index { |slot| slot.id == id }
      return index if index

      shares = extract_shares(row)
      security = row.security.to_s.strip
      if filled?(security) && shares.positive?
        index = remaining.index do |slot|
          slot.shares == shares &&
            filled?(slot.security) &&
            slot.security.casecmp?(security) &&
            (slot.date - row.date).abs <= SHARE_MATCH_DAYS
        end
        return index if index
      end

      remaining.index { |slot| (slot.date - row.date).abs <= CASH_MATCH_DAYS && slot.cents == row.amount_cents.abs }
    end

    def assign_counterparts!(tx, row, account, client)
      type = tx.type.to_s
      if buy_sell?(type)
        assign_buy_sell!(tx, row, account, client)
        return
      end
      return if row.offset_account.to_s.empty?
      raise ArgumentError, "client required to resolve offset account" if client.nil?

      if type == "CASH_TRANSFER"
        assign_cash_transfer!(tx, row, account, client)
      else
        assign_offset!(tx, row.offset_account, client)
      end
    end

    def assign_buy_sell!(tx, row, account, client)
      raise ArgumentError, "client required to resolve buy/sell" if client.nil?
      raise ArgumentError, "buy/sell needs an offset securities account" if row.offset_account.to_s.empty?

      vehicle = find_vehicle(client, row.offset_account)
      raise ArgumentError, "offset account not found: #{row.offset_account}" unless vehicle
      unless vehicle.kind == :securities
        raise ArgumentError, "buy/sell offset must be a securities account: #{row.offset_account}"
      end

      security = find_security(client, row.security)
      raise ArgumentError, "security not found: #{row.security}" unless security

      tx.account = account.uuid
      tx.portfolio = vehicle.uuid
      tx.security = security.uuid
      stamp_cross_entry!(tx)
    end

    def assign_cash_transfer!(tx, row, account, client)
      other = find_account(client, row.offset_account)
      raise ArgumentError, "offset account not found: #{row.offset_account}" unless other

      inbound = row.type.to_s != "REMOVAL"
      source = inbound ? other : account
      dest = inbound ? account : other
      tx.account = source.uuid
      tx.otherAccount = dest.uuid
      tx.currencyCode = source.currencyCode
      stamp_cross_entry!(tx)

      source_cents, dest_cents = transfer_amounts(client, row, source, dest, inbound)
      tx.amount = source_cents
      return if source.currencyCode.to_s == dest.currencyCode.to_s

      tx.units << Proto::PTransactionUnit.new(
        type: :GROSS_VALUE,
        amount: source_cents,
        currencyCode: source.currencyCode,
        fxAmount: dest_cents,
        fxCurrencyCode: dest.currencyCode,
        fxRateToBase: encode_decimal(source_cents.to_f / dest_cents)
      )
    end

    def transfer_amounts(client, row, source, dest, inbound)
      if source.currencyCode.to_s == dest.currencyCode.to_s
        return [row.amount_cents, row.amount_cents]
      end

      if inbound
        dest_cents = row.amount_cents
        [convert_cents(client, dest, source, dest_cents, row.date), dest_cents]
      else
        source_cents = row.amount_cents
        [source_cents, convert_cents(client, source, dest, source_cents, row.date)]
      end
    end

    def assign_offset!(tx, name, client)
      vehicle = find_vehicle(client, name)
      raise ArgumentError, "offset account not found: #{name}" unless vehicle

      if vehicle.kind == :securities
        tx.portfolio = vehicle.uuid
      else
        tx.otherAccount = vehicle.uuid
      end
    end

    def stamp_cross_entry!(tx, at: Time.now.utc)
      now = at.utc
      tx.otherUuid = SecureRandom.uuid if tx.otherUuid.to_s.empty?
      return if tx.has_otherUpdatedAt?

      tx.otherUpdatedAt = Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec)
    end

    def fx_rate(client, from_account, to_account, date)
      from = from_account.currencyCode.to_s
      to = to_account.currencyCode.to_s
      pair = [from_account.uuid, to_account.uuid]
      candidates = client.transactions.select do |tx|
        next false unless tx.type.to_s == "CASH_TRANSFER"
        next false unless tx.has_account? && tx.has_otherAccount?
        next false unless pair.include?(tx.account) && pair.include?(tx.otherAccount)

        unit = gross_fx_unit(tx)
        unit && unit.amount.positive? && unit.fxAmount.positive?
      end
      if candidates.empty?
        raise ArgumentError,
              "no FX rate between #{from_account.name} (#{from}) and #{to_account.name} (#{to})"
      end

      best = candidates.min_by do |tx|
        tx_date = tx.has_date? ? Time.at(tx.date.seconds).utc.to_date : Date.new(1970, 1, 1)
        (tx_date - date).abs
      end
      rate_from_unit(gross_fx_unit(best), from, to)
    end

    def gross_fx_unit(tx)
      tx.units.find do |unit|
        unit.type.to_s == "GROSS_VALUE" && unit.has_fxAmount? && unit.has_fxCurrencyCode?
      end
    end

    def biginteger_bytes(value)
      int = Integer(value)
      raise ArgumentError, "FX rate must be positive" unless int.positive?

      hex = int.to_s(16)
      hex = "0#{hex}" if hex.length.odd?
      bytes = [hex].pack("H*")
      bytes.getbyte(0) >= 0x80 ? "\x00".b + bytes : bytes
    end
  end
end
