#include "controltask.hpp"
#include <iostream>

int main(int argc, char** argv)
{
    CorbaAccess::InitOrb(argc, argv);
    try {
        list<string> names = CorbaAccess::knownTasks();
        for (list<string>::iterator it = names.begin(); it != names.end(); ++it)
        {
            std::cout << CorbaAccess::findByName(*it).in()->getTaskState() << std::endl;
        }

    } catch(...) {
        CorbaAccess::DestroyOrb();
        throw;
    }
    CorbaAccess::DestroyOrb();
}

