require 'rake'
require './lib/orocos/version'

begin
    require 'hoe'
    config = Hoe.new('orocos.rb', Orocos::VERSION) do |p|
        p.developer("Sylvain Joyeux", "sylvain.joyeux@dfki.de")

        p.summary = 'Controlling Orocos modules from Ruby'
        p.description = "blabla"
        p.url = ""
        p.changes = "blabla"
        # p.description = p.paragraphs_of('README.txt', 3..6).join("\n\n")
        # p.url         = p.paragraphs_of('README.txt', 0).first.split(/\n/)[1..-1]
        # p.changes     = p.paragraphs_of('History.txt', 0..1).join("\n\n")

        p.extra_deps << 'utilrb' << 'rake'
    end
    config.spec.extensions << 'ext/extconf.rb'
rescue LoadError
    STDERR.puts "cannot load the Hoe gem. Distribution is disabled"
rescue Exception => e
    STDERR.puts "cannot load the Hoe gem, or Hoe fails. Distribution is disabled"
    STDERR.puts "error message is: #{e.message}"
    STDERR.puts "  #{e.backtrace.join("\n  ")}"
end

def build_orogen(name)
    require 'lib/orocos/test'
    work_dir = File.expand_path(File.join('test', 'working_copy'))
    prefix   = File.join(work_dir, 'prefix')
    data_dir = File.expand_path(File.join('test', 'data'))

    Orocos::Test.generate_and_build File.join(data_dir, name, "#{name}.orogen"), work_dir
end

namespace :setup do
    desc "builds Orocos.rb C extension"
    task :ext do
        builddir = File.join('ext', 'build')
        prefix   = File.join(Dir.pwd, 'ext')

        FileUtils.mkdir_p builddir
        orocos_target = ENV['OROCOS_TARGET'] || 'gnulinux'
        Dir.chdir(builddir) do
            if !system("cmake", "-DCMAKE_INSTALL_PREFIX=#{prefix}", "-DOROCOS_TARGET=#{orocos_target}", "-DCMAKE_BUILD_TYPE=Debug", "..")
                raise "unable to configure the extension using CMake"
            end

            if !system("make") || !system("make", "install")
                throw "unable to build the extension"
            end
        end
        FileUtils.ln_sf "../ext/rorocos_ext.so", "lib/rorocos_ext.so"
    end

    desc "builds the oroGen modules that are needed by the tests"
    task :orogen_all => :ext do
        build_orogen 'process'
        build_orogen 'simple_sink'
        build_orogen 'simple_source'
        build_orogen 'echo'
    end

    desc "builds the test 'process' module"
    task :orogen_process do build_orogen 'process' end
    desc "builds the test 'simple_sink' module"
    task :orogen_sink    do build_orogen 'simple_sink' end
    desc "builds the test 'simple_source' module"
    task :orogen_source  do build_orogen 'simple_source' end
    desc "builds the test 'echo' module"
    task :orogen_echo    do build_orogen 'echo' end
end
task :setup => "setup:ext"

desc "remove by-products of setup"
task :clean do
    FileUtils.rm_rf "ext/build"
    FileUtils.rm_rf "ext/rorocos_ext.so"
    FileUtils.rm_rf "lib/rorocos_ext.so"
    FileUtils.rm_rf "test/working_copy"
end

