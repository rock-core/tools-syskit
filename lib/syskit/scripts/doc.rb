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

class Page < Syskit::GUI::Page
    attr_accessor :root_dir

    def link_to(object, text = nil)
        if object.name
            text = MetaRuby::GUI::HTML.escape_html(text || object.name)
            relative_path = File.join(*(root_dir + object.name.split("::"))) + ".html"
            "<a href=\"#{relative_path}\">#{text}</a>"
        else super
        end
    end

    def self.to_html_page(model, renderer, options = Hash.new)
        options, page_options = Kernel.filter_options options, :root_dir => nil
        page = new(MetaRuby::GUI::HTML::HTMLPage.new)
        page.root_dir = options[:root_dir]
        renderer.new(page).render(model, page_options)
        page
    end
end

root_dir = File.join(Roby.app.app_dir, 'doc')
asset_dir = 'assets'
MetaRuby::GUI::HTML::Page.copy_assets_to(File.join(root_dir, asset_dir))

Hash[Syskit::TaskContext => task_contexts,
     Syskit::Composition => compositions,
     Syskit::DataService => data_services,
     Syskit::Actions::Profile => profiles
     ].each do |root_model, model_set|

    model_set.each do |sub|
        path_elements = sub.name.split('::')
        path = File.join(root_dir, *path_elements)

        view = Syskit::GUI::ModelBrowser::AVAILABLE_VIEWS.find { |v| v.root_model == root_model }
        FileUtils.mkdir_p File.dirname(path)
        File.open(path + ".html", 'w') do |io|
            relative_to_root = [".."] * (path_elements.size - 1)
            io.write Page.to_html(sub, view.renderer, :interactive => false,
                                  :external_objects => path + "-%s",
                                  :root_dir => relative_to_root,
                                  :ressource_dir => File.join(relative_to_root, 'assets'))
        end
        puts "written #{path}"
    end

end

index_page = Page.new(MetaRuby::GUI::HTML::HTMLPage.new)
index_page.root_dir = []

all_items = (task_contexts.to_a + compositions.to_a + data_services.to_a + profiles.to_a).
    sort_by { |m| m.name }.
    map { |m| index_page.link_to(m) }
index_page.render_list(nil, all_items, :id => 'model-index')
index_page.update_html
File.open(File.join("doc", "index.html"), "w") do |io|
    io.write(index_page.html)
end

