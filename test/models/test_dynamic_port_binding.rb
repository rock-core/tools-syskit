# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe DynamicPortBinding do
            describe "creation from a port matcher" do
                before do
                    task_m = Syskit::TaskContext.new_submodel do
                        output_port "out", "/double"
                    end
                    @matcher = task_m.match.out_port
                end

                it "creates from matcher in .create" do
                    flexmock(DynamicPortBinding)
                        .should_receive(:create_from_matcher)
                        .with(@matcher).once.and_return(ret = flexmock)
                    assert_equal ret,
                                 Models::DynamicPortBinding.create(@matcher)
                end

                it "raises if the matcher's type cannot be inferred" do
                    flexmock(@matcher).should_receive(try_resolve_type: nil)
                    e = assert_raises(ArgumentError) do
                        Models::DynamicPortBinding.create_from_matcher(@matcher)
                    end
                    assert_equal "cannot create a dynamic data source from a matcher "\
                                "whose type cannot be inferred", e.message
                end

                it "raises if the matcher's direction cannot be inferred "\
                   "and 'direction' is :auto" do
                    flexmock(@matcher).should_receive(try_resolve_direction: nil)
                    e = assert_raises(ArgumentError) do
                        Models::DynamicPortBinding.create_from_matcher(@matcher)
                    end
                    assert_equal "cannot create a dynamic data source from a matcher "\
                                "whose direction cannot be inferred", e.message
                end

                it "sets the direction if the matcher's resolves it to :output" do
                    flexmock(@matcher).should_receive(try_resolve_direction: :output)
                    m = Models::DynamicPortBinding.create_from_matcher(@matcher)
                    assert m.output?
                end

                it "sets the direction if the matcher's resolves it to :input" do
                    flexmock(@matcher).should_receive(try_resolve_direction: :input)
                    m = Models::DynamicPortBinding.create_from_matcher(@matcher)
                    refute m.output?
                end

                it "uses an input direction given to the create method" do
                    flexmock(@matcher).should_receive(try_resolve_direction: :output)
                    m = Models::DynamicPortBinding.create_from_matcher(
                        @matcher, direction: :input
                    )
                    refute m.output?
                end

                it "uses an output direction given to the create method" do
                    flexmock(@matcher).should_receive(try_resolve_direction: :input)
                    m = Models::DynamicPortBinding.create_from_matcher(
                        @matcher, direction: :output
                    )
                    assert m.output?
                end

                it "raises if the direction is invalid" do
                    flexmock(@matcher).should_receive(try_resolve_direction: nil)
                    e = assert_raises(ArgumentError) do
                        Models::DynamicPortBinding.create_from_matcher(
                            @matcher, direction: :something
                        )
                    end
                    assert_equal "'something' is not a valid value for the 'direction' "\
                                 "option. Should be one of :auto, :input or :output",
                                 e.message
                end
            end

            describe "#to_data_accessor" do
                it "creates a reader if the port is an output" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: true, port_resolver: nil)
                    accessor = m.to_data_accessor
                    assert_kind_of DynamicPortBinding::OutputReader, accessor
                    assert_equal m, accessor.port_binding
                end

                it "passes the policy to the reader object" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: true, port_resolver: nil)
                    accessor = m.to_data_accessor(type: :buffer, size: 20)
                    assert_equal({ type: :buffer, size: 20 }, accessor.policy)
                end

                it "creates a writer if the port is an input" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: false, port_resolver: nil)
                    accessor = m.to_data_accessor
                    assert_kind_of DynamicPortBinding::InputWriter, accessor
                    assert_equal m, accessor.port_binding
                end

                it "passes the policy to the writer object" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: false, port_resolver: nil)
                    accessor = m.to_data_accessor(type: :buffer, size: 20)
                    assert_equal({ type: :buffer, size: 20 }, accessor.policy)
                end
            end

            describe "#to_bound_data_accessor" do
                it "creates a bound reader if the port is an output" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: true, port_resolver: nil)
                    component_m = flexmock
                    accessor = m.to_bound_data_accessor("name", component_m)
                    assert_kind_of DynamicPortBinding::BoundOutputReader, accessor
                    assert_equal "name", accessor.name
                    assert_equal component_m, accessor.component_model
                    assert_equal m, accessor.port_binding
                end

                it "passes the policy to the reader object" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: true, port_resolver: nil)
                    accessor = m.to_bound_data_accessor(
                        "name", flexmock, type: :buffer, size: 20
                    )
                    assert_equal({ type: :buffer, size: 20 }, accessor.policy)
                end

                it "creates a bound writer if the port is an input" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: false, port_resolver: nil)
                    component_m = flexmock
                    accessor = m.to_bound_data_accessor("test", component_m)
                    assert_kind_of DynamicPortBinding::BoundInputWriter, accessor
                    assert_equal "test", accessor.name
                    assert_equal component_m, accessor.component_model
                    assert_equal m, accessor.port_binding
                end

                it "passes the policy to the writer object" do
                    m = DynamicPortBinding.new(flexmock, flexmock,
                                               output: false, port_resolver: nil)
                    accessor = m.to_bound_data_accessor(
                        "name", flexmock, type: :buffer, size: 20
                    )
                    assert_equal({ type: :buffer, size: 20 }, accessor.policy)
                end
            end

            describe "#create_from_component_port" do
                before do
                    @task_m = task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    @cmp_m = Syskit::Composition.new_submodel { add task_m, as: "test" }

                    @cmp = syskit_stub_and_deploy(@cmp_m, remote_task: false)
                end

                it "is used for a plain component port" do
                    flexmock(DynamicPortBinding)
                        .should_receive(:create_from_component_port)
                        .with(@task_m.out_port).once.and_return(ret = flexmock)
                    assert_equal ret, Models::DynamicPortBinding.create(@task_m.out_port)
                end

                it "is used for a component child port" do
                    flexmock(DynamicPortBinding)
                        .should_receive(:create_from_component_port)
                        .with(@cmp.test_child.out_port).once.and_return(ret = flexmock)
                    assert_equal(
                        ret, Models::DynamicPortBinding.create(@cmp.test_child.out_port)
                    )
                end

                it "sets the type" do
                    port_binding_m =
                        Models::DynamicPortBinding
                        .create_from_component_port(@cmp_m.test_child.out_port)
                    assert_equal port_binding_m.type, @cmp_m.test_child.out_port.type
                end

                it "sets the direction to output" do
                    port_binding_m =
                        Models::DynamicPortBinding
                        .create_from_component_port(@cmp_m.test_child.out_port)
                    assert port_binding_m.output?
                end

                it "sets the direction to input" do
                    port_binding_m =
                        Models::DynamicPortBinding
                        .create_from_component_port(@cmp_m.test_child.in_port)
                    refute port_binding_m.output?
                end
            end

            describe DynamicPortBinding::ValueResolver do
                it "responds to __reader and __resolver" do
                    registry = Typelib::CXXRegistry.new
                    type = registry.create_compound "/C" do |c|
                        c.field = "/int"
                    end
                    resolver = make_resolver(type)
                    assert_respond_to resolver, :__reader
                    assert_respond_to resolver, :__resolve
                    assert_respond_to resolver.field, :__reader
                    assert_respond_to resolver.field, :__resolve
                end
            end

            describe "the data reader subfield resolution" do
                before do
                    @registry = Typelib::CXXRegistry.new
                end

                describe "from a compound type" do
                    before do
                        @type = @registry.create_compound "/C" do |c|
                            c.field = "/int"
                        end
                        @resolver = make_resolver(@type)
                    end

                    it "responds to a field name" do
                        assert @resolver.respond_to?(:field)
                    end

                    it "does not respond to []" do
                        refute @resolver.respond_to?(:[])
                    end

                    it "does not respond to other methods" do
                        refute @resolver.respond_to?(:something)
                    end

                    it "creates a resolver for a field of a compound" do
                        s = @type.new(field: 20)
                        assert_equal 20, @resolver.field.__resolve(s)
                    end

                    it "raises NoMethodError if trying to access a field that does not "\
                    "exist" do
                        e = assert_raises(NoMethodError) do
                            @resolver.does_not_exist
                        end
                        assert_equal :does_not_exist, e.name
                    end

                    it "raises if attempting to pass positional arguments to a field" do
                        assert_raises(ArgumentError) do
                            @resolver.field(10)
                        end
                    end

                    it "raises if attempting to pass keyword arguments to a field" do
                        assert_raises(ArgumentError) do
                            @resolver.field(kw: 10)
                        end
                    end
                end

                describe "from an array" do
                    before do
                        @type = @registry.create_compound "/C" do |c|
                            c.field = "/int[10]"
                        end
                        @resolver = make_resolver(@type)
                    end

                    it "responds to []" do
                        assert @resolver.field.respond_to?(:[])
                    end

                    it "does not respond to other methods" do
                        refute @resolver.field.respond_to?(:something)
                    end

                    it "raises if trying to access another method than []" do
                        e = assert_raises(NoMethodError) do
                            @resolver.field.something
                        end
                        assert_equal :something, e.name
                    end

                    it "creates a resolver for an element" do
                        v = @type.new
                        v.field[5] = 42
                        assert_equal 42, @resolver.field[5].__resolve(v)
                    end

                    it "validates the index when accessing an array" do
                        assert_raises(ArgumentError) do
                            @resolver.field[10]
                        end
                    end

                    it "raises if attempting to not pass the index" do
                        assert_raises(ArgumentError) do
                            @resolver.field[]
                        end
                    end

                    it "raises if attempting to pass a value that is not an integer" do
                        assert_raises(TypeError) do
                            @resolver.field["some"]
                        end
                    end

                    it "raises if attempting to pass more than one positional argument" do
                        assert_raises(ArgumentError) do
                            @resolver.field[1, 2]
                        end
                    end

                    it "raises if attempting to pass keyword arguments" do
                        assert_raises(ArgumentError) do
                            @resolver.field[kw: 10]
                        end
                    end
                end

                describe "from a container" do
                    before do
                        @type = @registry.create_container "/std/vector", "/int"
                        @resolver = make_resolver(@type)
                    end

                    it "responds to []" do
                        assert @resolver.respond_to?(:[])
                    end

                    it "does not respond to other methods" do
                        refute @resolver.respond_to?(:something)
                    end

                    it "creates a resolver for an element" do
                        v = @type.new
                        v << 1 << 42 << 5
                        assert_equal 42, @resolver[1].__resolve(v)
                    end

                    it "raises if attempting to access another method than []" do
                        e = assert_raises(NoMethodError) do
                            @resolver.somethingsomething
                        end
                        assert_equal :somethingsomething, e.name
                    end

                    it "raises if attempting to not pass the index" do
                        assert_raises(ArgumentError) do
                            @resolver[]
                        end
                    end

                    it "raises if attempting to pass a value that is not an integer" do
                        assert_raises(TypeError) do
                            @resolver["some"]
                        end
                    end

                    it "raises if attempting to pass more than one positional argument" do
                        assert_raises(ArgumentError) do
                            @resolver[1, 2]
                        end
                    end

                    it "raises if attempting to pass keyword arguments" do
                        assert_raises(ArgumentError) do
                            @resolver[kw: 10]
                        end
                    end
                end

                it "resolves sub-sub-values" do
                    a_t = @registry.create_compound "/A" do |a|
                        a.field = "/int[10]"
                    end
                    vector_a_t = @registry.create_container "/std/vector", a_t
                    b_t = @registry.create_compound "/B" do |b|
                        b.field = vector_a_t
                    end

                    r = make_resolver(b_t)
                    a = a_t.new
                    a.field[5] = 42
                    b = b_t.new(field: [a_t.new, a])
                    assert_equal 42, r.field[1].field[5].__resolve(b)
                end

                describe "transform" do
                    before do
                        @type = @registry.create_compound "/C" do |c|
                            c.field = "/int"
                        end
                        @resolver = make_resolver(@type)
                    end

                    it "accepts an arbitrary transformation in the form of a block" do
                        v = @type.new(field: 20)
                        assert_equal 20, @resolver.transform(&:field).__resolve(v)
                    end

                    it "accepts an arbitrary transformation in sub-fields" do
                        resolver = @resolver.field.transform { |v| v * 2 }
                        v = @type.new(field: 20)
                        assert_equal 40, resolver.__resolve(v)
                    end

                    it "returns a new resolver" do
                        parent = @resolver.field
                        transformed = parent.transform { |v| v * 2 }
                        v = @type.new(field: 20)
                        assert_equal 20, parent.__resolve(v)
                        assert_equal 40, transformed.__resolve(v)
                    end

                    it "raises if trying to add two transformations" do
                        @resolver.transform { |v| v * 2 }
                        e = assert_raises(ArgumentError) do
                            @resolver.transform { |v| v * 2 }.transform { |v| v + 2 }
                        end
                        assert_equal "this resolver already has a transform block",
                                     e.message
                    end

                    it "raises if trying to access a subfield after "\
                       "a transform block is set" do
                        resolver = @resolver.transform(&:field)
                        e = assert_raises(ArgumentError) do
                            resolver.field
                        end
                        assert_equal "cannot refine a resolver on which "\
                                     ".transform has been called", e.message
                    end
                end

                it "can directly be used as resolver" do
                    struct_m = @registry.create_compound "/C" do |c|
                        c.field = "/int"
                    end
                    r = make_resolver(struct_m)

                    s = struct_m.new(field: 20)
                    assert_equal s, r.__resolve(s)
                end
            end

            def make_resolver(type)
                app.default_loader.register_type_model(type)

                srv_m = Syskit::DataService.new_submodel do
                    output_port "out", type
                end
                DynamicPortBinding.create_from_matcher(srv_m.match.out_port)
                                  .to_data_accessor
            end
        end
    end
end
