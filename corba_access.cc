#include "corba_access.hh"
#include <list>
using namespace CORBA;
using namespace std;

CORBA::ORB_var               CorbaAccess::orb;
CosNaming::NamingContext_var CorbaAccess::rootContext;

IllegalServer::IllegalServer() : reason("This server does not exist or has the wrong type.") {}

IllegalServer::~IllegalServer() throw() {}

const char* IllegalServer::what() const throw() { return reason.c_str(); }

bool CorbaAccess::InitOrb(int argc, char* argv[] ) {
    if (!CORBA::is_nil(orb))
        return false;

    try {
        // First initialize the ORB, that will remove some arguments...
        orb = CORBA::ORB_init (argc, const_cast<char**>(argv), "omniORB4");

        CORBA::Object_var rootObj = orb->resolve_initial_references("NameService");
        rootContext = CosNaming::NamingContext::_narrow(rootObj.in());
        if (CORBA::is_nil(rootObj.in() )) {
            cerr << "CorbaAccess could not acquire NameService."<<endl;
            throw IllegalServer();
        }
        cout << "found CORBA NameService."<<endl;

        // Also activate the POA Manager, since we may get call-backs !
#if 0
        CORBA::Object_var poa_object =
            orb->resolve_initial_references ("RootPOA");
        PortableServer::POA_var poa =
            PortableServer::POA::_narrow (poa_object.in ());
        PortableServer::POAManager_var poa_manager =
            poa->the_POAManager ();
        poa_manager->activate ();
#endif
        return true;
    }
    catch (CORBA::Exception &e) {
        cerr << "Orb Init : CORBA exception raised!" << endl;
        cerr << e._name() << endl;
    }
    return false;
}

void CorbaAccess::DestroyOrb()
{
    try {
        // Destroy the POA, waiting until the destruction terminates
        //poa->destroy (1, 1);
        rootContext->destroy();
        orb->destroy();
        std::cerr <<"Orb destroyed."<<std::endl;
    }
    catch (CORBA::Exception &e) {
        cerr << "Orb destruction : CORBA exception raised!" << endl;
        cerr << e._name() << endl;
    }
}

CORBA::ORB_var               CorbaAccess::getOrb() { return orb; }
CosNaming::NamingContext_var CorbaAccess::getRootContext() { return rootContext; }

list<string> CorbaAccess::knownTasks()
{
    // NameService

    CosNaming::Name serverName;
    serverName.length(1);
    serverName[0].id = CORBA::string_dup("ControlTasks");

    list<string> names;
    try {
        CORBA::Object_var control_tasks_var = rootContext->resolve(serverName);
        CosNaming::NamingContext_var control_tasks = CosNaming::NamingContext::_narrow (control_tasks_var.in ());

        CosNaming::BindingList_var binding_list;
        CosNaming::BindingIterator_var binding_it;
        control_tasks->list(0, binding_list, binding_it);

        while(binding_it->next_n(10, binding_list))
        {
            for (int i = 0; i < binding_list.in().length(); ++i)
                names.push_back(binding_list.in()[i].binding_name[0].id.in());
        }
    } catch(CosNaming::NamingContext::NotFound) { }

    return names;
}

RTT::Corba::ControlTask_var CorbaAccess::findByName(std::string const& name)
{
    try {
        CosNaming::Name serverName;
        serverName.length(2);
        serverName[0].id = CORBA::string_dup("ControlTasks");
        serverName[1].id = CORBA::string_dup( name.c_str() );

        // Get object reference
        CORBA::Object_var task_object = rootContext->resolve(serverName);
        RTT::Corba::ControlTask_var mtask = RTT::Corba::ControlTask::_narrow (task_object.in ());
        if ( CORBA::is_nil( mtask.in() ) ) {
            cerr << "Failed to acquire ControlTaskServer '"+name+"'."<<endl;
            throw IllegalServer();
        }
        CORBA::String_var nm = mtask->getName(); // force connect to object.
        cout << "Successfully connected to ControlTaskServer '" << nm << "'." <<endl;
        return mtask;
    }
    catch (CORBA::Exception &e) {
        cerr<< "CORBA exception raised when resolving Object !" << endl;
        cerr << e._name() << endl;
        throw IllegalServer();
    }
    catch (...) {
        cerr <<"Unknown Exception in CorbaAccess construction!"<<endl;
        throw;
    }
}

