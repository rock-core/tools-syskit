#ifndef EXEC_CLIENT_CONTROL_TASK_HPP
#define EXEC_CLIENT_CONTROL_TASK_HPP

#include <omniORB4/CORBA.h>
#include <exception>
#include "ControlTask.hh"
#include <iostream>
#include <string>
#include <stack>
#include <list>

using namespace std;

/**
 * Thrown if a server does not exist or has the wrong type.
 */
struct IllegalServer 
    : public std::exception
{
    std::string reason;
    IllegalServer();
    ~IllegalServer() throw();
    const char* what() const throw();
};

/**
 * This class locates and connects to a Corba ControlTask.
 * It can do that through an IOR or through the NameService.
 */
class CorbaAccess
{
    static CORBA::ORB_var orb;
    static CosNaming::NamingContext_var rootContext;

public:
    static bool           InitOrb(int argc, char* argv[] );
    static void           DestroyOrb();
    static CORBA::ORB_var getOrb();
    static CosNaming::NamingContext_var getRootContext();
    static std::list<std::string> knownTasks();
    static RTT::Corba::ControlTask_var findByName(std::string const& name);
};

#endif

