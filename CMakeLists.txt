PROJECT(rasguard-corba)

ADD_DEFINITIONS(-D_REENTRANT)

INCLUDE_DIRECTORIES(${CMAKE_CURRENT_BINARY_DIR})

MACRO(TAO_ORB)
    INCLUDE_DIRECTORIES(/usr/include/orbsvcs)
    FILE(GLOB IDL_FILES *.idl)
    FOREACH(idl_file ${IDL_FILES})
        FILE(RELATIVE_PATH idl_file ${CMAKE_CURRENT_SOURCE_DIR} ${idl_file})
        SET(CORBA_CLIENT_HDRS "C.h;C.inl;S.h;S.inl;S_T.h;S_T.inl")
        SET(CORBA_CLIENT_IMPL "C.cpp;S.cpp;S_T.cpp")

        STRING(REGEX REPLACE ".idl$" "C.h"   hdr_file ${idl_file})
        STRING(REGEX REPLACE ".idl$" "C.inl" inl_file ${idl_file})
        STRING(REGEX REPLACE ".idl$" "C.cpp" cpp_file ${idl_file})
        SET(client_hdr "${hdr_file};${inl_file}")
        SET(client_imp ${cpp_file})

        LIST(APPEND ORB_IDL_FILES ${client_imp})
        add_custom_command(OUTPUT ${client_hdr} ${client_imp}
            COMMAND tao_idl -Gt -Gd ${CMAKE_CURRENT_SOURCE_DIR}/${idl_file} -I${CMAKE_CURRENT_SOURCE_DIR}
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/${idl_file})
    ENDFOREACH(idl_file ${IDL_FILES})

    SET(ORB_LIBRARIES /usr/lib/libTAO.so /usr/lib/libTAO_CosNaming.so)
ENDMACRO(TAO_ORB)

TAO_ORB()
ADD_EXECUTABLE(corba_test corba_access.cc main.cpp ${ORB_IDL_FILES})
TARGET_LINK_LIBRARIES(corba_test ${ORB_LIBRARIES})

