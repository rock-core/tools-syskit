begin
require 'simplecov'
rescue Exception
    puts "!!! Cannot load simplecov. Coverage is disabled !!!"
end

def start_simple_cov(name)
    if defined? SimpleCov
        if !defined? @@simple_cov_started
            SimpleCov.command_name name
            @@simple_cov_started = true
            SimpleCov.root(File.join(File.dirname(__FILE__),".."))
            SimpleCov.start
        end
    end
end
