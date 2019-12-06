# Run tests in test/ using Syskit
#
# If test/ has a bundle/ folder, the tests are run within this bundle's context.
# Otherwise, a new temporary bundle is generated and tests are run there in live
# mode
function(syskit_orogen_tests NAME)
    set(workdir ${CMAKE_CURRENT_BINARY_DIR})
    set(mode FILES)
    foreach(arg ${ARGN})
        if (arg STREQUAL "FILES")
            set(mode FILES)
        elseif (arg STREQUAL "WORKING_DIRECTORY")
            set(mode WORKING_DIRECTORY)
        elseif (mode STREQUAL "WORKING_DIRECTORY")
            set(workdir "${arg}")
            set(mode "")
        elseif (mode STREQUAL "FILES")
            list(APPEND test_args "${arg}")
        else()
            message(FATAL_ERROR "trailing arguments ${arg} to syskit_orogen_tests")
        endif()
    endforeach()

    list(LENGTH test_args has_test_args)
    if (NOT has_test_args)
        if (IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/test)
            list(APPEND test_args "${CMAKE_CURRENT_SOURCE_DIR}/test")
        else()
            message(FATAL_ERROR "syskit_orogen_tests: called without test files, and there is no test/ folder")
        endif()
    endif()


    foreach(test_arg ${test_args})
        if (IS_DIRECTORY ${test_arg})
            file(GLOB_RECURSE dir_testfiles "${test_arg}/*_test.rb")
            list(LENGTH dir_testfiles dir_testfiles_length)
            message(STATUS "syskit_orogen_tests: adding ${dir_testfiles_length} test files from ${test_arg} to ${NAME}")
            list(APPEND testfiles ${dir_testfiles})
        else()
            list(APPEND testfiles ${test_arg})
        endif()
    endforeach()

    if (ROCK_TEST_LOG_DIR)
        file(MAKE_DIRECTORY ${ROCK_TEST_LOG_DIR})
        list(APPEND __minitest_args
            --junit
            --junit-filename=${ROCK_TEST_LOG_DIR}/report.junit.xml
            --junit-jenkins
        )
    endif()

    add_test(
        NAME ${NAME}
        COMMAND syskit orogen-test ${testfiles} --workdir ${workdir}/bundle
                       -- ${__minitest_args}
    )
endfunction()
