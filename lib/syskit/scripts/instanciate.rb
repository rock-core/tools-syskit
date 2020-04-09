# frozen_string_literal: true

require "roby/standalone"
require "syskit/scripts/common"
require "syskit/gui/instanciate"
Scripts = Syskit::Scripts

available_annotations = Syskit::Graphviz.available_annotations

compute_policies    = true
compute_deployments = true
remove_compositions = false
remove_loggers      = true
validate_network    = true
test = false
annotations = Set.new
default_annotations = %w[connection_policy task_info]
display_timepoints = false

parser = OptionParser.new do |opt|
    opt.banner = "instanciate [options] [files] actions
    where 'actions' is the list of actions that should be instanciated (they
    must be names of definitions and/or devices with the corresponding _def or _dev
    suffixes). If files are provided on the command line, they are loaded to define
    models and/or add things to the plan
    "

    opt.on("--trace=DIR", String, "generate a dot graph for each step of the generation") do |trace_dir|
        trace_dir = File.expand_path(trace_dir)
        FileUtils.mkdir_p trace_dir
        Syskit::NetworkGeneration::MergeSolver.tracing_directory = trace_dir
    end

    opt.on("--annotate=LIST", Array, "comma-separated list of annotations that should be added to the output (defaults to #{default_annotations.to_a.join(',')}). Available annotations: #{available_annotations.to_a.sort.join(', ')}") do |ann|
        ann.each do |name|
            unless available_annotations.include?(name)
                STDERR.puts "#{name} is not a known annotation. Known annotations are: #{available_annotations.join(', ')}"
                exit 1
            end
        end

        annotations |= ann.to_set
    end

    opt.on("--no-policies", "don't compute the connection policies") do
        compute_policies = false
    end
    opt.on("--no-deployments", "don't deploy") do
        compute_deployments = false
    end
    opt.on("--[no-]loggers", "remove all loggers from the generated data flow graph") do |value|
        remove_loggers = !value
    end
    opt.on("--no-compositions", "remove all compositions from the generated data flow graph") do
        remove_compositions = true
    end
    opt.on("--dont-validate", "do not validate the generate system network") do
        validate_network = false
    end
    opt.on("--timepoints") do
        display_timepoints = true
    end
    opt.on("--rprof=FILE", String, "run the deployment algorithm under ruby-prof, and generates a kcachegrind-compatible output to FILE") do |path|
        display_timepoints = true
        if path
            Scripts.use_rprof(path)
        end
    end
    opt.on("--pprof=FILE", String, "run the deployment algorithm under google perftools, and generates the raw profiling information to FILE") do |path|
        display_timepoints = true
        if path
            Scripts.use_pprof(path)
        end
    end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty?
    STDERR.puts parser
    exit(1)
end
direct_files, required_actions = remaining.partition do |arg|
    File.file?(arg)
end

if annotations.empty?
    annotations = default_annotations
end

Roby.app.using "syskit"
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Roby.app.ignore_all_load_errors = true
Roby.app.auto_load_models = direct_files.empty?
Roby.app.additional_model_files.concat(direct_files)

begin
    app = Qt::Application.new([])

    setup_error = Scripts.setup
    w = Syskit::GUI::Instanciate.new(
        nil,
        required_actions.join(" "),
        Roby.app.permanent_requirements
    )
    w.show
    if setup_error
        w.exception_view.push(setup_error)
    else
        w.compute
    end
    app.exec
ensure Roby.app.cleanup
end
