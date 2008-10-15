= Orocos.rb: Ruby bindings to access Orocos modules

Orocos.rb is a Ruby library which allows to access, read out and control Orocos RTT
(http://www.orocos.org) components. It uses the CORBA transport of Orocos for that,
so you need to have the CORBA library installed, as well as the rtt-corba library.

== Installation

This package requires the following dependencies:
* Orocos/RTT with built-in CORBA transport. For now, you need to use OmniORB4 instead
  of TAO.
* the CORBA development tools (IDL compiler and header files)
* utilrb (available as a gem, see http://utilrb.rubyforge.org)
* rake (available as a gem, see http://rake.rubyforge.org)

To build the C extension which allows to connect to Orocos modules, do
  rake setup

