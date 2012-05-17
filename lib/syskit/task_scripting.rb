module Orocos
    module RobyPlugin
        module TaskScripting
            module ScriptEngineExtension
                attribute(:data_readers) { Hash.new }
                attribute(:data_writers) { Hash.new }

                def initialize_copy(original)
                    super

                    @data_readers = original.data_readers.dup
                    @data_writers = original.data_writers.dup
                end

                def prepare(task)
                    super if defined? super

                    data_readers.each do |name, reader_def|
                        reader_def[1] = task.data_reader(*reader_def[0])
                    end
                    data_writers.each do |name, writer_def|
                        writer_def[1] = task.data_writer(*writer_def[0])
                        writer_def[2] = writer_def[1].new_sample
                        writer_def[2].zero!
                    end
                end

                def script_extensions(name, *args, &block)
                    catch(:no_match) { super if defined? super }
                    if !args.empty? || block
                        throw :no_match
                    end

                    case name.to_s
                    when /^(\w+)_reader$/
                        name = $1.to_sym
                        if reader = data_readers[name]
                            return reader[1]
                        else
                            raise NoMethodError, "no data reader called #{name} defined: got #{data_readers.keys.map(&:inspect).join(", ")}"
                        end

                    when /^(\w+)_writer$/
                        name = $1.to_sym
                        if writer = data_writers[name]
                            return writer[1]
                        else
                            raise NoMethodError, "has no data writer called #{name} defined: got #{data_writers.keys.map(&:inspect).join(", ")}"
                        end

                    when /^write_(\w+)$/
                        name = $1.to_sym
                        if writer = data_writers[name]
                            writer[1].write(writer[2])
                        else
                            raise NoMethodError, "no data writer called #{name} defined: got #{data_writers.keys.map(&:inspect).join(", ")}"
                        end


                    else
                        if reader = data_readers[name]
                            value = reader[1].read
                            return value
                        elsif writer = data_writers[name]
                            return writer[2]
                        else
                            throw :no_match
                        end
                    end
                end
            end

            module ScriptExtension
                def data_reader(name, path, options = Hash.new)
                    if !path.respond_to?(:to_ary)
                        path = [path]
                    end
                    if script_engine.data_writers[name.to_sym]
                        raise ArgumentError, "a writer called #{name} already exists"
                    elsif script_engine.data_readers[name.to_sym]
                        raise ArgumentError, "a reader called #{name} already exists"
                    end
                    script_engine.data_readers[name.to_sym] = [(path.dup << options), nil]
                end

                def data_writer(name, path, options = Hash.new)
                    if !path.respond_to?(:to_ary)
                        path = [path]
                    end
                    if script_engine.data_writers[name.to_sym]
                        raise ArgumentError, "a writer called #{name} already exists"
                    elsif script_engine.data_readers[name.to_sym]
                        raise ArgumentError, "a reader called #{name} already exists"
                    end
                    script_engine.data_writers[name.to_sym] = [(path.dup << options), nil]
                end
            end
            Roby::TaskScripting::ScriptEngine.include ScriptEngineExtension
            Roby::TaskScripting::Script.include ScriptExtension
        end
    end
end

