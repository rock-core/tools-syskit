require 'syskit/scripts/common'
Scripts = Syskit::Scripts

Roby.app.using_plugins 'orocos'
available_annotations = Syskit::Graphviz.available_annotations

compute_policies    = true
compute_deployments = true
remove_compositions = false
remove_loggers      = true
validate_network    = true
test = false
annotations = Set.new
default_annotations = ["connection_policy", "task_info"]
display_timepoints = false

parser = OptionParser.new do |opt|
    opt.banner = "instanciate [options] deployment [additional services]
   'deployment' is either the name of a deployment in config/deployments,
    or a file that should be loaded to get the desired deployment
    'additional services', if given, refers to services defined with
    'define' that should be added
    "

    opt.on('--trace=DIR', String, 'generate a dot graph for each step of the generation') do |trace_dir|
        trace_dir = File.expand_path(trace_dir)
        FileUtils.mkdir_p trace_dir
        Syskit::NetworkMergeSolver.tracing_directory = trace_dir
    end

    opt.on('--annotate=LIST', Array, "comma-separated list of annotations that should be added to the output (defaults to #{default_annotations.to_a.join(",")}). Available annotations: #{available_annotations.to_a.sort.join(", ")}") do |ann|
        ann.each do |name|
            if !available_annotations.include?(name)
                STDERR.puts "#{name} is not a known annotation. Known annotations are: #{available_annotations.join(", ")}"
                exit 1
            end
        end

        annotations |= ann.to_set
    end

    opt.on('--no-policies', "don't compute the connection policies") do
        compute_policies = false
    end
    opt.on('--no-deployments', "don't deploy") do
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
    opt.on('--test', 'test mode: instanciates everything defined in the given file') do
        test = true
    end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty?
    STDERR.puts parser
    exit(1)
end

if annotations.empty?
    annotations = default_annotations
end

require 'roby/standalone'

class Instanciate
    attr_accessor :passes
    def initialize(passes)
        @passes = passes
    end

    def self.parse_passes(remaining)
        if remaining.empty?
            return []
        end

        remaining = remaining.dup
        passes = [[remaining.shift, []]]
        pass = 0
        while name = remaining.shift
            if name == "/"
                pass += 1
                passes[pass] = [remaining.shift, []]
            else
                passes[pass][1] << name
            end
        end
        passes
    end

    def self.setup
        Roby.app.orocos_only_load_models = true
        Roby.app.orocos_disables_local_process_server = true
        Roby.app.single
    end

    def self.compute(passes, compute_policies, compute_deployments, validate_network, display_timepoints = false)
        Scripts.start_profiling
        Scripts.pause_profiling

        passes.each do |deployment_file, additional_services|
            if deployment_file != '-'
                Roby.app.load_orocos_deployment(deployment_file)
            end
            additional_services.each do |service_name|
                Scripts.add_service(service_name)
            end

            Scripts.resume_profiling
            Scripts.tic
            Roby.app.orocos_engine.
                resolve(:compute_policies => compute_policies,
                    :compute_deployments => compute_deployments,
                    :validate_network => validate_network,
                    :on_error => :commit)
            Scripts.toc_tic "computed deployment in %.3f seconds"
            if display_timepoints
                pp Roby.app.orocos_engine.format_timepoints
            end
            Scripts.pause_profiling
        end
        Scripts.end_profiling
    end

    def run(compute_policies = true, compute_deployments = true, validate_network = true, remove_loggers = true, remove_compositions = false, annotations = [], display_timepoints = false)
        excluded_models      = ValueSet.new
        Scripts.setup_output("instanciate", Roby.app.orocos_engine) do
            Roby.app.orocos_engine.
                to_dot_dataflow(remove_compositions, excluded_models, annotations)
        end

        self.class.setup
        error = Scripts.run do
            GC.start
            self.class.compute(passes, compute_policies, compute_deployments, validate_network, display_timepoints)
        end

        if remove_loggers
            if defined? Syskit::Logger::Logger
                excluded_models << Syskit::Logger::Logger
            end
        end

        Scripts.generate_output(:remove_compositions => remove_compositions,
                                :excluded_models => excluded_models,
                                :annotations => annotations)

        error
    end
