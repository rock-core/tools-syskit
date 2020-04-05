# frozen_string_literal: true

require 'syskit/test/self'

module Syskit
    module Models
        describe DynamicDataSource do
            before do
                @registry = Typelib::CXXRegistry.new
            end

            describe 'from a compound type' do
                before do
                    @type = @registry.create_compound '/C' do |c|
                        c.field = '/int'
                    end
                    @resolver = make_resolver(@type)
                end

                it 'responds to a field name' do
                    assert @resolver.respond_to?(:field)
                end

                it 'does not respond to []' do
                    refute @resolver.respond_to?(:[])
                end

                it 'does not respond to other methods' do
                    refute @resolver.respond_to?(:something)
                end

                it 'creates a resolver for a field of a compound' do
                    s = @type.new(field: 20)
                    assert_equal 20, @resolver.field.__resolve(s)
                end

                it 'raises NoMethodError if trying to access a field that does not '\
                   'exist' do
                    e = assert_raises(NoMethodError) do
                        @resolver.does_not_exist
                    end
                    assert_equal :does_not_exist, e.name
                end

                it 'raises if attempting to pass positional arguments to a field' do
                    assert_raises(ArgumentError) do
                        @resolver.field(10)
                    end
                end

                it 'raises if attempting to pass keyword arguments to a field' do
                    assert_raises(ArgumentError) do
                        @resolver.field(kw: 10)
                    end
                end
            end

            describe 'from an array' do
                before do
                    @type = @registry.create_compound '/C' do |c|
                        c.field = '/int[10]'
                    end
                    @resolver = make_resolver(@type)
                end

                it 'responds to []' do
                    assert @resolver.field.respond_to?(:[])
                end

                it 'does not respond to other methods' do
                    refute @resolver.field.respond_to?(:something)
                end

                it 'raises if trying to access another method than []' do
                    e = assert_raises(NoMethodError) do
                        @resolver.field.something
                    end
                    assert_equal :something, e.name
                end

                it 'creates a resolver for an element' do
                    v = @type.new
                    v.field[5] = 42
                    assert_equal 42, @resolver.field[5].__resolve(v)
                end

                it 'validates the index when accessing an array' do
                    assert_raises(ArgumentError) do
                        @resolver.field[10]
                    end
                end

                it 'raises if attempting to not pass the index' do
                    assert_raises(ArgumentError) do
                        @resolver.field[]
                    end
                end

                it 'raises if attempting to pass a value that is not an integer' do
                    assert_raises(TypeError) do
                        @resolver.field['some']
                    end
                end

                it 'raises if attempting to pass more than one positional argument' do
                    assert_raises(ArgumentError) do
                        @resolver.field[1, 2]
                    end
                end

                it 'raises if attempting to pass keyword arguments' do
                    assert_raises(ArgumentError) do
                        @resolver.field[kw: 10]
                    end
                end
            end

            describe 'from a container' do
                before do
                    @type = @registry.create_container '/std/vector', '/int'
                    @resolver = make_resolver(@type)
                end

                it 'responds to []' do
                    assert @resolver.respond_to?(:[])
                end

                it 'does not respond to other methods' do
                    refute @resolver.respond_to?(:something)
                end

                it 'creates a resolver for an element' do
                    v = @type.new
                    v << 1 << 42 << 5
                    assert_equal 42, @resolver[1].__resolve(v)
                end

                it 'raises if attempting to access another method than []' do
                    e = assert_raises(NoMethodError) do
                        @resolver.somethingsomething
                    end
                    assert_equal :somethingsomething, e.name
                end

                it 'raises if attempting to not pass the index' do
                    assert_raises(ArgumentError) do
                        @resolver[]
                    end
                end

                it 'raises if attempting to pass a value that is not an integer' do
                    assert_raises(TypeError) do
                        @resolver['some']
                    end
                end

                it 'raises if attempting to pass more than one positional argument' do
                    assert_raises(ArgumentError) do
                        @resolver[1, 2]
                    end
                end

                it 'raises if attempting to pass keyword arguments' do
                    assert_raises(ArgumentError) do
                        @resolver[kw: 10]
                    end
                end
            end

            it 'resolves sub-sub-values' do
                a_t = @registry.create_compound '/A' do |a|
                    a.field = '/int[10]'
                end
                vector_a_t = @registry.create_container '/std/vector', a_t
                b_t = @registry.create_compound '/B' do |b|
                    b.field = vector_a_t
                end

                r = make_resolver(b_t)
                a = a_t.new
                a.field[5] = 42
                b = b_t.new(field: [a_t.new, a])
                assert_equal 42, r.field[1].field[5].__resolve(b)
            end

            describe 'transform' do
                before do
                    @type = @registry.create_compound '/C' do |c|
                        c.field = '/int'
                    end
                    @resolver = make_resolver(@type)
                end

                it 'accepts an arbitrary transformation in the form of a block' do
                    v = @type.new(field: 20)
                    assert_equal 20, @resolver.transform(&:field).__resolve(v)
                end

                it 'accepts an arbitrary transformation in sub-fields' do
                    resolver = @resolver.field.transform { |v| v * 2 }
                    v = @type.new(field: 20)
                    assert_equal 40, resolver.__resolve(v)
                end

                it 'raises if trying to add two transformations' do
                    @resolver.transform { |v| v * 2 }
                    e = assert_raises(ArgumentError) do
                        @resolver.transform { |v| v * 2 }
                    end
                    assert_equal 'this resolver already has a transform block', e.message
                end

                it 'raises if trying to access a subfield after '\
                   'a transform block is set' do
                    @resolver.transform(&:field)
                    e = assert_raises(ArgumentError) do
                        @resolver.field
                    end
                    assert_equal 'cannot refine a resolver once .transform '\
                                 'has been called', e.message
                end
            end

            it 'can directly used as resolver' do
                struct_m = @registry.create_compound '/C' do |c|
                    c.field = '/int'
                end
                r = make_resolver(struct_m)

                s = struct_m.new(field: 20)
                assert_equal s, r.__resolve(s)
            end

            def make_resolver(type)
                app.default_loader.register_type_model(type)

                srv_m = Syskit::DataService.new_submodel do
                    output_port 'out', type
                end
                DynamicDataSource.create(srv_m.match.out_port)
            end
        end
    end
end
