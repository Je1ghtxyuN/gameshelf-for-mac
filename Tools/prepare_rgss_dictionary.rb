require 'json'
require 'zlib'
source, target = ARGV
Dir.mkdir(target) unless Dir.exist?(target)
Dir.children(source).each do |name|
  next if ['Tool','Game.exe','Game.ini'].include?(name)
  dest = File.join(target,name)
  next if File.exist?(dest) || File.symlink?(dest)
  next if name.match?(/\.(rvdata2|sav)$/i)
  File.symlink(File.join(source,name),dest)
end
require 'fileutils'
FileUtils.cp(File.join(source,'Game.exe'),File.join(target,'Game.exe'))
ini=File.binread(File.join(source,'Game.ini')).sub(/^Scripts=.*$/,"Scripts=GameShelfBootstrap.rvdata2\r")
File.binwrite(File.join(target,'Game.ini'),ini)
translations=JSON.parse(File.read(File.join(source,'翻译文件.json'),encoding:'UTF-8'))
translations.select! {|k,v| k.is_a?(String) && v.is_a?(String) && !k.empty? }
File.binwrite(File.join(target,'GameShelfTranslations.rvdata2'),Marshal.dump(translations))
bootstrap = <<'RGSS'
# encoding: utf-8
$gameshelf_dictionary = Marshal.load(File.binread('GameShelfTranslations.rvdata2'))
module GameShelfDictionary
  def self.translated?(text)
    text.is_a?(String) && text.instance_variable_get(:@gameshelf_translated)
  end

  # Always start from the complete, original message. This entry deliberately
  # bypasses the rendering guard: all_text is read inside process_all_text.
  def self.translate_message(text)
    return text unless text.is_a?(String)
    return text if translated?(text)
    if $gameshelf_dictionary.has_key?(text)
      result = $gameshelf_dictionary[text]
      @translated = (@translated || 0) + 1
    elsif text.end_with?("\n") && $gameshelf_dictionary.has_key?(text[0...-1])
      # VX Ace all_text adds a final newline that dictionary block keys may omit.
      result = $gameshelf_dictionary[text[0...-1]] + "\n"
      @translated = (@translated || 0) + 1
    else
      result = text.split("\n", -1).map {|line| $gameshelf_dictionary.fetch(line,line)}.join("\n")
    end
    # Do not tag/mutate dictionary values or caller strings. The marker survives
    # clone/dup, keeping a translated all_text safe if passed to draw_text_ex.
    result = result.dup
    result.instance_variable_set(:@gameshelf_translated, true)
    result
  end

  def self.translate(text)
    return text if Thread.current[:gameshelf_render_active] || translated?(text)
    translate_message(text)
  end

  def self.with_render_guard
    # Thread#[] is fiber-local, so a yielding message must not suppress labels
    # rendered by the scene's other fiber. Restore nested guards on exceptions.
    previous = Thread.current[:gameshelf_render_active]
    Thread.current[:gameshelf_render_active] = true
    begin
      yield
    ensure
      Thread.current[:gameshelf_render_active] = previous
    end
  end

  def self.install
    if defined?(Game_Message) && !Game_Message.method_defined?(:gameshelf_original_all_text)
      Game_Message.class_eval do
        alias_method :gameshelf_original_all_text, :all_text
        def all_text
          GameShelfDictionary.translate_message(gameshelf_original_all_text)
        end
      end
    end
    if defined?(Bitmap) && !Bitmap.method_defined?(:gameshelf_original_draw_text)
      Bitmap.class_eval do
        alias_method :gameshelf_original_draw_text, :draw_text
        def draw_text(*args)
          index = args[0].is_a?(Rect) ? 1 : 4
          args[index] = GameShelfDictionary.translate(args[index]) if args.length > index
          gameshelf_original_draw_text(*args)
        end
      end
    end
    if defined?(Window_Base) && !Window_Base.method_defined?(:gameshelf_original_draw_text_ex)
      Window_Base.class_eval do
        alias_method :gameshelf_original_draw_text_ex, :draw_text_ex
        def draw_text_ex(x, y, text)
          translated = GameShelfDictionary.translate(text)
          GameShelfDictionary.with_render_guard do
            gameshelf_original_draw_text_ex(x, y, translated)
          end
        end
      end
    end
    if defined?(Window_Message) && !Window_Message.method_defined?(:gameshelf_original_process_all_text)
      Window_Message.class_eval do
        alias_method :gameshelf_original_process_all_text, :process_all_text
        def process_all_text
          GameShelfDictionary.with_render_guard do
            gameshelf_original_process_all_text
          end
        end
      end
    end
  end
