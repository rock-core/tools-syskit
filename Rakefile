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

desc "builds Orocos.rb C extension"
task :setup do
    builddir = File.join('ext', 'build')
    prefix   = File.join(Dir.pwd, 'ext')

    FileUtils.mkdir_p builddir
    Dir.chdir(builddir) do
        if !system("cmake", "-DCMAKE_INSTALL_PREFIX=#{prefix}", "-DOROCOS_TARGET=gnulinux", "..")
            throw "unable to configure the extension using CMake"
        end

        if !system("make") || !system("make", "install")
            throw "unable to build the extension"
        end
    end
    FileUtils.ln_sf "../ext/rorocos_ext.so", "lib/rorocos_ext.so"
end

desc "remove by-products of setup"
task :clean do
    FileUtils.rm_rf "ext/build"
    FileUtils.rm_rf "ext/rorocos_ext.so"
    FileUtils.rm_rf "lib/rorocos_ext.so"
end

