# frozen_string_literal: true

require "date"
require "digest"
require "securerandom"
require "time"

require_relative "proto/client_pb"
require_relative "transaction_identity"

module PortfolioPerformanceApi
  module TransactionSync
    HEADERS = %w[date type amount currency description destination uuid].freeze
    DEPOSIT_EXTRA_COLUMNS = ["security", "shares", "per share", "offset account", "note", "source"].freeze
    SECURITIES_EXTRA_COLUMNS = ["symbol", "isin", "shares", "quote", "fees", "taxes", "net transaction value"].freeze
    DEPOSIT_EXTRA_KEYS = %i[security shares per_share offset_account note source].freeze
    SECURITIES_EXTRA_KEYS = %i[symbol isin shares quote fees taxes net].freeze
    DERIVED_EXTRA_KEYS = %i[per_share quote net].freeze
    SECURITY_REF_KEYS = %i[security symbol isin].freeze
    SHARE_SCALE = 100_000_000
    EXTRA_HEADERS = {
      security: [/\Asecurity\z/, /\Atitolo\z/],
      shares: [/\Ashares\z/],
      per_share: [/per[_\s-]*share/],
      offset_account: [/offset[_\s-]*account/],
      note: [/\Anote\z/],
      source: [/\Asource\z/],
      symbol: [/\Asymbol\z/, /\Aticker\z/],
      isin: [/\Aisin\z/],
      quote: [/\Aquote\z/],
      fees: [/\Afees?\z/],
      taxes: [/\Ataxes?\z/],
      net: [/net[_\s-]*(transaction[_\s-]*)?value/]
    }.freeze
    OUTFLOW_TYPES = %w[
      PURCHASE SALE OUTBOUND_DELIVERY REMOVAL INTEREST_CHARGE TAX FEE
    ].freeze
    TYPE_ALIASES = {
      "withdrawal" => "REMOVAL",
      "prelievo" => "REMOVAL",
      "uscite" => "REMOVAL",
      "deposit" => "DEPOSIT",
      "versamento" => "DEPOSIT",
      "entrate" => "DEPOSIT",
      "transfer" => "CASH_TRANSFER",
      "trasferimento" => "CASH_TRANSFER"
    }.freeze
    DEFAULT_COLUMNS = {
      date: 0,
      type: 1,
      amount: 2,
      currency: 3,
      description: 4,
      destination: 5,
      uuid: 6
    }.freeze

    Vehicle = Struct.new(:kind, :name, :uuid, :currency, keyword_init: true)
    Record = Struct.new(
      :id, :account_name, :date, :type, :signed_cents, :currency, :description, :destination, :uuid, :row_number,
      :extras,
      keyword_init: true
    )
    Plan = Struct.new(:create_sheet, :create_portfolio, :update_sheet, :update_portfolio, keyword_init: true)
    Result = Struct.new(:created_sheet, :created_portfolio, :updated_sheet, :updated_portfolio, keyword_init: true)

    module_function

    def identity_id(account_name, date, signed_cents, description, destination = "", security = "")
      TransactionIdentity.id(account_name, date, signed_cents, description, destination, security)
    end

    def signed_cents(type, amount_cents)
      cents = Integer(amount_cents).abs
      outflow?(type) ? -cents : cents
    end

    def outflow?(type)
      OUTFLOW_TYPES.include?(type.to_s)
    end

    def normalize_description(value)
      TransactionIdentity.normalize_description(value)
    end

    def normalize_type(value, signed_cents = nil)
      text = value.to_s.strip
      return TYPE_ALIASES[text.downcase] if TYPE_ALIASES.key?(text.downcase)
      return text.upcase if text.match?(/\A[A-Z_]+\z/)
      return "REMOVAL" if signed_cents.to_i.negative?
      return "DEPOSIT" if signed_cents.to_i.positive?

      nil
    end

    def vehicles(client)
      currencies = client.accounts.to_h { |account| [account.uuid, account.currencyCode] }
      deposits = client.accounts.map do |account|
        Vehicle.new(kind: :deposit, name: account.name, uuid: account.uuid, currency: account.currencyCode)
      end
      securities = client.portfolios.map do |portfolio|
        reference = portfolio.has_referenceAccount? ? currencies[portfolio.referenceAccount] : nil
        currency = reference.to_s.empty? ? client.baseCurrency : reference
        currency = "EUR" if currency.to_s.empty?
        Vehicle.new(kind: :securities, name: portfolio.name, uuid: portfolio.uuid, currency: currency)
      end
      deposits + securities
    end

    def uuid_names(client)
      vehicles(client).to_h { |vehicle| [vehicle.uuid, vehicle.name] }
    end

    def security_names(client)
      Array(client.securities).to_h { |security| [security.uuid, security.name.to_s] }
    end

    def name_index(client)
      vehicles(client).each_with_object({}) do |vehicle, index|
        index[vehicle.name] ||= vehicle
        index[vehicle.name.downcase] ||= vehicle
      end
    end

    def lookup_name(index, name)
      text = name.to_s.strip
      return if text.empty?

      index[text] || index[text.downcase]
    end

    def from_proto(tx, vehicle, names: {}, security_names: {}, securities: {})
      vehicle = wrap_vehicle(vehicle)
      return unless belongs?(tx, vehicle)
      return unless tx.has_date?

      date = Time.at(tx.date.seconds).utc.to_date
      description = tx.has_note? ? normalize_description(tx.note) : ""
      destination = destination_name(tx, vehicle, names)
      security = security_name(tx, security_names)
      cents = signed_cents(tx.type, tx.amount)
      Record.new(
        id: identity_id(vehicle.name, date, cents, description, destination, security),
        account_name: vehicle.name,
        date: date,
        type: tx.type.to_s,
        signed_cents: cents,
        currency: tx.currencyCode.to_s.empty? ? vehicle.currency : tx.currencyCode,
        description: description,
        destination: destination,
        uuid: tx.uuid,
        extras: extras_from_proto(tx, destination, security_names, securities)
      )
    end

    def extra_columns_for(kind)
      kind.to_s == "securities" ? SECURITIES_EXTRA_COLUMNS : DEPOSIT_EXTRA_COLUMNS
    end

    def extra_keys_for(kind)
      kind.to_s == "securities" ? SECURITIES_EXTRA_KEYS : DEPOSIT_EXTRA_KEYS
    end

    def headers_for(kind)
      HEADERS + extra_columns_for(kind)
    end

    def parse_sheet(raw_rows, account_name, currency:, skip_rows: 0, kind: :deposit)
      rows = Array(raw_rows)
      mapping = column_mapping(ensure_headers(rows[skip_rows], kind))
      rows.each_with_index.filter_map do |row, index|
        next if index < skip_rows
        next if header_row?(row)

        record = from_sheet_row(row, account_name, currency: currency, mapping: mapping)
        next unless record

        record.row_number = index + 1
        record
      end
    end

    def from_sheet_row(row, account_name, currency:, mapping: DEFAULT_COLUMNS)
      cells = Array(row)
      return if header_row?(cells)

      date = parse_date(cells[mapping[:date]])
      amount = parse_signed_cents(cells[mapping[:amount]])
      description = normalize_description(cells[mapping[:description]])
      return if date.nil? || amount.nil?

      type = normalize_type(cells[mapping[:type]], amount)
      return if type.nil?

      extras = extras_from_sheet(cells, mapping)
      destination = mapping[:destination] ? cells[mapping[:destination]].to_s.strip : ""
      destination = extras[:offset_account].to_s.strip if destination.empty?
      cents = signed_cents(type, amount)
      uuid = cells[mapping[:uuid]].to_s.strip
      currency_cell = cells[mapping[:currency]].to_s.strip
      Record.new(
        id: identity_id(account_name, date, cents, description, destination),
        account_name: account_name,
        date: date,
        type: type,
        signed_cents: cents,
        currency: currency_cell.empty? ? currency : currency_cell,
        description: description,
        destination: destination,
        uuid: uuid.empty? ? nil : uuid,
        extras: extras
      )
    end

    def find_sheet_row(sheet_records, identity)
      Array(sheet_records).find { |record| record.id == identity }
    end

    def take_sheet_row!(remaining, proto)
      if proto.uuid.to_s != ""
        index = remaining.find_index { |row| row.uuid.to_s == proto.uuid.to_s }
        return remaining.delete_at(index) if index
      end

      index = remaining.find_index { |row| row.id == proto.id }
      remaining.delete_at(index) if index
    end

    def to_sheet_row(record, header: nil, existing: nil)
      mapping = header ? column_mapping(header) : DEFAULT_COLUMNS.merge(extras: {})
      cells = existing ? Array(existing).dup : []
      write_cell(cells, mapping[:date], record.date.strftime("%Y-%m-%d"))
      write_cell(cells, mapping[:type], record.type)
      write_cell(cells, mapping[:amount], (record.signed_cents / 100.0).round(2))
      write_cell(cells, mapping[:currency], record.currency)
      write_cell(cells, mapping[:description], record.description)
      write_cell(cells, mapping[:destination], record.destination.to_s)
      write_cell(cells, mapping[:uuid], record.uuid.to_s)
      mapping.fetch(:extras, {}).each do |key, index|
        write_cell(cells, index, extra_cell(key, record))
      end
      cells
    end

    def account_plan(client, vehicle, raw_rows, names: uuid_names(client), skip_rows: 0)
      secs = security_names(client)
      securities = securities_by_uuid(client)
      portfolio_records = client.transactions.filter_map do |tx|
        from_proto(tx, vehicle, names: names, security_names: secs, securities: securities)
      end
      sheet_records = parse_sheet(
        raw_rows, vehicle.name, currency: vehicle.currency, skip_rows: skip_rows, kind: vehicle.kind
      )
      plan(
        portfolio_records,
        sheet_records,
        names_index: name_index(client),
        extra_keys: extra_keys_for(vehicle.kind),
        securities: Array(client.securities)
      )
    end

    def split_plan(plan)
      [
        Plan.new(
          create_sheet: plan.create_sheet,
          update_sheet: plan.update_sheet,
          create_portfolio: [],
          update_portfolio: []
        ),
        Plan.new(
          create_sheet: [],
          update_sheet: [],
          create_portfolio: plan.create_portfolio,
          update_portfolio: plan.update_portfolio
        )
      ]
    end

    def plan(portfolio_records, sheet_records, names_index: {}, extra_keys: [], securities: [])
      create_sheet = []
      create_portfolio = []
      update_sheet = []
      update_portfolio = []
      remaining = Array(sheet_records).dup

      Array(portfolio_records).each do |proto|
        row = take_sheet_row!(remaining, proto)
        if row.nil?
          create_sheet << proto
        else
          merged = merge(proto, row, names_index, extra_keys: extra_keys)
          unless same_row?(row, merged)
            merged.row_number = row.row_number
            update_sheet << merged
          end
          update_portfolio << merged unless same_proto?(
            proto, merged, names_index: names_index, securities: securities
          )
        end
      end

      Plan.new(
        create_sheet: create_sheet,
        create_portfolio: remaining,
        update_sheet: update_sheet,
        update_portfolio: update_portfolio
      )
    end

    def apply_portfolio!(client, vehicle, records)
      vehicle = wrap_vehicle(vehicle)
      names = name_index(client)
      changed = 0
      records.each do |record|
        existing = find_transaction(client, vehicle, record, names: uuid_names(client))
        if existing
          changed += 1 if update_transaction!(existing, record, vehicle, names, client)
        else
          client.transactions << build_transaction(vehicle, record, names, client)
          changed += 1
        end
      end
      changed
    end

    def apply_sheet(sheets, title, plan, skip_rows: 0, chunk_size: 100, raw_rows: nil, kind: :deposit)
      grid = materialize_sheet(
        raw_rows || sheets.read_rows(title), plan, skip_rows: skip_rows, kind: kind
      )
      return [plan.create_sheet.size, plan.update_sheet.size] if grid.size <= skip_rows

      sheets.write_chunks(title, grid, start_row: skip_rows + 1, chunk_size: chunk_size)
      [plan.create_sheet.size, plan.update_sheet.size]
    end

    def materialize_sheet(raw_rows, plan, skip_rows: 0, kind: :deposit)
      source = Array(raw_rows)
      grid = Array.new([source.size, skip_rows + 1].max) { |index| Array(source[index]).dup }
      grid[skip_rows] = ensure_headers(grid[skip_rows], kind)
      header = grid[skip_rows]

      Array(plan.update_sheet).each do |record|
        index = record.row_number.to_i - 1
        next if index.negative?

        grid << [] while grid.size <= index
        grid[index] = to_sheet_row(record, header: header, existing: grid[index])
      end
      Array(plan.create_sheet).each do |record|
        grid << to_sheet_row(record, header: header)
      end
      grid
    end

    def sheet_chunks(grid, start_row:, chunk_size:)
      data = Array(grid)[(start_row - 1)..]
      return [] if data.nil? || data.empty?

      size = [Integer(chunk_size), 1].max
      data.each_slice(size).map.with_index do |slice, index|
        first = start_row + (index * size)
        { start_row: first, end_row: first + slice.size - 1, values: slice }
      end
    end

    def column_mapping(header)
      labels = Array(header).map { |cell| cell.to_s.strip.downcase }
      return DEFAULT_COLUMNS.merge(extras: {}) unless header_row?(labels)

      {
        date: labels.index("date") || DEFAULT_COLUMNS[:date],
        type: labels.index("type") || DEFAULT_COLUMNS[:type],
        amount: labels.index("amount") || DEFAULT_COLUMNS[:amount],
        currency: labels.index("currency") || DEFAULT_COLUMNS[:currency],
        description: labels.index("description") || DEFAULT_COLUMNS[:description],
        destination: destination_column(labels),
        uuid: labels.index("uuid") || DEFAULT_COLUMNS[:uuid],
        extras: extra_columns(labels)
      }
    end

    def parse_date(value)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      text = value.to_s.strip
      return if text.empty?

      Date.iso8601(text)
    rescue ArgumentError
      begin
        Date.strptime(text, "%d/%m/%Y")
      rescue ArgumentError
        Date.parse(text)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def header_row?(cells)
      labels = Array(cells).map { |cell| cell.to_s.strip.downcase }
      labels.include?("date") && (labels.include?("amount") || labels.include?("type"))
    end

    def parse_signed_cents(value)
      return if value.nil? || value.to_s.strip.empty?
      return (value.to_f * 100).round if value.is_a?(Numeric)

      text = value.to_s.strip.gsub(/[€$£\s]/, "")
      last_comma = text.rindex(",")
      last_dot = text.rindex(".")
      text = if last_comma && last_dot
        if last_comma > last_dot
          text.delete(".").tr(",", ".")
        else
          text.delete(",")
        end
      elsif text.count(",") > 1
        text.delete(",")
      elsif text.include?(",")
        text.tr(",", ".")
      else
        text
      end
      (Float(text) * 100).round
    rescue ArgumentError
      nil
    end

    def wrap_vehicle(vehicle)
      return vehicle if vehicle.is_a?(Vehicle)
      return vehicle if vehicle.respond_to?(:kind) && vehicle.respond_to?(:currency)

      if vehicle.respond_to?(:currencyCode)
        Vehicle.new(kind: :deposit, name: vehicle.name, uuid: vehicle.uuid, currency: vehicle.currencyCode)
      else
        Vehicle.new(kind: :securities, name: vehicle.name, uuid: vehicle.uuid, currency: "EUR")
      end
    end

    def belongs?(tx, vehicle)
      if vehicle.kind == :securities
        (tx.has_portfolio? && tx.portfolio == vehicle.uuid) ||
          (tx.has_otherPortfolio? && tx.otherPortfolio == vehicle.uuid)
      else
        (tx.has_account? && tx.account == vehicle.uuid) ||
          (tx.has_otherAccount? && tx.otherAccount == vehicle.uuid)
      end
    end

    def security_name(tx, names)
      uuid = tx.respond_to?(:has_security?) && !tx.has_security? ? nil : tx.security
      return "" if uuid.to_s.empty?

      names[uuid].to_s.strip
    end

    def destination_name(tx, vehicle, names)
      other_uuid =
        if vehicle.uuid == (tx.has_account? ? tx.account : nil)
          (tx.has_otherAccount? && tx.otherAccount) ||
            (tx.has_otherPortfolio? && tx.otherPortfolio) ||
            (tx.has_portfolio? && tx.portfolio)
        elsif vehicle.uuid == (tx.has_otherAccount? ? tx.otherAccount : nil)
          tx.has_account? ? tx.account : nil
        elsif vehicle.uuid == (tx.has_portfolio? ? tx.portfolio : nil)
          (tx.has_otherPortfolio? && tx.otherPortfolio) ||
            (tx.has_otherAccount? && tx.otherAccount) ||
            (tx.has_account? && tx.account)
        elsif vehicle.uuid == (tx.has_otherPortfolio? ? tx.otherPortfolio : nil)
          tx.has_portfolio? ? tx.portfolio : nil
        end
      names[other_uuid].to_s
    end

    def destination_column(labels)
      labels.index("destination") ||
        labels.index { |label| label.match?(/destinat|offset|other/) }
    end

    def merge(proto, row, names_index = {}, extra_keys: [])
      destination = pick_destination(proto, row, names_index)
      Record.new(
        id: proto.id,
        account_name: proto.account_name,
        date: proto.date,
        type: row.type || proto.type,
        signed_cents: proto.signed_cents,
        currency: proto.currency,
        description: proto.description,
        destination: destination,
        uuid: proto.uuid.to_s.empty? ? row.uuid : proto.uuid,
        row_number: row.row_number,
        extras: merge_extras(proto, row, destination, extra_keys)
      )
    end

    def pick_destination(proto, row, names_index)
      sheet_dest = row.destination.to_s.strip
      proto_dest = proto.destination.to_s.strip
      return proto_dest if sheet_dest.empty?
      return sheet_dest if proto_dest.empty? || sheet_dest == proto_dest

      sheet_hit = lookup_name(names_index, sheet_dest)
      proto_hit = lookup_name(names_index, proto_dest)
      if proto_hit && (sheet_hit.nil? || sheet_hit.uuid == proto_hit.uuid ||
                       sheet_hit.name == proto.account_name)
        proto_dest
      else
        sheet_dest
      end
    end

    def same_row?(row, merged)
      row.type == merged.type &&
        row.currency == merged.currency &&
        row.uuid.to_s == merged.uuid.to_s &&
        row.description == merged.description &&
        row.destination.to_s == merged.destination.to_s &&
        row.signed_cents == merged.signed_cents &&
        row.date == merged.date &&
        same_extras?(row.extras, merged.extras, merged.extras.to_h.keys)
    end

    def same_proto?(proto, merged, names_index: {}, securities: [])
      keys = merged.extras.to_h.keys - DERIVED_EXTRA_KEYS - SECURITY_REF_KEYS - %i[offset_account]
      proto.type == merged.type &&
        proto.uuid.to_s == merged.uuid.to_s &&
        same_destination?(proto.destination, merged.destination, names_index) &&
        same_extras?(proto.extras, merged.extras, keys) &&
        same_security_ref?(proto, merged, securities)
    end

    def same_destination?(proto_dest, merged_dest, names_index)
      return true if proto_dest.to_s.strip == merged_dest.to_s.strip

      merged_hit = lookup_name(names_index, merged_dest)
      return true unless merged_hit

      proto_hit = lookup_name(names_index, proto_dest)
      proto_hit&.uuid == merged_hit.uuid
    end

    def same_security_ref?(proto, merged, securities)
      extras = merged.extras.to_h
      return true unless extras.keys.any? { |key| SECURITY_REF_KEYS.include?(key) }

      merged_sec = lookup_security_list(securities, extras)
      return true unless merged_sec

      proto_sec = lookup_security_list(securities, proto.extras.to_h)
      proto_sec&.uuid == merged_sec.uuid
    end

    def find_transaction(client, vehicle, record, names: {})
      if record.uuid.to_s != ""
        found = client.transactions.find { |tx| tx.uuid == record.uuid }
        return found if found
      end

      client.transactions.find do |tx|
        mapped = from_proto(
          tx, vehicle,
          names: names,
          security_names: security_names(client),
          securities: securities_by_uuid(client)
        )
        mapped && mapped.id == record.id
      end
    end

    def update_transaction!(tx, record, vehicle, names, client = nil)
      changed = false
      if tx.type.to_s != record.type
        tx.type = record.type
        changed = true
      end
      amount = record.signed_cents.abs
      if tx.amount != amount
        tx.amount = amount
        changed = true
      end
      if record.uuid.to_s != "" && tx.uuid != record.uuid
        tx.uuid = record.uuid
        changed = true
      end
      counterpart = assign_counterpart!(tx, vehicle, record, names)
      extras = apply_extras!(tx, record, client)
      changed || counterpart || extras
    end

    def build_transaction(vehicle, record, names, client = nil)
      now = Time.now.utc
      date = Time.utc(record.date.year, record.date.month, record.date.day)
      extras = record.extras.to_h
      note = extra_present?(extras[:note]) ? extras[:note].to_s : record.description
      tx = Proto::PTransaction.new(
        uuid: record.uuid.to_s.empty? ? SecureRandom.uuid : record.uuid,
        type: record.type,
        date: Google::Protobuf::Timestamp.new(seconds: date.to_i),
        currencyCode: record.currency.to_s.empty? ? vehicle.currency : record.currency,
        amount: record.signed_cents.abs,
        shares: extras[:shares].to_i,
        note: note,
        updatedAt: Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec)
      )
      tx.source = extras[:source].to_s if extra_present?(extras[:source])
      if vehicle.kind == :securities
        tx.portfolio = vehicle.uuid
      else
        tx.account = vehicle.uuid
      end
      assign_counterpart!(tx, vehicle, record, names)
      apply_extras!(tx, record, client)
      tx
    end

    def assign_counterpart!(tx, vehicle, record, names)
      dest = lookup_name(names, record.destination)
      return false unless dest

      before = [tx.has_account? && tx.account, tx.has_otherAccount? && tx.otherAccount,
                tx.has_portfolio? && tx.portfolio, tx.has_otherPortfolio? && tx.otherPortfolio]
      if vehicle.kind == :deposit && dest.kind == :deposit
        tx.otherAccount = dest.uuid
      elsif vehicle.kind == :deposit && dest.kind == :securities
        tx.portfolio = dest.uuid
      elsif vehicle.kind == :securities && dest.kind == :securities
        tx.otherPortfolio = dest.uuid
      elsif vehicle.kind == :securities && dest.kind == :deposit
        tx.account = dest.uuid
      end
      after = [tx.has_account? && tx.account, tx.has_otherAccount? && tx.otherAccount,
               tx.has_portfolio? && tx.portfolio, tx.has_otherPortfolio? && tx.otherPortfolio]
      before != after
    end

    def securities_by_uuid(client)
      Array(client.securities).to_h { |security| [security.uuid, security] }
    end

    def extra_columns(labels)
      used = [
        labels.index("date"),
        labels.index("type"),
        labels.index("amount"),
        labels.index("currency"),
        labels.index("description"),
        destination_column(labels),
        labels.index("uuid")
      ].compact
      EXTRA_HEADERS.each_with_object({}) do |(key, patterns), extras|
        index = labels.index { |label| patterns.any? { |pattern| label.match?(pattern) } }
        next if index.nil? || used.include?(index)

        extras[key] = index
      end
    end

    def extras_from_proto(tx, destination, security_names, securities)
      security = tx.respond_to?(:has_security?) && tx.has_security? ? securities[tx.security] : nil
      shares = tx.respond_to?(:has_shares?) && tx.has_shares? ? tx.shares.to_i : 0
      amount = tx.amount.to_i
      per_share = per_share_value(amount, shares)
      {
        security: security_name(tx, security_names),
        shares: shares.positive? ? shares : nil,
        per_share: per_share,
        offset_account: destination.to_s,
        note: tx.has_note? ? tx.note.to_s : "",
        source: tx.respond_to?(:has_source?) && tx.has_source? ? tx.source.to_s : "",
        symbol: security_attr(security, :tickerSymbol),
        isin: security_attr(security, :isin),
        quote: per_share,
        fees: unit_cents(tx, "FEE"),
        taxes: unit_cents(tx, "TAX"),
        net: amount
      }
    end

    def extras_from_sheet(cells, mapping)
      mapping.fetch(:extras, {}).each_with_object({}) do |(key, index), extras|
        extras[key] = parse_extra(key, cells[index])
      end
    end

    def parse_extra(key, value)
      case key
      when :shares
        number = parse_decimal(value)
        number && (number * SHARE_SCALE).round
      when :fees, :taxes, :net
        parse_signed_cents(value)&.abs
      when :per_share, :quote
        parse_decimal(value)
      else
        value.to_s.strip
      end
    end

    def parse_extra_number(value)
      cents = parse_signed_cents(value)
      cents && cents / 100.0
    end

    def parse_decimal(value)
      return if value.nil? || value.to_s.strip.empty?
      return value.to_f if value.is_a?(Numeric)

      text = value.to_s.strip.gsub(/[\u20ac$\u00a3\s]/, "")
      last_comma = text.rindex(",")
      last_dot = text.rindex(".")
      text = if last_comma && last_dot
        if last_comma > last_dot
          text.delete(".").tr(",", ".")
        else
          text.delete(",")
        end
      elsif text.count(",") > 1
        text.delete(",")
      elsif text.include?(",")
        text.tr(",", ".")
      else
        text
      end
      Float(text)
    rescue ArgumentError
      nil
    end

    def per_share_value(amount_cents, shares)
      return if shares.to_i <= 0

      (amount_cents.to_f / 100.0) / (shares.to_f / SHARE_SCALE)
    end

    def unit_cents(tx, type)
      unit = Array(tx.units).find { |item| item.type.to_s == type }
      unit&.amount
    end

    def security_attr(security, name)
      return "" unless security
      return "" unless security.respond_to?(name)

      optional = "has_#{name}?"
      return "" if security.respond_to?(optional) && !security.public_send(optional)

      security.public_send(name).to_s
    end

    def ensure_headers(header, kind)
      extras = extra_columns_for(kind)
      labels = Array(header).map { |cell| cell.to_s }
      return HEADERS + extras unless header_row?(labels)

      extras.each do |name|
        labels << name unless extra_header_present?(labels, name)
      end
      labels
    end

    def extra_header_present?(labels, name)
      key = extra_key_for_label(name)
      Array(labels).any? do |label|
        text = label.to_s.strip.downcase
        next true if text == name.downcase
        next false unless key

        EXTRA_HEADERS[key].any? { |pattern| text.match?(pattern) }
      end
    end

    def extra_key_for_label(name)
      text = name.to_s.strip.downcase
      EXTRA_HEADERS.find { |_key, patterns| patterns.any? { |pattern| text.match?(pattern) } }&.first
    end

    def merge_extras(proto, row, destination, extra_keys = [])
      keys = Array(extra_keys)
      keys = row.extras.to_h.keys if keys.empty?
      keys.each_with_object({}) do |key, merged|
        sheet_val = row.extras[key]
        proto_val = proto.extras.to_h[key]
        proto_val = destination if key == :offset_account && !extra_present?(proto_val)
        merged[key] = extra_present?(sheet_val) ? sheet_val : proto_val
        merged[key] = destination if key == :offset_account && !extra_present?(merged[key])
      end
    end

    def same_extras?(left, right, keys)
      keys.all? { |key| extra_equal?(key, left.to_h[key], right.to_h[key]) }
    end

    def extra_equal?(key, left, right)
      return left.to_s.strip == right.to_s.strip unless %i[shares fees taxes net per_share quote].include?(key)
      return true unless extra_present?(left) || extra_present?(right)
      return false unless extra_present?(left) && extra_present?(right)

      l = left.to_f
      r = right.to_f
      (l - r).abs <= [l.abs, r.abs, 1.0].max * 1e-9
    end

    def extra_present?(value)
      return false if value.nil?
      return false if value.is_a?(String) && value.strip.empty?

      true
    end

    def extra_cell(key, record)
      value = record.extras.to_h[key]
      value = record.destination if key == :offset_account && !extra_present?(value)
      format_extra(key, value)
    end

    def format_extra(key, value)
      return "" unless extra_present?(value)

      case key
      when :shares
        value.to_f / SHARE_SCALE
      when :fees, :taxes, :net
        value.to_f / 100.0
      when :per_share, :quote
        value.to_f
      else
        value.to_s
      end
    end

    def write_cell(cells, index, value)
      return if index.nil?

      cells << nil while cells.size <= index
      cells[index] = value
    end

    def apply_extras!(tx, record, client)
      extras = record.extras.to_h
      return false if extras.empty?

      changed = false
      if extras.key?(:note) && extra_present?(extras[:note]) && tx.note.to_s != extras[:note].to_s
        tx.note = extras[:note].to_s
        changed = true
      end
      if extras.key?(:source) && tx.source.to_s != extras[:source].to_s
        tx.source = extras[:source].to_s
        changed = true
      end
      if extras.key?(:shares) && extra_present?(extras[:shares]) && tx.shares.to_i != extras[:shares].to_i
        tx.shares = extras[:shares].to_i
        changed = true
      end
      security = lookup_security(client, extras)
      if security && tx.security.to_s != security.uuid
        tx.security = security.uuid
        changed = true
      end
      changed | apply_units!(tx, extras)
    end

    def lookup_security(client, extras)
      lookup_security_list(Array(client&.securities), extras)
    end

    def lookup_security_list(securities, extras)
      extras = extras.to_h
      isin = extras[:isin].to_s.strip
      symbol = extras[:symbol].to_s.strip
      name = extras[:security].to_s.strip
      found = Array(securities).find { |item| !isin.empty? && security_attr(item, :isin).casecmp?(isin) }
      found ||= Array(securities).find { |item| !symbol.empty? && security_attr(item, :tickerSymbol).casecmp?(symbol) }
      found ||= Array(securities).find { |item| !name.empty? && item.name == name }
      found || Array(securities).find { |item| !name.empty? && item.name.casecmp?(name) }
    end

    def apply_units!(tx, extras)
      changed = false
      { fees: :FEE, taxes: :TAX }.each do |key, type|
        next unless extras.key?(key) && extra_present?(extras[key])

        cents = extras[key].to_i
        unit = tx.units.find { |item| item.type.to_s == type.to_s }
        if unit.nil?
          tx.units << Proto::PTransactionUnit.new(
            type: type,
            amount: cents,
            currencyCode: tx.currencyCode
          )
          changed = true
        elsif unit.amount != cents
          unit.amount = cents
          changed = true
        end
      end
      changed
    end

    private_class_method :merge, :same_row?, :same_proto?, :find_transaction,
                         :update_transaction!, :build_transaction, :wrap_vehicle, :belongs?,
                         :destination_name, :security_name, :destination_column, :assign_counterpart!,
                         :lookup_name, :take_sheet_row!, :pick_destination, :securities_by_uuid,
                         :extra_columns, :extras_from_proto, :extras_from_sheet, :parse_extra,
                         :parse_extra_number, :parse_decimal, :per_share_value, :unit_cents, :security_attr,
                         :merge_extras, :same_extras?, :extra_equal?, :extra_present?, :extra_cell,
                         :format_extra, :write_cell, :apply_extras!, :lookup_security, :lookup_security_list,
                         :apply_units!, :same_destination?, :same_security_ref?,
                         :ensure_headers, :extra_header_present?, :extra_key_for_label
  end
end