end

module GameShelfDictionary
  def self.tick
    @start ||= Time.now
    @frames = (@frames || 0) + 1
    if @frames % 300 == 0
      capture_once
      elapsed = Time.now - @start
      scene = diagnostic_value do
        if defined?(SceneManager) && SceneManager.respond_to?(:scene)
          current = SceneManager.scene
          current ? current.class.to_s : 'nil'
        else
          'unavailable'
        end
      end
      brightness = diagnostic_value {defined?(Graphics) && Graphics.respond_to?(:brightness) ? Graphics.brightness : 'unavailable'}
      unifont = diagnostic_value {defined?(Font) && Font.respond_to?(:exist?) ? Font.exist?("Unifont Smooth") : 'unavailable'}
      File.open('GameShelf-frame-times.log','a') {|f| f.puts("frames=#{@frames} seconds=#{elapsed.round(3)} fps=#{(@frames / elapsed).round(2)} translated=#{@translated || 0} unifont=#{unifont} scene=#{scene} brightness=#{brightness}")}
    end
  rescue Exception
    # Optional diagnostics must never interrupt the game or change update's result.
    nil
  end
  def self.capture_absolute_path?(path)
    return false unless path.is_a?(String) && !path.empty? && !path.include?("\0")
    return false if path.split(/[\\\/]/).include?('..')
    !!(path =~ /\A(?:[A-Za-z]:[\\\/]|\\\\[^\\\/]+[\\\/][^\\\/]+[\\\/]|\/)/)
  end
  def self.png_chunk(type, payload)
    [payload.bytesize].pack('N') + type + payload + [Zlib.crc32(type + payload)].pack('N')
  end
  def self.png_from_bitmap(bitmap)
    source_width, source_height = bitmap.width.to_i, bitmap.height.to_i
    raise ArgumentError, 'Invalid capture bitmap dimensions' unless source_width > 0 && source_height > 0
    scale = [1.0, 1920.0 / source_width, 1080.0 / source_height].min
    width, height = [(source_width * scale).floor, 1].max, [(source_height * scale).floor, 1].max
    compressed = [].pack('C*') # Binary bytes without RGSS encoding-alias lookup.
    compressor = Zlib::Deflate.new(Zlib::BEST_SPEED)
    begin
      height.times do |y|
        row = [0].pack('C') # PNG filter None; RGBA8, top-to-bottom rows.
        source_y = y * source_height / height
        width.times do |x|
          color = bitmap.get_pixel(x * source_width / width, source_y)
          channels = [color.red, color.green, color.blue, color.alpha].map {|value| [[value.round, 0].max, 255].min}
          row << channels.pack('C4')
        end
        compressed << compressor.deflate(row)
      end
      compressed << compressor.finish
    ensure
      begin
        compressor.close
      rescue Exception => error
        log_error('capture', error)
      end
    end
    [137,80,78,71,13,10,26,10].pack('C8') +
      png_chunk('IHDR', [width,height,8,6,0,0,0].pack('NNC5')) +
      png_chunk('IDAT', compressed) + png_chunk('IEND', '')
  end
  def self.capture_once
    output = ENV['GAMESHELF_CAPTURE_OUTPUT']
    return unless ENV['GAMESHELF_PROFILE'] == '1' && output && !output.empty?
    return if @capture_attempted || (@frames || 0) < 300
    @capture_attempted = true # Failure is also one attempt; never retry per frame.
    bitmap = nil
    begin
      raise ArgumentError, 'Capture output must be an explicit absolute path without traversal' unless capture_absolute_path?(output)
      raise NotImplementedError, 'Graphics.snap_to_bitmap is unavailable' unless Graphics.respond_to?(:snap_to_bitmap)
      bitmap = Graphics.snap_to_bitmap # Game framebuffer only; no OS capture/input.
      png = png_from_bitmap(bitmap)
      # Controller owns the absolute destination and creates its private parent.
      # No default path, directory creation, overwrite, or relative-cwd output.
      File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
        file.binmode
        file.write(png)
      end
    rescue Exception => error
      log_error('capture', error)
    ensure
      if bitmap
        begin
          bitmap.dispose
        rescue Exception => error
          log_error('capture', error)
        end
      end
    end
    nil
  end
  def self.diagnostic_value
    yield
  rescue Exception
    'unavailable'
  end
  def self.apply_initial_window_bounds
    return if @window_bounds_attempted
    @window_bounds_attempted = true
    requested = ENV['GAMESHELF_WINDOW_BOUNDS']
    return unless ['1280x720', '1024x768'].include?(requested)
    return unless defined?(WLIB) && WLIB.respond_to?(:GetDesktopRect) && WLIB.respond_to?(:SetGameWindowSize)
    return unless defined?(Graphics) && Graphics.respond_to?(:width) && Graphics.respond_to?(:height)
    desktop = WLIB.GetDesktopRect
    if desktop.respond_to?(:width) && desktop.respond_to?(:height)
      desktop_width, desktop_height = desktop.width, desktop.height
    elsif desktop.is_a?(Array) && desktop.size == 4
      desktop_width, desktop_height = desktop[2] - desktop[0], desktop[3] - desktop[1]
    elsif desktop.is_a?(Array) && desktop.size == 2
      desktop_width, desktop_height = desktop
    else
      raise ArgumentError, 'Unsupported WLIB desktop rectangle'
    end
    source_width, source_height = Graphics.width, Graphics.height
    unless [source_width, source_height, desktop_width, desktop_height].all? {|value| value.is_a?(Integer) && value > 0}
      raise ArgumentError, 'Invalid initial window dimensions'
    end
    requested_width, requested_height = requested.split('x').map {|value| value.to_i}
    # Leave space for native window chrome; never alter Graphics resolution,
    # the game's size list, saved preference, or later F5/fullscreen controls.
    max_width, max_height = [requested_width, desktop_width - 64].min, [requested_height, desktop_height - 64].min
    raise ArgumentError, 'Desktop too small for window margins' unless max_width > 0 && max_height > 0
    if max_width * source_height <= max_height * source_width
      width, height = max_width, source_height * max_width / source_width
    else
      width, height = source_width * max_height / source_height, max_height
    end
    raise ArgumentError, 'Aspect-fit window has no positive pixel area' unless width > 0 && height > 0
    WLIB.SetGameWindowSize(width, height)
  rescue Exception => error
    log_error('window-bounds', error)
    nil
  end
  def self.log_error(boundary, error)
    # Relative to the launcher's private Play cwd; never open original resources.
    # Log even non-StandardError RGSS exceptions, then callers re-raise unchanged.
    File.open('GameShelf-RGSS-error.log','ab') do |file|
      file.puts("#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')} boundary=#{boundary} #{error.class}: #{error.message}")
      Array(error.backtrace).each {|line| file.puts(line)}
    end
  rescue Exception
    # Disk/encoding/logging failures must not replace the exception being observed.
    nil
  end
