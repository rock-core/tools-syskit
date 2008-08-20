PROJECT(rasguard-corba)

ADD_DEFINITIONS(-D_REENTRANT)

INCLUDE_DIRECTORIES(${CMAKE_CURRENT_BINARY_DIR})
FILE(GLOB IDL_FILES *.idl)
FOREACH(idl_file ${IDL_FILES})
    FILE(RELATIVE_PATH idl_file ${CMAKE_CURRENT_SOURCE_DIR} ${idl_file})
    STRING(REGEX REPLACE ".idl$" ".hh"      hh_file  ${idl_file})
    STRING(REGEX REPLACE ".idl$" "SK.cc"    stub     ${idl_file})
    STRING(REGEX REPLACE ".idl$" "DynSK.cc" typecode ${idl_file})
    LIST(APPEND CORBA_CODE ${CMAKE_CURRENT_BINARY_DIR}/${stub} ${CMAKE_CURRENT_BINARY_DIR}/${typecode})
    add_custom_command(OUTPUT
        ${CMAKE_CURRENT_BINARY_DIR}/${hh_file}
        ${CMAKE_CURRENT_BINARY_DIR}/${stub}
        ${CMAKE_CURRENT_BINARY_DIR}/${typecode}
        COMMAND omniidl -bcxx -Wba ${CMAKE_CURRENT_SOURCE_DIR}/${idl_file}
        MAIN_DEPENDENCY ${CMAKE_CURRENT_SOURCE_DIR}/${idl_file})
    MESSAGE(${CORBA_CODE})
ENDFOREACH(idl_file ${IDL_FILES})

ADD_EXECUTABLE(corba_test corba_access.cc main.cpp ${CORBA_CODE})
TARGET_LINK_LIBRARIES(corba_test /usr/lib/libomniORB4.so /usr/lib/libomniDynamic4.so)

