# frozen_string_literal: true

require "tty-cursor"
require "tty-reader"
require "tty-screen"

require_relative "preview_window"

module PortfolioPerformanceApi
  class RowPreview
    Section = Struct.new(:title, :lines, :counts, :page_size, :scroll, keyword_init: true)

    def initialize(heading, sections, page_size:, prompt:, choices:, help: nil, acknowledge: false)
      @heading = heading
      @sections = Array(sections).map { |section| coerce_section(section) }
      raise ArgumentError, "preview needs at least one section" if @sections.empty?

      requested = [Integer(page_size), 1].max
      page_sizes = fit_page_sizes(requested)
      @window = PreviewWindow.new(
        @sections.map(&:lines),
        page_size: requested,
        page_sizes: page_sizes,
        locked: @sections.map { |section| section.scroll == false }
      )
      @prompt = prompt
      @choices = Array(choices).map { |choice| choice.to_s.upcase }
      @acknowledge = acknowledge
      @help = help
      @reader = TTY::Reader.new(interrupt: :exit)
      @cursor = TTY::Cursor
      @drawn_lines = 0
    end

    def run
      return static_choice unless $stdin.tty?

      $stdout.print @cursor.hide
      $stdout.sync = true
      choice = nil
      @reader.on(:keyup) { @window.up }
      @reader.on(:keydown) { @window.down }
      @reader.on(:keyescape) { choice = "N" }
      @reader.on(:keypress) do |event|
        choice = key_choice(event)
        @window.page_up if %w[u U].include?(event.value)
        @window.page_down if %w[v V].include?(event.value)
      end

      begin
        until choice
          draw
          @reader.read_keypress
        end
      ensure
        clear_frame
        $stdout.print @cursor.show
      end

      choice
    end

    private

    def coerce_section(section)
      return section if section.is_a?(Section)

      Section.new(
        title: section.fetch(:title),
        lines: Array(section[:lines]),
        counts: section[:counts],
        page_size: section[:page_size],
        scroll: section.fetch(:scroll, true)
      )
    end

    def fit_page_sizes(requested)
      sizes = @sections.map { |section| section.page_size ? [Integer(section.page_size), 1].max : requested }
      return sizes unless $stdin.tty?

      usable = [TTY::Screen.height - 5, 4].max
      locked = @sections.each_with_index.sum do |section, index|
        next 0 unless section.scroll == false

        [sizes[index], [section.lines.size, 1].max].min
      end
      remaining = [usable - locked, 1].max
      scrollable = [@sections.count { |section| section.scroll != false }, 1].max
      per = [remaining / scrollable, 1].max
      @sections.each_with_index.map do |section, index|
        next sizes[index] if section.scroll == false

        [sizes[index], per].min
      end
    end

    def static_choice
      render_lines.each { |line| $stdout.puts line }
      return "N" if @acknowledge

      loop do
        $stderr.print "#{@prompt} "
        answer = $stdin.gets.to_s.strip.upcase
        return answer if @choices.include?(answer)
        return "N" if answer.empty? || answer == "\e" || answer == "Q"

        warn "type #{@choices.join(", ")} or press Esc/Q to skip"
      end
    end

    def key_choice(event)
      return "N" if skip_key?(event)
      return "N" if @acknowledge && enter_key?(event)

      value = event.value.to_s.upcase
      return value if @choices.include?(value)

      nil
    end

    def enter_key?(event)
      return true if event.key&.name == :return || event.key&.name == :enter

      ["\r", "\n"].include?(event.value)
    end

    def skip_key?(event)
      return true if event.key&.name == :escape || event.value == "\e"

      event.value.to_s.upcase == "Q" && !@choices.include?("Q")
    end

    def draw
      lines = render_lines
      clear_frame
      lines.each { |line| $stdout.puts line }
      @drawn_lines = lines.size
    end

    def clear_frame
      return if @drawn_lines.zero?

      $stdout.print @cursor.up(@drawn_lines)
      @drawn_lines.times do
        $stdout.print @cursor.clear_line
        $stdout.print @cursor.next_line
      end
      $stdout.print @cursor.up(@drawn_lines)
      @drawn_lines = 0
    end

    def render_lines
      section_lines = @sections.each_with_index.flat_map do |section, index|
        render_section(section, @window.visible(index), @window.range(index))
      end
      [
        @heading,
        section_lines,
        @prompt,
        @help || "↑/↓ row  u/v page ±#{@window.page_size}  esc/q skip"
      ].flatten
    end

    def render_section(section, rows, range)
      from, to, total = range
      parts = [section.title]
      if section.counts
        parts << "+#{section.counts.fetch(:create, 0)}/~#{section.counts.fetch(:update, 0)}"
      end
      parts << "#{from}-#{to}/#{total}" if total.positive?
      [parts.join("  ")] + (rows.empty? ? ["  (none)"] : rows.map { |row| "  #{row}" })
    end
  end
end
