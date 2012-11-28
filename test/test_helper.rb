begin
require 'simplecov'
rescue Exception
    Syskit.warn "coverage is disabled because the 'simplecov' gem cannot be loaded"
end

begin
require 'pry'
rescue Exception
    Syskit.warn "debugging is disabled because the 'pry' gem cannot be loaded"
end

def start_simple_cov(name)
    if defined? SimpleCov
        if !defined? @@simple_cov_started
            SimpleCov.command_name name
            @@simple_cov_started = true
            SimpleCov.root(File.join(File.dirname(__FILE__),".."))
            SimpleCov.add_filter "/test/"
            SimpleCov.start
        end
    end
end
