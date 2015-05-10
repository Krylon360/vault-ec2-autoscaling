# vault-ec2-autoscaling

Experiments in deploying [Hashicorp Vault](https://vaultproject.io/) with AWS
EC2 and Auto Scaling.

See the
[docs/](https://github.com/tonyhburns/vault-ec2-autoscaling/tree/master/docs)
directory and [issue
tracker](https://github.com/tonyhburns/vault-ec2-autoscaling/issues) for
documentation and ideas.

## Requirements

* An [AWS account](http://aws.amazon.com)
* [Ansible](http://docs.ansible.com/intro_installation.html) 1.9+
* [Packer](https://www.packer.io/downloads.html) 0.7+
* [Ruby](https://www.ruby-lang.org/en/downloads/) 2.2+
* [Terraform](https://terraform.io/downloads.html) 0.5+

## Warning about AWS charges

Running the proof of concept in this repository will not entirely fall under the
[aws free tier](http://aws.amazon.com/free/). **You are responsible for all
charges incurred.**

## Getting started

Run the following command to set up development dependencies:

```console
$ ./bin/setup
```

I recommend that you use [direnv](http://direnv.net/) to set up the environment
variables needed to run the provisioning scripts, tests, and orchestration tasks
in this repository. An example `.envrc` file is included in
[.envrc.example](https://github.com/tonyhburns/vault-ec2-autoscaling/blob/master/.envrc.example).

## Running the proof of concept

TODO

## License

&copy; 2015 Tony Burns

Distributed under the MIT License. See `LICENSE.txt` for details.
