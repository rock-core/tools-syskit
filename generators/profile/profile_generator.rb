require 'roby/app/gen'
class ProfileGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = 'profiles'
        super
    end
end

