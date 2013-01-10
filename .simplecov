if ENV['SYSKIT_ENABLE_COVERAGE'] == '1'
    SimpleCov.command_name 'syskit'
    SimpleCov.start do
        add_filter "/test/"
        add_filter "/gui/"
        add_filter "/scripts/"
    end

    require 'syskit'
    Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
    Syskit.logger.level = Logger::DEBUG
end

