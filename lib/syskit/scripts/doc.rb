require 'roby/standalone'
require 'syskit/scripts/common'
require 'Qt'
require 'syskit/gui/model_browser'
require 'kramdown'

Scripts = Syskit::Scripts

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: syskit doc [options]
Generate HTML documentation for all the models present in this bundle
    EOD
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using_plugins 'syskit'
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Roby.app.ignore_all_load_errors = true

direct_files, model_names = remaining.partition do |arg|
    File.file?(arg)
end
# Load all task libraries if we don't get a file to require
Roby.app.syskit_load_all = direct_files.empty?
Roby.app.additional_model_files.concat(direct_files)

Qt::Application.new(ARGV)

# Look into all the models we want to generate documentation for
Scripts.setup

task_contexts = Syskit::TaskContext.each_submodel.
    find_all { |m| !(m <= Syskit::PlaceholderTask) && !m.private_specialization? }
compositions = Syskit::Composition.each_submodel.
    find_all { |m| !m.is_specialization? }
data_services = Syskit::DataService.each_submodel
profiles = Syskit::Actions::Profile.profiles

Hash[Syskit::TaskContext => task_contexts,
     Syskit::Composition => compositions,
     Syskit::DataService => data_services,
     Syskit::Actions::Profile => profiles].each do |root_model, model_set|
    model_set.each do |sub|
        path = File.join(Roby.app.app_dir, 'doc', *sub.name.split('::'))

        view = Syskit::GUI::ModelBrowser::AVAILABLE_VIEWS.find { |v| v.root_model == root_model }
        FileUtils.mkdir_p File.dirname(path)
        File.open(path + ".html", 'w') do |io|
            io.write Syskit::GUI::Page.to_html(sub, view.renderer, :interactive => false)
        end
        puts "written #{path}"
    end
end

