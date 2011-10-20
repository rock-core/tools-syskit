require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

module Orocos
    module RobyPlugin
        module Scripts
            class << self
                attr_accessor :debug
                attr_accessor :output_file
                attr_accessor :output_type
                attr_accessor :robot_type
                attr_accessor :robot_name
            end
            @debug = false
            @output_type = 'txt'

            def self.tic
                @tic = Time.now
            end
            def self.toc(string = nil)
                if string
                    STDERR.puts string % [Time.now - @tic]
                else STDERR.puts yield(Time.now - @tic)
                end
            end
            def self.toc_tic(string = nil, &block)
                toc(string, &block)
                tic
            end

            def self.resolve_service_name(service)
                service_name, service_conf = service.split(':')
                if service_conf
                    service_conf = service_conf.split(',')
                end
                engine = Roby.app.orocos_engine
                instance = engine.resolve_name(service_name)
                if service_conf
                    instance.use_conf(*service_conf)
                end
                instance
            end

            def self.common_options(opt, with_output = false)
                opt.on('--debug', "turn debugging output on") do
                    Scripts.debug = true
                end
                if with_output
                    opt.on('-o TYPE[:file]', '--output=TYPE[:file]', String, 'in what format to output the result (can be: txt, dot, png or svg), defaults to txt') do |output_arg|
                        output_type, output_file = output_arg.split(':')
                        Scripts.output_file = output_file
                        Scripts.output_type = output_type.downcase
                    end
                end
                Roby::Application.common_optparse_setup(opt)
            end

            DOT_DIRECT_OUTPUT = %w{txt x11}

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

            def self.generate_output
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
                end

                if output_file
                    STDERR.puts "exported result to #{output_file}"
                end
            end

            def self.setup
            end

            def self.run
                error = Roby.display_exception do
                    tic = Time.now
                    Roby.app.filter_backtraces = !debug
                    Roby.app.using_plugins 'orocos'
                    if debug
                        RobyPlugin.logger = ::Logger.new(STDOUT)
                        RobyPlugin.logger.formatter = Roby.logger.formatter
                        RobyPlugin.logger.level = ::Logger::DEBUG
                        Engine.logger = ::Logger.new(STDOUT)
                        Engine.logger.formatter = Roby.logger.formatter
                        Engine.logger.level = ::Logger::DEBUG
                        SystemModel.logger = ::Logger.new(STDOUT)
                        SystemModel.logger.formatter = Roby.logger.formatter
                        SystemModel.logger.level = ::Logger::DEBUG
                    end

                    Roby.app.setup
                    toc = Time.now
                    STDERR.puts "loaded Roby application in %.3f seconds" % [toc - tic]

                    yield
                end

                if error
                    exit(1)
                end
            ensure Roby.app.stop_process_servers
            end
        end
    end
end

