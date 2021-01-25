module Orocos
    module RemoteProcesses
        DEFAULT_PORT = 20202

        COMMAND_GET_INFO   = "I"
        COMMAND_GET_PID    = "D"
        COMMAND_MOVE_LOG   = "L"
        COMMAND_CREATE_LOG = "C"
        COMMAND_START      = "S"
        COMMAND_END        = "E"
        COMMAND_QUIT       = "Q"
        COMMAND_UPLOAD_LOG = "U"

        EVENT_DEAD_PROCESS = "D"
        RET_STARTED_PROCESS = "P"
        RET_YES = "Y"
        RET_NO  = "N"
    end
end
