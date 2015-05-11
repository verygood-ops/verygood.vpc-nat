VPC NAT
=========

Creates PAT for a NAT.

Assumes that the NAT box is running on AWS and is generated using the Very Good NAT Stack. Quite brittle without that.

Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: nat
      roles:
         - { role: verygood.vpc-nat }

License
-------

BSD

Author Information
------------------

Very Good Group
