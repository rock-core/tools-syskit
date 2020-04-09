# frozen_string_literal: true

require "roby/standalone"
require "syskit/scripts/common"
require "Qt"
require "syskit/gui/model_browser"
require "kramdown"

Scripts = Syskit::Scripts

load_all = false
parser = OptionParser.new do |opt|
    opt.banner = <<~BANNER_TEXT
        Usage: syskit doc [options]
        Generate HTML documentation for all the models present in this bundle
    BANNER_TEXT

    opt.on "--all", "-a", "Load all models from all active bundles instead of only the ones from the current" do
        load_all = true
    end
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using "syskit"
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Roby.app.ignore_all_load_errors = true

direct_files, model_names = remaining.partition do |arg|
    File.file?(arg)
end
# Load all task libraries if we don't get a file to require
Roby.app.auto_load_all = load_all
Roby.app.additional_model_files.concat(direct_files)

Qt::Application.new(ARGV)

# Look into all the models we want to generate documentation for
Scripts.setup

task_contexts = Syskit::TaskContext.each_submodel
                                   .find_all { |m| !m.placeholder? && !m.private_specialization? }
compositions = Syskit::Composition.each_submodel
                                  .find_all { |m| !m.is_specialization? }
data_services = Syskit::DataService.each_submodel
profiles = Syskit::Actions::Profile.profiles

class Page < MetaRuby::GUI::HTML::Page
    attr_accessor :root_dir

    def self.filter_file_path(elements)
        elements.map { |el| el.gsub(/[^\w]/, "_") }
    end

    def self.make_file_path(object, root_dir)
        if object.kind_of?(Class) && (object <= Typelib::Type)
            make_type_file_path(object, root_dir)
        else make_object_file_path(object, root_dir)
        end
    end

    def self.make_type_file_path(type, root_dir)
        name_elements = type.split_typename
        path = filter_file_path(name_elements)
        File.join(*(root_dir + ["types", *path])) + ".html"
    end

    def self.make_object_file_path(object, root_dir)
        path = filter_file_path(object.name.split("::"))
        File.join(*(root_dir + path)) + ".html"
    end

    def link_to(object, text = nil)
        if object.kind_of?(Orocos::Spec::TaskContext)
            link_to(Syskit::TaskContext.find_model_from_orogen_name(object.name), text)

        elsif object.kind_of?(Class) && (object <= Typelib::Type)
            text = MetaRuby::GUI::HTML.escape_html(text || object.name)
            relative_path = Page.make_type_file_path(object, root_dir)
            "<a href=\"#{relative_path}\">#{text}</a>"

        elsif object.name
            text = MetaRuby::GUI::HTML.escape_html(text || object.name)
            relative_path = Page.make_object_file_path(object, root_dir)
            "<a href=\"#{relative_path}\">#{text}</a>"

        else super
        end
    end

    def self.to_html_page(model, renderer, options = {})
        options, page_options = Kernel.filter_options options, :root_dir => nil
        page = new(MetaRuby::GUI::HTML::HTMLPage.new)
        page.root_dir = options[:root_dir]
        renderer.new(page).render(model, page_options)
        page
    end
end

root_dir = File.join(Roby.app.app_dir, "doc")
asset_dir = "assets"
MetaRuby::GUI::HTML::Page.copy_assets_to(File.join(root_dir, asset_dir))

Hash[Syskit::TaskContext => task_contexts,
     Syskit::Composition => compositions,
     Syskit::DataService => data_services,
     Syskit::Actions::Profile => profiles,
     Typelib::Type => Orocos.registry.each.to_a].each do |root_model, model_set|
    model_set.each do |sub|
        path = Page.make_file_path(sub, [root_dir])
        relative_to_root = Pathname.new(root_dir).relative_path_from(Pathname.new(path).dirname).to_path

        view = Syskit::GUI::ModelBrowser::AVAILABLE_VIEWS.find { |v| v.root_model == root_model }
        FileUtils.mkdir_p File.dirname(path)
        File.open(path, "w") do |io|
            io.write Page.to_html(sub, view.renderer, :interactive => false,
                                                      :external_objects => path + "-%s",
                                                      :root_dir => [relative_to_root],
                                                      :ressource_dir => File.join(relative_to_root, asset_dir))
        end
        puts "written #{path}"
    end
end

index_page = Page.new(MetaRuby::GUI::HTML::HTMLPage.new)
index_page.root_dir = []

all_items = (task_contexts.to_a + compositions.to_a + data_services.to_a + profiles.to_a + Orocos.registry.each.to_a)
            .sort_by(&:name)
            .map { |m| index_page.link_to(m) }
index_page.render_list(nil, all_items, :filter => true, :id => "model-index")
html = index_page.html(:ressource_dir => asset_dir)
File.open(File.join("doc", "index.html"), "w") do |io|
    io.write(html)
end
