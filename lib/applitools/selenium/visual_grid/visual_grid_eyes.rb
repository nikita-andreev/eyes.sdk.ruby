require 'applitools/selenium/configuration'
module Applitools
  module Selenium
    class VisualGridEyes
      extend Forwardable

      def_delegators 'Applitools::EyesLogger', :logger, :log_handler, :log_handler=

      attr_accessor :visual_grid_manager, :driver, :current_url, :current_config, :fetched_cache_map, :config
      attr_accessor :test_list

      attr_accessor :api_key, :server_url, :proxy, :opened

      def_delegators 'config', *Applitools::Selenium::Configuration.methods_to_delegate
      def_delegators 'config', *Applitools::EyesBaseConfiguration.methods_to_delegate

      def initialize(visual_grid_manager, server_url = nil)
        ensure_config
        self.visual_grid_manager = visual_grid_manager
        self.test_list = Applitools::Selenium::TestList.new
        self.opened = false
      end

      def ensure_config
        self.config = Applitools::Selenium::Configuration.new
      end


      def open(*args)
        self.test_list = Applitools::Selenium::TestList.new
        options = Applitools::Utils.extract_options!(args)
        Applitools::ArgumentGuard.hash(options, 'options', [:driver])

        self.driver = options.delete(:driver)
        self.current_url = driver.current_url

        visual_grid_manager.open(self)

        logger.info("getting all browsers info...")
        browsers_info_list = config.browsers_info
        logger.info("creating test descriptors for each browser info...")
        browsers_info_list.each do |bi|
          test_list.push Applitools::Selenium::RunningTest.new(eyes_connector, bi, driver)
        end
        self.opened = true
        driver
      end

      def eyes_connector
        logger.info("creating VisualGridEyes server connector")
        ::Applitools::Selenium::EyesConnector.new(server_url).tap do |connector|
          connector.batch = batch_info
          connector.config = config.deep_clone
        end
      end

      def check(tag, target)
        script = <<-END
          var callback = arguments[arguments.length - 1]; return (#{Applitools::Selenium::Scripts::PROCESS_RESOURCES})().then(JSON.stringify).then(callback, function(err) {callback(err.stack || err.toString())});
        END
        begin
          script_result = driver.execute_async_script(script).freeze
          mod = Digest::SHA2.hexdigest(script_result)
          test_list.each do |t|
            t.check(tag, target, script_result.dup, visual_grid_manager, mod)
          end
          test_list.each { |t| t.becomes_not_rendered}
        rescue StandardError => e
          Applitools::EyesLogger.error e.message
          test_list.each { |t| t.becomes_tested}
        end
      end

      def close(throw_exception = true)
        return false if test_list.empty?
        test_list.each do |t|
          t.close
        end

        while (!((states = test_list.map(&:state_name).uniq).count == 1 && states.first == :completed)) do
          sleep 0.5
        end
        self.opened = false

        test_list.select { |t| t.pending_exceptions && !t.pending_exceptions.empty? }.each do |t|
          t.pending_exceptions.each do |e|
            raise e
          end
        end

        if throw_exception
          test_list.map(&:test_result).compact.each do |r|
            raise Applitools::NewTestError.new new_test_error_message(r), r if r.new?
            raise Applitools::DiffsFoundError.new diffs_found_error_message(r), r if r.unresolved? && !r.new?
            raise Applitools::TestFailedError.new test_failed_error_message(r), r if r.failed?
          end
        end
        failed_results = test_list.map(&:test_result).compact.select { |r| !r.as_expected? }
        failed_results.empty? ? test_list.map(&:test_result).compact.first : failed_results
      end

      def open?
        opened
      end

      def get_all_test_results
        test_list.map(&:test_result)
      end

      def new_test_error_message(result)
        original_results = result.original_results
        "New test '#{original_results['name']}' " \
            "of '#{original_results['appName']}' " \
            "Please approve the baseline at #{original_results['appUrls']['session']} "
      end

      def diffs_found_error_message(result)
        original_results = result.original_results
        "Test '#{original_results['name']}' " \
            "of '#{original_results['appname']}' " \
            "detected differences! See details at #{original_results['appUrls']['session']}"
      end

      def test_failed_error_message(result)
        original_results = result.original_results
        "Test '#{original_results['name']}' of '#{original_results['appName']}' " \
            "is failed! See details at #{original_results['appUrls']['session']}"
      end
      private :new_test_error_message, :diffs_found_error_message, :test_failed_error_message

      # Takes a snapshot of the application under test and matches it with the expected output.
      #
      # @param [String] tag An optional tag to be assosiated with the snapshot.
      # @param [Fixnum] match_timeout The amount of time to retry matching (seconds)
      def check_window(tag = nil, match_timeout = USE_DEFAULT_MATCH_TIMEOUT)
        target = Applitools::Selenium::Target.window.tap do |t|
          t.timeout(match_timeout)
          t.fully if force_full_page_screenshot
        end
        check(tag, target)
      end

      # Takes a snapshot of the application under test and matches a region of
      # a specific element with the expected region output.
      #
      # @param [Applitools::Selenium::Element] element Represents a region to check.
      # @param [Symbol] how a finder, such :css or :id. Selects a finder will be used to find an element
      #   See Selenium::Webdriver::Element#find_element documentation for full list of possible finders.
      # @param [String] what The value will be passed to a specified finder. If finder is :css it must be a css selector.
      # @param [Hash] options
      # @option options [String] :tag An optional tag to be associated with the snapshot.
      # @option options [Fixnum] :match_timeout The amount of time to retry matching. (Seconds)
      # @option options [Boolean] :stitch_content If set to true, will try to get full content of the element
      #   (including hidden content due overflow settings) by scrolling the element,
      #   taking and stitching partial screenshots.
      # @example Check region by element
      #   check_region(element, tag: 'Check a region by element', match_timeout: 3, stitch_content: false)
      # @example Check region by css selector
      #   check_region(:css, '.form-row .input#e_mail', tag: 'Check a region by element', match_timeout: 3,
      #   stitch_content: false)
      # @!parse def check_region(element, how=nil, what=nil, options = {}); end
      def check_region(*args)
        options = { timeout: USE_DEFAULT_MATCH_TIMEOUT, tag: nil }.merge! Applitools::Utils.extract_options!(args)
        target = Applitools::Selenium::Target.new.region(*args).timeout(options[:match_timeout])
        target.fully if options[:stitch_content]
        check(options[:tag], target)
      end

      # Validates the contents of an iframe and matches it with the expected output.
      #
      # @param [Hash] options The specific parameters of the desired screenshot.
      # @option options [Fixnum] :timeout The amount of time to retry matching. (Seconds)
      # @option options [String] :tag An optional tag to be associated with the snapshot.
      # @option options [String] :frame Frame element or frame name or frame id.
      # @option options [String] :name_or_id The name or id of the target frame (deprecated. use :frame instead).
      # @option options [String] :frame_element The frame element (deprecated. use :frame instead).
      # @return [Applitools::MatchResult] The match results.

      def check_frame(options = {})
        options = { timeout: USE_DEFAULT_MATCH_TIMEOUT, tag: nil }.merge!(options)
        frame = options[:frame] || options[:frame_element] || options[:name_or_id]
        target = Applitools::Selenium::Target.frame(frame).timeout(options[:timeout]).fully
        check(options[:tag], target)
      end

      # Validates the contents of a region in an iframe and matches it with the expected output.
      #
      # @param [Hash] options The specific parameters of the desired screenshot.
      # @option options [String] :name_or_id The name or id of the target frame (deprecated. use :frame instead).
      # @option options [String] :frame_element The frame element (deprecated. use :frame instead).
      # @option options [String] :frame Frame element or frame name or frame id.
      # @option options [String] :tag An optional tag to be associated with the snapshot.
      # @option options [Symbol] :by By which identifier to find the region (e.g :css, :id).
      # @option options [Fixnum] :timeout The amount of time to retry matching. (Seconds)
      # @option options [Boolean] :stitch_content Whether to stitch the content or not.
      # @return [Applitools::MatchResult] The match results.
      def check_region_in_frame(options = {})
        options = { timeout: USE_DEFAULT_MATCH_TIMEOUT, tag: nil, stitch_content: false }.merge!(options)
        Applitools::ArgumentGuard.not_nil options[:by], 'options[:by]'
        Applitools::ArgumentGuard.is_a? options[:by], 'options[:by]', Array

        how_what = options.delete(:by)
        frame = options[:frame] || options[:frame_element] || options[:name_or_id]

        target = Applitools::Selenium::Target.new.timeout(options[:timeout])
        target.frame(frame) if frame
        target.fully if options[:stitch_content]
        target.region(*how_what)

        check(options[:tag], target)
      end

      # Use this method to perform seamless testing with selenium through eyes driver.
      # It yields a block and passes to it an Applitools::Selenium::Driver instance, which wraps standard driver.
      # Using Selenium methods inside the 'test' block will send the messages to Selenium
      # after creating the Eyes triggers for them. Options are similar to {open}
      # @yieldparam driver [Applitools::Selenium::Driver] Gives a driver to a block, which translates calls to a native
      #   Selemium::Driver instance
      # @example
      #   eyes.test(app_name: 'my app', test_name: 'my test') do |driver|
      #      driver.get "http://www.google.com"
      #      driver.check_window("initial")
      #   end
      def test(options = {}, &_block)
        open(options)
        yield(driver)
        close
      ensure
        abort_if_not_closed
      end
    end
  end
end
