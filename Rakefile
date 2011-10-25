require 'rake'
require './lib/orocos/version'

begin
    require 'hoe'
    namespace 'dist' do
        config = Hoe.spec('orocos.rb') do |p|
            self.developer("Sylvain Joyeux", "sylvain.joyeux@dfki.de")

            self.summary = 'Controlling Orocos modules from Ruby'
            self.description = ""
            self.url = ["http://doudou.github.com/orocos-rb", "http://github.com/doudou/orocos.rb.git"]
            self.changes = ""

            self.extra_deps <<
                ['utilrb', ">= 1.1"] <<
                ['rake', ">= 0.8"]

            #self.spec.extra_rdoc_files.reject! { |file| file =~ /Make/ }
            #self.spec.extensions << 'ext/extconf.rb'
        end

        Rake.clear_tasks(/dist:(re|clobber_|)docs/)
    end

rescue LoadError
    STDERR.puts "cannot load the Hoe gem. Distribution is disabled"
rescue Exception => e
    if e.message !~ /\.rubyforge/
        STDERR.puts "cannot load the Hoe gem, or Hoe fails. Distribution is disabled"
        STDERR.puts "error message is: #{e.message}"
    end
end

def build_orogen(name)
    require './lib/orocos/test'
    work_dir = File.expand_path(File.join('test', 'working_copy'))
    prefix   = File.join(work_dir, 'prefix')
    data_dir = File.expand_path(File.join('test', 'data'))

    Orocos::Test.generate_and_build File.join(data_dir, name, "#{name}.orogen"), work_dir
end

task :default => ["setup:ext", "setup:uic"]

namespace :setup do
    desc "builds Orocos.rb C extension"
    task :ext do
        builddir = File.join('ext', 'build')
        prefix   = File.join(Dir.pwd, 'ext')

        FileUtils.mkdir_p builddir
        orocos_target = ENV['OROCOS_TARGET'] || 'gnulinux'
        Dir.chdir(builddir) do
            FileUtils.rm_f "CMakeCache.txt"
            if !system("cmake", "-DRUBY_PROGRAM_NAME=#{FileUtils::RUBY}", "-DCMAKE_INSTALL_PREFIX=#{prefix}", "-DOROCOS_TARGET=#{orocos_target}", "-DCMAKE_BUILD_TYPE=Debug", "..")
                raise "unable to configure the extension using CMake"
            end

            if !system("make") || !system("make", "install")
                throw "unable to build the extension"
            end
        end
        FileUtils.ln_sf "../ext/rorocos_ext.so", "lib/rorocos_ext.so"
    end

    desc "builds the oroGen modules that are needed by the tests"
    task :orogen_all do
        build_orogen 'process'
        build_orogen 'simple_sink'
        build_orogen 'simple_source'
        build_orogen 'echo'
        build_orogen 'operations'
        build_orogen 'configurations'
        build_orogen 'states'
        build_orogen 'uncaught'
        build_orogen 'system'
    end

    desc "builds the test 'process' module"
    task :orogen_process do build_orogen 'process' end
    desc "builds the test 'simple_sink' module"
    task :orogen_sink    do build_orogen 'simple_sink' end
    desc "builds the test 'simple_source' module"
    task :orogen_source  do build_orogen 'simple_source' end
    desc "builds the test 'echo' module"
    task :orogen_echo    do build_orogen 'echo' end
    desc "builds the test 'states' module"
    task :orogen_states    do build_orogen 'states' end
    desc "builds the test 'uncaught' module"
    task :orogen_uncaught    do build_orogen 'uncaught' end
    desc "builds the test 'system' module"
    task :orogen_system    do build_orogen 'system' end
    desc "builds the test 'operations' module"
    task :orogen_operations    do build_orogen 'operations' end
    desc "builds the test 'configurations' module"
    task :orogen_configurations    do build_orogen 'configurations' end

    UIFILES = %w{orocos_composer.ui orocos_system_builder.ui}
    desc 'generate all Qt UI files using rbuic4'
    task :uic do
        rbuic = 'rbuic4'
        if File.exists?('/usr/lib/kde4/bin/rbuic4')
            rbuic = '/usr/lib/kde4/bin/rbuic4'
        end

        UIFILES.each do |file|
            file = 'lib/orocos/roby/gui/' + file
            if !system(rbuic, '-o', file.gsub(/\.ui$/, '_ui.rb'), file)
                STDERR.puts "Failed to generate #{file}"
            end
        end
    end
end
task :setup => "setup:ext"
desc "remove by-products of setup"
task :clean do
    FileUtils.rm_rf "ext/build"
    FileUtils.rm_rf "ext/rorocos_ext.so"
    FileUtils.rm_rf "lib/rorocos_ext.so"
    FileUtils.rm_rf "test/working_copy"
end

do_doc = begin
             require 'rdoc/task'
             true
         rescue LoadError => e
             STDERR.puts "WARN: cannot load RDoc, documentation generation disabled"
             STDERR.puts "WARN:   #{e.message}"
         end

if do_doc
    task 'doc' => 'doc:all'
    task 'clobber_docs' => 'doc:clobber'
    task 'redocs' do
        Rake::Task['clobber_docs'].invoke
        if !system('rake', 'doc:all')
            raise "failed to regenerate documentation"
        end
    end

    namespace 'doc' do
        task 'all' => %w{api}
        RDoc::Task.new("api") do |rdoc|
            rdoc.rdoc_dir = 'doc'
            rdoc.title    = "orocos.rb"
            rdoc.options << '--show-hash'
            rdoc.rdoc_files.include('lib/**/*.rb')
        end
    end
end

