# frozen_string_literal: true

module PortfolioPerformanceApi
  # Canonical PTransaction.Type values from Portfolio Performance's client.proto.
  # Java XML/UI uses different names (BUY, FEES, TAXES, DIVIDENDS, TRANSFER_IN, …).
  # Writing those into protobuf makes PP throw UnsupportedOperationException on open.
  # https://github.com/portfolio-performance/portfolio
  module TransactionTypes
    PROTO = %w[
      PURCHASE SALE INBOUND_DELIVERY OUTBOUND_DELIVERY SECURITY_TRANSFER
      CASH_TRANSFER DEPOSIT REMOVAL DIVIDEND INTEREST INTEREST_CHARGE
      TAX TAX_REFUND FEE FEE_REFUND
    ].freeze

    DEPOSIT_ACCOUNT = %w[
      DEPOSIT REMOVAL DIVIDEND INTEREST INTEREST_CHARGE TAX TAX_REFUND FEE FEE_REFUND
      CASH_TRANSFER PURCHASE SALE
    ].freeze

    SECURITIES_ACCOUNT = %w[
      PURCHASE SALE INBOUND_DELIVERY OUTBOUND_DELIVERY SECURITY_TRANSFER
    ].freeze

    CROSS_ENTRY = %w[PURCHASE SALE CASH_TRANSFER SECURITY_TRANSFER].freeze

    # Java XML / CSV / UI labels that mean a cash or securities transfer.
    # Kind decides CASH_TRANSFER vs SECURITY_TRANSFER; never write TRANSFER_IN.
    TRANSFER_ALIASES = %w[
      transfer transfer_in transfer_out transfer_inbound transfer_outbound
      trasferimento trasferimento_in_entrata trasferimento_in_uscita
    ].freeze

    ALIASES = {
      "buy" => "PURCHASE",
      "sell" => "SALE",
      "compra" => "PURCHASE",
      "vendi" => "SALE",
      "dividends" => "DIVIDEND",
      "dividend" => "DIVIDEND",
      "dividendo" => "DIVIDEND",
      "fees" => "FEE",
      "fee" => "FEE",
      "commissioni" => "FEE",
      "fees_refund" => "FEE_REFUND",
      "fee_refund" => "FEE_REFUND",
      "rimborso_commissioni" => "FEE_REFUND",
      "taxes" => "TAX",
      "tax" => "TAX",
      "tasse" => "TAX",
      "tax_refund" => "TAX_REFUND",
      "rimborso_tasse" => "TAX_REFUND",
      "delivery_inbound" => "INBOUND_DELIVERY",
      "inbound_delivery" => "INBOUND_DELIVERY",
      "delivery_outbound" => "OUTBOUND_DELIVERY",
      "outbound_delivery" => "OUTBOUND_DELIVERY",
      "trasferimento_titoli_in_entrata" => "INBOUND_DELIVERY",
      "trasferimento_titoli_in_uscita" => "OUTBOUND_DELIVERY",
      "deposit" => "DEPOSIT",
      "deposito" => "DEPOSIT",
      "versamento" => "DEPOSIT",
      "entrate" => "DEPOSIT",
      "removal" => "REMOVAL",
      "withdrawal" => "REMOVAL",
      "prelievo" => "REMOVAL",
      "uscite" => "REMOVAL",
      "interest" => "INTEREST",
      "interessi" => "INTEREST",
      "interest_charge" => "INTEREST_CHARGE",
      "interessi_passivi" => "INTEREST_CHARGE"
    }.freeze

    module_function

    def proto?(type)
      name = type.to_s
      return false if name.empty? || name == "UNRECOGNIZED"

      PROTO.include?(name)
    end

    def key(value)
      value.to_s.strip.downcase.gsub(/[()]/, "").gsub(/[\s\-]+/, "_").gsub(/_+/, "_")
    end

    def normalize(value, signed_cents = nil, kind: nil)
      text = value.to_s.strip
      keyed = key(text)
      if TRANSFER_ALIASES.include?(keyed)
        return kind.to_s == "securities" ? "SECURITY_TRANSFER" : "CASH_TRANSFER"
      end

      named = ALIASES[keyed]
      named ||= text.upcase if proto?(text.upcase)
      return named if named
      return "REMOVAL" if signed_cents.to_i.negative?
      return "DEPOSIT" if signed_cents.to_i.positive?

      nil
    end

    def coerce(type, kind: :deposit)
      named = proto?(type.to_s) ? type.to_s : normalize(type, kind: kind)
      return unless named

      allowed = kind.to_s == "securities" ? SECURITIES_ACCOUNT : DEPOSIT_ACCOUNT
      return named if allowed.include?(named)

      case [kind.to_s, named]
      when %w[securities DEPOSIT] then "INBOUND_DELIVERY"
      when %w[securities REMOVAL] then "OUTBOUND_DELIVERY"
      when %w[deposit INBOUND_DELIVERY] then "DEPOSIT"
      when %w[deposit OUTBOUND_DELIVERY] then "REMOVAL"
      end
    end

    # Fields ProtobufWriter.loadTransactions requires before PP will open the file.
    def loadable?(tx)
      type = tx.type.to_s
      return false unless proto?(type)

      case type
      when "PURCHASE", "SALE"
        present?(tx, :account) && present?(tx, :portfolio) && present?(tx, :security) && present?(tx, :otherUuid)
      when "CASH_TRANSFER"
        present?(tx, :account) && present?(tx, :otherAccount) && present?(tx, :otherUuid)
      when "SECURITY_TRANSFER"
        present?(tx, :portfolio) && present?(tx, :otherPortfolio) && present?(tx, :security) && present?(tx, :otherUuid)
      when "INBOUND_DELIVERY", "OUTBOUND_DELIVERY"
        present?(tx, :portfolio) && present?(tx, :security)
      else
        present?(tx, :account)
      end
    end

    def present?(tx, field)
      has = "has_#{field}?"
      return false if tx.respond_to?(has) && !tx.public_send(has)

      tx.public_send(field).to_s != ""
    end
  end
end
