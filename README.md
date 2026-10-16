# BigBang Development Taskfiles

Task automation for [BigBang](https://repo1.dso.mil/big-bang/bigbang) development workflows. Provides tasks for creating k3d clusters, deploying BigBang, and running tests — locally or on an EC2 instance driven through a docker context.

## Requirements

- [go-task](https://taskfile.dev/)
- [helm](https://helm.sh/)
- [yq](https://github.com/mikefarah/yq)
- [k3d](https://k3d.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- AWS CLI (for remote development)

## Configuration

Set Registry1 credentials as environment variables:

```bash
export REGISTRY1_USERNAME=<username>
export REGISTRY1_PASSWORD=<password>
```

## Local development

Everything runs against your local docker daemon by default:

```bash
task                  # k3d cluster → BigBang → wait for ready
task package:default # k3d cluster → deploy package from CWD → tests
```

## Remote development (EC2)

`scripts/ec2-dev.sh` provisions a spot EC2 instance with docker installed
(via `scripts/cloud-config.yaml`); k3d itself always runs on your
workstation and drives the instance's docker daemon through a docker
context.

```bash
# one-time per instance: EC2 instance + ssh alias (bb-dev) + docker context (bb-dev)
task aws:ec2

# then any workflow, switched to the instance with a single variable
task default DOCKER_CONTEXT=bb-dev
task package:default DOCKER_CONTEXT=bb-dev DISABLE_CORE=true

# tear down (instance, context, dev.yaml)
task aws:ec2:destroy
```

`DOCKER_CONTEXT=bb-dev` switches the whole workflow:

- `docker`/`k3d` commands target the instance's daemon (via `DOCKER_CONTEXT`)
- volume mounts (`BASE_MOUNT_DIR`) move to `/home/ubuntu` on the instance
- host-side commands (`COMMAND_PREFIX`) run over `ssh bb-dev`
- the k3d API server is published on the instance's public IP
  (`k3d.serverHost`, read from `dev.yaml`), so the `k3d-bb-helm` kubectl
  context that k3d writes locally works from your workstation — no
  kubeconfig copying or editing

Notes:

- `task aws:ec2` writes `dev.yaml` with the instance metadata and is a
  no-op while the instance is reachable
- instances self-terminate 8 hours after boot (`sudo crontab -r` on the
  instance to disable); the security group and key pair are reused across
  instances
- rerun `task aws:ec2` after your workstation IP changes to re-authorize
  it in the security group
- instance size/disk: `INSTANCE_TYPE` and `VOLUME_SIZE` env vars for
  `scripts/ec2-dev.sh`

## Package development

Run from a package repo checkout (package is detected from the git remote):

```bash
task -t /path/to/taskfiles/Taskfile.yml package:default DISABLE_CORE=true
task -t /path/to/taskfiles/Taskfile.yml package:deploy    # deploy current branch
task -t /path/to/taskfiles/Taskfile.yml package:upgrade   # released → branch upgrade test
task -t /path/to/taskfiles/Taskfile.yml package:test      # unit + e2e tests
task -t /path/to/taskfiles/Taskfile.yml package:info      # show detected package/path/namespace
```

Common variables: `DISABLE_CORE=true`, `TEST_VALUES=tests/test-sso-values.yaml`,
`EXTRA_VALUES="--set foo=bar"`, and `DOCKER_CONTEXT=bb-dev` to run any of the
above against the EC2 instance.

## Project Structure

```
├── Taskfile.yml          # Main taskfile (deployment, package workflows)
├── taskfiles/
│   ├── aws.yml           # EC2 instance, ssh config, docker context
│   ├── base.yml          # k3d cluster creation, deploy, remote-mode vars
│   └── util.yml          # Utilities (health, readme, ...)
└── scripts/
    ├── ec2-dev.sh        # EC2 provisioning (key pair, SG, spot instance)
    └── cloud-config.yaml # Instance cloud-init (docker, kernel tuning)
```

To see all available tasks run `task --list`.
