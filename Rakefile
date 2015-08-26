require 'rake'
require './lib/syskit/version'
require 'utilrb/doc/rake'

begin
    require 'hoe'
    Hoe::RUBY_FLAGS.gsub! /-w/, ''
    namespace 'dist' do
        config = Hoe.spec('syskit') do |p|
            self.readme_file = 'README.rd'
            self.description = "Model-based coordination of component-based layers"
            self.developer("Sylvain Joyeux", "sylvain.joyeux@dfki.de")
            self.license 'LGPLv2+'

            self.extra_deps <<
                ['utilrb', ">= 1.1"] <<
                ['rake', ">= 0.8"]

            self.test_globs = ['test/suite.rb']
        end
    end

    Rake.clear_tasks(/^default$/)
    Rake.clear_tasks(/^doc$/)

rescue LoadError
    STDERR.puts "cannot load the Hoe gem. Distribution is disabled"
rescue Exception => e
    if e.message !~ /\.rubyforge/
        STDERR.puts "cannot load the Hoe gem, or Hoe fails. Distribution is disabled"
        STDERR.puts "error message is: #{e.message}"
    end
end

task :default => ["setup:uic"]
task :test => 'dist:test'

namespace :setup do
    UIFILES = %w{}
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
            :title => 'Syskit',
            :plugins => ['utilrb', 'roby'],
            :files => ['Upgrading.md']

        # desc 'generate all documentation'
        # task 'all' => 'doc:api'
    end

    task 'redocs' => 'doc:reapi'
    task 'doc' => 'doc:api'
    task 'gem' => 'dist:gem'
else
    STDERR.puts "WARN: cannot load yard or rdoc , documentation generation disabled"
end

