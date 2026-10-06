# frozen_string_literal: true

require "fileutils"
require "time"

require_relative "errors"
require_relative "config"
require_relative "drive_client"
require_relative "portfolio_store"

module PortfolioPerformanceApi
  class Import
    PROVIDERS = { "fineco" => "Fineco" }.freeze

    def self.run(argv = [])
      provider, *rest = Array(argv)
      klass = provider_class(provider)
      abort usage if klass.nil?

      klass.new.run(rest)
    end

    def self.usage
      "Usage: bin/import PROVIDER ACCOUNT [--file XLS] [XLS] [--exclude REGEXP] [--skip-lines N] " \
        "[--match-security [/REGEXP/VALUE]] [--match-offset-account /REGEXP/VALUE]\n" \
        "Providers: #{PROVIDERS.keys.join(", ")}"
    end

    def self.provider_class(name)
      const_name = PROVIDERS[name.to_s.downcase]
      return if const_name.nil?

      const_get(const_name)
    end

    def self.import_dir
      File.expand_path("../../import", __dir__)
    end

    def self.backup_path(path, at: Time.now)
      directory = File.dirname(path)
      basename = File.basename(path, ".portfolio")
      File.join(directory, "#{basename}-import-backup-#{at.strftime("%Y%m%dT%H%M%S")}.portfolio")
    end

    class Session
      def initialize(dir: Import.import_dir)
        @dir = dir
      end

      def download_and_backup
        FileUtils.mkdir_p(@dir)
        portfolio_id = Config.drive_file_id
        abort "missing PORTFOLIO_GOOGLE_DRIVE_FILE_ID" if portfolio_id.to_s.empty?
        abort "missing GOOGLE_SERVICE_ACCOUNT_JSON" if Config.service_account_json.to_s.empty?

        drive = DriveClient.new(file_id: portfolio_id, scope: DriveClient::SYNC_SCOPE)
        downloaded = drive.download
        name = downloaded.dig(:meta, :name).to_s
        name = "portfolio.portfolio" if name.empty?
        path = File.join(@dir, File.basename(name))
        File.binwrite(path, downloaded.fetch(:bytes))
        backup = Import.backup_path(path)
        FileUtils.cp(path, backup)
        loaded = PortfolioStore.load(path, password: Config.portfolio_password)
        [drive, loaded, backup]
      end

      def persist(loaded, drive)
        PortfolioStore.save(loaded)
        drive.upload(PortfolioStore.dump(loaded))
      end

      def self.discard_backup(path)
        return if path.to_s.empty? || !File.file?(path)

        File.delete(path)
      end
    end
  end
end

require_relative "import/fineco"
