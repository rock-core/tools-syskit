require 'optparse'
require 'orocos'
require 'syskit'
require 'syskit/roby_app'

    module Syskit
        module Scripts
            class << self
                attr_accessor :debug
                attr_accessor :output_file
                attr_accessor :output_type
                attr_accessor :robot_type
                attr_accessor :robot_name

                # The path to the ruby-prof output, as provided to use_rprof, or nil
                # if profiling with ruby-prof is not enabled
                attr_reader :rprof_file_path
                # The path to the perftools output, as provided to use_pprof, or nil
                # if profiling with perftools is not enabled
                attr_reader :pprof_file_path
            end
            @debug = false

            def self.tic
                @tic = Time.now
            end
            def self.toc(string = nil)
                if string
                    ::Robot.info string % [Time.now - @tic]
                else ::Robot.info yield(Time.now - @tic)
                end
            end
            def self.toc_tic(string = nil, &block)
                toc(string, &block)
                tic
            end

            def self.add_service(service_name)
                if service_name =~ /^\w+(:\w+(,\w+)*)?$/
                    service_name = Scripts.resolve_service_name(service_name)
                    Roby.app.syskit_engine.add service_name
                else
                    Kernel.eval_dsl(service_name, Roby.syskit_engine,
                            Syskit.constant_search_path,
                            !Roby.app.filter_backtraces?)
                end
            end

            def self.resolve_service_name(service)
                service_name, *service_conf = *service.split(':')
                service_conf =
                    if service_conf.size > 1
                        raise ArgumentError, "found more than one colon in #{service}"
                    elsif !service_conf.empty?
                        service_conf.first.split(',')
                    end

                engine = Roby.app.syskit_engine
                instance = engine.resolve_name(service_name)
                if service_conf
                    instance.use_conf(*service_conf)
                end
                instance
            end

            def self.use_rprof(file_path)
                require 'ruby-prof'
                @rprof_file_path = file_path
            end

            def self.use_pprof(file_path)
                require 'perftools'
                @pprof_file_path = file_path
            end

            def self.start_profiling
                resume_profiling
            end

            def self.pause_profiling
                if rprof_file_path
                    RubyProf.pause
                end
            end

            def self.resume_profiling
                if rprof_file_path
                    RubyProf.resume
                end
                if pprof_file_path && !PerfTools::CpuProfiler.running?
                    PerfTools::CpuProfiler.start(pprof_file_path)
                end
            end

            def self.end_profiling
                if rprof_file_path
                    result = RubyProf.stop
                    printer = RubyProf::CallTreePrinter.new(result)
                    printer.print(File.open(rprof_file_path, 'w'), 0)
                end
                if pprof_file_path
                    PerfTools::CpuProfiler.stop
                end
            end

            class << self
                # List of output modes as detected by #autodetect_output_modes
                attr_reader :output_modes
                # The default output mode as detected by #autodetect_output_modes
                attr_reader :default_output_mode
            end

            def self.common_options(opt, with_output = false)
                opt.on('--debug', "turn debugging output on") do
                    Scripts.debug = true
                    Roby.app.public_logs = true
                end
                if with_output
                    autodetect_output_modes
                    self.output_type = default_output_mode
                    opt.on('-o TYPE[:file]', '--output=TYPE[:file]', String, "in what format to output the result (can be: #{output_modes.join(", ")}), defaults to #{default_output_mode}") do |output_arg|
                        output_type, output_file = output_arg.split(':')
                        output_type = output_type.downcase
                        if !output_modes.include?(output_type)
                            raise ArgumentError, "unknown or unavailable output mode #{output_type}, available output modes: #{output_modes.join(", ")}"
                        end
                        Scripts.output_file = output_file
                        Scripts.output_type = output_type.downcase
                    end
                end
                Roby::Application.common_optparse_setup(opt)
            end

            DOT_DIRECT_OUTPUT = %w{txt x11 qt}

            # Autodetects which output modes are available, and which should be
            # used by default. It depends on the availability of an X11
            # connection (tested by looking at ENV['DISPLAY'] and the
            # availability of Qt / x11 output in dot.
            #
            # The preference is:
            #  * qt
            #  * dot-x11
            #  * txt
            def self.autodetect_output_modes
                @output_modes = %w{txt svg png dot}

                has_x11_display = ENV['DISPLAY']
                if !has_x11_display
                    @default_output_mode = 'txt'
                end

                `dot -Tx11 does_not_exist 2>&1`
                if has_dot_x11 = ($?.exitstatus != 1)
                    @output_modes << 'x11'
                    @default_output_mode = 'x11'
                end

                has_qt =
                    begin
                        require 'Qt4'
                    rescue LoadError
                    end
                if has_qt
                    @output_modes << 'qt'
                    @default_output_mode = 'qt'
                end
            end

            # This sets up output in either text or dot format
            #
            # The text generation is based on Ruby's pretty print (we
            # pretty-print the given object). Otherwise, the given block is
            # meant to generate a dot file that is then postprocessed by
            # generate_dot_output (which needs to be called at the script's end)
            def self.setup_output(script_name, object, &block)
                @dot_generation = block
                @output_object = object

                output_type, output_file = self.output_type, self.output_file
                if !DOT_DIRECT_OUTPUT.include?(output_type) && !output_file
                    @output_file =
                        if base_name = (self.robot_name || self.robot_type)
                            "#{base_name}.#{output_type}"
                        else
                            "#{script_name}.#{output_type}"
                        end
                end
            end

            def self.generate_output(display_options = Hash.new)
                default_exclude = []
                if defined? OroGen::Logger::Logger
                    default_exclude << OroGen::Logger::Logger
                end
                display_options = Kernel.validate_options display_options,
                    :remove_compositions => false,
                    :excluded_models => default_exclude.to_set,
                    :annotations => Set.new

                # Now output them
                case output_type
                when "txt"
                    pp @output_object
                when "dot"
                    File.open(output_file, 'w') do |output_io|
                        output_io.puts @dot_generation.call
                    end
                when "png", "svg", "x11"
                    cmd = "dot -T#{output_type}"
                    if !DOT_DIRECT_OUTPUT.include?(output_type)
                        cmd << " -o#{output_file}"
                    end
                    io = IO.popen(cmd, "w")
                    io.write(@dot_generation.call)
                    io.flush
                    io.close
                when "qt"
                    require 'syskit/gui/instanciated_network_display'
                    if !$qApp
                        app = Qt::Application.new(ARGV)
                    end
                    display = Ui::InstanciatedNetworkDisplay.new
                    display.plan_display.push_plan('Task Dependency Hierarchy', 'hierarchy',
                                      Roby.plan, Roby.syskit_engine, display_options)
                    display.plan_display.push_plan('Dataflow', 'dataflow',
                                      Roby.plan, Roby.syskit_engine, display_options)
                    if @last_error
                        display.add_error(@last_error)
                    end
                    display.show
                    $qApp.exec
                end

                if output_file
                    STDERR.puts "exported result to #{output_file}"
                end
            end

            def self.setup
                tic = Time.now
                Roby.app.using_plugins 'syskit'
                if debug
                    Roby.app.filter_backtraces = false
                end
                if debug
                    Syskit.logger = ::Logger.new(STDOUT)
                    Syskit.logger.formatter = Roby.logger.formatter
                    Syskit.logger.level = ::Logger::DEBUG
                    Orocos.logger = ::Logger.new(STDOUT)
                    Orocos.logger.formatter = Roby.logger.formatter
                    Orocos.logger.level = ::Logger::DEBUG
                end

                Roby.display_exception do
                    Roby.app.setup
                    yield if block_given?
                    toc = Time.now
                    ::Robot.info "loaded Roby application in %.3f seconds" % [toc - tic]
                end
            end

            def self.run
                error = Roby.display_exception do
                    setup_error = setup
                    if !setup_error
                        yield
                        nil
                    else setup_error
                    end
                end
                @last_error = error
            ensure Roby.app.cleanup
            end
        end
end

