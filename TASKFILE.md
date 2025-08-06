# Taskfile Dev

Taskfile to automate dev tasks. To see available tasks run `task --list`

## Requirements
- [yq](https://github.com/mikefarah/yq)
- [go-task](https://taskfile.dev/)
- [helm](https://helm.sh/)

## Quickstart (uses EC2 instance via k3d-dev.sh)
```sh
# creates ec2 instance, creates k3d cluster on instance, deploys bigbang, runs helm tests
task
```

## Deploy BigBang using local machine
```sh
# creates k3d cluster, deploys bigbang, runs helm tests
task localdev COMMAND_PREFIX="" DOCKER_HOST=""
```