end

if test
    test_file = remaining.shift
    test_setup = YAML.load(File.read(test_file))

    config = test_setup.delete('configuration') || %w{--no-loggers --no-compositions -osvg}

    default_deployment = test_setup.delete('default_deployment') || '-'
    default_robot = test_setup.delete('default_robot')
    default_def = { 'deployment' => default_deployment, 'robot' => default_robot, 'services' => [] }

    output_option, config = config.partition { |s| s =~ /^-o(\w+)$/ }
    output_option = output_option.first
    if !output_option
        output_option = "-osvg"
    end

    simple_tests = test_setup.delete('simple_tests') || []
    simple_tests.each do |name|
        test_setup[name] = [name]
    end

    test_setup.each do |test_name, test_def|
        if test_def.respond_to?(:to_ary)
            test_def = { 'services' => test_def }
        elsif test_def.respond_to?(:to_str)
            test_def = { 'services' => [test_def] }
        end

        test_def = default_def.merge(test_def)

        dirname = "instanciate"
        if test_def['robot']
            dirname << "-#{test_def['robot']}"
        end
        outdir = File.join(File.dirname(test_file), 'results', dirname)
        outdir = File.expand_path(outdir)
        FileUtils.mkdir_p(outdir)

        cmdline = []
        cmdline.concat(config)
        cmdline << output_option + ":#{File.join(outdir, test_name)}"
        if test_def['robot']
            cmdline << "-r#{test_def['robot']}"
        end
        cmdline << test_def['deployment']
        cmdline.concat(test_def['services'])

        txtlog = File.join(outdir, "#{test_name}-out.txt")
        shellcmd = "'#{cmdline.join("' '")}' >> #{txtlog} 2>&1"
        File.open(txtlog, 'w') do |io|
            io.puts test_name
            io.puts shellcmd
            io.puts
        end

        STDERR.print "running test #{test_name}... "
        `rock-roby instanciate #{shellcmd}`
        if $?.exitstatus != 0
            if $?.exitstatus == 2
                STDERR.puts "deployment successful, but dot failed to generate the resulting network"
            else
                STDERR.puts "failed"
            end
        else
            STDERR.puts "success"
        end
    end
    exit(0)

else
    passes = Instanciate.parse_passes(remaining)
end


# If we are using the Qt GUI, do everything in there
if Scripts.output_type == 'qt'
    require 'syskit/gui/instanciated_network_display'
    class InstanciateGUI < Qt::Widget
        attr_reader :apply_btn
        attr_reader :instance_txt
        attr_reader :network_display

        def initialize(parent = nil, arguments = "")
            super(parent)

            main_layout = Qt::VBoxLayout.new(self)
            toolbar_layout = Qt::HBoxLayout.new
            main_layout.add_layout(toolbar_layout)

            @apply_btn = Qt::PushButton.new("Reload && Apply", self)
            @instance_txt = Qt::LineEdit.new(self)
            toolbar_layout.add_widget(@apply_btn)
            toolbar_layout.add_widget(@instance_txt)

            main_layout.add_widget(
                @network_display = Ui::InstanciatedNetworkDisplay.new(self))

            @apply_btn.connect(SIGNAL('clicked()')) do
                Roby.app.reload_config
                compute
            end

            @instance_txt.text = arguments
            compute
        end

        def compute
            passes = Instanciate.parse_passes(instance_txt.text.split(" "))

            Roby.plan.clear
            Roby.orocos_engine.clear
            begin Instanciate.compute(passes, true, true, true)
            rescue Exception => e
                error = e
            end

            network_display.display_plan(Roby.plan, Roby.orocos_engine)
            if error
                network_display.add_error(error)
            end
        end
        slots 'compute()'
    end

    app = Qt::Application.new(ARGV)
    Instanciate.setup
    Scripts.setup
    display = InstanciateGUI.new(nil, remaining.join(" "))
    display.show
    app.exec
else
    cmd_handler = Instanciate.new(passes)
    if cmd_handler.run(compute_policies, compute_deployments, validate_network, remove_loggers, remove_compositions, annotations, display_timepoints)
        exit 1
    end
end

STDOUT.flush
