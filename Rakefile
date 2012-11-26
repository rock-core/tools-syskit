require 'rake'
require './lib/syskit/version'
require 'utilrb/doc/rake'

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

task :default => ["setup:uic"]

namespace :setup do
    UIFILES = %w{orocos_composer.ui orocos_system_builder.ui}
    desc 'generate all Qt UI files using rbuic4'
    task :uic do
        rbuic = 'rbuic4'
        if File.exists?('/usr/lib/kde4/bin/rbuic4')
            rbuic = '/usr/lib/kde4/bin/rbuic4'
        end

        UIFILES.each do |file|
            file = 'lib/syskit/gui/' + file
            if !system(rbuic, '-o', file.gsub(/\.ui$/, '_ui.rb'), file)
                STDERR.puts "Failed to generate #{file}"
            end
        end
    end
end
task :setup => "setup:ext"
desc "remove by-products of setup"
task :clean

if Utilrb.doc?
    namespace 'doc' do
        Utilrb.doc 'api', :include => ['lib/**/*.rb'],
            :exclude => [],
            :target_dir => 'doc',
            :title => 'Syskit'

        # desc 'generate all documentation'
        # task 'all' => 'doc:api'
    end

    task 'redocs' => 'doc:reapi'
    task 'doc' => 'doc:api'
else
    STDERR.puts "WARN: cannot load yard or rdoc , documentation generation disabled"
end

