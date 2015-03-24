require 'roby/app/gen'
class DevGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = 'devices'
        super
    end

    def has_test?; false end
end

