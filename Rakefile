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

        Rake.clear_tasks(/dist:publish_docs/)
        Rake.clear_tasks(/dist:(re|clobber_|)docs/)
        task 'publish_docs' => 'redocs' do
            if !system('doc/misc/update_github')
                raise "cannot update the gh-pages branch for GitHub"
            end
            if !system('git', 'push', 'github', 'gh-pages')
                raise "cannot push the documentation"
            end
        end
    end

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
             require 'webgen/webgentask'
             require 'rdoc/task'
             true
         rescue LoadError => e
             STDERR.puts "ERROR: cannot load webgen and/or RDoc, documentation generation disabled"
             STDERR.puts "ERROR:   #{e.message}"
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
        task 'all' => %w{guide api}
        task 'clobber' => 'clobber_guide'
        Webgen::WebgenTask.new('guide') do |website|
            website.clobber_outdir = true
            website.directory = File.join(Dir.pwd, 'doc', 'guide')
            website.config_block = lambda do |config|
                config['output'] = ['Webgen::Output::FileSystem', File.join(Dir.pwd, 'doc', 'html')]
            end
        end
        RDoc::Task.new("api") do |rdoc|
            rdoc.rdoc_dir = 'doc/html/api'
            rdoc.title    = "orocos.rb"
            rdoc.options << '--show-hash'
            rdoc.rdoc_files.include('lib/**/*.rb')
        end
    end
end