end
if ENV["GAMESHELF_PROFILE"] == "1"
class << Graphics
  alias gameshelf_original_update update
  def update
    result = gameshelf_original_update
    GameShelfDictionary.tick
    result
  end
end
end
alias gameshelf_original_rgss_main rgss_main
def rgss_main(&block)
  GameShelfDictionary.install
  unless Font.exist?("Unifont Smooth")
    font_path = ("Fonts\\unifont-all.ttf" + "\0").encode("UTF-16LE")
    Win32API.new('gdi32','AddFontResourceExW','pll','i').call(font_path,16,0)
  end
  Font.default_name = ["Unifont Smooth", "VL Gothic"]
  GameShelfDictionary.apply_initial_window_bounds
  return gameshelf_original_rgss_main unless block
  gameshelf_original_rgss_main do |*args|
    begin
      block.call(*args)
    rescue Exception => error
      # Observe inside the actual native main block, before RGSS can handle it.
      GameShelfDictionary.log_error('rgss-main', error)
      raise
    end
  end
end
begin
  $RGSS_SCRIPTS = load_data('Data/Scripts.rvdata2')
  $RGSS_SCRIPTS.each_with_index do |script, index|
    next unless script && script[2]
    eval(Zlib::Inflate.inflate(script[2]).force_encoding("UTF-8"), TOPLEVEL_BINDING, "GameShelfSource#{index}")
  end
rescue Exception => error
  GameShelfDictionary.log_error('source-eval', error)
  raise
end
RGSS
File.write(File.join(target,'GameShelfAdapter.rb'),bootstrap,encoding:'UTF-8')
trampoline = "eval(File.binread('GameShelfAdapter.rb').force_encoding('UTF-8'), TOPLEVEL_BINDING, 'GameShelfAdapter')"
File.binwrite(File.join(target,'GameShelfBootstrap.rvdata2'),Marshal.dump([[0,'GameShelfDictionary',Zlib::Deflate.deflate(trampoline)]]))
puts "DICTIONARY_READY #{translations.length}"
