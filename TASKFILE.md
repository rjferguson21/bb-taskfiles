# Taskfile Dev

Taskfile to automate dev tasks. To see available tasks run `task --list`

## Requirements

- [yq](https://github.com/mikefarah/yq)
- [go-task](https://taskfile.dev/)
- [helm](https://helm.sh/)

## Quickstart (uses EC2 instance)

```sh
# creates ec2 instance, ssh config entry (bb-dev), and docker context (bb-dev)
task aws:ec2

# creates k3d cluster on the instance, deploys bigbang, runs helm tests;
# DOCKER_CONTEXT=bb-dev also derives BASE_MOUNT_DIR, COMMAND_PREFIX, and the
# kubeconfig server address (from dev.yaml) — no other vars needed
task default DOCKER_CONTEXT=bb-dev

# destroy the instance, docker context, and dev.yaml
task aws:ec2:destroy
```

## Deploy BigBang using local machine

```sh
# creates k3d cluster, deploys bigbang, runs helm tests
task
```
